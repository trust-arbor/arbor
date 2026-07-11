defmodule Arbor.Persistence.EventLog.EctoConcurrentAppendTest do
  @moduledoc """
  Regression test for the `events_stream_id_event_number_index` unique-constraint
  flood.

  `EventLog.Ecto.do_append/4` assigns `event_number` as an unlocked
  read-modify-write (`max(event_number) + 1`). Concurrent appends to the SAME
  stream (e.g. a heartbeat run firing several durable signals to one
  `orchestrator:pipeline:run_Heartbeat_…` stream via `Task.start`) race: two
  appends read the same version, assign the same number, and the second violates
  the unique index — flooding the logs via `Signals.durable_emit`.

  The fix serializes appends with a bounded global advisory transaction lock
  acquired before reading stream and global positions. This test fires real
  concurrent appends without the Sandbox's single shared connection, covering
  same-stream CAS, different-stream global order, and held-lock deadlines.

  Verified to FAIL (duplicate event_numbers / `Ecto.ConstraintError`) when the
  advisory lock is removed from `do_append`, and to PASS with it in place.

  ## Setup Required

      ARBOR_DB=postgres MIX_ENV=test mix ecto.create -r Arbor.Persistence.Repo
      ARBOR_DB=postgres MIX_ENV=test mix ecto.migrate -r Arbor.Persistence.Repo
      ARBOR_DB=postgres MIX_ENV=test mix test \
        apps/arbor_persistence/test/arbor/persistence/event_log/ecto_concurrent_append_test.exs \
        --include database
  """

  use ExUnit.Case, async: false

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.Ecto, as: EventLog
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Test.PostgresDelayProxy
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :database

  defmodule SingleConnectionRepo do
    use Ecto.Repo,
      otp_app: :arbor_persistence,
      adapter: Ecto.Adapters.Postgres
  end

  defmodule DelayedCommitRepo do
    use Ecto.Repo,
      otp_app: :arbor_persistence,
      adapter: Ecto.Adapters.Postgres
  end

  # This test is meaningful only against Postgres — the advisory lock is
  # Postgres-only, and only Postgres' real connection pool gives the genuine
  # concurrency that reproduces the race. Skip on the SQLite lane (which
  # serializes writes anyway) rather than producing a misleading green/red.
  setup_all do
    case Repo.start_link() do
      {:ok, pid} -> on_postgres_or_skip(pid)
      {:error, {:already_started, pid}} -> on_postgres_or_skip(pid)
      {:error, reason} -> {:skip, "Database not available: #{inspect(reason)}"}
    end
  end

  defp on_postgres_or_skip(pid) do
    if apply(Repo, :__adapter__, []) == Ecto.Adapters.Postgres do
      single_connection_config =
        Repo.config()
        |> Keyword.drop([:adapter, :name, :otp_app, :repo])
        |> Keyword.put(:pool, DBConnection.ConnectionPool)
        |> Keyword.put(:pool_size, 1)

      start_supervised!({SingleConnectionRepo, single_connection_config})

      proxy =
        start_supervised!(
          {PostgresDelayProxy,
           upstream_host: Keyword.get(Repo.config(), :hostname, "localhost"),
           upstream_port: Keyword.get(Repo.config(), :port, 5432)}
        )

      delayed_repo_config =
        single_connection_config
        |> Keyword.drop([:socket, :socket_dir])
        |> Keyword.put(:hostname, "127.0.0.1")
        |> Keyword.put(:port, PostgresDelayProxy.port(proxy))

      start_supervised!({DelayedCommitRepo, delayed_repo_config})
      {:ok, repo_pid: pid, commit_proxy: proxy}
    else
      {:skip, "concurrent-append race is Postgres-only (advisory lock + real pool)"}
    end
  end

  setup do
    # Put the sandbox in :auto mode for this test so the Tasks we spawn each
    # acquire their OWN real connection from the pool and run truly in parallel.
    # (The default :manual + shared single connection serializes appends and
    # would mask the race the lock is meant to fix.) Clean the table by hand
    # before and after since :auto mode doesn't roll back.
    :ok = Sandbox.mode(Repo, :auto)
    Repo.delete_all(Arbor.Persistence.Schemas.Event)

    on_exit(fn ->
      # Re-checkout under :auto for the cleanup query, then restore :manual so
      # later modules in this BEAM aren't left in :auto.
      Sandbox.mode(Repo, :auto)
      Repo.delete_all(Arbor.Persistence.Schemas.Event)
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "N concurrent appends to one stream all succeed with monotonic event_numbers (regression)" do
    n = 25
    stream_id = "race-stream-#{System.unique_integer([:positive])}"

    results =
      1..n
      |> Task.async_stream(
        fn i ->
          event = Event.new(stream_id, "race.evt", %{i: i})
          EventLog.append(stream_id, event, repo: Repo)
        end,
        max_concurrency: n,
        timeout: 30_000,
        ordered: false
      )
      |> Enum.to_list()

    # Every task ran to completion (no Task crash from a raised ConstraintError).
    assert Enum.all?(results, &match?({:ok, _}, &1)),
           "a concurrent append task crashed (likely Ecto.ConstraintError from the race): " <>
             inspect(Enum.reject(results, &match?({:ok, _}, &1)))

    append_results = Enum.map(results, fn {:ok, r} -> r end)

    # Every append returned {:ok, [event]} — none returned {:error, _}.
    assert Enum.all?(append_results, &match?({:ok, [_]}, &1)),
           "an append returned a non-ok result: " <>
             inspect(Enum.reject(append_results, &match?({:ok, [_]}, &1)))

    # The event_numbers actually written are exactly 1..N — no gaps, no dupes.
    {:ok, persisted} = EventLog.read_stream(stream_id, repo: Repo)
    numbers = persisted |> Enum.map(& &1.event_number) |> Enum.sort()

    assert numbers == Enum.to_list(1..n),
           "expected event_numbers 1..#{n} with no gaps/dupes, got #{inspect(numbers)}"

    assert length(numbers) == length(Enum.uniq(numbers)),
           "duplicate event_numbers written: #{inspect(numbers -- Enum.uniq(numbers))}"
  end

  test "concurrent exact-version appends accept exactly one after the stream lock" do
    n = 20
    stream_id = "cas-race-#{System.unique_integer([:positive])}"

    results =
      1..n
      |> Task.async_stream(
        fn i ->
          EventLog.append(stream_id, Event.new(stream_id, "terminal", %{winner: i}),
            repo: Repo,
            expected_version: 0
          )
        end,
        max_concurrency: n,
        timeout: 30_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, [_]}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :version_conflict})) == n - 1
    assert {:ok, 1} = EventLog.stream_version(stream_id, repo: Repo)
  end

  test "concurrent different-stream appends retain one strict global order" do
    n = 25
    events_per_writer = 10

    results =
      1..n
      |> Task.async_stream(
        fn i ->
          stream_id = "global-race-#{i}"

          events =
            for sequence <- 1..events_per_writer do
              Event.new(stream_id, "global", %{writer: i, sequence: sequence})
            end

          EventLog.append(stream_id, events, repo: Repo)
        end,
        max_concurrency: n,
        timeout: 30_000,
        ordered: false
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, [_ | _]}}, &1)),
           "a different-stream append failed or exited: #{inspect(results)}"

    returned_positions =
      results
      |> Enum.flat_map(fn {:ok, {:ok, events}} -> Enum.map(events, & &1.global_position) end)
      |> Enum.sort()

    expected_positions = Enum.to_list(1..(n * events_per_writer))
    assert returned_positions == expected_positions

    assert {:ok, persisted} = EventLog.read_all(repo: Repo)
    positions = Enum.map(persisted, & &1.global_position)
    assert positions == expected_positions
    assert length(positions) == length(Enum.uniq(positions))
  end

  test "held global append lock respects one deadline and cannot commit later" do
    parent = self()

    locker =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!(
            "SELECT pg_advisory_xact_lock(hashtext('arbor.persistence.event_log.global_append'))"
          )

          Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["postgres-deadline"])

          send(parent, :postgres_append_lock_acquired)

          receive do
            :release_postgres_append_lock -> :ok
          after
            2_000 -> raise "test advisory lock release timed out"
          end
        end)
      end)

    assert_receive :postgres_append_lock_acquired, 1_000
    event = Event.new("postgres-deadline", "must-not-commit", %{})

    assert {:ok, operation} =
             Arbor.Persistence.EventLog.build_operation("postgres-deadline", [event])

    try do
      started_at = System.monotonic_time(:millisecond)

      assert EventLog.append("postgres-deadline", event,
               repo: Repo,
               append_timeout_ms: 40
             ) in [
               {:error, :operation_timeout},
               {:error, {:append_indeterminate, operation}}
             ]

      elapsed_ms = System.monotonic_time(:millisecond) - started_at
      assert elapsed_ms < 250
    after
      send(locker.pid, :release_postgres_append_lock)
    end

    assert {:ok, {:ok, :ok}} = Task.yield(locker, 1_000)
    Process.sleep(75)
    assert {:ok, 0} = EventLog.stream_version("postgres-deadline", repo: Repo)
    assert {:ok, :absent} = EventLog.reconcile_append(operation, repo: Repo)
  end

  test "pool checkout shares the append deadline and cannot leave work behind" do
    parent = self()

    holder =
      Task.async(fn ->
        SingleConnectionRepo.transaction(
          fn ->
            send(parent, :postgres_pool_slot_held)

            receive do
              :release_postgres_pool_slot -> :ok
            after
              2_000 -> raise "test pool slot release timed out"
            end
          end,
          timeout: 3_000
        )
      end)

    assert_receive :postgres_pool_slot_held, 1_000
    event = Event.new("postgres-checkout-deadline", "must-not-commit", %{})

    assert {:ok, operation} =
             Arbor.Persistence.EventLog.build_operation("postgres-checkout-deadline", [event])

    {result, elapsed_ms} =
      try do
        started_at = System.monotonic_time(:millisecond)

        result =
          EventLog.append(
            "postgres-checkout-deadline",
            event,
            repo: SingleConnectionRepo,
            append_timeout_ms: 40
          )

        {result, System.monotonic_time(:millisecond) - started_at}
      after
        send(holder.pid, :release_postgres_pool_slot)
      end

    assert result in [
             {:error, :operation_timeout},
             {:error, {:append_indeterminate, operation}}
           ]

    assert elapsed_ms < 250

    assert {:ok, {:ok, :ok}} = Task.yield(holder, 1_000)

    Process.sleep(75)

    assert {:ok, 0} =
             EventLog.stream_version("postgres-checkout-deadline", repo: SingleConnectionRepo)

    assert {:ok, :absent} = EventLog.reconcile_append(operation, repo: Repo)
  end

  test "delayed COMMIT acknowledgement returns a reconcilable indeterminate outcome", %{
    commit_proxy: proxy
  } do
    stream_id = "postgres-delayed-commit"
    event = Event.new(stream_id, "committed-before-reply", %{value: 1})
    :ok = PostgresDelayProxy.delay_next_commit(proxy, self(), 300)
    started_at = System.monotonic_time(:millisecond)

    assert {:error, {:append_indeterminate, operation}} =
             EventLog.append(stream_id, event,
               repo: DelayedCommitRepo,
               append_timeout_ms: 75
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert elapsed_ms < 250
    assert_receive :postgres_proxy_delaying_commit_reply, 1_000

    assert {:ok, {:committed, [%Event{id: committed_id, data: %{"value" => 1}}]}} =
             EventLog.reconcile_append(operation, repo: Repo)

    assert committed_id == event.id

    assert {:ok, [%Event{id: retried_id, global_position: 1}]} =
             EventLog.append(stream_id, event, repo: Repo)

    assert retried_id == event.id
    assert {:ok, 1} = EventLog.stream_version(stream_id, repo: Repo)
  end
end
