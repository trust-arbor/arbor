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

    {results, overlap} = run_with_fence_overlap(claims, &execute(agent_id, &1), agent_id)
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
      run_with_fence_overlap(
        batches,
        fn {claimant, batch} ->
          {claimant, batch, execute(agent_id, batch)}
        end,
        agent_id
      )

    assert_fence_overlap(overlap)

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

  defp run_with_fence_overlap(inputs, callback, agent_id) do
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        @fence_claim_event,
        &__MODULE__.handle_fence_claim/4,
        %{parent: self(), handler_id: handler_id, agent_id: agent_id}
      )

    try do
      tasks = Enum.map(inputs, fn input -> Task.async(fn -> callback.(input) end) end)
      claims = await_fence_claims(length(inputs), handler_id, tasks, [])

      Enum.each(claims, fn claim ->
        send(claim.process_id, {:release_fence_claim, handler_id})
      end)

      results = Enum.map(tasks, &Task.await(&1, 20_000))
      {results, claims}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp await_fence_claims(0, _handler_id, _tasks, claims), do: Enum.reverse(claims)

  defp await_fence_claims(remaining, handler_id, tasks, claims) do
    receive do
      {:fence_claim_ready, ^handler_id, claim} ->
        await_fence_claims(remaining - 1, handler_id, tasks, [claim | claims])
    after
      5_000 ->
        Enum.each(claims, fn claim ->
          send(claim.process_id, {:release_fence_claim, handler_id})
        end)

        Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
        flunk("claimants did not overlap at the fenced update; observed: #{inspect(claims)}")
    end
  end

  defp assert_fence_overlap(claims) do
    assert length(claims) == 2
    assert claims |> Enum.map(& &1.process_id) |> Enum.uniq() |> length() == 2
    assert claims |> Enum.map(& &1.backend_pid) |> Enum.uniq() |> length() == 2
    assert claims |> Enum.map(& &1.transaction_id) |> Enum.uniq() |> length() == 2
    assert claims |> Enum.map(& &1.operation_fingerprint) |> Enum.uniq() |> length() == 2
    assert claims |> Enum.map(& &1.expected_fence) |> Enum.uniq() == [{1, 1}]
  end

  @doc false
  def handle_fence_claim(
        _event,
        _measurements,
        %{agent_id: agent_id} = metadata,
        %{agent_id: agent_id} = config
      ) do
    %{rows: [[transaction_id, backend_pid]]} =
      Repo.query!("SELECT txid_current(), pg_backend_pid()")

    claim = %{
      process_id: self(),
      backend_pid: backend_pid,
      transaction_id: transaction_id,
      operation_fingerprint: metadata.operation_fingerprint,
      expected_fence: {metadata.expected_generation, metadata.expected_revision}
    }

    send(config.parent, {:fence_claim_ready, config.handler_id, claim})

    receive do
      {:release_fence_claim, handler_id} when handler_id == config.handler_id -> :ok
    after
      10_000 -> raise "fence claim release timed out"
    end
  end

  def handle_fence_claim(_event, _measurements, _metadata, _config), do: :ok

  defp execute(agent_id, operation),
    do: Arbor.Persistence.execute_vector_operation(agent_id, operation)

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
