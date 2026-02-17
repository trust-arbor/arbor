defmodule Arbor.Orchestrator.Handlers.RetryEscalateHandler do
  @moduledoc """
  Handler that tries cheaper/faster LLM models first, escalating to more
  capable ones on failure, low quality scores, or timeouts.

  Node attributes:
    - `source_key` - context key for the prompt (default: "last_response")
    - `prompt` - direct prompt text (used if source_key not found)
    - `system_prompt` - optional system prompt for LLM calls
    - `models` - comma-separated model ladder (default: "haiku,sonnet,opus")
    - `escalate_on` - comma-separated triggers: "fail", "low_score", "timeout"
      (default: "fail,timeout")
    - `score_threshold` - minimum acceptable score (default: "0.7")
    - `timeout_ms` - per-model timeout in milliseconds (default: "30000")
    - `score_key` - context key with a quality score from a previous node

  Opts:
    - `:llm_backend` - fn(prompt, opts) -> {:ok, response} | {:error, reason}
      for testability. If not provided, uses CodergenHandler's LLM pattern.
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  import Arbor.Orchestrator.Handlers.Helpers

  @default_models "haiku,sonnet,opus"
  @default_escalate_on "fail,timeout"
  @default_timeout 30_000
  @default_threshold 0.7

  @impl true
  def execute(node, context, _graph, opts) do
    prompt = resolve_prompt(node, context)

    unless prompt do
      raise "retry.escalate requires a prompt via source_key or prompt attribute"
    end

    models = parse_csv(Map.get(node.attrs, "models", @default_models))
    escalate_on = parse_csv(Map.get(node.attrs, "escalate_on", @default_escalate_on))
    timeout_ms = parse_int(Map.get(node.attrs, "timeout_ms"), @default_timeout)
    threshold = parse_float(Map.get(node.attrs, "score_threshold"), @default_threshold)
    score_key = Map.get(node.attrs, "score_key")
    system_prompt = Map.get(node.attrs, "system_prompt")
    llm_backend = Keyword.get(opts, :llm_backend)

    score = if score_key, do: parse_float(Context.get(context, score_key), nil), else: nil

    result =
      try_models(models, prompt, %{
        system_prompt: system_prompt,
        timeout_ms: timeout_ms,
        threshold: threshold,
        escalate_on: escalate_on,
        score: score,
        llm_backend: llm_backend,
        history: [],
        attempt: 0
      })

    build_outcome(result, node)
  rescue
    e ->
      %Outcome{
        status: :fail,
        failure_reason: "retry.escalate error: #{Exception.message(e)}"
      }
  end

  @impl true
  def idempotency, do: :side_effecting

  # --- Model ladder ---

  defp try_models([], _prompt, state) do
    # All models exhausted
    {:exhausted, state.history}
  end

  defp try_models([model | rest], prompt, state) do
    attempt = state.attempt + 1

    # Check low_score before calling — only on first attempt
    if state.attempt == 0 and should_escalate?(:low_score, state) and rest != [] do
      entry = %{model: model, status: "low_score", reason: "score below threshold"}
      # Skip this model and try next, but only escalate once (clear score)
      try_models(rest, prompt, %{
        state
        | history: state.history ++ [entry],
          attempt: attempt,
          score: nil
      })
    else
      case call_llm(prompt, model, state) do
        {:ok, response} ->
          entry = %{model: model, status: "success", reason: nil}
          {:success, response, model, attempt, state.history ++ [entry]}

        {:error, :timeout} ->
          entry = %{model: model, status: "timeout", reason: "exceeded #{state.timeout_ms}ms"}

          if "timeout" in state.escalate_on and rest != [] do
            try_models(rest, prompt, %{
              state
              | history: state.history ++ [entry],
                attempt: attempt
            })
          else
            {:failed, nil, model, attempt, state.history ++ [entry], "timeout"}
          end

        {:error, reason} ->
          reason_str = if is_binary(reason), do: reason, else: inspect(reason)
          entry = %{model: model, status: "fail", reason: reason_str}

          if "fail" in state.escalate_on and rest != [] do
            try_models(rest, prompt, %{
              state
              | history: state.history ++ [entry],
                attempt: attempt
            })
          else
            {:failed, nil, model, attempt, state.history ++ [entry], reason_str}
          end
      end
    end
  end

  defp should_escalate?(:low_score, state) do
    "low_score" in state.escalate_on and
      state.score != nil and
      state.threshold != nil and
      state.score < state.threshold
  end

  # --- LLM calling ---

  defp call_llm(prompt, model, state) do
    if state.llm_backend do
      call_with_timeout(
        fn ->
          state.llm_backend.(prompt, model: model, system_prompt: state.system_prompt)
        end,
        state.timeout_ms
      )
    else
      call_real_llm(prompt, model, state)
    end
  end

  defp call_with_timeout(fun, timeout) do
    task = Task.async(fn -> fun.() end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp call_real_llm(prompt, model, state) do
    if Code.ensure_loaded?(Arbor.Orchestrator.UnifiedLLM.Client) do
      request =
        struct!(Arbor.Orchestrator.UnifiedLLM.Request,
          provider: "claude_cli",
          model: model,
          messages: [apply(Arbor.Orchestrator.UnifiedLLM.Message, :user, [prompt])],
          temperature: 0.3
        )

      request =
        if state.system_prompt do
          sys = apply(Arbor.Orchestrator.UnifiedLLM.Message, :system, [state.system_prompt])
          %{request | messages: [sys | request.messages]}
        else
          request
        end

      case apply(Arbor.Orchestrator.UnifiedLLM.Client, :generate_with_tools, [request, []]) do
        {:ok, response} -> {:ok, response.content}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, "no LLM backend available"}
    end
  end

  # --- Outcome building ---

  defp build_outcome({:success, response, model, attempts, history}, node) do
    %Outcome{
      status: :success,
      notes: "Model #{model} succeeded after #{attempts} attempt(s)",
      context_updates: %{
        "last_response" => response,
        "escalate.#{node.id}.model_used" => model,
        "escalate.#{node.id}.attempts" => to_string(attempts),
        "escalate.#{node.id}.history" => Jason.encode!(history)
      }
    }
  end

  defp build_outcome({:failed, _response, model, attempts, history, reason}, node) do
    %Outcome{
      status: :fail,
      failure_reason: "All models failed. Last: #{model} (#{reason})",
      context_updates: %{
        "escalate.#{node.id}.model_used" => model,
        "escalate.#{node.id}.attempts" => to_string(attempts),
        "escalate.#{node.id}.history" => Jason.encode!(history)
      }
    }
  end

  defp build_outcome({:exhausted, history}, node) do
    %Outcome{
      status: :fail,
      failure_reason: "All models exhausted",
      context_updates: %{
        "escalate.#{node.id}.attempts" => to_string(length(history)),
        "escalate.#{node.id}.history" => Jason.encode!(history)
      }
    }
  end

  # --- Helpers ---

  defp resolve_prompt(node, context) do
    source_key = Map.get(node.attrs, "source_key", "last_response")

    Context.get(context, source_key) ||
      Map.get(node.attrs, "prompt")
  end

  defp parse_float(nil, default), do: default

  defp parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> default
    end
  end

  defp parse_float(val, _default) when is_number(val), do: val / 1
  defp parse_float(_, default), do: default
end
