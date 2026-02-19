defmodule Arbor.Orchestrator.AgentLoop.Loop do
  @moduledoc """
  Minimal coding-agent loop scaffold.

  Current scope:
  - session turn loop
  - event callback emission
  - tool call round-trip execution
  - simple repeated-output loop detection
  - unified-llm client integration through provider profiles
  """

  alias Arbor.Orchestrator.AgentLoop.{Config, Event, Session}
  alias Arbor.Orchestrator.AgentLoop.ProviderProfiles.Default, as: DefaultProfile
  alias Arbor.Orchestrator.UnifiedLLM.Client

  @type model_response ::
          %{type: :final, content: String.t()}
          | %{type: :tool_call, tool_calls: [map()], assistant_content: String.t()}

  @type model_client :: (Session.t() -> model_response() | {:error, term()})
  @type tool_executor :: (map() -> map())

  @spec run(keyword()) :: {:ok, Session.t()} | {:error, term(), Session.t()}
  def run(opts \\ []) do
    session = Session.new(opts)
    model_client = build_model_client(opts)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn call -> %{id: call[:id], content: "ok"} end)

    emit(opts, %Event{type: :session_started, session_id: session.id, turn: 0, data: %{}})
    emit(opts, %Event{type: :session_start, session_id: session.id, turn: 0, data: %{}})

    do_run(session, model_client, tool_executor, opts, [], 0)
  end

  defp build_model_client(opts) do
    case Keyword.get(opts, :model_client) do
      fun when is_function(fun, 1) ->
        fun

      _ ->
        client = Keyword.fetch!(opts, :llm_client)
        profile = Keyword.get(opts, :provider_profile, DefaultProfile)
        llm_opts = Keyword.get(opts, :llm_opts, [])

        fn session ->
          request = profile.build_request(session, Keyword.merge(opts, llm_opts))

          case Client.complete(client, request, llm_opts) do
            {:ok, response} ->
              profile.decode_response(response, session, Keyword.merge(opts, llm_opts))

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end

  defp do_run(
         %Session{turn: turn, config: %Config{max_turns: max_turns}} = session,
         _client,
         _tool_exec,
         opts,
         _assistant_window,
         _round_count
       )
       when max_turns > 0 and turn >= max_turns do
    failed = %{session | status: :failed, result: %{reason: :max_turns_exceeded}}

    emit(opts, %Event{
      type: :turn_limit,
      session_id: session.id,
      turn: turn,
      data: %{reason: :max_turns_exceeded}
    })

    emit(opts, %Event{
      type: :session_failed,
      session_id: session.id,
      turn: turn,
      data: %{reason: :max_turns_exceeded}
    })

    emit(opts, %Event{
      type: :error,
      session_id: session.id,
      turn: turn,
      data: %{reason: :max_turns_exceeded}
    })

    emit(opts, %Event{
      type: :session_end,
      session_id: session.id,
      turn: turn,
      data: %{status: :failed, reason: :max_turns_exceeded}
    })

    {:error, :max_turns_exceeded, failed}
  end

  defp do_run(
         %Session{config: %Config{max_tool_rounds: max_tool_rounds}} = session,
         _model_client,
         _tool_executor,
         opts,
         _assistant_window,
         round_count
       )
       when max_tool_rounds > 0 and round_count >= max_tool_rounds do
    failed = %{session | status: :failed, result: %{reason: :max_tool_rounds_exceeded}}

    emit(opts, %Event{
      type: :turn_limit,
      session_id: session.id,
      turn: session.turn,
      data: %{reason: :max_tool_rounds_exceeded}
    })

    emit(opts, %Event{
      type: :session_failed,
      session_id: session.id,
      turn: session.turn,
      data: %{reason: :max_tool_rounds_exceeded}
    })

    emit(opts, %Event{
      type: :error,
      session_id: session.id,
      turn: session.turn,
      data: %{reason: :max_tool_rounds_exceeded}
    })

    emit(opts, %Event{
      type: :session_end,
      session_id: session.id,
      turn: session.turn,
      data: %{status: :failed, reason: :max_tool_rounds_exceeded}
    })

    {:error, :max_tool_rounds_exceeded, failed}
  end

  defp do_run(session, model_client, tool_executor, opts, assistant_window, round_count) do
    if abort_signaled?(opts) do
      failed = %{session | status: :failed, result: %{reason: :aborted}}

      emit(opts, %Event{
        type: :session_failed,
        session_id: session.id,
        turn: session.turn,
        data: %{reason: :aborted}
      })

      emit(opts, %Event{
        type: :error,
        session_id: session.id,
        turn: session.turn,
        data: %{reason: :aborted}
      })

      emit(opts, %Event{
        type: :session_end,
        session_id: session.id,
        turn: session.turn,
        data: %{status: :failed, reason: :aborted}
      })

      {:error, :aborted, failed}
    else
      next_turn = session.turn + 1
      emit(opts, %Event{type: :turn_started, session_id: session.id, turn: next_turn, data: %{}})

      response = model_client.(session)

      case response do
        %{type: :final, content: content} ->
          emit(opts, %Event{
            type: :assistant_text_start,
            session_id: session.id,
            turn: next_turn,
            data: %{}
          })

          emit(opts, %Event{
            type: :assistant_text_delta,
            session_id: session.id,
            turn: next_turn,
            data: %{text: content}
          })

          emit(opts, %Event{
            type: :assistant_text_end,
            session_id: session.id,
            turn: next_turn,
            data: %{text: content}
          })

          emit(opts, %Event{
            type: :turn_completed,
            session_id: session.id,
            turn: next_turn,
            data: %{mode: :final}
          })

          completed =
            session
            |> append_message(:assistant, content)
            |> Map.put(:turn, next_turn)
            |> Map.put(:status, :completed)
            |> Map.put(:result, %{content: content})

          emit(opts, %Event{
            type: :session_completed,
            session_id: session.id,
            turn: next_turn,
            data: %{}
          })

          emit(opts, %Event{
            type: :session_end,
            session_id: session.id,
            turn: next_turn,
            data: %{status: :completed}
          })

          {:ok, completed}

        %{type: :tool_call, tool_calls: tool_calls, assistant_content: assistant_content} ->
          emit(opts, %Event{
            type: :assistant_text_start,
            session_id: session.id,
            turn: next_turn,
            data: %{}
          })

          emit(opts, %Event{
            type: :assistant_text_delta,
            session_id: session.id,
            turn: next_turn,
            data: %{text: assistant_content}
          })

          emit(opts, %Event{
            type: :assistant_text_end,
            session_id: session.id,
            turn: next_turn,
            data: %{text: assistant_content}
          })

          session =
            session
            |> append_message(:assistant, assistant_content, %{tool_calls: tool_calls})
            |> Map.put(:turn, next_turn)

          emit(opts, %Event{
            type: :tool_calls_requested,
            session_id: session.id,
            turn: next_turn,
            data: %{count: length(tool_calls)}
          })

          {tool_messages, tool_events} = execute_tool_calls(tool_calls, tool_executor, opts)

          Enum.each(tool_events, fn {event_type, data} ->
            emit(opts, %Event{
              type: event_type,
              session_id: session.id,
              turn: next_turn,
              data: data
            })

            emit_tool_event_alias(event_type, data, session.id, next_turn, opts)
          end)

          session =
            Enum.reduce(tool_messages, session, fn {content, metadata}, acc ->
              append_message(acc, :tool, content, metadata)
            end)

          window =
            update_window(
              assistant_window,
              assistant_content,
              session.config.loop_detection_window
            )

          if loop_detected?(window) do
            warning =
              "Loop detected: the last #{session.config.loop_detection_window} turns repeat. " <>
                "Try a different approach."

            warned = append_message(session, :assistant, warning, %{steering: true})
            failed = %{warned | status: :failed, result: %{reason: :loop_detected}}

            emit(opts, %Event{
              type: :loop_detected,
              session_id: session.id,
              turn: next_turn,
              data: %{warning: warning}
            })

            emit(opts, %Event{
              type: :steering_injected,
              session_id: session.id,
              turn: next_turn,
              data: %{content: warning}
            })

            emit(opts, %Event{
              type: :error,
              session_id: session.id,
              turn: next_turn,
              data: %{reason: :loop_detected}
            })

            emit(opts, %Event{
              type: :session_end,
              session_id: session.id,
              turn: next_turn,
              data: %{status: :failed, reason: :loop_detected}
            })

            {:error, :loop_detected, failed}
          else
            emit(opts, %Event{
              type: :turn_completed,
              session_id: session.id,
              turn: next_turn,
              data: %{mode: :tool_round}
            })

            do_run(session, model_client, tool_executor, opts, window, round_count + 1)
          end

        {:error, reason} ->
          failed = %{session | status: :failed, result: %{reason: {:llm_error, reason}}}

          emit(opts, %Event{
            type: :session_failed,
            session_id: session.id,
            turn: next_turn,
            data: %{reason: {:llm_error, reason}}
          })

          emit(opts, %Event{
            type: :error,
            session_id: session.id,
            turn: next_turn,
            data: %{reason: {:llm_error, reason}}
          })

          emit(opts, %Event{
            type: :session_end,
            session_id: session.id,
            turn: next_turn,
            data: %{status: :failed, reason: {:llm_error, reason}}
          })

          {:error, {:llm_error, reason}, failed}

        other ->
          failed = %{
            session
            | status: :failed,
              result: %{reason: {:invalid_model_response, other}}
          }

          emit(opts, %Event{
            type: :session_failed,
            session_id: session.id,
            turn: next_turn,
            data: %{reason: :invalid_model_response}
          })

          emit(opts, %Event{
            type: :error,
            session_id: session.id,
            turn: next_turn,
            data: %{reason: :invalid_model_response}
          })

          emit(opts, %Event{
            type: :session_end,
            session_id: session.id,
            turn: next_turn,
            data: %{status: :failed, reason: :invalid_model_response}
          })

          {:error, :invalid_model_response, failed}
      end
    end
  end

  defp execute_tool_calls(tool_calls, fallback_executor, opts) do
    parallel = Keyword.get(opts, :parallel_tool_execution, false)
    registry = Keyword.get(opts, :tool_registry, %{})
    default_timeout_ms = Keyword.get(opts, :default_command_timeout_ms, 10_000)
    max_timeout_ms = Keyword.get(opts, :max_command_timeout_ms, 600_000)

    runner = fn call ->
      execute_tool_call(call, registry, fallback_executor, default_timeout_ms, max_timeout_ms)
    end

    results =
      if parallel and length(tool_calls) > 1 do
        tool_calls
        |> Task.async_stream(runner, timeout: max_timeout_ms + 1_000, ordered: true)
        |> Enum.map(fn
          {:ok, result} ->
            result

          {:exit, reason} ->
            tool_failure_result(
              %{},
              :execution_failed,
              "tool execution crashed: #{inspect(reason)}"
            )
        end)
      else
        Enum.map(tool_calls, runner)
      end

    tool_messages =
      Enum.map(results, fn result ->
        {
          result.content,
          %{
            tool_result: result.raw,
            tool_name: result.tool_name,
            tool_call_id: result.tool_call_id,
            is_error: result.is_error
          }
        }
      end)

    tool_events =
      Enum.flat_map(results, fn result ->
        [
          {:tool_call_start,
           %{tool: result.tool_name, call_id: result.tool_call_id, arguments: result.arguments}},
          {:tool_call_end,
           %{
             tool: result.tool_name,
             call_id: result.tool_call_id,
             is_error: result.is_error,
             output: result.full_output,
             full_output: result.full_output
           }}
        ]
      end)

    {tool_messages, tool_events}
  end

  defp execute_tool_call(call, registry, fallback_executor, default_timeout_ms, max_timeout_ms) do
    call_id = call_value(call, :id, "call")
    tool_name = call_value(call, :name, "unknown")

    with {:ok, arguments} <- parse_tool_arguments(call),
         {:ok, executor} <- resolve_tool_executor(tool_name, registry, fallback_executor),
         :ok <- validate_tool_args(tool_name, arguments, registry) do
      timeout_ms =
        normalize_timeout(
          arguments["timeout_ms"] || arguments[:timeout_ms],
          default_timeout_ms,
          max_timeout_ms
        )

      run_executor(tool_name, call_id, arguments, timeout_ms, executor)
    else
      {:error, {:unknown_tool, name}} ->
        tool_failure_result(call, :unknown_tool, "unknown tool: #{name}")

      {:error, {:invalid_arguments, reason}} ->
        tool_failure_result(
          call,
          :invalid_arguments,
          "invalid tool arguments: #{inspect(reason)}"
        )

      {:error, reason} ->
        tool_failure_result(call, :execution_failed, "tool execution failed: #{inspect(reason)}")
    end
  end

  defp parse_tool_arguments(call) do
    args = call_value(call, :arguments, call_value(call, :args, %{}))

    cond do
      is_map(args) ->
        {:ok, args}

      is_binary(args) ->
        case Jason.decode(args) do
          {:ok, map} when is_map(map) -> {:ok, map}
          {:ok, other} -> {:error, {:invalid_arguments, {:not_object, other}}}
          {:error, reason} -> {:error, {:invalid_arguments, reason}}
        end

      true ->
        {:error, {:invalid_arguments, :unsupported_argument_format}}
    end
  end

  defp resolve_tool_executor(tool_name, registry, fallback_executor) do
    case Map.get(registry, to_string(tool_name)) || Map.get(registry, tool_name) do
      %{execute: execute} when is_function(execute, 1) ->
        {:ok, {:registry, execute}}

      %{executor: execute} when is_function(execute, 1) ->
        {:ok, {:registry, execute}}

      nil when is_function(fallback_executor, 1) ->
        {:ok, {:fallback, fallback_executor}}

      _ ->
        {:error, {:unknown_tool, tool_name}}
    end
  end

  defp validate_tool_args(tool_name, args, registry) do
    entry = Map.get(registry, to_string(tool_name)) || Map.get(registry, tool_name)
    schema = (entry && (entry[:parameters] || entry[:schema])) || nil

    case schema do
      nil ->
        :ok

      schema when is_map(schema) ->
        validate_args_against_schema(args, schema)

      _ ->
        {:error, {:invalid_arguments, :invalid_schema}}
    end
  end

  defp validate_args_against_schema(args, schema) when is_map(args) and is_map(schema) do
    type = Map.get(schema, "type") || Map.get(schema, :type)

    if type in [nil, "object", :object] do
      required = Map.get(schema, "required") || Map.get(schema, :required) || []
      properties = Map.get(schema, "properties") || Map.get(schema, :properties) || %{}

      with :ok <- validate_required_fields(args, required) do
        validate_property_types(args, properties)
      end
    else
      {:error, {:invalid_arguments, {:schema_type, type}}}
    end
  end

  defp validate_args_against_schema(_args, _schema),
    do: {:error, {:invalid_arguments, :schema_mismatch}}

  defp validate_required_fields(args, required) do
    case Enum.find(required, fn key ->
           key_s = to_string(key)
           not (Map.has_key?(args, key_s) or Map.has_key?(args, key))
         end) do
      nil -> :ok
      key -> {:error, {:invalid_arguments, {:missing_required, to_string(key)}}}
    end
  end

  defp validate_property_types(args, properties) do
    Enum.reduce_while(properties, :ok, fn {key, prop_schema}, _acc ->
      key_s = to_string(key)
      value = if Map.has_key?(args, key_s), do: Map.get(args, key_s), else: Map.get(args, key)

      if is_nil(value) do
        {:cont, :ok}
      else
        expected = Map.get(prop_schema, "type") || Map.get(prop_schema, :type)

        if type_matches?(value, expected) do
          {:cont, :ok}
        else
          {:halt, {:error, {:invalid_arguments, {:type_mismatch, key_s, expected}}}}
        end
      end
    end)
  end

  defp type_matches?(_value, nil), do: true
  defp type_matches?(value, type) when type in ["string", :string], do: is_binary(value)
  defp type_matches?(value, type) when type in ["integer", :integer], do: is_integer(value)
  defp type_matches?(value, type) when type in ["number", :number], do: is_number(value)
  defp type_matches?(value, type) when type in ["boolean", :boolean], do: is_boolean(value)
  defp type_matches?(value, type) when type in ["object", :object], do: is_map(value)
  defp type_matches?(value, type) when type in ["array", :array], do: is_list(value)
  defp type_matches?(_value, _type), do: true

  defp normalize_timeout(timeout_ms, _default_timeout_ms, max_timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    min(timeout_ms, max_timeout_ms)
  end

  defp normalize_timeout(_, default_timeout_ms, max_timeout_ms),
    do: min(default_timeout_ms, max_timeout_ms)

  defp run_executor(tool_name, call_id, arguments, timeout_ms, {:registry, execute}) do
    run_executor_with_timeout(tool_name, call_id, arguments, timeout_ms, execute)
  end

  defp run_executor(tool_name, call_id, arguments, timeout_ms, {:fallback, execute}) do
    run_executor_with_timeout(tool_name, call_id, arguments, timeout_ms, fn _ ->
      execute.(%{id: call_id, name: tool_name, arguments: arguments})
    end)
  end

  defp run_executor_with_timeout(tool_name, call_id, arguments, timeout_ms, execute_fun) do
    parent = self()
    ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, execute_fun.(arguments)}
          rescue
            exception ->
              {:error, {:exception, Exception.message(exception)}}
          catch
            kind, reason ->
              {:error, {kind, reason}}
          end

        send(parent, {ref, result})
      end)

    result =
      receive do
        {^ref, {:ok, value}} ->
          value

        {^ref, {:error, reason}} ->
          {:error, reason}

        {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
          {:error, {:task_exit, reason}}
      after
        timeout_ms ->
          Process.exit(pid, :kill)
          {:error, :timeout}
      end

    Process.demonitor(monitor_ref, [:flush])

    normalize_tool_result(tool_name, call_id, arguments, result)
  rescue
    exception ->
      tool_failure_result(
        %{"id" => call_id, "name" => tool_name, "arguments" => arguments},
        :execution_failed,
        Exception.message(exception)
      )
  end

  defp normalize_tool_result(tool_name, call_id, arguments, {:ok, value}) do
    tool_success_result(tool_name, call_id, arguments, value)
  end

  defp normalize_tool_result(tool_name, call_id, arguments, {:error, :timeout}) do
    tool_failure_result(
      %{"id" => call_id, "name" => tool_name, "arguments" => arguments},
      :timeout,
      "tool timed out"
    )
  end

  defp normalize_tool_result(tool_name, call_id, arguments, {:error, reason}) do
    tool_failure_result(
      %{"id" => call_id, "name" => tool_name, "arguments" => arguments},
      :execution_failed,
      inspect(reason)
    )
  end

  defp normalize_tool_result(tool_name, call_id, arguments, value) do
    tool_success_result(tool_name, call_id, arguments, value)
  end

  defp tool_success_result(tool_name, call_id, arguments, value) do
    output = if is_binary(value), do: value, else: Jason.encode!(value)

    %{
      tool_name: to_string(tool_name),
      tool_call_id: to_string(call_id),
      arguments: arguments,
      content: output,
      full_output: output,
      is_error: false,
      raw: %{
        "status" => "ok",
        "tool" => to_string(tool_name),
        "call_id" => to_string(call_id),
        "output" => output
      }
    }
  end

  defp tool_failure_result(call, type, message) do
    tool_name = call_value(call, :name, "unknown")
    call_id = call_value(call, :id, "call")
    arguments = call_value(call, :arguments, %{})

    raw = %{
      "status" => "error",
      "type" => type,
      "tool" => to_string(tool_name),
      "call_id" => to_string(call_id),
      "error" => message
    }

    %{
      tool_name: to_string(tool_name),
      tool_call_id: to_string(call_id),
      arguments: arguments,
      content: Jason.encode!(raw),
      full_output: message,
      is_error: true,
      raw: raw
    }
  end

  defp call_value(call, key, default) do
    Map.get(call, key) || Map.get(call, to_string(key)) || default
  end

  defp append_message(%Session{messages: messages} = session, role, content, metadata \\ %{}) do
    msg = %{role: role, content: to_string(content), metadata: metadata}
    %{session | messages: messages ++ [msg]}
  end

  defp emit_tool_event_alias(:tool_call_start, data, session_id, turn, opts) do
    emit(opts, %Event{type: :tool_call_started, session_id: session_id, turn: turn, data: data})
  end

  defp emit_tool_event_alias(:tool_call_end, data, session_id, turn, opts) do
    emit(opts, %Event{type: :tool_call_completed, session_id: session_id, turn: turn, data: data})
  end

  defp emit_tool_event_alias(_event_type, _data, _session_id, _turn, _opts), do: :ok

  defp emit(opts, %Event{} = event) do
    case Keyword.get(opts, :on_event) do
      callback when is_function(callback, 1) -> callback.(event)
      _ -> :ok
    end
  end

  defp update_window(window, content, limit) do
    (window ++ [to_string(content)])
    |> Enum.take(-limit)
  end

  defp loop_detected?(window) when length(window) < 3, do: false
  defp loop_detected?([a, b, c]), do: a == b and b == c
  defp loop_detected?(window), do: loop_detected?(Enum.take(window, -3))

  defp abort_signaled?(opts) do
    case Keyword.get(opts, :abort?) do
      true -> true
      fun when is_function(fun, 0) -> fun.()
      _ -> false
    end
  end
end
