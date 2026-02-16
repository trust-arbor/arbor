defmodule Arbor.Orchestrator.Engine.Executor do
  @moduledoc """
  Execution and retry logic for the pipeline engine.

  Handles node execution with configurable retry policies, backoff strategies,
  and exception-based retry decisions.
  """

  alias Arbor.Orchestrator.Engine.{Authorization, Outcome}
  alias Arbor.Orchestrator.Handlers.Registry

  import Arbor.Orchestrator.Handlers.Helpers

  # --- Execution with retry ---

  @doc false
  def execute_with_retry(node, context, graph, retries, opts) do
    handler = Registry.resolve(node)
    max_attempts = parse_max_attempts(node, graph)
    current_retry_count = parse_int(Map.get(retries, node.id, 0), 0)

    do_execute_with_retry(
      handler,
      node,
      context,
      graph,
      retries,
      opts,
      current_retry_count + 1,
      max_attempts
    )
  end

  defp do_execute_with_retry(handler, node, context, graph, retries, opts, attempt, max_attempts) do
    try do
      outcome = Authorization.authorize_and_execute(handler, node, context, graph, opts)

      case outcome.status do
        status when status in [:success, :partial_success] ->
          duration_ms =
            System.monotonic_time(:millisecond) - Keyword.get(opts, :stage_started_at, 0)

          emit(opts, %{
            type: :stage_completed,
            node_id: node.id,
            status: status,
            duration_ms: duration_ms
          })

          {outcome, Map.delete(retries, node.id)}

        status when status in [:retry, :fail] ->
          if attempt < max_attempts do
            delay = retry_delay_ms(node, graph, attempt, opts)

            if status == :fail do
              emit(opts, %{
                type: :stage_failed,
                node_id: node.id,
                error: outcome.failure_reason || "stage failed",
                will_retry: true
              })
            end

            emit(opts, %{
              type: :stage_retrying,
              node_id: node.id,
              attempt: attempt,
              delay_ms: delay
            })

            sleep(opts, delay)

            retries = Map.put(retries, node.id, attempt)

            do_execute_with_retry(
              handler,
              node,
              context,
              graph,
              retries,
              opts,
              attempt + 1,
              max_attempts
            )
          else
            terminal_outcome =
              case status do
                :retry ->
                  if truthy?(Map.get(node.attrs, "allow_partial", false)) do
                    %Outcome{
                      status: :partial_success,
                      notes: "retries exhausted, partial accepted"
                    }
                  else
                    %Outcome{status: :fail, failure_reason: "max retries exceeded"}
                  end

                :fail ->
                  outcome
              end

            emit_stage_terminal(opts, node.id, terminal_outcome)
            {terminal_outcome, retries}
          end

        :skipped ->
          duration_ms =
            System.monotonic_time(:millisecond) - Keyword.get(opts, :stage_started_at, 0)

          emit(opts, %{
            type: :stage_completed,
            node_id: node.id,
            status: :skipped,
            duration_ms: duration_ms
          })

          {outcome, retries}
      end
    rescue
      exception ->
        if should_retry_exception?(exception) and attempt < max_attempts do
          delay = retry_delay_ms(node, graph, attempt, opts)

          emit(opts, %{
            type: :stage_failed,
            node_id: node.id,
            error: Exception.message(exception),
            will_retry: true
          })

          emit(opts, %{type: :stage_retrying, node_id: node.id, attempt: attempt, delay_ms: delay})

          sleep(opts, delay)

          retries = Map.put(retries, node.id, attempt)

          do_execute_with_retry(
            handler,
            node,
            context,
            graph,
            retries,
            opts,
            attempt + 1,
            max_attempts
          )
        else
          outcome = %Outcome{status: :fail, failure_reason: Exception.message(exception)}

          duration_ms =
            System.monotonic_time(:millisecond) - Keyword.get(opts, :stage_started_at, 0)

          emit(opts, %{
            type: :stage_failed,
            node_id: node.id,
            error: Exception.message(exception),
            will_retry: false,
            duration_ms: duration_ms
          })

          {outcome, retries}
        end
    end
  end

  defp emit_stage_terminal(opts, node_id, %Outcome{status: :fail, failure_reason: reason}) do
    duration_ms = System.monotonic_time(:millisecond) - Keyword.get(opts, :stage_started_at, 0)

    emit(opts, %{
      type: :stage_failed,
      node_id: node_id,
      error: reason,
      will_retry: false,
      duration_ms: duration_ms
    })
  end

  defp emit_stage_terminal(opts, node_id, %Outcome{status: status}) do
    duration_ms = System.monotonic_time(:millisecond) - Keyword.get(opts, :stage_started_at, 0)

    emit(opts, %{
      type: :stage_completed,
      node_id: node_id,
      status: status,
      duration_ms: duration_ms
    })
  end

  @doc false
  def should_retry_exception?(exception) do
    message =
      exception
      |> Exception.message()
      |> String.downcase()

    cond do
      String.contains?(message, "timeout") -> true
      String.contains?(message, "timed out") -> true
      String.contains?(message, "network") -> true
      String.contains?(message, "connection") -> true
      String.contains?(message, "rate limit") -> true
      String.contains?(message, "429") -> true
      String.contains?(message, "5xx") -> true
      String.contains?(message, "server error") -> true
      String.contains?(message, "401") -> false
      String.contains?(message, "403") -> false
      String.contains?(message, "400") -> false
      String.contains?(message, "validation") -> false
      true -> false
    end
  end

  # --- Retry delay and policy helpers ---

  def retry_delay_ms(node, graph, attempt, opts) do
    profile = retry_profile(node, graph)

    initial_delay =
      parse_int(Map.get(node.attrs, "retry_initial_delay_ms"), profile.initial_delay_ms)

    factor = parse_float(Map.get(node.attrs, "retry_backoff_factor"), profile.backoff_factor)
    max_delay = parse_int(Map.get(node.attrs, "retry_max_delay_ms"), profile.max_delay_ms)
    jitter? = parse_bool(Map.get(node.attrs, "retry_jitter"), profile.jitter)

    delay = trunc(initial_delay * :math.pow(factor, attempt - 1))
    delay = min(delay, max_delay)
    maybe_apply_jitter(delay, jitter?, opts)
  end

  defp maybe_apply_jitter(delay, false, _opts), do: delay
  defp maybe_apply_jitter(delay, _jitter, _opts) when delay <= 0, do: delay

  defp maybe_apply_jitter(delay, true, opts) do
    rand_fn = Keyword.get(opts, :rand_fn, &:rand.uniform/0)

    rand =
      rand_fn.()
      |> case do
        v when is_float(v) -> v
        v when is_integer(v) -> v / 1
        _ -> 0.5
      end
      |> min(1.0)
      |> max(0.0)

    jitter_factor = 0.5 + rand
    trunc(delay * jitter_factor)
  end

  def parse_max_attempts(node, graph) do
    cond do
      Map.has_key?(node.attrs, "max_retries") ->
        parse_int(Map.get(node.attrs, "max_retries"), 0) + 1

      Map.has_key?(graph.attrs, "default_max_retry") ->
        parse_int(Map.get(graph.attrs, "default_max_retry"), 0) + 1

      true ->
        retry_profile(node, graph).max_attempts
    end
  end

  defp parse_float(nil, default), do: default
  defp parse_float(value, _default) when is_float(value), do: value
  defp parse_float(value, _default) when is_integer(value), do: value / 1

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp parse_float(_, default), do: default

  defp parse_bool(nil, default), do: default
  defp parse_bool(value, _default) when is_boolean(value), do: value
  defp parse_bool("true", _default), do: true
  defp parse_bool("false", _default), do: false
  defp parse_bool(1, _default), do: true
  defp parse_bool(0, _default), do: false
  defp parse_bool(_, default), do: default

  defp retry_profile(node, graph) do
    preset_name =
      Map.get(node.attrs, "retry_policy", Map.get(graph.attrs, "retry_policy", "none"))
      |> to_string()
      |> String.downcase()

    case preset_name do
      "standard" ->
        %{
          max_attempts: 5,
          initial_delay_ms: 200,
          backoff_factor: 2.0,
          max_delay_ms: 60_000,
          jitter: true
        }

      "aggressive" ->
        %{
          max_attempts: 5,
          initial_delay_ms: 500,
          backoff_factor: 2.0,
          max_delay_ms: 60_000,
          jitter: true
        }

      "linear" ->
        %{
          max_attempts: 3,
          initial_delay_ms: 500,
          backoff_factor: 1.0,
          max_delay_ms: 60_000,
          jitter: true
        }

      "patient" ->
        %{
          max_attempts: 3,
          initial_delay_ms: 2_000,
          backoff_factor: 3.0,
          max_delay_ms: 60_000,
          jitter: true
        }

      "none" ->
        %{
          max_attempts: 1,
          initial_delay_ms: 200,
          backoff_factor: 2.0,
          max_delay_ms: 60_000,
          jitter: false
        }

      _ ->
        %{
          max_attempts: 1,
          initial_delay_ms: 200,
          backoff_factor: 2.0,
          max_delay_ms: 60_000,
          jitter: true
        }
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  defp emit(opts, event) do
    pipeline_id = Keyword.get(opts, :pipeline_id, :all)
    Arbor.Orchestrator.EventEmitter.emit(pipeline_id, event, opts)
  end

  defp sleep(opts, delay_ms) do
    sleep_fn = Keyword.get(opts, :sleep_fn, fn ms -> Process.sleep(ms) end)
    sleep_fn.(delay_ms)
  end
end
