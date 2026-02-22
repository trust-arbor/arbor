defmodule Arbor.Persistence.SessionStore do
  @moduledoc """
  Persistence context for agent sessions and session entries.

  Sessions are append-only life logs — each turn, heartbeat, or tool
  interaction creates a new SessionEntry row. No ETS caching is needed
  since sessions are write-heavy and reads are infrequent (primarily
  on restart recovery and JSONL export).

  ## JSONL Export

  `export_jsonl/1` streams entries in Claude Code's JSONL format, making
  sessions portable and compatible with external tooling.
  """

  import Ecto.Query

  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.{Session, SessionEntry}

  require Logger

  # ── Session lifecycle ──────────────────────────────────────────────

  @doc """
  Create a new session record for an agent.

  ## Options

  - `:model` — default LLM model
  - `:cwd` — working directory context
  - `:git_branch` — branch context
  - `:metadata` — extensible JSONB map
  """
  @spec create_session(String.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def create_session(agent_id, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "agent-session-#{agent_id}")

    attrs = %{
      session_id: session_id,
      agent_id: agent_id,
      status: "active",
      model: Keyword.get(opts, :model),
      cwd: Keyword.get(opts, :cwd),
      git_branch: Keyword.get(opts, :git_branch),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get a session by its session_id string.
  """
  @spec get_session(String.t()) :: {:ok, Session.t()} | {:error, :not_found}
  def get_session(session_id) do
    case Repo.one(from s in Session, where: s.session_id == ^session_id) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  @doc """
  Find the active session for an agent. Returns the most recently created one.
  """
  @spec get_active_session(String.t()) :: {:ok, Session.t()} | {:error, :not_found}
  def get_active_session(agent_id) do
    query =
      from s in Session,
        where: s.agent_id == ^agent_id and s.status == "active",
        order_by: [desc: s.inserted_at],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  @doc """
  Terminate a session (sets status to "terminated").
  """
  @spec terminate_session(String.t()) :: {:ok, Session.t()} | {:error, term()}
  def terminate_session(session_id) do
    case get_session(session_id) do
      {:ok, session} ->
        session
        |> Session.changeset(%{status: "terminated"})
        |> Repo.update()

      error ->
        error
    end
  end

  # ── Session entries ────────────────────────────────────────────────

  @doc """
  Append a single entry to a session.

  The `session_id` here is the Postgres UUID, not the string session_id.
  Use `get_session/1` first to resolve the UUID.

  ## Required attrs

  - `:entry_type` — "user", "assistant", "heartbeat", etc.
  - `:timestamp` — UTC datetime

  ## Optional attrs

  - `:role`, `:content`, `:model`, `:stop_reason`, `:token_usage`,
    `:parent_entry_id`, `:metadata`
  """
  @spec append_entry(Ecto.UUID.t(), map()) :: {:ok, SessionEntry.t()} | {:error, term()}
  def append_entry(session_uuid, attrs) do
    attrs
    |> Map.put(:session_id, session_uuid)
    |> Map.put_new(:timestamp, DateTime.utc_now())
    |> then(&SessionEntry.changeset(%SessionEntry{}, &1))
    |> Repo.insert()
  end

  @doc """
  Bulk-insert multiple entries for a session (single transaction).
  """
  @spec append_entries(Ecto.UUID.t(), [map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def append_entries(session_uuid, entries) when is_list(entries) do
    now = DateTime.utc_now()

    rows =
      Enum.map(entries, fn attrs ->
        attrs
        |> Map.put(:session_id, session_uuid)
        |> Map.put_new(:timestamp, now)
        |> Map.put_new(:id, Ecto.UUID.generate())
      end)

    case Repo.insert_all(SessionEntry, rows) do
      {count, _} -> {:ok, count}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Load entries for a session, ordered by timestamp ascending.

  ## Options

  - `:limit` — max entries to return (default: 1000)
  - `:after_timestamp` — only entries after this DateTime
  - `:entry_types` — filter to specific types (list of strings)
  """
  @spec load_entries(Ecto.UUID.t(), keyword()) :: [SessionEntry.t()]
  def load_entries(session_uuid, opts \\ []) do
    limit = Keyword.get(opts, :limit, 1000)
    after_ts = Keyword.get(opts, :after_timestamp)
    types = Keyword.get(opts, :entry_types)

    query =
      from e in SessionEntry,
        where: e.session_id == ^session_uuid,
        order_by: [asc: e.timestamp],
        limit: ^limit

    query =
      if after_ts do
        from e in query, where: e.timestamp > ^after_ts
      else
        query
      end

    query =
      if types do
        from e in query, where: e.entry_type in ^types
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Load entries by the string session_id (resolves UUID internally).
  """
  @spec load_entries_by_session_id(String.t(), keyword()) :: [SessionEntry.t()]
  def load_entries_by_session_id(session_id, opts \\ []) do
    case get_session(session_id) do
      {:ok, session} -> load_entries(session.id, opts)
      {:error, _} -> []
    end
  end

  @doc """
  Count entries in a session.
  """
  @spec entry_count(Ecto.UUID.t()) :: non_neg_integer()
  def entry_count(session_uuid) do
    Repo.one(from e in SessionEntry, where: e.session_id == ^session_uuid, select: count())
  end

  # ── JSONL export ───────────────────────────────────────────────────

  @doc """
  Export a session as a list of JSONL-compatible maps.

  Each map follows Claude Code's session JSONL format:
  type, uuid, parentUuid, sessionId, timestamp, message (role, content, model, etc.)
  """
  @spec export_jsonl(String.t()) :: {:ok, [map()]} | {:error, term()}
  def export_jsonl(session_id) do
    case get_session(session_id) do
      {:ok, session} ->
        entries = load_entries(session.id, limit: 100_000)

        lines =
          Enum.map(entries, fn entry ->
            %{
              "type" => entry.entry_type,
              "uuid" => entry.id,
              "parentUuid" => entry.parent_entry_id,
              "sessionId" => session.session_id,
              "timestamp" => format_timestamp(entry.timestamp),
              "message" => %{
                "role" => entry.role,
                "content" => entry.content,
                "model" => entry.model,
                "stop_reason" => entry.stop_reason,
                "usage" => entry.token_usage
              },
              "version" => Map.get(entry.metadata, "version"),
              "cwd" => session.cwd || Map.get(entry.metadata, "cwd"),
              "gitBranch" => session.git_branch
            }
          end)

        {:ok, lines}

      error ->
        error
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp format_timestamp(nil), do: nil
  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  @doc """
  Check if the session store is available (Repo process running).
  """
  @spec available?() :: boolean()
  def available? do
    Process.whereis(Repo) != nil
  end
end
