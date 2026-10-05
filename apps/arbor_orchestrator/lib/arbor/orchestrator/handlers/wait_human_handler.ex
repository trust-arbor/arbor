defmodule Arbor.Orchestrator.Handlers.WaitHumanHandler do
  @moduledoc false

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Human.{Answer, Question}

  @impl true
  def execute(node, context, graph, opts) do
    if Map.has_key?(node.attrs, "reviews_keys") or Map.has_key?(node.attrs, "review_on_choice") do
      %Outcome{status: :fail, failure_reason: "unsupported protected human review gate"}
    else
      if opts[:conversation_source] != nil and
           Enum.any?(
             Graph.outgoing_edges(graph, node.id),
             &(Map.get(&1.attrs, "condition", "") not in ["", nil])
           ) do
        %Outcome{status: :fail, failure_reason: "unsupported conditional conversation choice"}
      else
        execute_choice(node, context, graph, opts)
      end
    end
  end

  defp execute_choice(node, _context, graph, opts) do
    choices =
      graph
      |> Graph.outgoing_edges(node.id)
      |> Enum.with_index(1)
      |> Enum.map(fn {edge, index} ->
        label = Map.get(edge.attrs, "label", edge.to)

        %{
          id: "choice_#{index}",
          key: accelerator_key(label),
          label: label,
          to: edge.to
        }
      end)

    if choices == [] do
      %Outcome{status: :fail, failure_reason: "No outgoing edges for human gate"}
    else
      question = %Question{
        text: Map.get(node.attrs, "label", "Select an option:"),
        options: choices,
        stage: node.id,
        default: Map.get(node.attrs, "human.default_choice"),
        timeout_seconds: parse_timeout_seconds(Map.get(node.attrs, "human.timeout_seconds")),
        metadata: %{"node_id" => node.id}
      }

      started_at = System.monotonic_time()
      emit(opts, %{type: :interview_started, stage: node.id, question: question.text})
      answer = ask_interviewer(question, opts)

      if answer.value == :timeout do
        emit(opts, %{
          type: :interview_timeout,
          stage: node.id,
          question: question.text,
          duration_ms: duration_ms(started_at)
        })
      end

      case select_choice(answer, question, choices, node) do
        {:ok, selected} ->
          emit(opts, %{
            type: :interview_completed,
            stage: node.id,
            question: question.text,
            answer: answer.value,
            selected: selected.to,
            duration_ms: duration_ms(started_at)
          })

          %Outcome{
            status: :success,
            preferred_label: preferred_label(selected, choices),
            suggested_next_ids: [selected.to],
            context_updates: %{
              "human.gate.selected" => selected.key,
              "human.gate.label" => selected.label
            },
            taint_reductions: []
          }

        {:retry, reason} ->
          %Outcome{status: :retry, failure_reason: reason}

        {:fail, reason} ->
          %Outcome{status: :fail, failure_reason: reason}
      end
    end
  end

  @impl true
  def idempotency, do: :side_effecting

  defp ask_interviewer(question, opts) do
    case opts[:conversation_source] do
      %{session_pid: pid, generation: generation, handle: handle}
      when is_pid(pid) and is_reference(generation) ->
        ask_conversation(question, pid, generation, handle)

      nil ->
        ask_configured_interviewer(question, opts)

      _ ->
        %Answer{value: :skipped}
    end
  rescue
    _ -> %Answer{value: :skipped}
  catch
    _, _ -> %Answer{value: :skipped}
  end

  defp ask_conversation(question, pid, generation, handle) do
    timeout_ms =
      if is_number(question.timeout_seconds),
        do: trunc(question.timeout_seconds * 1000),
        else: 300_000

    spec = %{
      kind: :choice,
      text: question.text,
      choices: Enum.map(question.options, &%{id: &1.id, label: &1.label})
    }

    with {:ok, receipt} <-
           GenServer.call(pid, {:conversation_interaction, generation, handle, spec, timeout_ms}),
         {:ok, {:choice, choice_id}, _metadata} <-
           Arbor.Comms.await_durable_interaction_response(
             receipt.request_id,
             receipt.agent_id,
             operation_id: receipt.operation_id,
             owner_deadline_unix_ms: receipt.owner_deadline_unix_ms
           ),
         selected when is_map(selected) <- Enum.find(question.options, &(&1.id == choice_id)) do
      %Answer{value: choice_id, selected_option: selected}
    else
      _ -> %Answer{value: :skipped}
    end
  end

  defp ask_configured_interviewer(question, opts) do
    interviewer = opts[:interviewer]

    raw_answer =
      case interviewer do
        fun when is_function(fun, 2) ->
          fun.(question, opts)

        fun when is_function(fun, 1) ->
          fun.(question)

        {module, module_opts} when is_atom(module) and is_list(module_opts) ->
          safe_module_ask(module, question, module_opts)

        module when is_atom(module) and module not in [nil, true, false] ->
          safe_module_ask(module, question, [])

        _ ->
          if is_list(opts[:human_answers]) do
            [answer | _] = opts[:human_answers] ++ [:skipped]
            %Answer{value: answer}
          else
            %Answer{value: :skipped}
          end
      end

    normalize_answer(raw_answer)
  end

  defp safe_module_ask(module, question, module_opts) do
    Code.ensure_loaded(module)
    apply(module, :ask, [question, module_opts])
  rescue
    _ -> %Answer{value: :skipped}
  end

  defp select_choice(%Answer{value: :timeout}, question, choices, node) do
    case default_choice(question, node, choices) do
      nil -> {:retry, "human gate timeout, no default"}
      choice -> {:ok, choice}
    end
  end

  defp select_choice(%Answer{value: :skipped}, _question, _choices, _node),
    do: {:fail, "human skipped interaction"}

  defp select_choice(%Answer{selected_option: selected}, _question, choices, _node)
       when is_map(selected) do
    case Enum.filter(choices, &(&1 == selected)) do
      [choice] -> {:ok, choice}
      _ -> {:fail, "invalid human gate selection"}
    end
  end

  defp select_choice(%Answer{value: value}, _question, choices, _node) do
    value_string = to_string(value)

    selected =
      Enum.filter(choices, fn choice ->
        choice.id == value_string or
          String.downcase(choice.key) == String.downcase(value_string) or
          String.downcase(choice.label) == String.downcase(value_string) or
          String.downcase(choice.to) == String.downcase(value_string)
      end)

    case selected do
      [choice] -> {:ok, choice}
      _ -> {:fail, "invalid or ambiguous human gate selection"}
    end
  end

  # The Engine resolves preferred labels before target ids. Repeated display
  # labels must therefore leave only the exact selected target as routing data.
  defp preferred_label(selected, choices) do
    if Enum.count(choices, &(&1.label == selected.label)) == 1, do: selected.label, else: nil
  end

  defp accelerator_key(label) do
    label = to_string(label)

    cond do
      Regex.match?(~r/^\[[^\]]+\]/, label) ->
        Regex.run(~r/^\[([^\]]+)\]/, label) |> Enum.at(1)

      Regex.match?(~r/^[A-Za-z0-9]\)/, label) ->
        String.first(label)

      Regex.match?(~r/^[A-Za-z0-9]\s*-/, label) ->
        String.first(label)

      true ->
        String.first(label) || "?"
    end
  end

  defp normalize_answer(%Answer{} = answer), do: answer

  defp normalize_answer(%{value: value} = map),
    do: %Answer{value: value, selected_option: map[:selected_option], text: map[:text]}

  defp normalize_answer(answer) when is_binary(answer), do: %Answer{value: answer}
  defp normalize_answer(answer) when is_atom(answer), do: %Answer{value: answer}
  defp normalize_answer(_), do: %Answer{value: :skipped}

  defp default_choice(question, node, choices) do
    default = question.default || Map.get(node.attrs, "human.default_choice")

    Enum.find(choices, fn choice ->
      choice.key == default or choice.label == default or choice.to == default
    end)
  end

  defp parse_timeout_seconds(nil), do: nil
  defp parse_timeout_seconds(v) when is_integer(v), do: v / 1
  defp parse_timeout_seconds(v) when is_float(v), do: v

  defp parse_timeout_seconds(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_timeout_seconds(_), do: nil

  defp duration_ms(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp emit(opts, event) do
    case Keyword.get(opts, :on_event) do
      callback when is_function(callback, 1) -> callback.(event)
      _ -> :ok
    end
  end
end
