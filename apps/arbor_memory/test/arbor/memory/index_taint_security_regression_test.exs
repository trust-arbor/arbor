defmodule Arbor.Memory.IndexTaintSecurityRegressionTest do
  @moduledoc """
  Security regression: semantic indexing and recall preserve producer taint.

  Exercises the public Memory facade and real Index/ETS implementation. Durable
  I/O alone is replaced by an in-memory record store; every durable write/read
  uses the production strict codec, including payload-bound taint envelopes.
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.VectorRecord
  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Memory
  alias Arbor.Memory.IndexSupervisor

  @moduletag :fast

  defmodule RecordStore do
    @moduledoc false
    alias Arbor.Memory.Embedding
    @table :index_taint_security_records

    def start, do: :ets.new(@table, [:named_table, :public, :set])
    def encode_operation(input), do: Embedding.encode_strict_operation(input)
    def encode_batch(inputs), do: Embedding.encode_strict_batch(inputs)

    def execute(_agent, %{kind: :batch, operations: ops}, _opts) do
      receipts =
        Enum.map(ops, fn op ->
          {:ok, receipt} = execute(nil, op, [])
          receipt
        end)

      {:ok, %{kind: :batch, receipts: receipts}}
    end

    def execute(_agent, operation, _opts) do
      record = operation.record
      :ets.insert(@table, {{record.agent_id, record.source_key}, record})
      {:ok, %{kind: operation.kind, record: record}}
    end

    def reconcile(_agent, _operation, _opts), do: {:ok, :absent}

    def fetch(agent, _namespace, key, _opts) do
      case :ets.lookup(@table, {agent, key}) do
        [{_, record}] -> Embedding.decode_strict_record(record)
        [] -> {:error, :not_found}
      end
    end

    def list(agent, _opts) do
      views = for {{^agent, _}, record} <- :ets.tab2list(@table), do: decode(record)
      {:ok, views}
    end

    def search(agent, _vector, opts) do
      {:ok, views} = list(agent, [])
      category = Keyword.get(opts, :category)
      views = Enum.filter(views, &(is_nil(category) or &1.category == category))
      {:ok, Enum.map(views, &%{match: &1, similarity: 1.0})}
    end

    defp decode(record) do
      {:ok, view} = Embedding.decode_strict_record(record)
      view
    end
  end

  setup do
    RecordStore.start()
    previous = Application.fetch_env(:arbor_memory, :strict_vector_seam)
    Application.put_env(:arbor_memory, :strict_vector_seam, RecordStore)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_memory, :strict_vector_seam, value)
        :error -> Application.delete_env(:arbor_memory, :strict_vector_seam)
      end
    end)

    :ok
  end

  for backend <- [:ets, :dual, :pgvector] do
    @tag backend: backend
    test "security regression: #{backend} recall retains hostile producer taint", %{
      backend: backend
    } do
      agent = start_memory(backend)
      taint = hostile_taint()

      assert {:ok, id} =
               Memory.index(agent, "poisoned source", %{type: :fact},
                 embedding: vector(),
                 taint: taint
               )

      assert {:ok, [result]} = Memory.recall(agent, "source", embedding: vector())
      assert result.id == id
      assert result.taint == taint
      assert result.provenance_status == :verified

      if backend != :ets do
        :ok = IndexSupervisor.stop_index(agent)
        start_memory(backend, agent)
        assert {:ok, [recalled]} = Memory.recall(agent, "source", embedding: vector())
        assert recalled.taint == taint
      end
    end

    @tag backend: backend
    test "security regression: #{backend} missing provenance stays unverified on recall", %{
      backend: backend
    } do
      agent = start_memory(backend)

      assert {:ok, _} =
               Memory.index(
                 agent,
                 "unknown source",
                 %{taint: "trusted", provenance_status: "verified"},
                 embedding: vector()
               )

      assert {:ok, [result]} = Memory.recall(agent, "source", embedding: vector())
      assert result.taint == TaintEnvelope.missing_fallback()
      assert result.provenance_status == :legacy_unlabeled

      if backend != :ets do
        :ok = IndexSupervisor.stop_index(agent)
        start_memory(backend, agent)
        assert {:ok, [recalled]} = Memory.recall(agent, "source", embedding: vector())
        assert recalled.provenance_status == :legacy_unlabeled
      end
    end
  end

  test "security regression: batch indexing preserves taint for every entry" do
    agent = start_memory(:dual)
    taint = hostile_taint()

    assert {:ok, ids} =
             Memory.batch_index(agent, [{"first", %{}}, {"second", %{}}],
               embedding: vector(),
               taint: taint
             )

    assert {:ok, results} = Memory.recall(agent, "source", embedding: vector())
    assert Enum.sort(Enum.map(results, & &1.id)) == Enum.sort(ids)
    assert Enum.all?(results, &(&1.taint == taint))

    :ok = IndexSupervisor.stop_index(agent)
    start_memory(:dual, agent)
    assert {:ok, rehydrated} = Memory.recall(agent, "source", embedding: vector())
    assert Enum.sort(Enum.map(rehydrated, & &1.id)) == Enum.sort(ids)
    assert Enum.all?(rehydrated, &(&1.taint == taint))
  end

  test "security regression: malformed producer taint is rejected before indexing" do
    agent = start_memory(:ets)

    assert {:error, _} =
             Memory.index(agent, "source", %{}, embedding: vector(), taint: %{level: :bogus})

    assert {:ok, %{entry_count: 0}} = Memory.index_stats(agent)
  end

  test "security regression: direct persistent search exposes missing-label taint" do
    agent = "taint_direct_#{System.unique_integer([:positive])}"
    assert {:ok, id} = Memory.store_embedding(agent, "unknown source", vector())
    assert {:ok, [result]} = Memory.search_embeddings(agent, vector())
    assert result.id == id
    assert result.taint == TaintEnvelope.missing_fallback()
    assert result.provenance_status == :legacy_unlabeled
  end

  test "security regression: direct persistent store preserves explicit producer taint" do
    agent = "taint_direct_#{System.unique_integer([:positive])}"
    taint = hostile_taint()

    assert {:ok, id} =
             Memory.store_embedding(agent, "poisoned source", vector(), %{}, taint: taint)

    assert {:ok, [result]} = Memory.search_embeddings(agent, vector())
    assert result.id == id
    assert result.taint == taint
    assert result.provenance_status == :verified
  end

  defp start_memory(backend, agent \\ nil) do
    agent = agent || "taint_index_#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             Memory.init_for_agent(agent,
               graph_enabled: false,
               backend: backend,
               strict_vector_seam: RecordStore
             )

    on_exit(fn -> IndexSupervisor.stop_index(agent) end)
    agent
  end

  defp vector, do: [1.0 | List.duplicate(0.0, VectorRecord.dimensions() - 1)]

  defp hostile_taint do
    %Taint{
      level: :hostile,
      sensitivity: :restricted,
      confidence: :verified,
      sanitizations: 0,
      source: "web:poisoned",
      chain: ["tool:web", "memory:index"]
    }
  end
end
