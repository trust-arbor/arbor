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

  The fix serializes per-stream appends with a Postgres advisory transaction lock
  (`pg_advisory_xact_lock(hashtext(stream_id))`) acquired before reading the
  version. This test fires N concurrent appends to one fresh stream and asserts
  ALL succeed with event_numbers exactly 1..N — and crucially does NOT use the
  Sandbox's single shared connection (which would serialize the concurrency away
  and hide the race). It checks out an `:auto`-mode connection so the spawned
  Tasks open real, independent pool connections that genuinely contend.

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
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration
  @moduletag :database

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
    if Repo.__adapter__() == Ecto.Adapters.Postgres do
      {:ok, repo_pid: pid}
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
end
