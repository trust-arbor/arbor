defmodule Arbor.Memory.C3G2StrictWiringTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.VectorRecord
  alias Arbor.Contracts.Security.TaintEnvelope

  alias Arbor.Memory.{
    EmbeddingEvidence,
    MemoryStoreIdentity,
    StrictEmbeddingInput,
    StrictVectorSeam
  }

  @moduletag :fast

  describe "MemoryStoreIdentity" do
    test "same key under different namespaces and agents yields distinct row ids" do
      a = MemoryStoreIdentity.row_id("agent_a", "ns1", "key")
      b = MemoryStoreIdentity.row_id("agent_a", "ns2", "key")
      c = MemoryStoreIdentity.row_id("agent_b", "ns1", "key")

      assert String.starts_with?(a, "ms_")
      assert a != b
      assert a != c
      assert b != c
    end

    test "row id is stable for the same triple" do
      assert MemoryStoreIdentity.row_id("a", "n", "k") ==
               MemoryStoreIdentity.row_id("a", "n", "k")
    end
  end

  describe "StrictEmbeddingInput MemoryStore identity" do
    test "source_key remains original key; id is ms_ digest" do
      input =
        StrictEmbeddingInput.memory_store_insert(%{
          agent_id: "agent_1",
          namespace: "goals",
          key: "goal_42",
          content: "do the thing",
          vector: List.duplicate(0.01, VectorRecord.dimensions()),
          type: :goal,
          model_evidence: :absent
        })

      assert input.source_namespace == "goals"
      assert input.source_key == "goal_42"
      assert input.id == MemoryStoreIdentity.row_id("agent_1", "goals", "goal_42")
      assert input.id != "goal_42"
      assert input.taint == TaintEnvelope.missing_fallback()
    end

    test "update and reinsert preserve original identity and exact fences" do
      attrs = %{
        agent_id: "agent_1",
        namespace: "goals",
        key: "goal_42",
        content: "replacement",
        vector: List.duplicate(0.02, VectorRecord.dimensions()),
        type: :goal,
        model_evidence: :absent
      }

      update =
        StrictEmbeddingInput.memory_store_replace(attrs, %{
          "generation" => 3,
          "revision" => 7,
          "tombstone" => false
        })

      reinsert =
        StrictEmbeddingInput.memory_store_replace(attrs, %{
          generation: 3,
          revision: 7,
          tombstone: true
        })

      for input <- [update, reinsert] do
        assert input.id == MemoryStoreIdentity.row_id("agent_1", "goals", "goal_42")
        assert input.agent_id == "agent_1"
        assert input.source_namespace == "goals"
        assert input.source_key == "goal_42"
        assert input.generation == 3
        assert input.revision == 7
        assert input.expected_generation == 3
        assert input.expected_revision == 7
        assert input.tombstone == false
      end

      assert update.kind == :update
      assert reinsert.kind == :reinsert
    end
  end

  describe "EmbeddingEvidence" do
    test "precomputed binds absent / legacy:unspecified" do
      assert {:ok, ev} =
               EmbeddingEvidence.from_precomputed(List.duplicate(0.2, VectorRecord.dimensions()))

      assert ev.model_evidence == :absent
      assert ev.model_id == "legacy:unspecified"
    end

    test "local hash fallback uses memory:local_hash_v1" do
      ev = EmbeddingEvidence.local_hash_fallback("hello")
      assert ev.model_evidence == {:model_id, "memory:local_hash_v1"}
      assert ev.model_id == "memory:local_hash_v1"
      assert length(ev.vector) == VectorRecord.dimensions()
    end

    test "provider result validates model/provider/dimensions" do
      vector = List.duplicate(0.05, VectorRecord.dimensions())

      assert {:ok, ev} =
               EmbeddingEvidence.from_provider_result(%{
                 embedding: vector,
                 model: "embed-v1",
                 provider: :ollama,
                 dimensions: VectorRecord.dimensions()
               })

      assert ev.model_evidence == {:provider_model, "ollama", "embed-v1"}
      assert ev.model_id == "ollama/embed-v1"
    end

    test "provider result rejects missing dimensions" do
      vector = List.duplicate(0.05, VectorRecord.dimensions())

      assert {:error, _} =
               EmbeddingEvidence.from_provider_result(%{
                 embedding: vector,
                 model: "embed-v1",
                 provider: :ollama
               })
    end

    test "provider result rejects invalid UTF-8 model labels" do
      vector = List.duplicate(0.05, VectorRecord.dimensions())
      bad = <<0xFF, 0xFE, "model">>

      assert {:error, :invalid_provider_embedding} =
               EmbeddingEvidence.from_provider_result(%{
                 embedding: vector,
                 model: bad,
                 provider: :ollama,
                 dimensions: VectorRecord.dimensions()
               })
    end

    test "local hash fallback vector is normalized to contract dimensions" do
      ev = EmbeddingEvidence.local_hash_fallback("normalize-me")
      vector = ev.vector
      assert {:ok, ^vector} = VectorRecord.normalize_vector(vector)
      assert length(ev.vector) == VectorRecord.dimensions()
    end
  end

  describe "StrictVectorSeam resolver" do
    test "defaults to Default implementation" do
      previous = Application.get_env(:arbor_memory, :strict_vector_seam)
      Application.delete_env(:arbor_memory, :strict_vector_seam)

      assert StrictVectorSeam.resolve() == Arbor.Memory.StrictVectorSeam.Default

      if previous,
        do: Application.put_env(:arbor_memory, :strict_vector_seam, previous)
    end

    test "Index start opts override app env" do
      assert StrictVectorSeam.resolve(strict_vector_seam: :fake_mod) == :fake_mod
    end
  end

  describe "Index equal-content distinct keys (ets)" do
    test "two indexes of equal content get distinct entry ids and local rows" do
      agent_id = "c3g2_eq_content_#{System.unique_integer([:positive])}"
      vector = List.duplicate(0.11, VectorRecord.dimensions())

      {:ok, pid} =
        Arbor.Memory.Index.start_link(
          agent_id: agent_id,
          backend: :ets,
          name: {:via, Registry, {Arbor.Memory.Registry, {:index, agent_id}}}
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      end)

      assert {:ok, id1} =
               Arbor.Memory.Index.index(pid, "same content", %{type: :fact}, embedding: vector)

      assert {:ok, id2} =
               Arbor.Memory.Index.index(pid, "same content", %{type: :fact}, embedding: vector)

      assert id1 != id2
      assert {:ok, e1} = Arbor.Memory.Index.get(pid, id1)
      assert {:ok, e2} = Arbor.Memory.Index.get(pid, id2)
      assert e1.content == e2.content
      assert e1.id != e2.id
      assert e1.model_id == "legacy:unspecified"
      assert e1.provenance_status == :verified
    end
  end

  describe "Signals redaction" do
    test "emit_recalled is compile-compatible and redacts query content behaviorally" do
      agent_id = "c3g2_signal_#{System.unique_integer([:positive])}"
      secret_query = "super-secret-user-query-content-xyz-#{System.unique_integer([:positive])}"

      assert :ok =
               Arbor.Memory.Signals.emit_recalled(agent_id, secret_query, 3, top_similarity: 0.9)

      # Emission is asynchronous, so poll until this agent's signal is observable.
      signal =
        Enum.reduce_while(1..50, nil, fn _, _acc ->
          case Arbor.Memory.Signals.query_recent(agent_id, types: [:recalled], limit: 10) do
            {:ok, [signal | _]} ->
              {:halt, signal}

            _ ->
              Process.sleep(10)
              {:cont, nil}
          end
        end)

      assert signal != nil, "expected the recalled signal to be observable"
      data = Map.get(signal, :data) || Map.get(signal, "data") || %{}
      refute inspect(data) =~ secret_query

      sensitive_keys =
        ~w(query content vector taint provenance model model_id provider digest)a ++
          ~w(query content vector taint provenance model model_id provider digest)

      Enum.each(sensitive_keys, fn key -> refute Map.has_key?(data, key) end)
      assert data[:result_count] == 3
      assert data[:top_similarity] == 0.9
    end
  end

  describe "ordinary non-authoritative metadata preservation" do
    test "payload keys named model/taint remain body data only" do
      input =
        StrictEmbeddingInput.index_insert(%{
          agent_id: "agent_meta",
          entry_id: "mem_meta_1",
          content: "body",
          vector: List.duplicate(0.01, VectorRecord.dimensions()),
          metadata: %{
            type: :fact,
            id: "caller-body-id",
            model: "attacker/forged",
            taint: "not-authority",
            note: "keep-me"
          },
          model_evidence: :absent
        })

      assert input.model_evidence == :absent
      assert input.taint == TaintEnvelope.missing_fallback()
      assert input.payload["metadata"]["model"] == "attacker/forged"
      assert input.payload["metadata"]["taint"] == "not-authority"
      assert input.payload["metadata"]["note"] == "keep-me"
      assert input.payload["metadata"]["id"] == "caller-body-id"
      assert input.id == "mem_meta_1"
      assert input.source_key == "mem_meta_1"
    end
  end
end
