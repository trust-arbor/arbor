defmodule Arbor.Security.ConversationNoticeReadCore do
  @moduledoc "Pure closed grammar for a scoped notice read; never authorization."
  @engagement ~r/\Aeng_[0-9a-f]{32}\z/
  def payload(subject, target, page, engagement) do
    with true <- principal?(subject),
         true <- principal?(target) and String.starts_with?(target, "agent_"),
         true <- is_binary(engagement) and Regex.match?(@engagement, engagement),
         true <- Keyword.keyword?(page),
         keys = Keyword.keys(page),
         true <-
           length(keys) == length(Enum.uniq(keys)) and
             Enum.all?(keys, &(&1 in [:before, :through, :limit])),
         true <- bound?(Keyword.get(page, :before)),
         true <- bound?(Keyword.get(page, :through)),
         true <- limit?(Keyword.get(page, :limit)) do
      {:ok,
       Jason.encode!([
         "arbor.conversation.notices.v1",
         subject,
         target,
         [Keyword.get(page, :before), Keyword.get(page, :through), Keyword.get(page, :limit)],
         engagement
       ])}
    else
      _ -> {:error, :invalid_notice_options}
    end
  rescue
    _ -> {:error, :invalid_notice_options}
  end

  def valid_payload?(payload, subject, target, expected) do
    with true <- is_binary(payload) and byte_size(payload) <= 4_096,
         {:ok,
          [
            "arbor.conversation.notices.v1",
            ^subject,
            ^target,
            [before, through, limit],
            ^expected
          ]} <- Jason.decode(payload),
         {:ok, ^payload} <-
           payload(subject, target, [before: before, through: through, limit: limit], expected) do
      true
    else
      _ -> false
    end
  end

  @page_keys [
    :owner_id,
    :target_agent_id,
    :engagement_id,
    :notices,
    :head,
    :through,
    :has_older,
    :next_before,
    :complete
  ]
  @record_keys [
    :notice_id,
    :recipient_subject_id,
    :kind,
    :text,
    :provenance,
    :ordinal,
    :created_at
  ]
  @value_keys [:notice_id, :recipient_subject_id, :kind, :text, :provenance]
  @maximum 9_223_372_036_854_775_807
  @page_budget 129_024

  @doc "Validate a closed producer page against the exact admitted read; never authority."
  def validate_page(scope, page, payload) do
    with {:ok, ^scope} <- Arbor.Security.ConversationNoticeCore.scope(scope),
         true <- is_binary(payload) and byte_size(payload) <= 4_096,
         {:ok,
          [
            "arbor.conversation.notices.v1",
            _subject,
            target,
            [before, requested_through, limit],
            engagement
          ]} <- Jason.decode(payload),
         true <- target == scope.target_agent_id and engagement == scope.engagement_id,
         true <- bound?(before) and bound?(requested_through) and limit?(limit),
         true <- is_map(page) and not is_struct(page) do
      page_scope = Map.take(page, [:owner_id, :target_agent_id, :engagement_id])

      cond do
        map_size(page_scope) != 3 -> {:error, :invalid_notice_response}
        page_scope != scope -> {:error, :conversation_scope_changed}
        true -> closed_page(scope, page, before, requested_through, limit || 20)
      end
    else
      _ -> {:error, :invalid_notice_response}
    end
  rescue
    _ -> {:error, :invalid_notice_response}
  end

  defp closed_page(scope, page, before, requested_through, limit) do
    with true <- closed?(page, @page_keys),
         true <- ordinal?(page.head, true) and ordinal?(page.through, true),
         true <- page.through <= page.head,
         true <- page.through == (requested_through || page.head),
         true <- page.complete == true and is_boolean(page.has_older),
         notices when is_list(notices) <- page.notices,
         bounded = Enum.take(notices, 51),
         true <- length(bounded) <= limit,
         true <- Enum.all?(bounded, &record?(scope, &1, page.through, before)),
         ordinals = Enum.map(bounded, & &1.ordinal),
         true <- strictly_descending?(ordinals),
         ids = Enum.map(bounded, & &1.notice_id),
         true <- length(Enum.uniq(ids)) == length(ids),
         true <- cursor?(page, bounded) do
      if byte_size(Jason.encode!(page)) <= @page_budget, do: :ok, else: {:error, :page_too_large}
    else
      _ -> {:error, :invalid_notice_response}
    end
  end

  defp record?(scope, record, through, before) do
    with true <- closed?(record, @record_keys),
         true <- ordinal?(record.ordinal, false) and record.ordinal <= through,
         true <- is_nil(before) or record.ordinal < before,
         true <- timestamp?(record.created_at),
         value = Map.take(record, @value_keys),
         {:ok, ^value} <- Arbor.Security.ConversationNoticeCore.value(scope, value) do
      true
    else
      _ -> false
    end
  end

  defp closed?(value, keys),
    do:
      is_map(value) and not is_struct(value) and
        map_size(value) == length(keys) and Enum.all?(keys, &Map.has_key?(value, &1))

  defp ordinal?(value, zero?),
    do:
      is_integer(value) and
        value >= if(zero?, do: 0, else: 1) and value <= @maximum

  defp strictly_descending?([]), do: true
  defp strictly_descending?([_]), do: true
  defp strictly_descending?([a, b | rest]), do: a > b and strictly_descending?([b | rest])
  defp cursor?(%{has_older: false, next_before: nil}, _), do: true

  defp cursor?(%{has_older: true, next_before: cursor}, [_ | _] = records),
    do: cursor == List.last(records).ordinal

  defp cursor?(_, _), do: false

  defp timestamp?(value) when is_binary(value) and byte_size(value) in 1..64 do
    case DateTime.from_iso8601(value) do
      {:ok, %{microsecond: {_, 6}} = date, 0} -> DateTime.to_iso8601(date) == value
      _ -> false
    end
  end

  defp timestamp?(_), do: false

  defp principal?(id),
    do:
      is_binary(id) and byte_size(id) in 1..256 and
        String.valid?(id) and Regex.match?(~r/\A(?:human|agent)_[A-Za-z0-9_-]+\z/, id)

  defp bound?(nil), do: true
  defp bound?(value), do: is_integer(value) and value in 1..9_223_372_036_854_775_807
  defp limit?(nil), do: true
  defp limit?(value), do: is_integer(value) and value in 1..50
end
