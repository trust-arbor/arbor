defmodule ConversationKit.Arbor.ControlCodec do
  @moduledoc false
  alias ConversationKit.Controls
  @delivery [:admitted, :dispatch_started, :completed, :uncertain]
  @cancel [:none, :requested, :confirmed]
  @termination [:never_dispatched, :queued_removed, :engine_terminated]
  @execution [:running, :queued, :not_observed]
  @progress [
    :pipeline_started,
    :pipeline_completed,
    :pipeline_failed,
    :stage_started,
    :stage_completed,
    :stage_failed,
    :stage_retrying
  ]
  @prompt_status [:pending, :responded, :expired, :abandoned, :retired, :cancelled]

  @wire_keys ~w(agent_id engagement_id commands source_watermark index_watermark incomplete has_more next_cursor truncated command_id task_id delivery_status cancellation admitted_cursor execution preview preview_truncated progress type node_id status termination admitted_event_number interactions request_id operation_id revision kind text choices deadline_unix_ms id label termination_observation)a
  @wire_enums %{
    delivery_status: @delivery,
    execution: @execution,
    status: @delivery ++ @cancel ++ @prompt_status,
    termination: @termination,
    type: @progress,
    termination_observation: [:confirmed, :unconfirmed]
  }

  def wire(context, data) do
    with true <- is_map(data) and not is_struct(data),
         true <- byte_size(JSON.encode!(data)) <= 131_584,
         {:ok, raw} <- wire_value(data),
         true <- raw[:agent_id] == context.target,
         raw = Map.delete(raw, :agent_id),
         engagement when is_binary(engagement) <- context.options[:expected_engagement_id],
         {:ok, _} <- validate_wire(context, raw, engagement) do
      {:ok, raw}
    else
      _ -> {:error, :invalid_transport_response}
    end
  rescue
    _ -> {:error, :invalid_transport_response}
  end

  defp validate_wire(%{operation: :activity, options: opts}, raw, eng) do
    case activity(raw, eng, opts) do
      {:ok, _, _} -> {:ok, raw}
      error -> error
    end
  end

  defp validate_wire(%{operation: :interactions, input: id}, raw, eng), do: prompts(raw, id, eng)
  defp validate_wire(%{operation: :cancel, input: id}, raw, eng), do: cancel(raw, id, eng)

  defp validate_wire(%{operation: op, input: input}, raw, eng)
       when op in [:interaction_choice, :interaction_approval], do: answer(raw, input, eng)

  defp validate_wire(_, _, _), do: {:error, :invalid_control_response}

  defp wire_value(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      atom = Enum.find(@wire_keys, &(Atom.to_string(&1) == key))

      result =
        if atom && Map.has_key?(@wire_enums, atom) do
          case Enum.find(@wire_enums[atom], &(Atom.to_string(&1) == value)) do
            nil -> :invalid
            enum -> {:ok, enum}
          end
        else
          wire_value(value)
        end

      case {atom, result} do
        {atom, {:ok, decoded}} when not is_nil(atom) ->
          {:cont, {:ok, Map.put(acc, atom, decoded)}}

        _ ->
          {:halt, :invalid}
      end
    end)
  end

  defp wire_value(value) when is_list(value) do
    if length(value) <= 100, do: map_items(value, &wire_value/1), else: :invalid
  end

  defp wire_value(value)
       when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp wire_value(_), do: :invalid

  def cancellation(nil), do: {:ok, %{"status" => "none"}}

  def cancellation(value) do
    with true <- plain?(value),
         true <- exact?(value, [:status]) or exact?(value, [:status, :termination]),
         true <- value.status in @cancel,
         true <-
           if(value.status == :confirmed,
             do: value[:termination] in @termination,
             else: not Map.has_key?(value, :termination)
           ) do
      {:ok, Map.new(value, fn {key, value} -> {Atom.to_string(key), Atom.to_string(value)} end)}
    else
      _ -> {:error, :invalid_command_response}
    end
  end

  def cancellation_delivery?(delivery, %{"status" => "confirmed", "termination" => termination}),
    do: termination == "never_dispatched" == (delivery == :admitted)

  def cancellation_delivery?(_, _), do: true

  def activity(page, engagement, opts) do
    with true <-
           exact?(page, [
             :commands,
             :source_watermark,
             :index_watermark,
             :incomplete,
             :has_more,
             :next_cursor,
             :engagement_id,
             :truncated
           ]),
         true <- page.engagement_id == engagement,
         true <- ordinal?(page.index_watermark) and ordinal?(page.source_watermark),
         true <- page.index_watermark <= page.source_watermark,
         true <- page.incomplete == page.index_watermark < page.source_watermark,
         true <- is_boolean(page.has_more) and is_boolean(page.truncated),
         true <- valid_cursor?(page.next_cursor),
         true <- page.has_more == not is_nil(page.next_cursor),
         true <- bounded_list?(page.commands, Keyword.get(opts, :limit, 50)),
         true <- :erlang.external_size(page) <= 262_144,
         {:ok, records} <- map_items(page.commands, &activity_record/1),
         true <- unique?(records, "command_id"),
         true <- ordered?(page.commands, opts[:cursor]),
         true <- last_cursor?(page),
         true <- closed_wire_bound?(page),
         {:ok, _} <-
           Controls.replace(Controls.new(), %{"activities" => records, "interactions" => []}) do
      positions =
        Map.new(
          page.commands,
          &{&1.command_id,
           %{admitted_event_number: &1.admitted_cursor, command_id: &1.command_id}}
        )

      {:ok, records,
       Map.put(
         Map.take(page, [:has_more, :incomplete, :truncated, :next_cursor]),
         :positions,
         positions
       )}
    else
      _ -> {:error, :invalid_control_response}
    end
  end

  defp activity_record(raw) do
    required = [
      :command_id,
      :task_id,
      :delivery_status,
      :cancellation,
      :admitted_cursor,
      :execution
    ]

    optional = [:preview, :preview_truncated, :progress]

    with true <- keys?(raw, required, optional),
         true <- id?(raw.command_id, 128) and text?(raw.task_id, 256),
         true <- ordinal?(raw.admitted_cursor) and raw.admitted_cursor > 0,
         true <- raw.delivery_status in @delivery and raw.execution in @execution,
         {:ok, cancellation} <- cancellation(raw.cancellation),
         true <- cancellation_delivery?(raw.delivery_status, cancellation),
         true <- text?(Map.get(raw, :preview, ""), 32_768),
         true <- is_boolean(Map.get(raw, :preview_truncated, false)),
         {:ok, progress} <- progress(Map.get(raw, :progress)) do
      {:ok,
       %{
         "command_id" => raw.command_id,
         "delivery_status" => Atom.to_string(raw.delivery_status),
         "execution" => Atom.to_string(raw.execution),
         "cancellation" => Map.take(cancellation, ["status"]),
         "preview" => Map.get(raw, :preview, ""),
         "preview_truncated" => Map.get(raw, :preview_truncated, false),
         "progress" => progress
       }}
    else
      _ -> {:error, :invalid_control_response}
    end
  end

  defp progress(nil), do: {:ok, nil}

  defp progress(value) do
    if exact?(value, [:type, :node_id]) and value.type in @progress and
         (is_nil(value.node_id) or id?(value.node_id, 256, ~r/\A[A-Za-z0-9_.:-]+\z/)),
       do: {:ok, %{"type" => Atom.to_string(value.type), "node_id" => value.node_id}},
       else: {:error, :invalid_control_response}
  end

  def prompts(envelope, command_id, engagement) do
    with true <- exact?(envelope, [:interactions, :command_id, :engagement_id]),
         true <- envelope.command_id == command_id and envelope.engagement_id == engagement,
         true <- bounded_list?(envelope.interactions, 32),
         true <- :erlang.external_size(envelope) <= 262_144,
         {:ok, prompts} <- map_items(envelope.interactions, &prompt(&1, command_id)),
         true <- unique?(prompts, "request_id") and unique?(prompts, "operation_id"),
         true <- closed_wire_bound?(envelope) do
      {:ok, prompts}
    else
      _ -> {:error, :invalid_control_response}
    end
  end

  defp prompt(raw, command_id) do
    with true <-
           exact?(raw, [
             :request_id,
             :operation_id,
             :command_id,
             :revision,
             :kind,
             :text,
             :choices,
             :deadline_unix_ms,
             :status
           ]),
         true <-
           raw.command_id == command_id and id?(raw.request_id, 256) and
             id?(raw.operation_id, 256),
         true <- raw.revision === 1 and raw.kind in ["choice", "approval"],
         true <- raw.status in @prompt_status and ordinal?(raw.deadline_unix_ms),
         true <- text?(raw.text, 4096),
         {:ok, choices} <- choices(raw.choices),
         record = %{
           "command_id" => command_id,
           "request_id" => raw.request_id,
           "operation_id" => raw.operation_id,
           "revision" => raw.revision,
           "kind" => raw.kind,
           "status" => Atom.to_string(raw.status),
           "text" => raw.text,
           "choices" => if(raw.kind == "approval", do: [], else: choices)
         },
         {:ok, _} <-
           Controls.replace(Controls.new(), %{"activities" => [], "interactions" => [record]}) do
      {:ok, record}
    else
      _ -> {:error, :invalid_control_response}
    end
  end

  defp choices(values) do
    with true <- bounded_list?(values, 32),
         {:ok, result} <-
           map_items(values, fn value ->
             if exact?(value, [:id, :label]) and id?(value.id, 256) and text?(value.label, 512),
               do: {:ok, %{"id" => value.id, "label" => value.label}},
               else: {:error, :invalid_control_response}
           end),
         true <- unique?(result, "id") do
      {:ok, result}
    else
      _ -> {:error, :invalid_control_response}
    end
  end

  def cancel(raw, command, engagement) do
    with true <-
           exact?(raw, [
             :command_id,
             :task_id,
             :delivery_status,
             :cancellation,
             :termination_observation,
             :engagement_id
           ]),
         true <- raw.command_id == command and raw.engagement_id == engagement,
         true <- text?(raw.task_id, 256) and raw.delivery_status in @delivery,
         {:ok, cancellation} <- cancellation(raw.cancellation),
         true <- cancellation_delivery?(raw.delivery_status, cancellation),
         true <-
           raw.termination_observation ==
             if(cancellation["status"] == "confirmed", do: :confirmed, else: :unconfirmed) do
      {:ok,
       %{
         "command_id" => command,
         "delivery_status" => Atom.to_string(raw.delivery_status),
         "cancellation" => Map.take(cancellation, ["status"])
       }}
    else
      _ -> {:error, :invalid_control_response}
    end
  end

  def answer(raw, input, engagement) do
    if exact?(raw, [:request_id, :operation_id, :revision, :command_id, :engagement_id, :status]) and
         Enum.all?([:request_id, :operation_id, :revision, :command_id], &(raw[&1] === input[&1])) and
         raw.engagement_id == engagement and raw.status == :responded,
       do:
         {:ok,
          Map.new(
            Map.take(raw, [:request_id, :operation_id, :revision, :command_id, :status]),
            fn {key, value} ->
              {Atom.to_string(key), if(is_atom(value), do: Atom.to_string(value), else: value)}
            end
          )},
       else: {:error, :invalid_control_response}
  end

  def answer_input(input, :interaction_choice) do
    exact?(input, [:command_id, :request_id, :operation_id, :revision, :choice_id]) and
      answer_identity?(input) and id?(input.choice_id, 256)
  end

  def answer_input(input, :interaction_approval) do
    exact?(input, [:command_id, :request_id, :operation_id, :revision, :decision, :note]) and
      answer_identity?(input) and
      input.decision in [:approve, :deny, :rework, "approve", "deny", "rework"] and
      (is_nil(input.note) or
         (text?(input.note, 1024) and
            not Regex.match?(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, input.note)))
  end

  defp answer_identity?(input),
    do:
      id?(input.command_id, 128) and id?(input.request_id, 256) and
        id?(input.operation_id, 256) and input.revision === 1

  def options?(opts),
    do:
      Keyword.keyword?(opts) and length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
        Enum.all?(opts, fn
          {:limit, n} -> is_integer(n) and n in 1..50
          {:cursor, cursor} -> not is_nil(cursor) and valid_cursor?(cursor)
          {:control_timeout, ms} -> is_integer(ms) and ms in 1..30_000
          _ -> false
        end)

  def valid_cursor?(nil), do: true

  def valid_cursor?(value),
    do:
      exact?(value, [:admitted_event_number, :command_id]) and
        ordinal?(value.admitted_event_number) and value.admitted_event_number > 0 and
        id?(value.command_id, 128)

  defp ordered?(commands, cursor) do
    tuples = Enum.map(commands, &{&1.admitted_cursor, &1.command_id})

    tuples == Enum.sort(tuples, :desc) and length(Enum.uniq(tuples)) == length(tuples) and
      (is_nil(cursor) or
         Enum.all?(tuples, &(&1 < {cursor.admitted_event_number, cursor.command_id})))
  end

  defp last_cursor?(%{has_more: false}), do: true
  defp last_cursor?(%{commands: []}), do: false

  defp last_cursor?(page) do
    last = List.last(page.commands)

    page.next_cursor == %{
      admitted_event_number: last.admitted_cursor,
      command_id: last.command_id
    }
  end

  defp closed_wire_bound?(value), do: byte_size(JSON.encode!(closed_wire_json(value))) <= 131_072

  defp closed_wire_json(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, value} -> {Atom.to_string(key), closed_wire_json(value)} end)

  defp closed_wire_json(value) when is_list(value), do: Enum.map(value, &closed_wire_json/1)
  defp closed_wire_json(value) when value in [nil, true, false], do: value
  defp closed_wire_json(value) when is_atom(value), do: Atom.to_string(value)
  defp closed_wire_json(value), do: value

  def bounded?(snapshot),
    do:
      byte_size(JSON.encode!(snapshot)) <= 262_144 and
        length(snapshot["activities"]) <= 50 and length(snapshot["interactions"]) <= 50

  def id?(value, max, pattern \\ ~r/\A[A-Za-z0-9_-]+\z/),
    do: text?(value, max) and byte_size(value) > 0 and Regex.match?(pattern, value)

  defp text?(value, max),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= max

  defp ordinal?(n), do: is_integer(n) and n >= 0 and n <= 9_223_372_036_854_775_807
  defp exact?(value, keys), do: plain?(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp keys?(value, required, optional),
    do:
      plain?(value) and Enum.all?(required, &Map.has_key?(value, &1)) and
        Enum.all?(Map.keys(value), &(&1 in (required ++ optional)))

  defp plain?(value), do: is_map(value) and not is_struct(value)
  defp bounded_list?([], _), do: true
  defp bounded_list?([_ | tail], n) when n > 0, do: bounded_list?(tail, n - 1)
  defp bounded_list?(_, _), do: false
  defp unique?(records, field), do: length(records) == length(Enum.uniq_by(records, & &1[field]))

  defp map_items(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        _ -> {:halt, {:error, :invalid_control_response}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end
