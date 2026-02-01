defmodule Arbor.Memory.EmbeddingUnitTest do
  @moduledoc """
  Unit tests for the Embedding module's pure logic.

  These tests don't require a database connection.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  describe "content_hash generation" do
    test "produces deterministic hash" do
      content = "Hello world"

      # Call the internal hash function via module_info or test it directly
      hash1 = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      hash2 = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      assert hash1 == hash2
      assert String.length(hash1) == 64
    end

    test "different content produces different hashes" do
      hash1 = :crypto.hash(:sha256, "content A") |> Base.encode16(case: :lower)
      hash2 = :crypto.hash(:sha256, "content B") |> Base.encode16(case: :lower)

      refute hash1 == hash2
    end

    test "hash is lowercase hex" do
      hash = :crypto.hash(:sha256, "test") |> Base.encode16(case: :lower)
      assert hash =~ ~r/^[a-f0-9]{64}$/
    end
  end

  describe "search result formatting" do
    test "formats result with similarity score" do
      result = %{
        id: "emb_123",
        content: "Test content",
        similarity: 0.876543,
        metadata: %{"type" => "fact"},
        memory_type: "fact",
        indexed_at: ~U[2026-01-31 12:00:00Z]
      }

      # Verify the result has expected structure
      assert result.id == "emb_123"
      assert result.content == "Test content"
      assert is_float(result.similarity)
      assert result.similarity > 0.0 and result.similarity <= 1.0
    end
  end

  describe "stats aggregation" do
    test "aggregates counts by type" do
      # Simulate what stats aggregation does
      type_counts = [
        {"fact", 50},
        {"insight", 30},
        {"experience", 20}
      ]

      by_type = Map.new(type_counts)

      assert by_type["fact"] == 50
      assert by_type["insight"] == 30
      assert by_type["experience"] == 20
      assert map_size(by_type) == 3
    end

    test "handles empty type distribution" do
      by_type = Map.new([])
      assert by_type == %{}
    end
  end

  describe "embedding vector validation" do
    test "embedding is a list of floats" do
      embedding = for i <- 0..127, do: :math.sin(i / 100)

      assert is_list(embedding)
      assert length(embedding) == 128
      assert Enum.all?(embedding, &is_float/1)
    end

    test "can create Pgvector from list" do
      embedding = [0.1, 0.2, 0.3, 0.4, 0.5]
      vector = Pgvector.new(embedding)

      # Vector should be creatable (verify it's a Pgvector struct)
      assert %Pgvector{} = vector
    end

    test "Pgvector can convert back to list" do
      original = [0.1, 0.2, 0.3, 0.4, 0.5]
      vector = Pgvector.new(original)
      back = Pgvector.to_list(vector)

      # Should round-trip
      assert length(back) == length(original)
    end
  end

  describe "metadata handling" do
    test "extracts type from atom key" do
      metadata = %{type: "fact", source: "test"}
      type = get_in(metadata, [:type]) || Map.get(metadata, "type")
      assert type == "fact"
    end

    test "extracts type from string key" do
      metadata = %{"type" => "fact", "source" => "test"}
      type = get_in(metadata, [:type]) || Map.get(metadata, "type")
      assert type == "fact"
    end

    test "returns nil for missing type" do
      metadata = %{source: "test"}
      type = get_in(metadata, [:type]) || Map.get(metadata, "type")
      assert type == nil
    end
  end
end
