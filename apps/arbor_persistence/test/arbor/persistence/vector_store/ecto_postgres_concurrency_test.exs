defmodule Arbor.Persistence.VectorStore.EctoPostgresConcurrencyTest do
  @moduledoc """
  Vector CAS and transaction tests using independent PostgreSQL sessions.

  The SQL sandbox runs in `:auto` mode here so concurrent Tasks check out
  separate connections. SQLite coverage intentionally makes no concurrency
  claim.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.{VectorOperation, VectorRecord}
  alias Arbor.Persistence.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :database
  @moduletag :integration
  @moduletag :postgres

  if Repo.__adapter__() != Ecto.Adapters.Postgres do
    @moduletag skip: "independent-session vector CAS coverage requires PostgreSQL"
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
      Sandbox.mode(Repo, :manual)
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

    results = run_concurrently(claims, &execute(agent_id, &1))

    assert Enum.count(results, &match?({:ok, _receipt}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :conflict})) == 1

    assert {:ok, current} =
             Arbor.Persistence.fetch_vector_record(agent_id, "voice", "shared-cas")

    assert current.revision == 2
    assert current.payload["claimant"] in ["one", "two"]
  end

  test "duplicate same-operation execution returns one exact committed receipt", %{
    agent_id: agent_id
  } do
    operation = insert_operation!(record!(agent_id, source_key: "duplicate-operation"))
    results = run_concurrently([operation, operation], &execute(agent_id, &1))

    assert [{:ok, first}, {:ok, second}] = results
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

    results =
      run_concurrently(batches, fn {claimant, batch} ->
        {claimant, batch, execute(agent_id, batch)}
      end)

    assert [{winner, winning_batch, {:ok, winning_receipt}}] =
             Enum.filter(results, &match?({_claimant, _batch, {:ok, _receipt}}, &1))

    assert [{loser, losing_batch, {:error, :conflict}}] =
             Enum.filter(results, &match?({_claimant, _batch, {:error, :conflict}}, &1))

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

  defp run_concurrently(inputs, callback) do
    parent = self()

    tasks =
      Enum.map(inputs, fn input ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> callback.(input)
          after
            5_000 -> flunk("concurrency barrier timed out")
          end
        end)
      end)

    for _input <- inputs, do: assert_receive({:ready, _pid}, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 20_000))
  end

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

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"

  defp restore_env(key, :not_configured), do: Application.delete_env(:arbor_persistence, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_persistence, key, value)
end
