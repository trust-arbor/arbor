defmodule Arbor.Persistence.VectorStore.EctoPostgresConcurrencyTest do
  @moduledoc """
  Vector CAS and transaction tests using independent PostgreSQL sessions.

  The SQL sandbox runs in `:auto` mode here so concurrent Tasks check out
  separate connections. SQLite coverage intentionally makes no concurrency
  claim. Because `:auto` commits and the receipt ledger is immutable, every
  durable fixture uses runtime cryptographic identifiers to isolate fresh BEAM
  runs without deleting protected receipts.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.{VectorOperation, VectorRecord}
  alias Arbor.Persistence.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @operation_transaction_event [:arbor, :persistence, :vector_store, :operation_transaction]
  @fence_claim_event [:arbor, :persistence, :vector_store, :fence_claim]

  @moduletag :database
  @moduletag :integration
  @moduletag :postgres

  if Repo.__adapter__() != Ecto.Adapters.Postgres do
    @moduletag skip: "independent-session vector CAS coverage requires PostgreSQL"
  end

  setup_all do
    {repo_pid, repo_owned?} = start_repo!()

    on_exit(fn ->
      if repo_owned? and Process.alive?(repo_pid) do
        Supervisor.stop(repo_pid, :normal, 5_000)
      end
    end)

    :ok
  end

  setup do
    original_backend =
      Application.get_env(:arbor_persistence, :vector_store_backend, :not_configured)

    original_repo = Application.get_env(:arbor_persistence, :vector_store_repo, :not_configured)

    :ok = Sandbox.mode(Repo, :auto)

    Application.put_env(
      :arbor_persistence,
      :vector_store_backend,
      Arbor.Persistence.VectorStore.Ecto
    )

    Application.put_env(:arbor_persistence, :vector_store_repo, Repo)

    on_exit(fn ->
      restore_env(:vector_store_backend, original_backend)
      restore_env(:vector_store_repo, original_repo)
      restore_sandbox_mode()
    end)

    {:ok, agent_id: unique("agent")}
  end

  test "two independent expected-fence claimants produce exactly one winner", %{
    agent_id: agent_id
  } do
    insert = insert_operation!(record!(agent_id, source_key: "shared-cas"))
    assert {:ok, inserted} = Arbor.Persistence.execute_vector_operation(agent_id, insert)

    claims =
      for claimant <- ["one", "two"] do
        inserted.record
        |> rebuild_record!(payload: %{"claimant" => claimant})
        |> operation_for_record!(:update)
      end

    {results, overlap} = run_with_fence_overlap(claims, &execute(agent_id, &1))
    assert_fence_overlap(overlap)
    outcomes = Enum.map(results, &summarize_result/1)

    assert Enum.count(results, &match?({:ok, _receipt}, &1)) == 1,
           "expected one CAS winner, got: #{inspect(outcomes)}"

    assert Enum.count(results, &(&1 == {:error, :conflict})) == 1,
           "expected one CAS conflict, got: #{inspect(outcomes)}"

    assert {:ok, current} =
             Arbor.Persistence.fetch_vector_record(agent_id, "voice", "shared-cas")

    assert current.revision == 2
    assert current.payload["claimant"] in ["one", "two"]
  end

  test "duplicate same-operation execution returns one exact committed receipt", %{
    agent_id: agent_id
  } do
    operation = insert_operation!(record!(agent_id, source_key: "duplicate-operation"))
    results = run_started_together([operation, operation], &execute(agent_id, &1))

    assert [{:ok, first}, {:ok, second}] = results,
           "expected two exact duplicate receipts, got: #{inspect(Enum.map(results, &summarize_result/1))}"

    assert first == second
    assert first.operation_fingerprint == operation.fingerprint

    assert {:ok, ^first} =
             Arbor.Persistence.reconcile_vector_operation(agent_id, operation)
  end

  test "overlapping batches commit one whole batch and roll back the loser", %{
    agent_id: agent_id
  } do
    shared_insert = insert_operation!(record!(agent_id, source_key: "batch-shared"))
    assert {:ok, shared} = Arbor.Persistence.execute_vector_operation(agent_id, shared_insert)

    batches =
      for claimant <- ["one", "two"] do
        unique_insert =
          insert_operation!(record!(agent_id, source_key: "batch-unique-#{claimant}"))

        shared_update =
          shared.record
          |> rebuild_record!(payload: %{"batch" => claimant})
          |> operation_for_record!(:update)

        {:ok, batch} =
          VectorOperation.new(%{kind: :batch, operations: [unique_insert, shared_update]})

        {claimant, batch}
      end

    {results, overlap} =
      run_with_transaction_overlap(
        batches,
        fn {claimant, batch} ->
          {claimant, batch, execute(agent_id, batch)}
        end
      )

    assert_transaction_overlap(overlap)

    outcomes = Enum.map(results, &summarize_batch_result/1)
    successes = Enum.filter(results, &match?({_claimant, _batch, {:ok, _receipt}}, &1))
    conflicts = Enum.filter(results, &match?({_claimant, _batch, {:error, :conflict}}, &1))

    assert length(successes) == 1,
           "expected one whole-batch winner, got: #{inspect(outcomes)}"

    assert length(conflicts) == 1,
           "expected one rolled-back batch conflict, got: #{inspect(outcomes)}"

    [{winner, winning_batch, {:ok, winning_receipt}}] = successes
    [{loser, losing_batch, {:error, :conflict}}] = conflicts

    assert winner != loser

    assert {:ok, _winner_unique} =
             Arbor.Persistence.fetch_vector_record(
               agent_id,
               "voice",
               "batch-unique-#{winner}"
             )

    assert {:error, :not_found} =
             Arbor.Persistence.fetch_vector_record(
               agent_id,
               "voice",
               "batch-unique-#{loser}"
             )

    assert {:ok, %{payload: %{"batch" => ^winner}, revision: 2}} =
             Arbor.Persistence.fetch_vector_record(agent_id, "voice", "batch-shared")

    assert {:ok, ^winning_receipt} =
             Arbor.Persistence.reconcile_vector_operation(agent_id, winning_batch)

    assert {:ok, :absent} =
             Arbor.Persistence.reconcile_vector_operation(agent_id, losing_batch)
  end

  test "admitted shared fence completes before destroy; later ops closed; other tenant safe", %{
    agent_id: agent_id
  } do
    other_id = unique("agent")
    insert = insert_operation!(record!(agent_id, source_key: "destroy-overlap"))
    other = insert_operation!(record!(other_id, source_key: "destroy-other"))

    assert {:ok, inserted} = Arbor.Persistence.execute_vector_operation(agent_id, insert)
    assert {:ok, _} = Arbor.Persistence.execute_vector_operation(other_id, other)

    update =
      inserted.record
      |> rebuild_record!(payload: %{"phase" => "held-shared-fence"})
      |> operation_for_record!(:update)

    parent = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        @operation_transaction_event,
        fn _event, _measurements, metadata, config ->
          if metadata.operation_fingerprint == update.fingerprint do
            %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(config.parent, {:held, self(), backend_pid})

            receive do
              :release -> :ok
            after
              10_000 -> raise "operation hold release timed out"
            end
          end
        end,
        %{parent: parent}
      )

    task = Task.async(fn -> execute(agent_id, update) end)
    assert_receive {:held, holder, holder_backend_pid}, 5_000
    destroy_task = Task.async(fn -> Arbor.Persistence.destroy_vector_agent(agent_id) end)

    results =
      try do
        destroy_backend_pid = await_destroy_lock_wait!(holder_backend_pid)
        assert is_integer(destroy_backend_pid)
        refute Task.yield(destroy_task, 0)

        released_at = NaiveDateTime.utc_now()
        send(holder, :release)

        update_result = Task.await(task, 20_000)
        destroy_result = Task.await(destroy_task, 20_000)
        {update_result, destroy_result, released_at}
      after
        if Process.alive?(task.pid), do: send(holder, :release)
        if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
        if Process.alive?(destroy_task.pid), do: Task.shutdown(destroy_task, :brutal_kill)
        :telemetry.detach(handler_id)
      end

    assert {{:ok, _receipt}, :ok, released_at} = results

    assert %{rows: [[0]]} =
             Repo.query!(
               """
               SELECT COUNT(*) FROM memory_embeddings
               WHERE agent_id = $1 AND vector_protocol = 'arbor_vector_store_v1'
               """,
               [agent_id]
             )

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT COUNT(*) FROM vector_operation_receipts WHERE agent_id = $1",
               [agent_id]
             )

    assert %{rows: [["closed", closed_at]]} =
             Repo.query!(
               "SELECT state, closed_at FROM vector_agent_fences WHERE agent_id = $1",
               [agent_id]
             )

    assert NaiveDateTime.compare(closed_at, released_at) in [:eq, :gt]

    assert {:error, :closed} =
             Arbor.Persistence.execute_vector_operation(
               agent_id,
               insert_operation!(record!(agent_id, source_key: "post-destroy"))
             )

    assert %{rows: [[1]]} =
             Repo.query!(
               """
               SELECT COUNT(*) FROM memory_embeddings
               WHERE agent_id = $1 AND vector_protocol = 'arbor_vector_store_v1'
               """,
               [other_id]
             )
  end

  test "raw receipt insert trigger FOR KEY SHARE blocks destroy until holder commits", %{
    agent_id: agent_id
  } do
    # Ensure open fence exists without holding locks.
    Repo.query!(
      """
      INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
      VALUES ($1, 'open', NULL, CURRENT_TIMESTAMP)
      ON CONFLICT (agent_id) DO NOTHING
      """,
      [agent_id]
    )

    parent = self()
    fingerprint = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    holder =
      Task.async(fn ->
        # One pinned connection owns insert + hold + release so FOR KEY SHARE
        # remains held until the transaction commits.
        result =
          Repo.transaction(fn ->
            {:ok, _} =
              Repo.query(
                """
                INSERT INTO vector_operation_receipts (
                  operation_fingerprint, agent_id, operation_kind,
                  operation_json, operation_digest, receipt_json, receipt_digest, inserted_at
                ) VALUES ($1, $2, 'insert', '{}', $3, '{}', $4, CURRENT_TIMESTAMP)
                """,
                [
                  fingerprint,
                  agent_id,
                  String.duplicate("1", 64),
                  String.duplicate("2", 64)
                ]
              )

            %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:insert_held, self(), backend_pid})

            receive do
              :commit_insert -> :committed
            after
              15_000 -> Repo.rollback(:holder_timeout)
            end
          end)

        case result do
          {:ok, :committed} -> :committed
          {:error, :holder_timeout} -> :timed_out
          other -> other
        end
      end)

    assert_receive {:insert_held, holder_pid, holder_backend_pid}, 5_000

    destroy_task =
      Task.async(fn ->
        send(parent, {:destroy_started, self()})
        Arbor.Persistence.destroy_vector_agent(agent_id)
      end)

    assert_receive {:destroy_started, _destroy_pid}, 5_000
    assert is_integer(await_destroy_lock_wait!(holder_backend_pid))
    refute Task.yield(destroy_task, 0)

    send(holder_pid, :commit_insert)
    assert :committed = Task.await(holder, 10_000)
    assert :ok = Task.await(destroy_task, 20_000)

    assert %{rows: [["closed"]]} =
             Repo.query!(
               "SELECT state FROM vector_agent_fences WHERE agent_id = $1",
               [agent_id]
             )

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT COUNT(*) FROM vector_operation_receipts WHERE agent_id = $1",
               [agent_id]
             )
  end

  test "security regression: vector telemetry omits raw logical identity", %{
    agent_id: agent_id
  } do
    insert = insert_operation!(record!(agent_id, source_key: "telemetry-metadata"))
    assert {:ok, inserted} = Arbor.Persistence.execute_vector_operation(agent_id, insert)

    update =
      inserted.record
      |> rebuild_record!(payload: %{"telemetry" => "bounded"})
      |> operation_for_record!(:update)

    handler_id = {__MODULE__, make_ref()}
    expected_fingerprints = MapSet.new([update.fingerprint])

    :ok =
      :telemetry.attach_many(
        handler_id,
        [@operation_transaction_event, @fence_claim_event],
        &__MODULE__.handle_metadata_capture/4,
        %{parent: self(), handler_id: handler_id, expected_fingerprints: expected_fingerprints}
      )

    captured =
      try do
        assert {:ok, _receipt} = execute(agent_id, update)

        for _event <- 1..2, into: %{} do
          assert_receive {:vector_telemetry_metadata, ^handler_id, event, metadata}, 5_000
          {event, metadata}
        end
      after
        :telemetry.detach(handler_id)
      end

    transaction_metadata = Map.fetch!(captured, @operation_transaction_event)
    fence_metadata = Map.fetch!(captured, @fence_claim_event)

    assert MapSet.new(Map.keys(transaction_metadata)) ==
             MapSet.new([:operation_fingerprint, :operation_kind])

    assert MapSet.new(Map.keys(fence_metadata)) ==
             MapSet.new([
               :operation_fingerprint,
               :operation_kind,
               :expected_generation,
               :expected_revision
             ])

    assert transaction_metadata.operation_fingerprint == update.fingerprint
    assert transaction_metadata.operation_kind == :update
    assert fence_metadata.operation_fingerprint == update.fingerprint
    assert fence_metadata.operation_kind == :update
    assert {fence_metadata.expected_generation, fence_metadata.expected_revision} == {1, 1}
  end

  defp run_started_together(inputs, callback) do
    parent = self()

    tasks =
      Enum.map(inputs, fn input ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> callback.(input)
          after
            5_000 -> flunk("start barrier timed out")
          end
        end)
      end)

    for _input <- inputs, do: assert_receive({:ready, _pid}, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 20_000))
  end

  defp run_with_fence_overlap(inputs, callback) do
    expected_fingerprints = MapSet.new(Enum.map(inputs, & &1.fingerprint))

    run_with_observed_overlap(
      inputs,
      callback,
      expected_fingerprints,
      @fence_claim_event,
      &__MODULE__.handle_fence_claim/4,
      :fence_claim
    )
  end

  defp run_with_transaction_overlap(inputs, callback) do
    expected_fingerprints =
      MapSet.new(Enum.map(inputs, fn {_claimant, operation} -> operation.fingerprint end))

    run_with_observed_overlap(
      inputs,
      callback,
      expected_fingerprints,
      @operation_transaction_event,
      &__MODULE__.handle_operation_transaction/4,
      :operation_transaction
    )
  end

  defp run_with_observed_overlap(
         inputs,
         callback,
         expected_fingerprints,
         event,
         handler,
         point
       ) do
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        handler,
        %{
          parent: self(),
          handler_id: handler_id,
          expected_fingerprints: expected_fingerprints,
          point: point
        }
      )

    try do
      tasks = Enum.map(inputs, fn input -> Task.async(fn -> callback.(input) end) end)
      claims = await_overlap(length(inputs), handler_id, tasks, point, [])

      Enum.each(claims, fn claim ->
        send(claim.process_id, {:release_overlap, handler_id})
      end)

      results = Enum.map(tasks, &Task.await(&1, 20_000))
      {results, claims}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp await_overlap(0, _handler_id, _tasks, _point, claims), do: Enum.reverse(claims)

  defp await_overlap(remaining, handler_id, tasks, point, claims) do
    receive do
      {:overlap_ready, ^handler_id, claim} ->
        await_overlap(remaining - 1, handler_id, tasks, point, [claim | claims])
    after
      5_000 ->
        Enum.each(claims, fn claim ->
          send(claim.process_id, {:release_overlap, handler_id})
        end)

        Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))

        flunk("claimants did not overlap at #{point}; observed: #{inspect(claims)}")
    end
  end

  defp assert_fence_overlap(claims) do
    assert_independent_transactions(claims)
    assert length(claims) == 2
    assert claims |> Enum.map(& &1.operation_fingerprint) |> Enum.uniq() |> length() == 2
    assert claims |> Enum.map(& &1.expected_fence) |> Enum.uniq() == [{1, 1}]
  end

  defp assert_transaction_overlap(claims) do
    assert_independent_transactions(claims)
    assert length(claims) == 2
    assert claims |> Enum.map(& &1.operation_fingerprint) |> Enum.uniq() |> length() == 2
  end

  defp assert_independent_transactions(claims) do
    assert claims |> Enum.map(& &1.process_id) |> Enum.uniq() |> length() == 2
    assert claims |> Enum.map(& &1.backend_pid) |> Enum.uniq() |> length() == 2
    assert claims |> Enum.map(& &1.transaction_id) |> Enum.uniq() |> length() == 2
  end

  @doc false
  def handle_fence_claim(
        _event,
        _measurements,
        %{operation_fingerprint: fingerprint} = metadata,
        %{expected_fingerprints: expected_fingerprints} = config
      ) do
    if MapSet.member?(expected_fingerprints, fingerprint) do
      observe_overlap(metadata, config,
        expected_fence: {metadata.expected_generation, metadata.expected_revision}
      )
    end
  end

  def handle_fence_claim(_event, _measurements, _metadata, _config), do: :ok

  @doc false
  def handle_operation_transaction(
        _event,
        _measurements,
        %{operation_fingerprint: fingerprint} = metadata,
        %{expected_fingerprints: expected_fingerprints} = config
      ) do
    if MapSet.member?(expected_fingerprints, fingerprint) do
      observe_overlap(metadata, config, [])
    end
  end

  def handle_operation_transaction(_event, _measurements, _metadata, _config), do: :ok

  @doc false
  def handle_metadata_capture(
        event,
        _measurements,
        %{operation_fingerprint: fingerprint} = metadata,
        %{
          parent: parent,
          handler_id: handler_id,
          expected_fingerprints: expected_fingerprints
        }
      ) do
    if MapSet.member?(expected_fingerprints, fingerprint) do
      send(parent, {:vector_telemetry_metadata, handler_id, event, metadata})
    end
  end

  def handle_metadata_capture(_event, _measurements, _metadata, _config), do: :ok

  defp observe_overlap(metadata, config, extra) do
    %{rows: [[transaction_id, backend_pid]]} =
      Repo.query!("SELECT txid_current(), pg_backend_pid()")

    claim =
      Map.merge(
        %{
          process_id: self(),
          backend_pid: backend_pid,
          transaction_id: transaction_id,
          operation_fingerprint: metadata.operation_fingerprint
        },
        Map.new(extra)
      )

    send(config.parent, {:overlap_ready, config.handler_id, claim})

    receive do
      {:release_overlap, handler_id} when handler_id == config.handler_id -> :ok
    after
      10_000 -> raise "#{config.point} release timed out"
    end
  end

  defp execute(agent_id, operation),
    do: Arbor.Persistence.execute_vector_operation(agent_id, operation)

  defp await_destroy_lock_wait!(holder_backend_pid) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    await_destroy_lock_wait!(holder_backend_pid, deadline)
  end

  defp await_destroy_lock_wait!(holder_backend_pid, deadline) do
    case Repo.query!(
           """
           SELECT activity.pid
           FROM pg_stat_activity AS activity
           WHERE activity.datname = current_database()
             AND activity.wait_event_type = 'Lock'
             AND $1 = ANY(pg_blocking_pids(activity.pid))
             AND activity.query ILIKE '%vector_agent_fences%'
             AND activity.query ILIKE '%FOR UPDATE%'
           LIMIT 1
           """,
           [holder_backend_pid]
         ) do
      %{rows: [[blocked_pid]]} ->
        blocked_pid

      %{rows: []} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          await_destroy_lock_wait!(holder_backend_pid, deadline)
        else
          %{rows: diagnostics} =
            Repo.query!(
              """
              SELECT activity.pid, activity.wait_event_type, activity.wait_event,
                     left(activity.query, 240)
              FROM pg_stat_activity AS activity
              WHERE activity.datname = current_database()
                AND $1 = ANY(pg_blocking_pids(activity.pid))
              """,
              [holder_backend_pid]
            )

          flunk("destroy never reached the fence lock wait; observed: #{inspect(diagnostics)}")
        end
    end
  end

  defp record!(agent_id, overrides) do
    overrides = Map.new(overrides)
    payload = Map.get(overrides, :payload, %{"content" => unique("payload")})
    vector = Map.get(overrides, :vector, unit_vector(0))
    {:ok, payload_digest} = VectorRecord.payload_digest(payload)
    {:ok, vector_digest} = VectorRecord.vector_digest(vector)

    attrs = %{
      id: unique("vec"),
      agent_id: agent_id,
      source_namespace: "voice",
      source_key: unique("source"),
      payload: payload,
      vector: vector,
      payload_digest: payload_digest,
      vector_digest: vector_digest,
      model_id: "provider/model-v1",
      dimensions: VectorRecord.dimensions(),
      encoding: VectorRecord.encoding(),
      category: "voice",
      generation: 0,
      revision: 0,
      tombstone: false
    }

    {:ok, record} = VectorRecord.new(Map.merge(attrs, overrides))
    record
  end

  defp rebuild_record!(record, overrides) do
    attrs = Map.merge(Map.from_struct(record), Map.new(overrides))
    {:ok, payload_digest} = VectorRecord.payload_digest(attrs.payload)
    {:ok, vector_digest} = VectorRecord.vector_digest(attrs.vector)

    attrs =
      attrs
      |> Map.put(:payload_digest, payload_digest)
      |> Map.put(:vector_digest, vector_digest)

    {:ok, rebuilt} = VectorRecord.new(attrs)
    rebuilt
  end

  defp insert_operation!(record), do: operation!(:insert, record)

  defp operation_for_record!(record, kind), do: operation!(kind, record)

  defp operation!(:insert, record) do
    {:ok, operation} =
      VectorOperation.new(%{
        kind: :insert,
        record: record,
        expected_generation: nil,
        expected_revision: nil
      })

    operation
  end

  defp operation!(kind, record) do
    {:ok, operation} =
      VectorOperation.new(%{
        kind: kind,
        record: record,
        expected_generation: record.generation,
        expected_revision: record.revision
      })

    operation
  end

  defp unit_vector(index) do
    List.replace_at(List.duplicate(0.0, VectorRecord.dimensions()), index, 1.0)
  end

  defp unique(prefix) do
    suffix = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    "#{prefix}_#{suffix}"
  end

  defp summarize_result({:ok, receipt}), do: {:ok, receipt.operation_fingerprint}
  defp summarize_result(error), do: error

  defp summarize_batch_result({claimant, _batch, {:ok, receipt}}),
    do: {claimant, {:ok, receipt.operation_fingerprint}}

  defp summarize_batch_result({claimant, _batch, error}), do: {claimant, error}

  defp start_repo! do
    case Repo.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        {pid, true}

      {:error, {:already_started, pid}} ->
        _ = Process.unlink(pid)
        {pid, false}

      {:error, reason} ->
        raise "PostgreSQL vector concurrency prerequisite unavailable: #{inspect(reason)}"
    end
  end

  defp restore_sandbox_mode do
    if Process.whereis(Repo) do
      Sandbox.mode(Repo, :manual)
    end
  catch
    :exit, _reason -> :ok
  end

  defp restore_env(key, :not_configured), do: Application.delete_env(:arbor_persistence, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_persistence, key, value)
end
