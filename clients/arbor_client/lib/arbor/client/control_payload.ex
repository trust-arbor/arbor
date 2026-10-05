defmodule Arbor.Client.ControlPayload do
  @moduledoc false

  @operations [:activity, :cancel, :interactions, :interaction_choice, :interaction_approval]
  @choice_keys [:command_id, :request_id, :operation_id, :revision, :choice_id]
  @approval_keys [:command_id, :request_id, :operation_id, :revision, :decision, :note]

  def operation?(operation), do: operation in @operations

  def encode(operation, caller, target, input, options) do
    with true <- operation?(operation),
         true <- principal?(caller) and principal?(target),
         {:ok, options} <- options(operation, options),
         {:ok, value} <- input(operation, input) do
      fence = Keyword.get(options, :expected_engagement_id)
      Jason.encode!(payload(operation, caller, target, value, options, fence))
    else
      _ -> {:error, :invalid_control_request}
    end
  rescue
    _ -> {:error, :invalid_control_request}
  end

  defp payload(operation, caller, target, input, options, fence)
       when operation in [:activity, :cancel] do
    cursor = Keyword.get(options, :cursor)
    cursor = if cursor, do: [cursor.admitted_event_number, cursor.command_id], else: nil

    [
      if(operation == :activity,
        do: "arbor.conversation.activity.v1",
        else: "arbor.conversation.cancel.v1"
      ),
      caller,
      target,
      input,
      [cursor, Keyword.get(options, :limit), Keyword.get(options, :control_timeout)],
      fence
    ]
  end

  defp payload(operation, caller, target, input, _options, fence) do
    tag =
      case operation do
        :interactions -> "arbor.conversation.interactions.v1"
        :interaction_choice -> "arbor.conversation.interaction.choice.v1"
        :interaction_approval -> "arbor.conversation.interaction.approval.v1"
      end

    [tag, caller, target, input, fence]
  end

  defp options(operation, options) when is_list(options) do
    allowed =
      case operation do
        :activity -> [:cursor, :limit, :control_timeout, :expected_engagement_id]
        :cancel -> [:control_timeout, :expected_engagement_id]
        _ -> [:expected_engagement_id]
      end

    if Keyword.keyword?(options) and
         length(options) == length(Enum.uniq(Keyword.keys(options))) and
         Enum.all?(options, fn {key, value} -> key in allowed and option?(key, value) end),
       do: {:ok, options},
       else: {:error, :invalid_options}
  end

  defp options(_, _), do: {:error, :invalid_options}

  defp option?(:cursor, %{admitted_event_number: ordinal, command_id: id} = cursor),
    do:
      map_size(cursor) == 2 and is_integer(ordinal) and ordinal in 1..9_223_372_036_854_775_807 and
        command_id?(id)

  defp option?(:limit, value), do: is_integer(value) and value in 1..50
  defp option?(:control_timeout, value), do: is_integer(value) and value in 1..30_000
  defp option?(:expected_engagement_id, value), do: fence?(value)
  defp option?(_, _), do: false

  defp input(:activity, nil), do: {:ok, nil}

  defp input(operation, id) when operation in [:cancel, :interactions] do
    if command_id?(id), do: {:ok, id}, else: {:error, :invalid_command}
  end

  defp input(:interaction_choice, input) when is_map(input) do
    if exact_keys?(input, @choice_keys) and command_id?(input.command_id) and
         Enum.all?([input.request_id, input.operation_id, input.choice_id], &bounded?(&1, 256)) and
         input.revision === 1,
       do:
         {:ok,
          [
            input.command_id,
            input.request_id,
            input.operation_id,
            input.revision,
            input.choice_id
          ]},
       else: {:error, :invalid_answer}
  end

  defp input(:interaction_approval, input) when is_map(input) do
    if exact_keys?(input, @approval_keys) and command_id?(input.command_id) and
         Enum.all?([input.request_id, input.operation_id], &bounded?(&1, 256)) and
         input.revision === 1 and
         input.decision in [:approve, :deny, :rework, "approve", "deny", "rework"] and
         note?(input.note),
       do:
         {:ok,
          [
            input.command_id,
            input.request_id,
            input.operation_id,
            input.revision,
            to_string(input.decision),
            input.note
          ]},
       else: {:error, :invalid_answer}
  end

  defp input(_, _), do: {:error, :invalid_input}

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp principal?(value),
    do: bounded?(value, 256) and Regex.match?(~r/\A(?:agent|human)_[A-Za-z0-9_-]+\z/, value)

  defp command_id?(value),
    do: bounded?(value, 128) and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value)

  defp bounded?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  defp fence?(value),
    do:
      is_binary(value) and byte_size(value) == 36 and
        Regex.match?(~r/\Aeng_[0-9a-f]{32}\z/, value)

  defp note?(nil), do: true

  defp note?(value) when is_binary(value) and byte_size(value) <= 1_024,
    do: String.valid?(value) and not Regex.match?(~r/[\x00-\x1f\x7f]/, value)

  defp note?(_), do: false
end
