defmodule Arbor.Memory.C3G2AnnAndFailClosedTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.VectorRecord
  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Memory.{Index, IndexOps, MemoryStore, MemoryStoreIdentity, Retrieval}
  alias Arbor.Memory.StrictEmbeddingInput

  @moduletag :fast

  defmodule RecordingSeam do
    @moduledoc false

    def configure(mode) do
      :persistent_term.put({__MODULE__, :mode}, mode)
      :persistent_term.put({__MODULE__, :searches}, [])
      :persistent_term.put({__MODULE__, :lists}, [])
      :persistent_term.put({__MODULE__, :executes}, [])
      :persistent_term.put({__MODULE__, :fetches}, [])
      :persistent_term.put({__MODULE__, :fetch_result}, {:error, :not_found})
    end

    def searches, do: Enum.reverse(:persistent_term.get({__MODULE__, :searches}, []))
    def lists, do: Enum.reverse(:persistent_term.get({__MODULE__, :lists}, []))
    def executes, do: Enum.reverse(:persistent_term.get({__MODULE__, :executes}, []))
    def fetches, do: Enum.reverse(:persistent_term.get({__MODULE__, :fetches}, []))

    def reset do
      for k <- [:mode, :searches, :lists, :executes, :fetches, :fetch_result] do
        :persistent_term.erase({__MODULE__, k})
      end
    end

    def encode_operation(input) do
      case Arbor.Memory.Embedding.encode_strict_operation(input) do
        {:ok, op, view} -> {:ok, op, view}
        other -> other
      end
    end

    def encode_batch(inputs) do
      Arbor.Memory.Embedding.encode_strict_batch(inputs)
    end

    def execute(agent_id, operation, opts) do
      prev = :persistent_term.get({__MODULE__, :executes}, [])
      :persistent_term.put({__MODULE__, :executes}, [{agent_id, operation, opts} | prev])

      case :persistent_term.get({__MODULE__, :mode}) do
        {:execute_ok, id} ->
          {:ok, %{kind: operation.kind, record: %{source_key: id, id: id}}}

        :execute_unsupported ->
          {:error, :unsupported}

        :track_only ->
          {:error, :unsupported}

        other ->
          {:error, {:unexpected_mode, other}}
      end
    end

    def reconcile(_agent_id, _operation, _opts), do: {:ok, :absent}

    def search(agent_id, vector, opts) do
      prev = :persistent_term.get({__MODULE__, :searches}, [])
      :persistent_term.put({__MODULE__, :searches}, [{agent_id, vector, opts} | prev])

      case :persistent_term.get({__MODULE__, :mode}) do
        {:malformed_memory_store, key} ->
          namespace = Keyword.fetch!(opts, :source_namespace)

          {:ok,
           [
             %{
               match: %{
                 id: MemoryStoreIdentity.row_id(agent_id, namespace, key),
                 agent_id: agent_id,
                 source_namespace: namespace,
                 source_key: key,
                 model_id: Keyword.fetch!(opts, :model_id),
                 dimensions: Keyword.fetch!(opts, :dimensions),
                 encoding: Keyword.fetch!(opts, :encoding),
                 category: Keyword.get(opts, :category, "untyped"),
                 provenance_status: :verified,
                 tombstone: false
               },
               similarity: 0.9
             }
           ]}

        {:search_results, results} ->
          category = Keyword.get(opts, :category)

          filtered =
            if is_binary(category) do
              Enum.filter(results, fn
                %{match: %{category: ^category}} -> true
                _ -> false
              end)
            else
              results
            end

          {:ok, filtered}

        {:search_error, reason} ->
          {:error, reason}

        _ ->
          {:ok, []}
      end
    end

    def fetch(agent_id, ns, key, opts) do
      prev = :persistent_term.get({__MODULE__, :fetches}, [])
      :persistent_term.put({__MODULE__, :fetches}, [{agent_id, ns, key, opts} | prev])
      :persistent_term.get({__MODULE__, :fetch_result}, {:error, :not_found})
    end

    def list(agent_id, opts) do
      prev = :persistent_term.get({__MODULE__, :lists}, [])
      :persistent_term.put({__MODULE__, :lists}, [{agent_id, opts} | prev])

      case :persistent_term.get({__MODULE__, :mode}) do
        {:list_results, results} -> {:ok, results}
        {:list_error, reason} -> {:error, reason}
        _ -> {:ok, []}
      end
    end
  end

  defp start_index(agent_id, mode) do
    RecordingSeam.configure(mode)

    {:ok, pid} =
      Index.start_link(
        agent_id: agent_id,
        backend: :pgvector,
        strict_vector_seam: RecordingSeam,
        embedding_provider: Arbor.AI,
        name: {:via, Registry, {Arbor.Memory.Registry, {:index, agent_id}}}
      )

    pid
  end

  setup do
    Application.put_env(:arbor_memory, :embedding_service_enabled, false)

    on_exit(fn ->
      RecordingSeam.reset()
      Application.put_env(:arbor_memory, :embedding_service_enabled, true)
    end)

    :ok
  end

  test "strict ANN query uses exact model/dimensions/encoding and category-omitted untyped search" do
    agent_id = "c3g2_ann_untyped_#{System.unique_integer([:positive])}"
    pid = start_index(agent_id, {:search_results, []})

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert {:ok, []} = Index.recall(pid, "hello world", limit: 5, threshold: 0.1)

    assert [{^agent_id, _vector, opts}] = RecordingSeam.searches()
    assert opts[:model_id] == "memory:local_hash_v1"
    assert opts[:dimensions] == VectorRecord.dimensions()
    assert opts[:encoding] == VectorRecord.encoding()
    assert opts[:source_namespace] == "memory_index"
    assert opts[:threshold] == 0.1
    assert opts[:limit] == 5
    refute Keyword.has_key?(opts, :category)
  end

  test "single type uses category-scoped ANN; types fan-out then id-dedupe" do
    agent_id = "c3g2_ann_types_#{System.unique_integer([:positive])}"

    match = fn id, cat, sim ->
      %{
        match: %{
          id: id,
          agent_id: agent_id,
          source_namespace: "memory_index",
          source_key: id,
          body: %{"content" => "c", "metadata" => %{"type" => cat}},
          vector: List.duplicate(0.1, 768),
          model_id: "memory:local_hash_v1",
          dimensions: 768,
          encoding: VectorRecord.encoding(),
          category: cat,
          taint: TaintEnvelope.missing_fallback(),
          provenance_status: :verified,
          tombstone: false
        },
        similarity: sim
      }
    end

    # Fan-out will call search twice; return overlapping ids
    pid =
      start_index(
        agent_id,
        {:search_results, [match.("mem_a", "fact", 0.9), match.("mem_b", "note", 0.8)]}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert {:ok, results} = Index.recall(pid, "q", types: [:fact, :note], limit: 10)
    assert length(RecordingSeam.searches()) == 2

    cats =
      RecordingSeam.searches()
      |> Enum.map(fn {_a, _v, opts} -> opts[:category] end)
      |> Enum.sort()

    assert cats == ["fact", "note"]

    ids = Enum.map(results, & &1.id)
    assert length(ids) == length(Enum.uniq(ids))
  end

  test "tenant-mismatched search result fails whole recall before use" do
    agent_id = "c3g2_ann_tenant_#{System.unique_integer([:positive])}"

    bad = %{
      match: %{
        id: "x",
        agent_id: "other_agent",
        source_namespace: "memory_index",
        source_key: "x",
        body: %{"content" => "c", "metadata" => %{}},
        vector: List.duplicate(0.1, 768),
        model_id: "memory:local_hash_v1",
        dimensions: 768,
        encoding: VectorRecord.encoding(),
        category: "untyped",
        taint: TaintEnvelope.missing_fallback(),
        provenance_status: :verified,
        tombstone: false
      },
      similarity: 0.99
    }

    pid = start_index(agent_id, {:search_results, [bad]})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert {:error, :tenant_mismatch} = Index.recall(pid, "q")
  end

  test "malformed decoded search view fails closed without raising" do
    agent_id = "c3g2_ann_malformed_#{System.unique_integer([:positive])}"

    malformed = %{
      match: %{
        id: "mem_missing_body",
        agent_id: agent_id,
        source_namespace: "memory_index",
        source_key: "mem_missing_body",
        model_id: "memory:local_hash_v1",
        dimensions: VectorRecord.dimensions(),
        encoding: VectorRecord.encoding(),
        category: "untyped",
        provenance_status: :verified,
        tombstone: false
      },
      similarity: 0.9
    }

    pid = start_index(agent_id, {:search_results, [malformed]})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert {:error, :malformed_persistence_result} = Index.recall(pid, "q")
  end

  test "IndexOps and Retrieval reject malformed strict search sets without raising" do
    agent_id = "c3g2_public_malformed_#{System.unique_integer([:positive])}"
    vector = List.duplicate(0.1, VectorRecord.dimensions())

    malformed = %{
      match: %{
        id: "mem_missing_body",
        agent_id: agent_id,
        source_namespace: "memory_index",
        source_key: "mem_missing_body",
        model_id: "legacy:unspecified",
        dimensions: VectorRecord.dimensions(),
        encoding: VectorRecord.encoding(),
        category: "untyped",
        provenance_status: :verified,
        tombstone: false
      },
      similarity: 0.9
    }

    previous = Application.get_env(:arbor_memory, :strict_vector_seam, :not_configured)
    Application.put_env(:arbor_memory, :strict_vector_seam, RecordingSeam)
    RecordingSeam.configure({:search_results, [malformed]})

    on_exit(fn ->
      case previous do
        :not_configured -> Application.delete_env(:arbor_memory, :strict_vector_seam)
        module -> Application.put_env(:arbor_memory, :strict_vector_seam, module)
      end
    end)

    assert {:error, :malformed_persistence_result} =
             IndexOps.search_embeddings(agent_id, vector)

    assert {:error, :malformed_persistence_result} =
             Retrieval.recall(agent_id, "query", backend: :persistent, embedding: vector)
  end

  test "MemoryStore semantic search rejects a malformed strict set without raising" do
    agent_id = "c3g2_store_malformed_#{System.unique_integer([:positive])}"
    previous = Application.get_env(:arbor_memory, :strict_vector_seam, :not_configured)

    Application.put_env(:arbor_memory, :strict_vector_seam, RecordingSeam)
    RecordingSeam.configure({:malformed_memory_store, "goal_1"})

    on_exit(fn ->
      case previous do
        :not_configured -> Application.delete_env(:arbor_memory, :strict_vector_seam)
        module -> Application.put_env(:arbor_memory, :strict_vector_seam, module)
      end
    end)

    assert {:error, :malformed_persistence_result} =
             MemoryStore.semantic_search("query", "goals", agent_id: agent_id)
  end

  test "warm cache fails closed on non-verified provenance before ETS admission" do
    agent_id = "c3g2_warm_#{System.unique_integer([:positive])}"

    legacy_view = %{
      id: "mem_leg",
      agent_id: agent_id,
      source_namespace: "memory_index",
      source_key: "mem_leg",
      body: %{"content" => "legacy", "metadata" => %{}},
      vector: List.duplicate(0.2, 768),
      model_id: "legacy:unspecified",
      dimensions: 768,
      encoding: VectorRecord.encoding(),
      category: "untyped",
      taint: TaintEnvelope.missing_fallback(),
      provenance_status: :legacy_unlabeled,
      tombstone: false
    }

    pid = start_index(agent_id, {:list_results, [legacy_view]})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert {:error, :unverified_strict_provenance} = Index.warm_cache(pid, limit: 10)
    assert {:error, :not_found} = Index.get(pid, "mem_leg")
  end

  test "explicit delete uses seam fetch then delete; only after durable terminal evidence" do
    agent_id = "c3g2_del_#{System.unique_integer([:positive])}"
    configured_id = "mem_del_#{System.unique_integer([:positive])}"
    vector = List.duplicate(0.3, VectorRecord.dimensions())

    RecordingSeam.configure({:execute_ok, configured_id})

    {:ok, pid} =
      Index.start_link(
        agent_id: agent_id,
        backend: :dual,
        strict_vector_seam: RecordingSeam,
        entry_id_generator: fn -> configured_id end,
        name: {:via, Registry, {Arbor.Memory.Registry, {:index, agent_id}}}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert {:ok, entry_id} =
             Index.index(pid, "to delete", %{type: :fact}, embedding: vector)

    assert entry_id == configured_id
    assert {:ok, %{id: ^entry_id}} = Index.get(pid, entry_id)

    view = %{
      "id" => entry_id,
      "agent_id" => agent_id,
      "source_namespace" => "memory_index",
      "source_key" => entry_id,
      "body" => %{"content" => "to delete", "metadata" => %{"type" => "fact"}},
      "vector" => vector,
      "model_id" => "legacy:unspecified",
      "dimensions" => 768,
      "encoding" => VectorRecord.encoding(),
      "category" => "fact",
      "taint" => TaintEnvelope.missing_fallback(),
      "provenance_status" => :verified,
      "generation" => 1,
      "revision" => 1,
      "tombstone" => false
    }

    :persistent_term.put({RecordingSeam, :fetch_result}, {:ok, view})
    :persistent_term.put({RecordingSeam, :mode}, {:execute_ok, entry_id})

    # Delete must fetch fence then execute delete; local removed only after success.
    assert :ok = Index.delete(pid, entry_id)
    assert {:error, :not_found} = Index.get(pid, entry_id)
    assert RecordingSeam.executes() != []

    assert Enum.any?(RecordingSeam.fetches(), fn
             {^agent_id, "memory_index", ^entry_id, _} -> true
             _ -> false
           end)
  end

  test "LRU eviction is cache-only and never issues durable delete" do
    agent_id = "c3g2_lru_#{System.unique_integer([:positive])}"
    RecordingSeam.configure(:track_only)

    {:ok, pid} =
      Index.start_link(
        agent_id: agent_id,
        backend: :ets,
        max_entries: 1,
        name: {:via, Registry, {Arbor.Memory.Registry, {:index, agent_id}}}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    vector = List.duplicate(0.4, VectorRecord.dimensions())
    assert {:ok, _} = Index.index(pid, "one", %{}, embedding: vector)
    assert {:ok, _} = Index.index(pid, "two", %{}, embedding: vector)

    # ETS-only LRU never calls the durable seam.
    assert RecordingSeam.executes() == []
  end

  test "closed index insert uses memory_index namespace and owner entry id" do
    input =
      StrictEmbeddingInput.index_insert(%{
        agent_id: "a",
        entry_id: "mem_abc",
        content: "c",
        vector: List.duplicate(0.0, 768),
        metadata: %{type: :fact, id: "forged"},
        model_evidence: :absent
      })

    assert input.source_namespace == "memory_index"
    assert input.source_key == "mem_abc"
    assert input.id == "mem_abc"
    assert input.category == "fact"
    assert input.taint == TaintEnvelope.missing_fallback()
    assert input.payload["metadata"]["id"] == "forged"
  end
end
