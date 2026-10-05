defmodule Arbor.Comms.ConversationDirectory do
  @moduledoc false
  alias Arbor.Comms.Config
  @keys [:agent_id, :engagement_id, :owner_tenant, :scope, :visibility, :status, :updated_at]
  @human ~r/\Ahuman_[A-Za-z0-9_-]+\z/
  @agent ~r/\Aagent_[A-Za-z0-9_-]+\z/
  @engagement ~r/\Aeng_[0-9a-f]{32}\z/

  def list(owner, opts) do
    persistence = Config.conversation_directory_persistence_module()

    with {:ok, bounds} <- persistence.normalize_conversation_directory_options(opts),
         true <- id?(owner, @human),
         {:ok, %{records: records, has_more: more, next_cursor: cursor} = page} <-
           persistence.list_user_conversation_records(owner, opts),
         true <- map_size(page) == 3 and is_list(records) and length(records) <= bounds.limit,
         true <- is_boolean(more),
         true <-
           (more and cursor == bounds.cursor + bounds.limit) or (not more and is_nil(cursor)),
         true <- Enum.all?(records, &valid_record?(&1, owner)) do
      {:ok, page}
    else
      {:error, reason}
      when reason in [:invalid_options, :invalid_identifier, :conversation_unavailable] ->
        {:error, reason}

      _ ->
        {:error, :conversation_unavailable}
    end
  rescue
    _ -> {:error, :conversation_unavailable}
  catch
    _, _ -> {:error, :conversation_unavailable}
  end

  def reference(owner, engagement_id) do
    with true <- id?(owner, @human) and id?(engagement_id, @engagement),
         {:ok, record} <-
           Config.conversation_directory_persistence_module().read_user_conversation_record(
             owner,
             engagement_id
           ),
         true <- valid_record?(record, owner) and record.engagement_id == engagement_id do
      {:ok, record}
    else
      {:error, reason}
      when reason in [:invalid_identifier, :not_found, :conversation_unavailable] ->
        {:error, reason}

      _ ->
        {:error, :conversation_unavailable}
    end
  rescue
    _ -> {:error, :conversation_unavailable}
  catch
    _, _ -> {:error, :conversation_unavailable}
  end

  defp valid_record?(record, owner) when is_map(record) and not is_struct(record) do
    Enum.sort(Map.keys(record)) == Enum.sort(@keys) and
      record.owner_tenant == owner and record.scope == "user" and record.visibility == "private" and
      record.status in ["active", "parked", "archived"] and id?(record.agent_id, @agent) and
      id?(record.engagement_id, @engagement) and match?(%DateTime{}, record.updated_at)
  end

  defp valid_record?(_, _), do: false

  defp id?(id, pattern) when is_binary(id),
    do: byte_size(id) in 1..256 and String.valid?(id) and Regex.match?(pattern, id)

  defp id?(_, _), do: false
end
