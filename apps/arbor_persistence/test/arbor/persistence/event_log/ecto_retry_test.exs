defmodule Arbor.Persistence.EventLog.EctoRetryTest do
  # Deterministic, DB-free regression test for the event_number append race.
  # The real bug only manifests under concurrent appends to one stream, which the
  # Postgres-only Ecto.Adapters.SQL.Sandbox (single shared connection) serializes
  # away — so reproducing it via real concurrency is flaky. Instead we inject a
  # stub `repo:` that simulates the collision deterministically: insert! raises
  # the unique-constraint error exactly as a losing concurrent append would.
  use ExUnit.Case, async: true

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.Ecto, as: EventLog

  @moduletag :fast

  # The append body runs the transaction fn inline (our stub transaction/1 just
  # calls it), so insert! executes in THIS process and the attempt counter lives
  # in the process dictionary.

  alias Arbor.Contracts.Persistence.AppendOperation

  # Conflicts once, then succeeds — models a concurrent append that lost the race
  # on the first try and picks up the winner's committed version on retry.
  defmodule ConflictOnceRepo do
    def transaction(fun), do: {:ok, fun.()}
    def rollback(reason), do: throw({:rollback, reason})
    def one(_query), do: 0

    def insert!(_changeset) do
      n = Process.get(:insert_attempts, 0) + 1
      Process.put(:insert_attempts, n)

      if n == 1 do
        raise %Ecto.ConstraintError{
          type: :unique,
          constraint: "events_stream_id_event_number_index",
          message: "duplicate key value violates unique constraint"
        }
      else
        :inserted
      end
    end
  end

  # Always conflicts — to prove the retry is bounded (no infinite loop) and the
  # error is surfaced once exhausted.
  defmodule AlwaysConflictRepo do
    def transaction(fun), do: {:ok, fun.()}
    def rollback(reason), do: throw({:rollback, reason})
    def one(_query), do: 0

    def insert!(_changeset) do
      Process.put(:insert_attempts, Process.get(:insert_attempts, 0) + 1)

      raise %Ecto.ConstraintError{
        type: :unique,
        constraint: "events_stream_id_event_number_index",
        message: "duplicate key value violates unique constraint"
      }
    end
  end

  # A non-event_number constraint (e.g. some other unique index) must NOT be
  # retried — it isn't the append race and silently retrying would mask a real
  # data error.
  defmodule OtherConflictRepo do
    def transaction(fun), do: {:ok, fun.()}
    def rollback(reason), do: throw({:rollback, reason})
    def one(_query), do: 0

    def insert!(_changeset) do
      Process.put(:insert_attempts, Process.get(:insert_attempts, 0) + 1)

      raise %Ecto.ConstraintError{
        type: :unique,
        constraint: "events_agent_id_index",
        message: "duplicate key value violates unique constraint"
      }
    end
  end

  setup do
    Process.delete(:insert_attempts)
    :ok
  end

  test "retries the event_number conflict and succeeds (regression)" do
    event = Event.new("stream-x", "test.evt", %{n: 1})

    assert {:ok, [_persisted]} = EventLog.append("stream-x", event, repo: ConflictOnceRepo)
    # Two insert! calls = conflicted once, then succeeded on retry.
    assert Process.get(:insert_attempts) == 2
  end

  test "a persistent event_number conflict surfaces after bounded retries (no infinite loop)" do
    event = Event.new("stream-x", "test.evt", %{n: 1})

    assert {:error, {:append_conflict, _operation_id}} =
             EventLog.append("stream-x", event, repo: AlwaysConflictRepo)

    # @max_append_attempts = 5: tried five times then returned a stable conflict.
    assert Process.get(:insert_attempts) == 5
  end

  test "does NOT retry a non-event_number constraint (it isn't the append race)" do
    event = Event.new("stream-x", "test.evt", %{n: 1})

    assert_raise Ecto.ConstraintError, fn ->
      EventLog.append("stream-x", event, repo: OtherConflictRepo)
    end

    # Surfaced immediately — exactly one attempt, no retry.
    assert Process.get(:insert_attempts) == 1
  end

  test "does NOT retry when the caller requested an expected_version" do
    event = Event.new("stream-x", "test.evt", %{n: 1})

    # An optimistic-concurrency caller must observe the conflict, not have it
    # silently resolved. expected_version: 0 matches our stub's one/1 -> 0, so
    # the version check passes and we reach insert!, which conflicts once.
    assert {:error, :version_conflict} =
             EventLog.append("stream-x", event, repo: ConflictOnceRepo, expected_version: 0)

    assert Process.get(:insert_attempts) == 1
  end

  test "forged operations and improper options are rejected before Ecto query construction" do
    event = Event.new("forged", "created", %{value: 1})

    assert {:ok, %AppendOperation{} = operation} =
             Arbor.Persistence.EventLog.build_operation("forged", [event])

    oversized_ids = Enum.map(1..1_001, &"evt_forged_#{&1}")

    forged_operations = [
      %AppendOperation{operation | event_ids: ["evt_forged" | :improper]},
      %AppendOperation{operation | event_ids: oversized_ids, fingerprints: %{}}
    ]

    Enum.each(forged_operations, fn forged ->
      assert {:error, :invalid_append_operation} =
               EventLog.reconcile_append(forged, repo: OtherConflictRepo)
    end)

    assert {:error, :invalid_precondition} =
             EventLog.reconcile_append(operation, [{:repo, OtherConflictRepo} | :improper])
  end
end
