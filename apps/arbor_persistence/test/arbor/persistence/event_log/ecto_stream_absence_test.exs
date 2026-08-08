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
    test "postgres public append and absence share advisory serialization authority" do
      run_with_auto_sandbox(fn ->
        stream_id = "ecto-absence-pg-overlap-#{System.unique_integer([:positive])}"
        parent = self()
        handler_id = "ecto-absence-pg-append-authority-#{System.unique_integer([:positive])}"
        query_event = Repo.config()[:telemetry_prefix] ++ [:query]
        # Arm only for the public append under test; hold at most once.
        armed = :atomics.new(1, signed: false)
        held = :atomics.new(1, signed: false)
        # Parent-owned mutable cell: try/after cannot see do-block rebindings.
        cleanup = start_race_cleanup_cell!()

        try do
          :ok =
            :telemetry.attach(
              handler_id,
              query_event,
              fn _event, _measurements, metadata, config ->
                query = metadata[:query] || ""

                if :atomics.get(config.armed, 1) == 1 and
                     String.contains?(query, "pg_try_advisory_xact_lock") and
                     String.contains?(query, "arbor.persistence.event_log.global_append") and
                     :atomics.compare_exchange(config.held, 1, 0, 1) == :ok do
                  send(config.parent, {:append_authority_held, self()})

                  receive do
                    :release_append_authority -> :ok
                  after
                    10_000 -> raise "postgres append authority release timed out"
                  end
                end
              end,
              %{parent: parent, armed: armed, held: held}
            )

          assert {:ok, true} =
                   Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, stream_id,
                     repo: Repo
                   )

          event =
            Arbor.Persistence.Event.new(stream_id, "retained.public_append", %{
              "token" => System.unique_integer([:positive])
            })

          :atomics.put(armed, 1, 1)

          append_task =
            Task.async(fn ->
              Persistence.append(:ecto_absence, EctoEventLog, stream_id, event,
                repo: Repo,
                append_timeout_ms: 15_000
              )
            end)

          put_race_cleanup!(cleanup, :append_task, append_task)

          assert_receive {:append_authority_held, holder}, 5_000
          put_race_cleanup!(cleanup, :holder, holder)

          # Public append holds the global append-ordering authority; absence
          # assembled against that in-flight observation must not return true.
          contended =
            Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, stream_id,
              repo: Repo,
              absence_timeout_ms: 500
            )

          refute match?({:ok, true}, contended),
                 "in-flight public append must not allow absence true, got #{inspect(contended)}"

          send(holder, :release_append_authority)
          put_race_cleanup!(cleanup, :holder, nil)

          assert {:ok, [_persisted]} = Task.await(append_task, 15_000)
          put_race_cleanup!(cleanup, :append_task, nil)

          assert {:ok, false} =
                   Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, stream_id,
                     repo: Repo
                   ),
                 "committed public append surfaces must be observed as retained"

          assert row_count(Event, stream_id) == 1
          assert row_count(EventLogOperation, stream_id) == 1
        after
          cleanup_append_absence_race!(handler_id, armed, cleanup)
        end
      end)
    end
  end

  if Repo.__adapter__() == Ecto.Adapters.SQLite3 do
    test "sqlite public append and absence share immediate transaction authority" do
      run_with_auto_sandbox(fn ->
        stream_id = "ecto-absence-sqlite-overlap-#{System.unique_integer([:positive])}"
        parent = self()
        handler_id = "ecto-absence-sqlite-append-authority-#{System.unique_integer([:positive])}"
        query_event = Repo.config()[:telemetry_prefix] ++ [:query]
        # Arm only for the public append under test; hold at most once.
        armed = :atomics.new(1, signed: false)
        held = :atomics.new(1, signed: false)
        # Parent-owned mutable cell: try/after cannot see do-block rebindings.
        cleanup = start_race_cleanup_cell!()

        try do
          :ok =
            :telemetry.attach(
              handler_id,
              query_event,
              fn _event, _measurements, metadata, config ->
                query = metadata[:query] || ""

                # BEGIN IMMEDIATE is the SQLite write-serialization authority. The
                # first in-transaction query after it is the protocol epoch SELECT;
                # suspending there proves the public append already holds that lock.
                if :atomics.get(config.armed, 1) == 1 and
                     String.contains?(query, "event_log_protocol") and
                     String.contains?(query, "protocol_version") and
                     :atomics.compare_exchange(config.held, 1, 0, 1) == :ok do
                  send(config.parent, {:append_authority_held, self()})

                  receive do
                    :release_append_authority -> :ok
                  after
                    10_000 -> raise "sqlite append authority release timed out"
                  end
                end
              end,
              %{parent: parent, armed: armed, held: held}
            )

          assert {:ok, true} =
                   Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, stream_id,
                     repo: Repo
                   )

          event =
            Arbor.Persistence.Event.new(stream_id, "retained.public_append", %{
              "token" => System.unique_integer([:positive])
            })

          :atomics.put(armed, 1, 1)

          append_task =
            Task.async(fn ->
              Persistence.append(:ecto_absence, EctoEventLog, stream_id, event,
                repo: Repo,
                append_timeout_ms: 15_000
              )
            end)

          put_race_cleanup!(cleanup, :append_task, append_task)

          assert_receive {:append_authority_held, holder}, 5_000
          put_race_cleanup!(cleanup, :holder, holder)

          # Public append holds BEGIN IMMEDIATE write authority; absence
          # assembled against that in-flight observation must not return true.
          contended =
            Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, stream_id,
              repo: Repo,
              absence_timeout_ms: 500
            )

          refute match?({:ok, true}, contended),
                 "in-flight public append must not allow absence true, got #{inspect(contended)}"

          send(holder, :release_append_authority)
          put_race_cleanup!(cleanup, :holder, nil)

          assert {:ok, [_persisted]} = Task.await(append_task, 15_000)
          put_race_cleanup!(cleanup, :append_task, nil)

          assert {:ok, false} =
                   Persistence.event_stream_absent?(:ecto_absence, EctoEventLog, stream_id,
                     repo: Repo
                   ),
                 "committed public append surfaces must be observed as retained"

          assert row_count(Event, stream_id) == 1
          assert row_count(EventLogOperation, stream_id) == 1
        after
          cleanup_append_absence_race!(handler_id, armed, cleanup)
        end
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

  # Agent cell survives try/do rebinding rules so after/ can always release the
  # blocked append worker and shut down the task after an assertion failure.
  defp start_race_cleanup_cell! do
    {:ok, cleanup} = Agent.start_link(fn -> %{append_task: nil, holder: nil} end)
    cleanup
  end

  defp put_race_cleanup!(cleanup, key, value) when is_pid(cleanup) and is_atom(key) do
    Agent.update(cleanup, &Map.put(&1, key, value))
  end

  defp cleanup_append_absence_race!(handler_id, armed, cleanup) do
    :telemetry.detach(handler_id)
    :atomics.put(armed, 1, 0)

    %{append_task: append_task, holder: holder} =
      if is_pid(cleanup) and Process.alive?(cleanup) do
        state = Agent.get(cleanup, & &1)
        Agent.stop(cleanup)
        state
      else
        %{append_task: nil, holder: nil}
      end

    # Drain a holder notice that arrived after a failed assert_receive/timeout.
    holder =
      receive do
        {:append_authority_held, pid} -> pid
      after
        0 -> holder
      end

    if is_pid(holder) and Process.alive?(holder) do
      send(holder, :release_append_authority)
    end

    if match?(%Task{}, append_task) do
      _ = Task.shutdown(append_task, :brutal_kill)
    end

    # BoundedWorker is spawn_monitor'd (not linked); force-kill if still stuck.
    if is_pid(holder) and Process.alive?(holder) do
      Process.exit(holder, :kill)
    end

    :ok
  end

  # Prefer DELETE over wrong-version UPDATE so Postgres CHECK (protocol_version = 3)
  # does not block the fail-closed fixture on either adapter lane.
  defp corrupt_protocol! do
    Repo.query!("DELETE FROM event_log_protocol")
  end

  # Compile-time adapter branches only — avoids unreachable case-clause warnings
  # under ARBOR_DB=sqlite and ARBOR_DB=postgres builds.
  if Repo.__adapter__() == Ecto.Adapters.Postgres do
    defp restore_protocol! do
      Repo.query!("DELETE FROM event_log_protocol")

      Repo.query!("""
      INSERT INTO event_log_protocol (singleton, protocol_version, cutover_at)
      VALUES (TRUE, 3, clock_timestamp())
      """)
    end
  end

  if Repo.__adapter__() == Ecto.Adapters.SQLite3 do
    defp restore_protocol! do
      Repo.query!("DELETE FROM event_log_protocol")

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
