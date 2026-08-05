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

  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.{Session, SessionEntry}

  require Logger

  @max_entry_ordinal 9_223_372_036_854_775_807
  @sqlite_transaction_max_attempts 5
  @sqlite_transaction_initial_backoff_ms 2
  @sqlite_transaction_max_backoff_ms 50
  @effect_marker_key {__MODULE__, :effect_marker}
  @entry_fields [
    :id,
    :session_id,
    :parent_entry_id,
    :entry_type,
    :role,
    :content,
    :model,
    :stop_reason,
    :token_usage,
    :timestamp,
    :metadata,
    :entry_ordinal
  ]

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
    case Repo.one(from(s in Session, where: s.session_id == ^session_id)) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  @doc """
  Return the existing session for `session_id`, or create it for `agent_id`.

  Concurrent first callers converge on the same persisted row: a losing racer's
  `create_session/2` fails on the `session_id` unique constraint, and this
  re-fetches the winner's row instead of surfacing the conflict. Either way the
  returned session's `agent_id` MUST match the requested `agent_id` — a
  `session_id` that already belongs to a different agent fails closed with
  `{:error, {:agent_id_mismatch, owner_agent_id, requested_agent_id}}` rather
  than silently handing back another agent's session.
  """
  @spec ensure_session(String.t(), String.t(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def ensure_session(session_id, agent_id, opts \\ []) do
    case get_session(session_id) do
      {:ok, session} -> check_session_owner(session, agent_id)
      {:error, :not_found} -> create_or_converge_session(session_id, agent_id, opts)
    end
  end

  defp create_or_converge_session(session_id, agent_id, opts) do
    case create_session(agent_id, Keyword.put(opts, :session_id, session_id)) do
      {:ok, session} ->
        check_session_owner(session, agent_id)

      {:error, %Ecto.Changeset{} = changeset} ->
        if session_id_unique_conflict?(changeset) do
          case get_session(session_id) do
            {:ok, session} -> check_session_owner(session, agent_id)
            error -> error
          end
        else
          {:error, changeset}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp check_session_owner(%Session{agent_id: owner_agent_id} = session, agent_id) do
    if owner_agent_id == agent_id do
      {:ok, session}
    else
      {:error, {:agent_id_mismatch, owner_agent_id, agent_id}}
    end
  end

  defp session_id_unique_conflict?(%Ecto.Changeset{errors: errors}) do
    case Keyword.get(errors, :session_id) do
      {_msg, opts} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end
  end

  @doc """
  Find the active session for an agent. Returns the most recently created one.
  """
  @spec get_active_session(String.t()) :: {:ok, Session.t()} | {:error, :not_found}
  def get_active_session(agent_id) do
    query =
      from(s in Session,
        where: s.agent_id == ^agent_id and s.status == "active",
        order_by: [desc: s.inserted_at],
        limit: 1
      )

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
  def append_entry(session_uuid, attrs) when is_map(attrs) do
    case append_entries_internal(session_uuid, [attrs]) do
      {:ok, [entry]} -> {:ok, entry}
      {:error, _reason} = error -> error
    end
  end

  def append_entry(_session_uuid, _attrs), do: {:error, :invalid_entry}

  @doc """
  Bulk-insert multiple entries for a session (single transaction).
  """
  @spec append_entries(Ecto.UUID.t(), [map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def append_entries(session_uuid, entries) when is_list(entries) do
    if proper_list?(entries) do
      case append_entries_internal(session_uuid, entries) do
        {:ok, persisted} -> {:ok, length(persisted)}
        {:error, _reason} = error -> error
      end
    else
      {:error, :improper_entries}
    end
  end

  def append_entries(_session_uuid, _entries), do: {:error, :invalid_entries}

  defp append_entries_internal(_session_uuid, []), do: {:ok, []}

  defp append_entries_internal(session_uuid, entries) do
    with {:ok, prepared} <- prepare_entries(session_uuid, entries) do
      try do
        case transaction(Repo, fn -> append_prepared(session_uuid, prepared) end) do
          {:ok, result} ->
            {:ok, result}

          {:error, reason} ->
            {:error, public_error(reason)}
        end
      rescue
        _error -> {:error, :database_error}
      catch
        :exit, _reason -> {:error, :database_error}
        :throw, _reason -> {:error, :database_error}
      end
    end
  end

  defp prepare_entries(session_uuid, entries) do
    now = DateTime.utc_now()

    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attrs, index}, {:ok, prepared} ->
      case prepare_entry(session_uuid, attrs, now) do
        {:ok, entry} -> {:cont, {:ok, [entry | prepared]}}
        {:error, reason} -> {:halt, {:error, {:invalid_entry, index, reason}}}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      {:error, _reason} = error -> error
    end
  rescue
    _ -> {:error, {:invalid_entry, 0, :malformed_entry}}
  end

  defp prepare_entry(session_uuid, attrs, now) when is_map(attrs) do
    attrs =
      attrs
      |> Map.delete(:entry_ordinal)
      |> Map.delete("entry_ordinal")
      |> Map.put(:session_id, session_uuid)
      |> Map.put_new(:timestamp, now)

    changeset = SessionEntry.changeset(%SessionEntry{}, attrs)

    with {:ok, entry} <- Ecto.Changeset.apply_action(changeset, :insert),
         {:ok, entry} <- ensure_entry_id(entry, attrs),
         :ok <- verify_durable_provenance(entry.metadata, entry.content) do
      {:ok, entry}
    else
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_entry}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_entry(_session_uuid, _attrs, _now), do: {:error, :malformed_entry}

  defp ensure_entry_id(%SessionEntry{id: nil} = entry, attrs) do
    id =
      case Map.get(attrs, :id) do
        value when is_binary(value) -> value
        _ -> Ecto.UUID.generate()
      end

    {:ok, %{entry | id: id}}
  end

  defp ensure_entry_id(%SessionEntry{} = entry, _attrs), do: {:ok, entry}

  defp verify_durable_provenance(metadata, content) when is_map(metadata) do
    cond do
      Map.has_key?(metadata, :taint) ->
        {:error, :ambiguous_taint_metadata_key}

      not Map.has_key?(metadata, "taint") ->
        :ok

      true ->
        case TaintEnvelope.verify(Map.get(metadata, "taint"), content) do
          {:ok, _envelope} -> :ok
          {:error, reason} -> {:error, {:invalid_durable_provenance, reason}}
        end
    end
  end

  defp verify_durable_provenance(_metadata, _content), do: {:error, :invalid_metadata}

  defp append_prepared(session_uuid, prepared) do
    with {:ok, _session} <- lock_session(session_uuid),
         {:ok, ordinals} <- allocate_ordinals(session_uuid, length(prepared)) do
      entries =
        prepared
        |> Enum.zip(ordinals)
        |> Enum.map(fn {entry, ordinal} -> %{entry | entry_ordinal: ordinal} end)

      case entries do
        [entry] ->
          mark_effect_started()

          case Repo.insert(SessionEntry.changeset(entry, %{})) do
            {:ok, persisted} -> [persisted]
            {:error, _changeset} -> Repo.rollback(:database_error)
          end

        entries ->
          rows = Enum.map(entries, &Map.take(&1, @entry_fields))
          mark_effect_started()

          case Repo.insert_all(SessionEntry, rows) do
            {count, _} when count == length(rows) -> entries
            {count, _} -> Repo.rollback({:insert_count_mismatch, count})
          end
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_session(session_uuid) do
    query = from(s in Session, where: s.id == ^session_uuid)
    query = if postgres_repo?(Repo), do: from(s in query, lock: "FOR UPDATE"), else: query

    case Repo.one(query) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  defp allocate_ordinals(session_uuid, count) when is_integer(count) and count > 0 do
    current =
      Repo.one(
        from(e in SessionEntry,
          where: e.session_id == ^session_uuid,
          select: max(e.entry_ordinal)
        )
      ) || 0

    cond do
      not is_integer(current) or current < 0 -> {:error, :invalid_entry_ordinal_state}
      current > @max_entry_ordinal - count -> {:error, :entry_ordinal_overflow}
      true -> {:ok, Enum.to_list((current + 1)..(current + count))}
    end
  end

  defp allocate_ordinals(_session_uuid, 0), do: {:ok, []}

  defp transaction(repo, fun) do
    if sqlite_repo?(repo) do
      sqlite_transaction(repo, fun, 1)
    else
      repo.transaction(fun)
    end
  end

  defp sqlite_transaction(repo, fun, attempt) do
    effect_marker = {__MODULE__, make_ref()}
    Process.put(@effect_marker_key, effect_marker)

    try do
      repo.transaction(fun, mode: :immediate)
    rescue
      error ->
        if retryable_sqlite_failure?(attempt, effect_marker, error) do
          backoff_and_retry(repo, fun, attempt)
        else
          reraise(error, __STACKTRACE__)
        end
    catch
      :exit, reason ->
        if retryable_sqlite_failure?(attempt, effect_marker, reason) do
          backoff_and_retry(repo, fun, attempt)
        else
          exit(reason)
        end

      :throw, reason ->
        throw(reason)
    after
      Process.delete(effect_marker)
      Process.delete(@effect_marker_key)
    end
  end

  defp public_error({:invalid_entry, index, reason}) when is_integer(index) and is_atom(reason),
    do: {:invalid_entry, index, reason}

  defp public_error({:invalid_entry, index, {:invalid_durable_provenance, reason}})
       when is_integer(index) and is_atom(reason),
       do: {:invalid_entry, index, {:invalid_durable_provenance, reason}}

  defp public_error(reason)
       when reason in [
              :not_found,
              :entry_ordinal_overflow,
              :invalid_entry_ordinal_state,
              :database_error,
              :improper_entries,
              :invalid_entries
            ],
       do: reason

  defp public_error(_reason), do: :database_error

  @doc """
  Load entries for a session, ordered by durable entry ordinal ascending.

  Timestamps remain available as a compatibility filter, but they are not the
  transcript ordering authority.

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
      from(e in SessionEntry,
        where: e.session_id == ^session_uuid,
        order_by: [asc: e.entry_ordinal],
        limit: ^limit
      )

    query =
      if after_ts do
        from(e in query, where: e.timestamp > ^after_ts)
      else
        query
      end

    query =
      if types do
        from(e in query, where: e.entry_type in ^types)
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
    Repo.one(from(e in SessionEntry, where: e.session_id == ^session_uuid, select: count()))
  end

  # ── Dashboard display API ──────────────────────────────────────────

  @doc """
  Load recent messages for dashboard display by session_id string.

  Returns display-ready maps with atom keys and unwrapped content.
  Supports cursor-based pagination via `:before_timestamp`.

  ## Options

  - `:limit` — max messages (default 50)
  - `:before_timestamp` — only messages before this DateTime (cursor)
  - `:engagement_id` — only entries stamped `metadata["engagement_id"]` with
    this value, applied in the query before `:limit`
  """
  @spec load_recent_for_display(String.t(), keyword()) :: [map()]
  def load_recent_for_display(session_id, opts \\ []) do
    case get_session(session_id) do
      {:ok, session} ->
        limit = Keyword.get(opts, :limit, 50)
        before_ts = Keyword.get(opts, :before_timestamp)
        engagement_id = Keyword.get(opts, :engagement_id)

        query =
          from(e in SessionEntry,
            where: e.session_id == ^session.id,
            where: e.entry_type in ["user", "assistant"]
          )

        query = maybe_before_timestamp(query, before_ts)
        query = maybe_engagement_filter(query, engagement_id)
        query = from(e in query, order_by: [desc: e.entry_ordinal], limit: ^limit)

        Repo.all(query)
        |> Enum.reverse()
        |> Enum.map(&entry_to_display_map/1)

      {:error, _} ->
        []
    end
  rescue
    _ -> []
  end

  defp maybe_before_timestamp(query, nil), do: query

  defp maybe_before_timestamp(query, before_ts) do
    from(e in query, where: e.timestamp < ^before_ts)
  end

  defp maybe_engagement_filter(query, nil), do: query

  defp maybe_engagement_filter(query, engagement_id) do
    case repo_adapter(Repo) do
      Ecto.Adapters.SQLite3 ->
        from(e in query,
          where: fragment("json_extract(?, '$.engagement_id')", e.metadata) == ^engagement_id
        )

      _ ->
        from(e in query, where: fragment("?->>'engagement_id'", e.metadata) == ^engagement_id)
    end
  end

  # Arbor.Persistence.Repo.__adapter__/0 is the ONLY adapter source that can't
  # drift from what the Repo module was actually compiled with (`use Ecto.Repo,
  # adapter: Application.compile_env(...)`). Application.get_env/3 reads the
  # same config key at RUNTIME and can be mutated independently of the already-
  # compiled Repo (e.g. by a test or a later config load), which would pick the
  # wrong SQL dialect below — a real correctness bug, not just a lint concern.
  #
  # __adapter__/0 is called through this repo-as-parameter indirection, not as
  # a literal `Repo.__adapter__()` inline in the case above: dispatching on a
  # parameter keeps Elixir's set-theoretic type checker from narrowing the
  # call's return type to this build's single compiled adapter (which is what
  # made the non-matching case clause a compile-time "will never match"
  # warning — fatal under --warnings-as-errors — when this was written as a
  # literal call). Same technique as `postgres_repo?/1` /
  # `sqlite_repo?/1` in event_log/ecto.ex, which take `repo` as a parameter for
  # the identical reason.
  defp repo_adapter(repo), do: repo.__adapter__()

  @doc """
  Count user + assistant messages for a session by session_id string.
  """
  @spec message_count_by_session_id(String.t()) :: non_neg_integer()
  def message_count_by_session_id(session_id) do
    case get_session(session_id) do
      {:ok, session} ->
        Repo.one(
          from(e in SessionEntry,
            where: e.session_id == ^session.id,
            where: e.entry_type in ["user", "assistant"],
            select: count()
          )
        )

      {:error, _} ->
        0
    end
  rescue
    _ -> 0
  end

  # Convert a SessionEntry to a display-ready map for the dashboard
  defp entry_to_display_map(entry) do
    {taint, taint_status} = resolve_entry_taint(entry.metadata, entry.content)

    role =
      case entry.role do
        "user" -> :user
        "assistant" -> :assistant
        "system" -> :system
        other -> String.to_existing_atom(other)
      end

    %{
      id: entry.id,
      role: role,
      content: unwrap_content(entry.content),
      timestamp: entry.timestamp,
      model: entry.model,
      token_usage: entry.token_usage,
      metadata: entry.metadata,
      taint: taint,
      taint_status: taint_status,
      entry_ordinal: entry.entry_ordinal
    }
  rescue
    # If atom conversion fails, keep as string
    _ ->
      {taint, taint_status} = resolve_entry_taint(entry.metadata, entry.content)

      %{
        id: entry.id,
        role: entry.role,
        content: unwrap_content(entry.content),
        timestamp: entry.timestamp,
        model: entry.model,
        token_usage: entry.token_usage,
        metadata: entry.metadata,
        taint: taint,
        taint_status: taint_status,
        entry_ordinal: entry.entry_ordinal
      }
  end

  defp resolve_entry_taint(metadata, content) when is_map(metadata) do
    if Map.has_key?(metadata, :taint) do
      {TaintEnvelope.invalid_fallback(), :invalid_durable_provenance}
    else
      TaintEnvelope.resolve(Map.get(metadata, "taint", :missing), content)
      |> case do
        {:ok, taint, status} -> {taint, status}
        _ -> {TaintEnvelope.invalid_fallback(), :invalid_durable_provenance}
      end
    end
  end

  defp resolve_entry_taint(_metadata, _content),
    do: {TaintEnvelope.invalid_fallback(), :invalid_durable_provenance}

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp postgres_repo?(repo), do: repo_adapter(repo) == Ecto.Adapters.Postgres
  defp sqlite_repo?(repo), do: repo_adapter(repo) == Ecto.Adapters.SQLite3

  defp sqlite_lock_failure?(%{__exception__: true} = error) do
    error
    |> Exception.message()
    |> sqlite_lock_message?()
  end

  defp sqlite_lock_failure?(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.any?(&sqlite_lock_failure?/1)
  end

  defp sqlite_lock_failure?(value) when is_list(value),
    do: Enum.any?(value, &sqlite_lock_failure?/1)

  defp sqlite_lock_failure?(_value), do: false

  defp sqlite_lock_message?(message) when is_binary(message) do
    normalized = String.downcase(message)

    String.contains?(normalized, "database is busy") or
      String.contains?(normalized, "database busy") or
      String.contains?(normalized, "database is locked") or
      String.contains?(normalized, "database table is locked")
  end

  defp sqlite_lock_message?(_message), do: false

  defp retryable_sqlite_failure?(attempt, marker, failure) do
    attempt < @sqlite_transaction_max_attempts and
      Process.get(marker) != true and sqlite_lock_failure?(failure)
  end

  defp backoff_and_retry(repo, fun, attempt) do
    backoff_ms =
      min(
        @sqlite_transaction_initial_backoff_ms * Integer.pow(2, attempt - 1),
        @sqlite_transaction_max_backoff_ms
      )

    Process.sleep(backoff_ms)
    sqlite_transaction(repo, fun, attempt + 1)
  end

  defp mark_effect_started do
    case Process.get(@effect_marker_key) do
      marker when is_tuple(marker) -> Process.put(marker, true)
      _ -> :ok
    end
  end

  # Unwrap content blocks to plain text for display.
  # Content may be: [%{"type" => "text", "text" => "hello"}], a plain string, or nil.
  defp unwrap_content(nil), do: ""
  defp unwrap_content(content) when is_binary(content), do: content

  defp unwrap_content(content) when is_list(content) do
    content
    |> Enum.filter(fn
      %{"type" => "text"} -> true
      _ -> false
    end)
    |> Enum.map_join("\n", fn block -> block["text"] || "" end)
  end

  defp unwrap_content(_), do: ""

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
