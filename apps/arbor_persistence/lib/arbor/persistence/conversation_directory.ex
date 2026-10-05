defmodule Arbor.Persistence.ConversationDirectory do
  @moduledoc false
  import Ecto.Query
  alias Arbor.Persistence.Config
  alias Arbor.Persistence.Schemas.{Engagement, Session, SessionEntry, ConversationNoticeHead}

  @maximum 9_223_372_036_854_775_807
  @human ~r/\Ahuman_[A-Za-z0-9_-]+\z/
  @engagement ~r/\Aeng_[0-9a-f]{32}\z/

  def normalize_options(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)
      cursor = Keyword.get(opts, :cursor, 0)
      limit = Keyword.get(opts, :limit, 20)

      if length(keys) == length(Enum.uniq(keys)) and
           Enum.all?(keys, &(&1 in [:cursor, :limit])) and
           is_integer(cursor) and cursor >= 0 and cursor <= @maximum - 100 and
           is_integer(limit) and limit in 1..100,
         do: {:ok, %{cursor: cursor, limit: limit}},
         else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  def list(owner, opts) do
    with {:ok, bounds} <- normalize_options(opts),
         true <- valid_id?(owner, @human),
         {:ok, repo} <- Config.sql_repository() do
      records =
        owner
        |> owned_query(repo)
        |> order_activity()
        |> limit(^(bounds.limit + 1))
        |> offset(^bounds.cursor)
        |> repo.all(timeout: 5_000)

      more = length(records) > bounds.limit

      {:ok,
       %{
         records: Enum.take(records, bounds.limit),
         has_more: more,
         next_cursor: if(more, do: bounds.cursor + bounds.limit, else: nil)
       }}
    else
      false -> {:error, :invalid_identifier}
      error -> error
    end
  rescue
    _ -> {:error, :conversation_unavailable}
  catch
    _, _ -> {:error, :conversation_unavailable}
  end

  def reference(owner, engagement_id) do
    with true <- valid_id?(owner, @human) and valid_id?(engagement_id, @engagement),
         {:ok, repo} <- Config.sql_repository(),
         record when not is_nil(record) <-
           repo.one(
             from(g in owned_query(owner, repo), where: g.engagement_id == ^engagement_id),
             timeout: 5_000
           ) do
      {:ok, record}
    else
      false -> {:error, :invalid_identifier}
      nil -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :conversation_unavailable}
  catch
    _, _ -> {:error, :conversation_unavailable}
  end

  # Metadata JSON syntax follows the compiled Repo adapter, never a mutable
  # application setting. All identifiers and owner/engagement values are bound.
  defp owned_query(owner, repo) do
    stamped =
      case repo_adapter(repo) do
        Ecto.Adapters.SQLite3 ->
          dynamic(
            [g, _s, e],
            fragment("json_extract(?, '$.engagement_id')", e.metadata) == g.engagement_id
          )

        _ ->
          dynamic([g, _s, e], fragment("?->>'engagement_id'", e.metadata) == g.engagement_id)
      end

    entry_join =
      dynamic(
        [_g, s, e],
        e.session_id == s.id and e.entry_type in ["user", "assistant"] and ^stamped
      )

    from(g in Engagement,
      where: g.owner_tenant == ^owner and g.scope == "user" and g.visibility == "private",
      left_join: s in Session,
      on:
        s.agent_id == g.agent_id and s.session_id == fragment("'agent-session-' || ?", g.agent_id),
      left_join: e in SessionEntry,
      on: ^entry_join,
      left_join: h in ConversationNoticeHead,
      on:
        h.engagement_id == g.engagement_id and h.owner_id == g.owner_tenant and
          h.target_agent_id == g.agent_id,
      group_by: [
        g.engagement_id,
        g.agent_id,
        g.owner_tenant,
        g.scope,
        g.visibility,
        g.status,
        g.updated_at,
        h.activity_at
      ],
      select: %{
        engagement_id: g.engagement_id,
        agent_id: g.agent_id,
        owner_tenant: g.owner_tenant,
        scope: g.scope,
        visibility: g.visibility,
        status: g.status,
        updated_at:
          selected_as(
            type(
              fragment(
                "CASE WHEN ? IS NULL THEN COALESCE(?, ?) WHEN ? IS NULL OR ? >= ? THEN ? ELSE ? END",
                max(e.timestamp),
                h.activity_at,
                g.updated_at,
                h.activity_at,
                max(e.timestamp),
                h.activity_at,
                max(e.timestamp),
                h.activity_at
              ),
              :utc_datetime_usec
            ),
            :activity
          )
      }
    )
  end

  defp order_activity(query),
    do: from(g in query, order_by: [desc: selected_as(:activity), asc: g.engagement_id])

  defp repo_adapter(repo), do: repo.__adapter__()

  defp valid_id?(id, pattern) when is_binary(id),
    do: byte_size(id) in 1..256 and String.valid?(id) and Regex.match?(pattern, id)

  defp valid_id?(_, _), do: false
end
