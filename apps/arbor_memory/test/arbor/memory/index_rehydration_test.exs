defmodule Arbor.Memory.IndexRehydrationTest do
  @moduledoc """
  Regression: persisted semantic vectors must rehydrate the ETS index on start.

  Fails if `Index.init/1` stops calling `maybe_rehydrate/1`. Store a fact, drop
  the index process, start a new one — recall and `Index.get/2` must find it
  without an explicit `warm_cache/2`.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.VectorRecord
  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Memory
  alias Arbor.Memory.{Index, IndexSupervisor, Lifecycle}
  alias Arbor.Memory.Test.DurableGraphAuthority

  @moduletag :fast

  defmodule DurableSeam do
    @moduledoc false

    @table :index_rehydration_durable_vectors

    def ensure_table! do
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [:named_table, :public, :set])

        _tid ->
          @table
      end
    end

    def reset! do
      ensure_table!()
      :ets.delete_all_objects(@table)
      :ok
    end

    def put_view(view) when is_map(view) do
      ensure_table!()
      :ets.insert(@table, {{view.agent_id, view.source_key}, view})
      :ok
    end

    def encode_operation(input) do
      case Arbor.Memory.Embedding.encode_strict_operation(input) do
        {:ok, op, view} ->
          put_view(view)
          {:ok, op, view}

        other ->
          other
      end
    end

    def encode_batch(inputs), do: Arbor.Memory.Embedding.encode_strict_batch(inputs)

    def execute(_agent_id, operation, _opts) do
      key = operation.record.source_key
      id = operation.record.id
      {:ok, %{kind: operation.kind, record: %{source_key: key, id: id}}}
    end

    def reconcile(_agent_id, _operation, _opts), do: {:ok, :absent}
    def search(_agent_id, _vector, _opts), do: {:error, :unsupported}
    def fetch(_agent_id, _ns, _key, _opts), do: {:error, :not_found}
    def destroy(_agent_id, _opts), do: :ok

    def list(agent_id, opts) do
      ns = Keyword.get(opts, :source_namespace, "memory_index")
      limit = Keyword.get(opts, :limit, 1000)

      views =
        @table
        |> :ets.tab2list()
        |> Enum.map(fn {_key, view} -> view end)
        |> Enum.filter(fn view ->
          view.agent_id == agent_id and view.source_namespace == ns and view.tombstone == false
        end)
        |> Enum.take(limit)

      {:ok, views}
    end
  end

  setup do
    DurableGraphAuthority.start!()
    DurableSeam.reset!()

    original_backend =
      Application.get_env(:arbor_memory, :embedding_backend, :not_configured)

    original_seam =
      Application.get_env(:arbor_memory, :strict_vector_seam, :not_configured)

    on_exit(fn ->
      restore_env(:arbor_memory, :embedding_backend, original_backend)
      restore_env(:arbor_memory, :strict_vector_seam, original_seam)
      DurableSeam.reset!()
    end)

    :ok
  end

  test "index start rehydrates ETS from durable list without warm_cache" do
    agent_id = unique("rehydrate_agent")
    entry_id = "mem_rehydrate_seed"
    vector = unit_vector(0)
    content = "Persisted fact about Elixir pattern matching"

    DurableSeam.put_view(verified_view(agent_id, entry_id, content, vector))

    {:ok, pid} = start_index(agent_id, rehydrate: true)

    assert Index.stats(pid).entry_count == 1

    assert {:ok,
            %{
              id: ^entry_id,
              content: ^content,
              model_id: "legacy:unspecified",
              provenance_status: :verified
            }} = Index.get(pid, entry_id)

    assert {:ok, [%{id: ^entry_id, content: ^content} | _]} =
             Index.recall(pid, "ignored", embedding: vector, threshold: -1.0, limit: 5)
  end

  test "skipping start rehydration leaves persisted vectors absent from ETS" do
    agent_id = unique("rehydrate_skip")
    entry_id = "mem_rehydrate_skip"
    vector = unit_vector(1)

    DurableSeam.put_view(
      verified_view(agent_id, entry_id, "Fact that must survive restart", vector)
    )

    {:ok, skipped} = start_index(agent_id, rehydrate: false)
    assert {:error, :not_found} = Index.get(skipped, entry_id)
    assert Index.stats(skipped).entry_count == 0
    GenServer.stop(skipped)

    {:ok, pid} = start_index(agent_id)
    assert {:ok, %{id: ^entry_id}} = Index.get(pid, entry_id)
  end

  test "store, drop the index process, restart, recall finds the same row" do
    agent_id = unique("rehydrate_roundtrip")
    vector = unit_vector(2)
    content = "The knowledge graph is not the semantic index"

    {:ok, writer} = start_index(agent_id)

    assert {:ok, entry_id} =
             Index.index(writer, content, %{type: :fact}, embedding: vector)

    assert {:ok, %{id: ^entry_id}} = Index.get(writer, entry_id)
    GenServer.stop(writer)

    {:ok, restarted} = start_index(agent_id)

    assert {:ok, %{id: ^entry_id, content: ^content}} = Index.get(restarted, entry_id)

    assert {:ok, results} =
             Index.recall(restarted, "semantic index",
               embedding: vector,
               threshold: -1.0,
               limit: 5
             )

    assert Enum.any?(results, &(&1.id == entry_id))
  end

  test "recall/3 starts and rehydrates when the graph survived but the index did not" do
    agent_id = unique("rehydrate_recall")
    vector = unit_vector(3)
    content = "Stored before the server restarted"

    Application.put_env(:arbor_memory, :embedding_backend, :dual)
    Application.put_env(:arbor_memory, :strict_vector_seam, DurableSeam)

    {:ok, _pid} = Memory.init_for_agent(agent_id, graph_enabled: true)

    on_exit(fn -> Memory.cleanup_for_agent(agent_id) end)

    assert {:ok, entry_id} =
             Memory.index(agent_id, content, %{type: :fact}, embedding: vector)

    :ok = IndexSupervisor.stop_index(agent_id)
    refute Memory.index_running?(agent_id)
    assert Memory.initialized?(agent_id)

    assert {:ok, results} =
             Memory.recall(agent_id, "restarted",
               embedding: vector,
               threshold: -1.0,
               limit: 5
             )

    assert Enum.any?(results, &(&1.id == entry_id and &1.content == content))
    assert Memory.index_running?(agent_id)
  end

  test "pgvector backend recalls from rehydrated ETS when ANN is unsupported" do
    agent_id = unique("rehydrate_pgvector")
    entry_id = "mem_pgvector_fallback"
    vector = unit_vector(5)
    content = "SQLite has no pgvector operator"

    DurableSeam.put_view(verified_view(agent_id, entry_id, content, vector))

    {:ok, pid} = start_index(agent_id, backend: :pgvector)

    assert {:ok, [%{id: ^entry_id, content: ^content} | _]} =
             Index.recall(pid, "sqlite", embedding: vector, threshold: -1.0, limit: 5)
  end

  test "recall/3 still returns :index_not_initialized when no index and no durable vectors" do
    agent_id = unique("rehydrate_absent")
    Application.put_env(:arbor_memory, :strict_vector_seam, DurableSeam)

    assert {:error, :index_not_initialized} = Memory.recall(agent_id, "nothing")
    refute Memory.index_running?(agent_id)
  end

  test "Lifecycle.on_agent_start restarts a missing index so recall is not amnesiac" do
    agent_id = unique("rehydrate_lifecycle")
    vector = unit_vector(4)
    content = "Lifecycle must rehydrate the index"

    Application.put_env(:arbor_memory, :embedding_backend, :dual)
    Application.put_env(:arbor_memory, :strict_vector_seam, DurableSeam)

    {:ok, _} = Lifecycle.on_agent_start(agent_id)
    on_exit(fn -> Memory.cleanup_for_agent(agent_id) end)

    assert {:ok, entry_id} =
             Memory.index(agent_id, content, %{type: :fact}, embedding: vector)

    :ok = IndexSupervisor.stop_index(agent_id)
    refute Memory.index_running?(agent_id)

    {:ok, _} = Lifecycle.on_agent_start(agent_id)
    assert Memory.index_running?(agent_id)
    assert {:ok, pid} = IndexSupervisor.get_index(agent_id)
    assert {:ok, %{id: ^entry_id, content: ^content}} = Index.get(pid, entry_id)
  end

  defp start_index(agent_id, opts \\ []) do
    {:ok, pid} =
      Index.start_link(
        Keyword.merge(
          [
            agent_id: agent_id,
            backend: :dual,
            strict_vector_seam: DurableSeam,
            name: nil
          ],
          opts
        )
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    {:ok, pid}
  end

  defp verified_view(agent_id, entry_id, content, vector) do
    %{
      id: entry_id,
      agent_id: agent_id,
      source_namespace: "memory_index",
      source_key: entry_id,
      body: %{"content" => content, "metadata" => %{"type" => "fact"}},
      vector: vector,
      model_id: "legacy:unspecified",
      dimensions: VectorRecord.dimensions(),
      encoding: VectorRecord.encoding(),
      category: "fact",
      provenance_status: :verified,
      tombstone: false,
      taint: TaintEnvelope.missing_fallback()
    }
  end

  defp unit_vector(index) do
    List.duplicate(0.0, VectorRecord.dimensions())
    |> List.replace_at(index, 1.0)
  end

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp restore_env(app, key, :not_configured), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
