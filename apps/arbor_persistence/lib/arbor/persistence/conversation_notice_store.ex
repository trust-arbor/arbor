defmodule Arbor.Persistence.ConversationNoticeStore do
  @moduledoc false
  import Ecto.Query
  alias Ecto.Adapter
  alias Ecto.Adapters.SQL
  alias Arbor.Persistence.{Config, ConversationNoticePageCore}
  alias Arbor.Persistence.Schemas.{Engagement, ConversationNotice, ConversationNoticeHead}

  @value_keys [:notice_id, :recipient_subject_id, :kind, :text, :provenance]
  @maximum 9_223_372_036_854_775_807

  def append(scope, value), do: append_with_mode(scope, value, :trusted_storage)
  def append_native(scope, value), do: append_with_mode(scope, value, :native)

  defp append_with_mode(scope, value, mode) do
    with {:ok, value, digest} <- facts(scope, value),
         true <- ConversationNoticePageCore.fits_record?(scope, value),
         {:ok, repo} <- Config.sql_repository() do
      deadline = deadline()

      write_transaction(repo, deadline, fn ->
        append_locked(repo, scope, value, digest, deadline, mode)
      end)
    else
      false -> {:error, :notice_too_large}
      error -> error
    end
  rescue
    _ -> {:error, :notice_unavailable}
  catch
    _, _ -> {:error, :notice_unavailable}
  end

  def reconcile(scope, value) do
    with {:ok, value, digest} <- facts(scope, value),
         {:ok, repo} <- Config.sql_repository() do
      deadline = deadline()

      read_transaction(repo, deadline, fn ->
        owned_engagement!(repo, scope, deadline, false)

        case repo.one(identity_query(scope, value.notice_id), query_options(repo, deadline)) do
          nil -> repo.rollback(:notice_not_found)
          record -> existing!(repo, scope, value, digest, record)
        end
      end)
    end
  rescue
    _ -> {:error, :notice_unavailable}
  catch
    _, _ -> {:error, :notice_unavailable}
  end

  def read(scope, opts) do
    with :ok <- validate_scope(scope),
         {:ok, bounds} <- ConversationNoticePageCore.options(opts),
         {:ok, repo} <- Config.sql_repository() do
      deadline = deadline()

      read_transaction(repo, deadline, fn ->
        owned_engagement!(repo, scope, deadline, false)

        head_record =
          repo.get(ConversationNoticeHead, scope.engagement_id, query_options(repo, deadline))

        head = validate_head!(repo, scope, head_record)

        {minimum, maximum} =
          repo.one(
            from(n in scope_query(scope), select: {min(n.ordinal), max(n.ordinal)}),
            query_options(repo, deadline)
          )

        unless is_nil(minimum) or (is_integer(minimum) and minimum > 0 and maximum <= head),
          do: repo.rollback(:invalid_notice_record)

        through = bounds.through || head
        if through > head, do: repo.rollback(:invalid_notice_options)

        query = scope_query(scope) |> where([n], n.ordinal <= ^through)
        query = if bounds.before, do: where(query, [n], n.ordinal < ^bounds.before), else: query

        rows =
          query
          |> order_by([n], desc: n.ordinal)
          |> limit(^(bounds.limit + 1))
          |> repo.all(query_options(repo, deadline))

        projections = Enum.map(rows, &verified_projection!(repo, scope, &1, head))

        case ConversationNoticePageCore.page(scope, projections, head, through, bounds.limit) do
          {:ok, page} -> page
          {:error, reason} -> repo.rollback(reason)
        end
      end)
    end
  rescue
    _ -> {:error, :notice_unavailable}
  catch
    _, _ -> {:error, :notice_unavailable}
  end

  defp append_locked(repo, scope, value, digest, deadline, mode) do
    engagement = owned_engagement!(repo, scope, deadline, true)

    case repo.one(identity_query(scope, value.notice_id), query_options(repo, deadline)) do
      nil ->
        insert!(repo, engagement, scope, value, digest, deadline, mode)

      record ->
        result = existing!(repo, scope, value, digest, record)
        native_gate!(repo, scope, value, mode, :reconcile)
        result
    end
  end

  defp insert!(repo, engagement, scope, value, digest, deadline, mode) do
    old_head =
      repo.get(ConversationNoticeHead, scope.engagement_id, query_options(repo, deadline))

    ordinal = validate_head!(repo, scope, old_head) + 1
    if ordinal > @maximum, do: repo.rollback(:notice_ordinal_exhausted)
    native_gate!(repo, scope, value, mode, :consume)
    created_at = DateTime.utc_now()

    attrs =
      Map.merge(scope, value)
      |> Map.merge(%{ordinal: ordinal, created_at: created_at, facts_digest: digest})

    record = repo.insert!(struct(ConversationNotice, attrs), query_options(repo, deadline))
    head_attrs = Map.merge(scope, %{ordinal: ordinal, activity_at: created_at})

    if old_head do
      old_head |> Ecto.Changeset.change(head_attrs) |> repo.update!(query_options(repo, deadline))
    else
      repo.insert!(struct(ConversationNoticeHead, head_attrs), query_options(repo, deadline))
    end

    engagement
    |> Ecto.Changeset.change(updated_at: created_at)
    |> repo.update!(query_options(repo, deadline))

    result(scope, value, record, :inserted)
  end

  defp native_gate!(_repo, _scope, _value, :trusted_storage, _operation), do: :ok

  defp native_gate!(repo, scope, value, :native, operation) do
    # No spawn or caller callback: the acquired transaction still runs on the
    # exact native worker whose private admission the Security broker owns.
    outcome =
      case operation do
        :consume -> Arbor.Security.consume_native_notice_commit(scope, value)
        :reconcile -> Arbor.Security.reconcile_native_notice_commit(scope, value)
      end

    case outcome do
      :ok -> :ok
      {:error, reason} when is_atom(reason) -> repo.rollback(reason)
      _ -> repo.rollback(:notice_publication_refused)
    end
  end

  defp existing!(repo, scope, value, digest, record) do
    stored = stored_value(record)

    with {:ok, ^stored, ^digest} <- facts(scope, stored),
         true <- record.facts_digest == digest and stored == value and valid_record?(record) do
      result(scope, stored, record, :existing)
    else
      {:ok, _, _} -> repo.rollback(:notice_conflict)
      false -> repo.rollback(:notice_conflict)
      _ -> repo.rollback(:invalid_notice_record)
    end
  end

  defp verified_projection!(repo, scope, record, head) do
    value = stored_value(record)

    with true <- valid_record?(record) and record.ordinal <= head,
         {:ok, ^value, digest} <- facts(scope, value),
         true <-
           record.facts_digest == digest and ConversationNoticePageCore.fits_record?(scope, value) do
      Map.take(value, [:notice_id, :recipient_subject_id, :kind, :text, :provenance])
      |> Map.merge(%{ordinal: record.ordinal, created_at: DateTime.to_iso8601(record.created_at)})
    else
      _ -> repo.rollback(:invalid_notice_record)
    end
  end

  defp result(scope, value, record, disposition),
    do: %{
      scope: scope,
      notice:
        Map.merge(value, %{
          ordinal: record.ordinal,
          created_at: DateTime.to_iso8601(record.created_at)
        }),
      disposition: disposition
    }

  defp stored_value(record), do: Map.take(record, @value_keys)

  defp valid_record?(record),
    do:
      is_integer(record.ordinal) and record.ordinal in 1..@maximum and
        match?(%DateTime{}, record.created_at)

  defp facts(scope, value) do
    with :ok <- validate_scope(scope),
         {:ok, value} <- Arbor.Security.validate_notice_publication_value(scope, value),
         {:ok, digest} <- Arbor.Security.notice_publication_facts_digest(scope, value) do
      {:ok, value, digest}
    end
  end

  defp validate_scope(scope) do
    case Arbor.Security.validate_notice_publication_scope(scope) do
      {:ok, _scope} -> :ok
      {:error, _} -> {:error, :invalid_notice_scope}
    end
  end

  defp owned_engagement!(repo, scope, deadline, lock?) do
    query =
      from(e in Engagement,
        where:
          e.engagement_id == ^scope.engagement_id and e.agent_id == ^scope.target_agent_id and
            e.owner_tenant == ^scope.owner_id and e.scope == "user" and e.visibility == "private"
      )

    query =
      if lock? and repo.__adapter__() == Ecto.Adapters.Postgres,
        do: lock(query, "FOR UPDATE"),
        else: query

    case repo.one(query, query_options(repo, deadline)) do
      nil -> repo.rollback(:notice_scope_not_found)
      engagement -> engagement
    end
  end

  defp validate_head!(_repo, _scope, nil), do: 0

  defp validate_head!(repo, scope, head) do
    if head.owner_id == scope.owner_id and head.target_agent_id == scope.target_agent_id and
         is_integer(head.ordinal) and head.ordinal in 1..@maximum and
         match?(%DateTime{}, head.activity_at),
       do: head.ordinal,
       else: repo.rollback(:invalid_notice_record)
  end

  defp scope_query(scope),
    do:
      from(n in ConversationNotice,
        where:
          n.owner_id == ^scope.owner_id and n.target_agent_id == ^scope.target_agent_id and
            n.engagement_id == ^scope.engagement_id
      )

  defp identity_query(scope, id), do: scope_query(scope) |> where([n], n.notice_id == ^id)
  defp deadline, do: System.monotonic_time(:millisecond) + 5_000

  defp read_transaction(repo, deadline, fun) do
    opts = if repo.__adapter__() == Ecto.Adapters.SQLite3, do: [mode: :deferred], else: []
    marker = {__MODULE__, make_ref()}

    try do
      read_acquire(repo, deadline, fun, opts, marker, 0)
    after
      Process.delete(marker)
    end
  end

  defp read_acquire(repo, deadline, fun, opts, marker, attempt) do
    if deadline > System.monotonic_time(:millisecond) do
      Process.put(marker, :acquiring)

      try do
        bounded_transaction(
          repo,
          deadline,
          fn ->
            Process.put(marker, :entered)
            fun.()
          end,
          opts
        )
      rescue
        error in DBConnection.ConnectionError ->
          # Only retry the pinned pool's immediate checkout refusal, before
          # any scoped read callback runs. Neither queueing nor query replay
          # may extend the caller's original absolute deadline.
          if Process.get(marker) == :acquiring and read_checkout_unavailable?(error) do
            remaining = deadline - System.monotonic_time(:millisecond)

            if remaining > 0 do
              Process.sleep(min(remaining, min(50, 2 * Integer.pow(2, min(attempt, 5)))))
              read_acquire(repo, deadline, fun, opts, marker, attempt + 1)
            else
              {:error, :notice_unavailable}
            end
          else
            reraise error, __STACKTRACE__
          end
      end
    else
      {:error, :notice_unavailable}
    end
  end

  defp read_checkout_unavailable?(%DBConnection.ConnectionError{
         message: "connection not available and queuing is disabled",
         reason: :error
       }),
       do: true

  defp read_checkout_unavailable?(_), do: false

  defp write_transaction(repo, deadline, fun) do
    case repo.__adapter__() do
      Ecto.Adapters.SQLite3 -> sqlite_write_transaction(repo, deadline, fun)
      Ecto.Adapters.Postgres -> bounded_transaction(repo, deadline, fun, [])
      _ -> {:error, :notice_unavailable}
    end
  end

  defp sqlite_write_transaction(repo, deadline, fun) do
    # Local attempt bookkeeping is not publisher evidence. Retry only BEGIN /
    # checkout acquisition, before the transaction callback has run any query.
    marker = {__MODULE__, make_ref()}

    try do
      sqlite_acquire(repo, deadline, fun, marker, 0)
    after
      Process.delete(marker)
    end
  end

  defp sqlite_acquire(repo, deadline, fun, marker, attempt) do
    Process.put(marker, :acquiring)

    result =
      try do
        sqlite_attempt(repo, deadline, fn ->
          Process.put(marker, :entered)
          fun.()
        end)
      rescue
        error -> {:acquisition_error, error}
      catch
        :exit, reason -> {:acquisition_error, reason}
      end

    case result do
      {:acquisition_error, failure} ->
        retry_acquisition(repo, deadline, fun, marker, attempt, failure)

      {:error, failure} ->
        if Process.get(marker) == :entered,
          do: {:error, failure},
          else: retry_acquisition(repo, deadline, fun, marker, attempt, failure)

      outcome ->
        outcome
    end
  end

  defp retry_acquisition(repo, deadline, fun, marker, attempt, failure) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if Process.get(marker) == :acquiring and remaining > 0 and acquisition_failure?(failure) do
      Process.sleep(min(remaining, min(50, 2 * Integer.pow(2, min(attempt, 5)))))

      if deadline > System.monotonic_time(:millisecond),
        do: sqlite_acquire(repo, deadline, fun, marker, attempt + 1),
        else: {:error, :notice_unavailable}
    else
      {:error, :notice_unavailable}
    end
  end

  defp acquisition_failure?(%{__exception__: true} = failure),
    do: acquisition_failure?(Exception.message(failure))

  defp acquisition_failure?(failure) when is_binary(failure),
    do:
      String.contains?(failure, [
        "database is locked",
        "database is busy",
        "SQLITE_BUSY",
        "SQLITE_LOCKED",
        "connection not available",
        "queue is full"
      ])

  defp acquisition_failure?(failure) when is_tuple(failure),
    do: failure |> Tuple.to_list() |> Enum.any?(&acquisition_failure?/1)

  defp acquisition_failure?(_), do: false

  defp sqlite_attempt(repo, deadline, fun) do
    repo.get_dynamic_repo()
    |> Adapter.lookup_meta()
    |> SQL.checkout(query_options(repo, deadline), fn ->
      %{rows: [[original]]} =
        repo.query!("PRAGMA busy_timeout", [], control_options(repo, deadline))

      try do
        repo.query!("PRAGMA busy_timeout = 5", [], control_options(repo, deadline))
        bounded_transaction(repo, deadline, fun, mode: :immediate)
      after
        repo.query("PRAGMA busy_timeout = #{original}", [], timeout: 25, queue: false)
      end
    end)
  end

  defp bounded_transaction(repo, deadline, fun, opts) do
    repo.transaction(
      fn ->
        query_options(repo, deadline)
        result = fun.()
        query_options(repo, deadline)
        result
      end,
      Keyword.merge(opts, query_options(repo, deadline))
    )
  end

  defp query_options(repo, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 ->
        [timeout: remaining, deadline: deadline, queue: false, log: false]

      _ ->
        repo.rollback(:notice_unavailable)
    end
  end

  defp control_options(repo, deadline),
    do: Keyword.update!(query_options(repo, deadline), :timeout, &min(&1, 25))
end
