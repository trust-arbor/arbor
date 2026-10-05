defmodule Arbor.Persistence.ConversationCommandIndex do
  @moduledoc """
  Durable observation index for Comms-owned conversation commands.

  A committed page and its source watermark are atomic here. EventLog append is
  independent: this index never proves that it has reached the authoritative head
  and never authorizes execution, cancellation or disclosure. Comms must compare
  the returned watermark to the journal head before claiming completeness.
  """
  import Ecto.Query
  alias Ecto.{Adapter, Adapters.SQL}
  alias Arbor.Persistence.Config
  alias Arbor.Persistence.Schemas.ConversationCommand, as: Command
  alias Arbor.Persistence.Schemas.ConversationCommandCheckpoint, as: Checkpoint
  alias Arbor.Persistence.Schemas.ConversationCommandPage, as: Page

  @maximum 2_147_483_647
  @scope_keys [:owner_id, :target_agent_id, :engagement_id, :stream_id]
  @row_keys [
    :command_id,
    :admitted_event_number,
    :source_event_number,
    :delivery_status,
    :cancellation_status,
    :cancellation_termination
  ]
  @delivery ["admitted", "dispatch_started", "completed", "uncertain", "cancelled"]
  @cancellation ["none", "requested", "confirmed"]
  @termination [nil, "never_dispatched", "queued_removed", "engine_terminated"]
  @page_timeout_ms 5_000
  @sqlite_busy_slice_ms 5
  @sqlite_pragma_timeout_ms 25

  def project(scope, row, cursor) when is_integer(cursor) and cursor > 0,
    do: project_page(scope, [row], %{from: cursor - 1, to: cursor})

  def project(_, _, _), do: {:error, :invalid_projection}

  def project_page(scope, rows, cursors) do
    with :ok <- validate_scope(scope),
         {:ok, rows, from_cursor, to_cursor} <- validate_page(rows, cursors),
         {:ok, repo} <- Config.sql_repository() do
      digest = digest({scope, rows, from_cursor, to_cursor})
      deadline = System.monotonic_time(:millisecond) + @page_timeout_ms

      project_transaction(repo, deadline, fn ->
        repo.insert_all(Checkpoint, [Map.put(scope, :watermark, 0)],
          on_conflict: :nothing,
          conflict_target: [:stream_id],
          timeout: remaining_timeout!(repo, deadline),
          deadline: deadline
        )

        checkpoint = repo.one(checkpoint_query(scope), query_options(repo, deadline))
        unless checkpoint, do: repo.rollback(:projection_scope_conflict)
        validate_checkpoint!(repo, checkpoint)

        page =
          repo.get_by(
            Page,
            [stream_id: scope.stream_id, from_cursor: from_cursor],
            query_options(repo, deadline)
          )

        cond do
          page && page.to_cursor == to_cursor && page.digest == digest ->
            %{watermark: checkpoint.watermark, projected: 0}

          page ->
            repo.rollback(:projection_source_conflict)

          checkpoint.watermark != from_cursor ->
            repo.rollback(:projection_watermark_conflict)

          true ->
            # CAS claims the page under the database's writer lock; a later
            # failure rolls both the claim and every command change back.
            {changed, _} =
              from(c in checkpoint_query(scope), where: c.watermark == ^from_cursor)
              |> repo.update_all([set: [watermark: to_cursor]], query_options(repo, deadline))

            if changed != 1, do: repo.rollback(:projection_watermark_conflict)
            Enum.each(rows, &persist_row(repo, scope, &1, from_cursor, deadline))

            repo.insert_all(
              Page,
              [
                %{
                  stream_id: scope.stream_id,
                  from_cursor: from_cursor,
                  to_cursor: to_cursor,
                  digest: digest
                }
              ],
              query_options(repo, deadline)
            )

            %{watermark: to_cursor, projected: length(rows)}
        end
      end)
    end
  rescue
    _ -> {:error, :conversation_index_unavailable}
  catch
    _, _ -> {:error, :conversation_index_unavailable}
  end

  def watermark(scope) do
    with :ok <- validate_scope(scope), {:ok, repo} <- Config.sql_repository() do
      case repo.get(Checkpoint, scope.stream_id, timeout: 5_000) do
        nil ->
          {:ok, 0}

        checkpoint ->
          cond do
            not matches_scope?(checkpoint, scope) -> {:error, :projection_scope_conflict}
            not valid_watermark?(checkpoint.watermark) -> {:error, :invalid_projection_record}
            true -> {:ok, checkpoint.watermark}
          end
      end
    end
  rescue
    _ -> {:error, :conversation_index_unavailable}
  catch
    _, _ -> {:error, :conversation_index_unavailable}
  end

  def read(scope, opts) do
    with :ok <- validate_scope(scope),
         {:ok, bounds} <- validate_options(opts),
         {:ok, repo} <- Config.sql_repository() do
      repo.transaction(
        fn ->
          # The checkpoint row locks concurrent index writers on PostgreSQL.
          # SQLite's read transaction provides a stable snapshot. No runtime
          # application setting selects SQL dialect.
          checkpoint = repo.one(read_checkpoint_query(repo, scope), timeout: 5_000)

          foreign =
            if checkpoint, do: false, else: repo.get(Checkpoint, scope.stream_id, timeout: 5_000)

          if foreign, do: repo.rollback(:projection_scope_conflict)
          if checkpoint, do: validate_checkpoint!(repo, checkpoint)
          watermark = if checkpoint, do: checkpoint.watermark, else: 0

          records =
            scoped_query(Command, scope)
            |> where([c], c.source_event_number <= ^watermark)
            |> active_query(bounds.active_only)
            |> cursor_query(bounds.cursor)
            |> order_by([c], desc: c.admitted_event_number, desc: c.command_id)
            |> limit(^(bounds.limit + 1))
            |> repo.all(timeout: 5_000)
            |> Enum.map(&Map.take(&1, @row_keys))

          if not Enum.all?(records, &(validate_row(&1) == :ok)),
            do: repo.rollback(:invalid_projection_record)

          more = length(records) > bounds.limit
          commands = Enum.take(records, bounds.limit)

          %{
            commands: commands,
            watermark: watermark,
            has_more: more,
            next_cursor:
              if(more, do: Map.take(List.last(commands), [:admitted_event_number, :command_id]))
          }
        end,
        read_transaction_options(repo)
      )
    end
  rescue
    _ -> {:error, :conversation_index_unavailable}
  catch
    _, _ -> {:error, :conversation_index_unavailable}
  end

  def validate_options(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)
      limit = Keyword.get(opts, :limit, 20)
      cursor = Keyword.get(opts, :cursor)
      active = Keyword.get(opts, :active_only, true)

      if length(keys) == length(Enum.uniq(keys)) and
           Enum.all?(keys, &(&1 in [:limit, :cursor, :active_only])) and
           is_integer(limit) and limit in 1..50 and is_boolean(active) and valid_cursor?(cursor),
         do: {:ok, %{limit: limit, cursor: cursor, active_only: active}},
         else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  defp validate_scope(scope) when is_map(scope) do
    if exact_keys?(scope, @scope_keys) and
         Enum.all?(
           @scope_keys,
           &valid_string?(scope[&1], if(&1 == :stream_id, do: 255, else: 256))
         ), do: :ok, else: {:error, :invalid_scope}
  end

  defp validate_scope(_), do: {:error, :invalid_scope}

  defp validate_page(rows, %{from: first, to: last} = cursors)
       when is_list(rows) and length(rows) <= 100 do
    valid =
      exact_keys?(cursors, [:from, :to]) and is_integer(first) and is_integer(last) and
        first >= 0 and last > first and last <= @maximum and last - first <= 100 and
        length(Enum.uniq_by(rows, &Map.get(&1, :command_id))) == length(rows) and
        Enum.all?(
          rows,
          &(validate_row(&1) == :ok and &1.source_event_number > first and
              &1.source_event_number <= last)
        )

    if valid,
      do:
        {:ok,
         rows
         |> Enum.map(&Map.put_new(&1, :cancellation_termination, nil))
         |> Enum.sort_by(& &1.command_id), first, last},
      else: {:error, :invalid_projection}
  rescue
    _ -> {:error, :invalid_projection}
  end

  defp validate_page(_, _), do: {:error, :invalid_projection}

  defp validate_row(row) when is_map(row) do
    required = @row_keys -- [:cancellation_termination]

    valid =
      Enum.sort(Map.keys(row)) in [Enum.sort(required), Enum.sort(@row_keys)] and
        valid_string?(row.command_id, 128) and is_integer(row.admitted_event_number) and
        is_integer(row.source_event_number) and row.admitted_event_number > 0 and
        row.source_event_number >= row.admitted_event_number and
        row.source_event_number <= @maximum and
        row.delivery_status in @delivery and row.cancellation_status in @cancellation and
        Map.get(row, :cancellation_termination) in @termination and
        row.cancellation_status == "confirmed" ==
          not is_nil(Map.get(row, :cancellation_termination))

    if valid, do: :ok, else: {:error, :invalid_projection}
  end

  defp validate_row(_), do: {:error, :invalid_projection}

  defp persist_row(repo, scope, row, from_cursor, deadline) do
    row = Map.put_new(row, :cancellation_termination, nil)

    existing =
      repo.get_by(
        Command,
        [stream_id: scope.stream_id, command_id: row.command_id],
        query_options(repo, deadline)
      )

    cond do
      is_nil(existing) and row.admitted_event_number <= from_cursor ->
        repo.rollback(:projection_identity_conflict)

      existing &&
          (not matches_scope?(existing, scope) or
             existing.admitted_event_number != row.admitted_event_number) ->
        repo.rollback(:projection_identity_conflict)

      existing && existing.source_event_number >= row.source_event_number ->
        repo.rollback(:projection_source_conflict)

      true ->
        repo.insert_all(Command, [Map.merge(scope, row)],
          conflict_target: [:stream_id, :command_id],
          on_conflict: {:replace, @row_keys -- [:command_id, :admitted_event_number]},
          timeout: remaining_timeout!(repo, deadline),
          deadline: deadline
        )
    end
  end

  defp checkpoint_query(scope), do: scoped_query(Checkpoint, scope)

  defp scoped_query(schema, scope),
    do:
      from(c in schema,
        where:
          c.stream_id == ^scope.stream_id and c.owner_id == ^scope.owner_id and
            c.target_agent_id == ^scope.target_agent_id and
            c.engagement_id == ^scope.engagement_id
      )

  defp read_checkpoint_query(repo, scope) do
    case repo.__adapter__() do
      Ecto.Adapters.SQLite3 -> checkpoint_query(scope)
      Ecto.Adapters.Postgres -> from(c in checkpoint_query(scope), lock: "FOR SHARE")
      _ -> raise ArgumentError, "unsupported SQL repository adapter"
    end
  end

  defp read_transaction_options(repo) do
    case repo.__adapter__() do
      Ecto.Adapters.SQLite3 -> [mode: :deferred, timeout: 5_000]
      Ecto.Adapters.Postgres -> [timeout: 5_000]
      _ -> raise ArgumentError, "unsupported SQL repository adapter"
    end
  end

  defp project_transaction(repo, deadline, fun) do
    case repo.__adapter__() do
      Ecto.Adapters.SQLite3 -> sqlite_project_transaction(repo, deadline, fun)
      Ecto.Adapters.Postgres -> bounded_transaction(repo, deadline, fun, [])
      _ -> raise ArgumentError, "unsupported SQL repository adapter"
    end
  end

  defp sqlite_project_transaction(repo, deadline, fun) do
    repo.get_dynamic_repo()
    |> Adapter.lookup_meta()
    |> SQL.checkout(query_options(repo, deadline), fn ->
      %{rows: [[original_busy_timeout]]} =
        repo.query!("PRAGMA busy_timeout", [], control_options(repo, deadline))

      try do
        # This pragma is connection-local. Short native acquisition prevents a
        # disposable projection from occupying a connection inside a long NIF
        # wait while authoritative journal writers need to finish their commit.
        busy_timeout = min(@sqlite_busy_slice_ms, remaining_timeout!(repo, deadline))

        repo.query!("PRAGMA busy_timeout = #{busy_timeout}", [], control_options(repo, deadline))
        bounded_transaction(repo, deadline, fun, mode: :immediate)
      after
        # Restore before check-in; a disconnected connection is discarded by
        # DBConnection and must not turn an already rolled-back page into success.
        repo.query("PRAGMA busy_timeout = #{original_busy_timeout}", [],
          timeout: @sqlite_pragma_timeout_ms,
          queue: false
        )
      end
    end)
  end

  defp bounded_transaction(repo, deadline, fun, opts) do
    repo.transaction(
      fn ->
        # BEGIN itself may finish after a scheduler or native wait. Check before
        # the first effect, every query, and immediately before COMMIT.
        remaining_timeout!(repo, deadline)
        result = fun.()
        remaining_timeout!(repo, deadline)
        result
      end,
      Keyword.merge(opts, query_options(repo, deadline))
    )
  end

  defp query_options(repo, deadline),
    do: [timeout: remaining_timeout!(repo, deadline), deadline: deadline, queue: false]

  defp control_options(repo, deadline),
    do:
      Keyword.update!(
        query_options(repo, deadline),
        :timeout,
        &min(&1, @sqlite_pragma_timeout_ms)
      )

  defp remaining_timeout!(repo, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> remaining
      _ -> repo.rollback(:conversation_index_unavailable)
    end
  end

  defp active_query(query, false), do: query

  defp active_query(query, true),
    do:
      where(
        query,
        [c],
        (c.delivery_status in ["admitted", "dispatch_started", "uncertain"] and
           c.cancellation_status != "confirmed") or
          c.cancellation_status == "requested"
      )

  defp cursor_query(query, nil), do: query

  defp cursor_query(query, cursor),
    do:
      where(
        query,
        [c],
        c.admitted_event_number < ^cursor.admitted_event_number or
          (c.admitted_event_number == ^cursor.admitted_event_number and
             c.command_id < ^cursor.command_id)
      )

  defp valid_cursor?(nil), do: true

  defp valid_cursor?(%{admitted_event_number: number, command_id: id} = cursor),
    do:
      exact_keys?(cursor, [:admitted_event_number, :command_id]) and
        is_integer(number) and number in 1..@maximum and valid_string?(id, 128)

  defp valid_cursor?(_), do: false

  defp matches_scope?(record, scope),
    do: Enum.all?(@scope_keys, &(Map.get(record, &1) == scope[&1]))

  defp validate_checkpoint!(repo, checkpoint) do
    unless valid_watermark?(checkpoint.watermark), do: repo.rollback(:invalid_projection_record)
  end

  defp valid_watermark?(value), do: is_integer(value) and value in 0..@maximum

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp valid_string?(value, max),
    do: is_binary(value) and byte_size(value) in 1..max and String.valid?(value)

  defp digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
end
