defmodule Arbor.Memory.EmbeddingTest do
  @moduledoc """
  Integration tests for the Embedding module.

  These tests require a PostgreSQL database with the pgvector extension installed.
  Run with: mix test --include database
  """

  use Arbor.Persistence.DatabaseCase

  @moduletag :database

  alias Arbor.Contracts.Persistence.{VectorOperation, VectorRecord}
  alias Arbor.Memory.Embedding
  alias Arbor.Persistence.Repo

  @test_agent_id "test_agent_embedding"
  @dimension 768

  setup do
    # Repo is started + a Sandbox connection is checked out by DatabaseCase.
    # Clean up any existing test data
    Embedding.delete_all(@test_agent_id)

    on_exit(fn ->
      Embedding.delete_all(@test_agent_id)
    end)

    :ok
  end

  defp generate_embedding(seed) do
    for i <- 0..(@dimension - 1) do
      :math.sin((seed + i) / 100) * 0.5 + 0.5
    end
  end

  describe "store/4" do
    test "creates embedding record in Postgres" do
      embedding = generate_embedding(1)
      metadata = %{type: "fact", source: "test"}

      assert {:ok, id} = Embedding.store(@test_agent_id, "Test content", embedding, metadata)
      assert String.starts_with?(id, "emb_")

      # Verify it's in the database
      assert Embedding.count(@test_agent_id) == 1
    end

    test "deduplicates by content_hash (upsert)" do
      embedding1 = generate_embedding(1)
      embedding2 = generate_embedding(2)
      content = "Same content"

      {:ok, _id1} = Embedding.store(@test_agent_id, content, embedding1, %{type: "fact"})
      {:ok, _id2} = Embedding.store(@test_agent_id, content, embedding2, %{type: "fact"})

      # Should only have one record (upserted)
      assert Embedding.count(@test_agent_id) == 1
    end

    test "stores metadata correctly" do
      embedding = generate_embedding(1)
      metadata = %{type: "insight", source: "reflection", custom: "value"}

      {:ok, id} = Embedding.store(@test_agent_id, "Content", embedding, metadata)
      {:ok, record} = Embedding.get(@test_agent_id, id)

      assert record.memory_type == "insight"
      assert record.source == "reflection"
      assert record.metadata["custom"] == "value"
    end
  end

  describe "search/3" do
    setup do
      # Create test embeddings
      embeddings = [
        {"The sky is blue", generate_embedding(1), %{type: "fact"}},
        {"Water is wet", generate_embedding(2), %{type: "fact"}},
        {"Elixir is awesome", generate_embedding(3), %{type: "insight"}},
        {"GenServer patterns", generate_embedding(4), %{type: "skill"}}
      ]

      for {content, emb, meta} <- embeddings do
        Embedding.store(@test_agent_id, content, emb, meta)
      end

      :ok
    end

    test "returns results sorted by similarity" do
      query_embedding = generate_embedding(1)

      {:ok, results} = Embedding.search(@test_agent_id, query_embedding, threshold: 0.0)

      assert results != []
      # First result should be most similar (to itself or similar)
      assert hd(results).content == "The sky is blue"
    end

    test "filters by type" do
      query_embedding = generate_embedding(1)

      {:ok, results} =
        Embedding.search(@test_agent_id, query_embedding,
          threshold: 0.0,
          type_filter: "fact"
        )

      assert length(results) == 2
      assert Enum.all?(results, &(&1.memory_type == "fact"))
    end

    test "respects threshold" do
      query_embedding = generate_embedding(100)

      {:ok, high_threshold} =
        Embedding.search(@test_agent_id, query_embedding, threshold: 0.99)

      {:ok, low_threshold} =
        Embedding.search(@test_agent_id, query_embedding, threshold: 0.0)

      # High threshold should return fewer or equal results
      assert length(high_threshold) <= length(low_threshold)
    end

    test "respects limit" do
      query_embedding = generate_embedding(1)

      {:ok, results} = Embedding.search(@test_agent_id, query_embedding, threshold: 0.0, limit: 2)

      assert length(results) <= 2
    end

    test "returns empty list for no matches" do
      # Search with a very different embedding and high threshold
      query_embedding = List.duplicate(0.0, @dimension)

      {:ok, results} = Embedding.search(@test_agent_id, query_embedding, threshold: 0.999)

      assert results == []
    end
  end

  describe "delete/2" do
    test "removes embedding" do
      embedding = generate_embedding(1)
      {:ok, id} = Embedding.store(@test_agent_id, "To delete", embedding)

      assert Embedding.count(@test_agent_id) == 1
      assert :ok = Embedding.delete(@test_agent_id, id)
      assert Embedding.count(@test_agent_id) == 0
    end

    test "returns error for non-existent embedding" do
      assert {:error, :not_found} = Embedding.delete(@test_agent_id, "emb_nonexistent")
    end
  end

  describe "count/1" do
    test "returns correct count" do
      assert Embedding.count(@test_agent_id) == 0

      for i <- 1..5 do
        Embedding.store(@test_agent_id, "Content #{i}", generate_embedding(i))
      end

      assert Embedding.count(@test_agent_id) == 5
    end
  end

  describe "stats/1" do
    test "returns type distribution" do
      Embedding.store(@test_agent_id, "Fact 1", generate_embedding(1), %{type: "fact"})
      Embedding.store(@test_agent_id, "Fact 2", generate_embedding(2), %{type: "fact"})
      Embedding.store(@test_agent_id, "Insight 1", generate_embedding(3), %{type: "insight"})

      stats = Embedding.stats(@test_agent_id)

      assert stats.total == 3
      assert stats.by_type["fact"] == 2
      assert stats.by_type["insight"] == 1
    end

    test "returns time bounds" do
      Embedding.store(@test_agent_id, "Content", generate_embedding(1))

      stats = Embedding.stats(@test_agent_id)

      assert stats.oldest != nil
      assert stats.newest != nil
      assert DateTime.compare(stats.oldest, stats.newest) in [:lt, :eq]
    end

    test "handles empty store" do
      stats = Embedding.stats(@test_agent_id)

      assert stats.total == 0
      assert stats.by_type == %{}
      assert stats.oldest == nil
      assert stats.newest == nil
    end
  end

  describe "store_batch/2" do
    test "inserts multiple entries" do
      entries = [
        {"Batch 1", generate_embedding(1), %{type: "fact"}},
        {"Batch 2", generate_embedding(2), %{type: "fact"}},
        {"Batch 3", generate_embedding(3), %{type: "insight"}}
      ]

      assert {:ok, 3} = Embedding.store_batch(@test_agent_id, entries)
      assert Embedding.count(@test_agent_id) == 3
    end

    test "handles empty list" do
      assert {:ok, 0} = Embedding.store_batch(@test_agent_id, [])
      assert Embedding.count(@test_agent_id) == 0
    end

    test "upserts on content conflict" do
      entries1 = [
        {"Content A", generate_embedding(1), %{type: "fact"}},
        {"Content B", generate_embedding(2), %{type: "fact"}}
      ]

      entries2 = [
        {"Content A", generate_embedding(3), %{type: "updated"}},
        {"Content C", generate_embedding(4), %{type: "new"}}
      ]

      {:ok, 2} = Embedding.store_batch(@test_agent_id, entries1)
      {:ok, 2} = Embedding.store_batch(@test_agent_id, entries2)

      # Should have 3 total (A updated, B unchanged, C new)
      assert Embedding.count(@test_agent_id) == 3
    end
  end

  describe "get/2" do
    test "retrieves existing embedding" do
      embedding = generate_embedding(1)
      {:ok, id} = Embedding.store(@test_agent_id, "Test", embedding, %{type: "fact"})

      {:ok, record} = Embedding.get(@test_agent_id, id)

      assert record.id == id
      assert record.content == "Test"
      assert record.memory_type == "fact"
    end

    test "returns error for non-existent" do
      assert {:error, :not_found} = Embedding.get(@test_agent_id, "emb_nonexistent")
    end
  end

  describe "delete_all/1" do
    test "removes all embeddings for agent" do
      for i <- 1..5 do
        Embedding.store(@test_agent_id, "Content #{i}", generate_embedding(i))
      end

      assert Embedding.count(@test_agent_id) == 5
      {:ok, deleted} = Embedding.delete_all(@test_agent_id)
      assert deleted == 5
      assert Embedding.count(@test_agent_id) == 0
    end
  end

  describe "vector-store V1 isolation security regression" do
    test "legacy reads and deletes cannot observe or remove a V1 tombstone" do
      source_key = "isolated_#{System.unique_integer([:positive])}"
      forged_agent = "forged_agent_#{System.unique_integer([:positive])}"

      payload = %{
        "content" => "V1 authority",
        "metadata" => %{
          "agent_id" => forged_agent,
          "source_namespace" => "legacy",
          "source_key" => "forged",
          "vector_protocol" => "legacy"
        },
        "caller_metadata" => %{"provenance" => "trusted"}
      }

      insert = vector_insert_operation!(@test_agent_id, source_key, payload)
      assert {:ok, inserted} = Arbor.Persistence.execute_vector_operation(@test_agent_id, insert)

      assert %{rows: [["arbor_vector_store_v1"]]} =
               Repo.query!("SELECT vector_protocol FROM memory_embeddings WHERE id = $1", [
                 inserted.record.id
               ])

      assert inserted.record.agent_id == @test_agent_id
      assert inserted.record.source_namespace == "voice"

      assert {:error, :not_found} =
               Arbor.Persistence.fetch_vector_record(forged_agent, "legacy", "forged")

      assert {:ok, []} =
               Embedding.search(@test_agent_id, inserted.record.vector, threshold: 0.0)

      delete = vector_delete_operation!(inserted.record)
      assert {:ok, deleted} = Arbor.Persistence.execute_vector_operation(@test_agent_id, delete)

      assert {:ok, []} =
               Embedding.search(@test_agent_id, inserted.record.vector, threshold: 0.0)

      assert Embedding.count(@test_agent_id) == 0
      assert Embedding.stats(@test_agent_id).total == 0
      assert {:error, :not_found} = Embedding.get(@test_agent_id, inserted.record.id)

      assert {:error, :protected_vector_row} =
               Embedding.delete(@test_agent_id, inserted.record.id)

      assert {:ok, 0} = Embedding.delete_all(@test_agent_id)

      assert {:error, :protected_vector_row} =
               Embedding.store(
                 @test_agent_id,
                 "legacy overwrite",
                 generate_embedding(20),
                 %{id: inserted.record.id}
               )

      deleted_record = deleted.record

      assert {:ok, ^deleted_record} =
               Arbor.Persistence.fetch_vector_record(@test_agent_id, "voice", source_key,
                 include_tombstone: true
               )

      assert {:ok, ^inserted} =
               Arbor.Persistence.reconcile_vector_operation(@test_agent_id, insert)
    end

    test "legacy single and batch upserts cannot update a V1-owned conflict" do
      source_key = "conflict_#{System.unique_integer([:positive])}"
      insert = vector_insert_operation!(@test_agent_id, source_key, %{"content" => "owned"})
      assert {:ok, inserted} = Arbor.Persistence.execute_vector_operation(@test_agent_id, insert)

      legacy_content = "forced collision #{System.unique_integer([:positive])}"
      collision_hash = :crypto.hash(:sha256, legacy_content) |> Base.encode16(case: :lower)

      Repo.query!("UPDATE memory_embeddings SET content_hash = $1 WHERE id = $2", [
        collision_hash,
        inserted.record.id
      ])

      assert {:error, :protected_vector_row} =
               Embedding.store(@test_agent_id, legacy_content, generate_embedding(21), %{
                 type: "single-overwrite"
               })

      assert {:error, :protected_vector_row} =
               Embedding.store_batch(@test_agent_id, [
                 {legacy_content, generate_embedding(22), %{type: "batch-overwrite"}}
               ])

      assert %{rows: [[nil, %{}]]} =
               Repo.query!("SELECT memory_type, metadata FROM memory_embeddings WHERE id = $1", [
                 inserted.record.id
               ])
    end
  end

  defp vector_insert_operation!(agent_id, source_key, payload) do
    vector = generate_embedding(99)
    {:ok, payload_digest} = VectorRecord.payload_digest(payload)
    {:ok, vector_digest} = VectorRecord.vector_digest(vector)

    {:ok, record} =
      VectorRecord.new(%{
        id: "vec_#{System.unique_integer([:positive])}",
        agent_id: agent_id,
        source_namespace: "voice",
        source_key: source_key,
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
      })

    {:ok, operation} =
      VectorOperation.new(%{
        kind: :insert,
        record: record,
        expected_generation: nil,
        expected_revision: nil
      })

    operation
  end

  defp vector_delete_operation!(record) do
    {:ok, operation} =
      VectorOperation.new(%{
        kind: :delete,
        record: record,
        expected_generation: record.generation,
        expected_revision: record.revision
      })

    operation
  end
end
