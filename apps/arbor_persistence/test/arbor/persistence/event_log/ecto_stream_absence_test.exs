defmodule Arbor.Persistence.EventLog.EctoStreamAbsenceTest do
  use Arbor.Persistence.DatabaseCase, async: false

  import Ecto.Query

  alias Arbor.Persistence
  alias Arbor.Persistence.EventLog.Ecto, as: EctoEventLog
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.{Event, EventLogOperation}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :database

  setup do
    Repo.delete_all(EventLogOperation)
    Repo.delete_all(Event)
    :ok
  end

  test "ecto absence proves false before purge, true after, without mutating survivors" do
    target = "ecto-absence-target"
    survivor = "ecto-absence-survivor"

    target_events = [
      Arbor.Persistence.Event.new(target, "target.created", %{"ordinal" => 1}),
      Arbor.Persistence.Event.new(target, "target.updated", %{"ordinal" => 2})
    ]

    survivor_event =
      Arbor.Persistence.Event.new(survivor, "survivor.created", %{"ordinal" => 1})

    assert {:ok, [_first, _second]} =
             Persistence.append(:ecto_absence, EctoEventLog, target, target_events, repo: Repo)

    assert {:ok, [surviving]} =
             Persistence.append(:ecto_absence, EctoEventLog, survivor, survivor_event, repo: Repo)

    assert row_count(Event, target) == 2
    assert row_count(EventLogOperation, target) == 1

    assert {:ok, false} =
             Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, target, repo: Repo)

    assert {:ok, false} =
             Persistence.check_complete_event_stream_absent_using_backend(
               :ecto_absence,
               EctoEventLog,
               target,
               repo: Repo
             )

    # Read-only: repeated checks leave rows untouched.
    assert {:ok, false} =
             Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, target, repo: Repo)

    assert row_count(Event, target) == 2
    assert row_count(EventLogOperation, target) == 1
    assert row_count(Event, survivor) == 1
    assert row_count(EventLogOperation, survivor) == 1

    assert :ok =
             Persistence.purge_stream(:ecto_absence, EctoEventLog, target, repo: Repo)

    assert {:ok, true} =
             Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, target, repo: Repo)

    assert {:ok, true} =
             Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, target, repo: Repo)

    assert row_count(Event, target) == 0
    assert row_count(EventLogOperation, target) == 0
    assert row_count(Event, survivor) == 1
    assert row_count(EventLogOperation, survivor) == 1

    assert {:ok, [remaining]} =
             Persistence.read_stream(:ecto_absence, EctoEventLog, survivor, repo: Repo)

    assert remaining.id == surviving.id
    assert remaining.global_position == surviving.global_position
  end

  test "ecto operation-fence-only surface is retained without event rows" do
    stream_id = "ecto-absence-fence-only"
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {1, _} =
      Repo.insert_all(EventLogOperation, [
        %{
          operation_id: "fence-only-#{System.unique_integer([:positive])}",
          stream_id: stream_id,
          identity: %{"event_ids" => ["evt-fence"], "fingerprints" => %{"evt-fence" => "fp"}},
          status: "committed",
          reason: nil,
          inserted_at: now,
          updated_at: now
        }
      ])

    assert row_count(Event, stream_id) == 0
    assert row_count(EventLogOperation, stream_id) == 1

    assert {:ok, false} =
             Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, stream_id, repo: Repo),
           "operation-fence rows alone must keep complete absence false"

    # Read-only: fence rows survive the check.
    assert row_count(EventLogOperation, stream_id) == 1

    Repo.delete_all(from(op in EventLogOperation, where: op.stream_id == ^stream_id))
    assert row_count(EventLogOperation, stream_id) == 0

    assert {:ok, true} =
             Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, stream_id, repo: Repo)
  end

  test "ecto protocol epoch unavailability never returns true" do
    stream_id = "ecto-absence-protocol-unavailable"

    corrupt_protocol!()

    try do
      result =
        Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, stream_id,
          repo: Repo,
          absence_timeout_ms: 1_000
        )

      refute match?({:ok, true}, result),
             "protocol unavailability must fail closed, got #{inspect(result)}"

      assert result in [
               {:error, :backend_unavailable},
               {:error, {:absence_indeterminate, stream_id}}
             ]
    after
      restore_protocol!()
    end

    assert {:ok, true} =
             Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, stream_id, repo: Repo)
  end

  test "ecto never returns true for missing repo option validation failures" do
    stream_id = "ecto-absence-invalid-repo"

    assert {:error, :invalid_precondition} =
             Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, stream_id,
               repo: :not_a_real_repo_module_xyz
             )
  end

  if Repo.__adapter__() == Ecto.Adapters.Postgres do
    test "postgres advisory lock serializes absence against public append surfaces" do
      run_with_auto_sandbox(fn ->
        stream_id = "ecto-absence-pg-lock-#{System.unique_integer([:positive])}"
        parent = self()

        assert {:ok, true} =
                 Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, stream_id,
                   repo: Repo
                 )

        locker =
          Task.async(fn ->
            Repo.transaction(
              fn ->
                Repo.query!(
                  "SELECT pg_advisory_xact_lock(hashtext('arbor.persistence.event_log.global_append'))"
                )

                send(parent, :postgres_absence_lock_held)

                receive do
                  :release_postgres_absence_lock -> :ok
                after
                  5_000 -> raise "postgres release timed out"
                end
              end,
              timeout: 15_000
            )
          end)

        assert_receive :postgres_absence_lock_held, 2_000

        # While the global append-ordering lock is held, absence cannot assemble true.
        contended =
          Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, stream_id,
            repo: Repo,
            absence_timeout_ms: 500
          )

        refute match?({:ok, true}, contended),
               "contended advisory lock must not yield true, got #{inspect(contended)}"

        send(locker.pid, :release_postgres_absence_lock)
        assert {:ok, _} = Task.yield(locker, 5_000)

        # Public append path only — raw Event inserts trip the post-cutover identity trigger.
        assert {:ok, [_persisted]} =
                 append_retained_surfaces!(stream_id)

        assert {:ok, false} =
                 Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, stream_id,
                   repo: Repo
                 ),
               "public append surfaces must be observed as retained"

        assert row_count(Event, stream_id) == 1
        assert row_count(EventLogOperation, stream_id) == 1
      end)
    end
  end

  if Repo.__adapter__() == Ecto.Adapters.SQLite3 do
    test "sqlite immediate transaction serializes absence against public append surfaces" do
      run_with_auto_sandbox(fn ->
        stream_id = "ecto-absence-sqlite-lock-#{System.unique_integer([:positive])}"
        parent = self()

        assert {:ok, true} =
                 Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, stream_id,
                   repo: Repo
                 )

        locker =
          Task.async(fn ->
            Repo.transaction(
              fn ->
                send(parent, :sqlite_absence_lock_held)

                receive do
                  :release_sqlite_absence_lock -> :ok
                after
                  5_000 -> raise "sqlite release timed out"
                end
              end,
              mode: :immediate,
              timeout: 15_000
            )
          end)

        assert_receive :sqlite_absence_lock_held, 2_000

        contended =
          Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, stream_id,
            repo: Repo,
            absence_timeout_ms: 500
          )

        refute match?({:ok, true}, contended),
               "contended SQLite immediate lock must not yield true, got #{inspect(contended)}"

        send(locker.pid, :release_sqlite_absence_lock)
        assert {:ok, _} = Task.yield(locker, 5_000)

        # Public append path only — raw Event inserts trip the post-cutover identity trigger.
        assert {:ok, [_persisted]} =
                 append_retained_surfaces!(stream_id)

        assert {:ok, false} =
                 Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, stream_id,
                   repo: Repo
                 ),
               "public append surfaces must be observed as retained"

        assert row_count(Event, stream_id) == 1
        assert row_count(EventLogOperation, stream_id) == 1
      end)
    end
  end

  defp run_with_auto_sandbox(fun) do
    :ok = Sandbox.mode(Repo, :auto)
    Repo.delete_all(EventLogOperation)
    Repo.delete_all(Event)

    try do
      fun.()
    after
      Repo.delete_all(EventLogOperation)
      Repo.delete_all(Event)
      Sandbox.mode(Repo, :manual)
    end
  end

  defp append_retained_surfaces!(stream_id) do
    event =
      Arbor.Persistence.Event.new(stream_id, "retained.public_append", %{
        "token" => System.unique_integer([:positive])
      })

    Persistence.append(:ecto_absence, EctoEventLog, stream_id, event,
      repo: Repo,
      append_timeout_ms: 5_000
    )
  end

  # Prefer DELETE over wrong-version UPDATE so Postgres CHECK (protocol_version = 3)
  # does not block the fail-closed fixture on either adapter lane.
  defp corrupt_protocol! do
    Repo.query!("DELETE FROM event_log_protocol")
  end

  defp restore_protocol! do
    Repo.query!("DELETE FROM event_log_protocol")

    case Repo.__adapter__() do
      Ecto.Adapters.Postgres ->
        Repo.query!("""
        INSERT INTO event_log_protocol (singleton, protocol_version, cutover_at)
        VALUES (TRUE, 3, clock_timestamp())
        """)

      Ecto.Adapters.SQLite3 ->
        Repo.query!("""
        INSERT INTO event_log_protocol (singleton, protocol_version, cutover_at)
        VALUES (1, 3, STRFTIME('%Y-%m-%d %H:%M:%f', 'now'))
        """)
    end
  end

  defp row_count(schema, stream_id) do
    from(row in schema, where: row.stream_id == ^stream_id, select: count())
    |> Repo.one!()
  end
end
