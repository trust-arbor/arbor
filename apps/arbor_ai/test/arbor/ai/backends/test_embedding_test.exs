defmodule Arbor.AI.Backends.TestEmbeddingTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.Backends.TestEmbedding

  @moduletag :fast

  describe "embed/2" do
    test "returns a result with correct structure" do
      {:ok, result} = TestEmbedding.embed("Hello world")

      assert is_list(result.embedding)
      assert result.provider == :test
      assert is_binary(result.model)
      assert result.dimensions == length(result.embedding)
      assert is_map(result.usage)
    end

    test "defaults to 768 dimensions" do
      {:ok, result} = TestEmbedding.embed("test")

      assert result.dimensions == 768
      assert length(result.embedding) == 768
    end

    test "respects custom dimensions" do
      {:ok, result} = TestEmbedding.embed("test", dimensions: 384)

      assert result.dimensions == 384
      assert length(result.embedding) == 384
    end

    test "is deterministic for same input" do
      {:ok, r1} = TestEmbedding.embed("same text")
      {:ok, r2} = TestEmbedding.embed("same text")

      assert r1.embedding == r2.embedding
    end

    test "produces different vectors for different input" do
      {:ok, r1} = TestEmbedding.embed("text one")
      {:ok, r2} = TestEmbedding.embed("text two")

      refute r1.embedding == r2.embedding
    end

    test "all values are floats between 0 and 1" do
      {:ok, result} = TestEmbedding.embed("check bounds")

      Enum.each(result.embedding, fn val ->
        assert is_float(val)
        assert val >= 0.0 and val <= 1.0
      end)
    end
  end

  describe "embed_batch/2" do
    test "returns correct number of embeddings" do
      texts = ["one", "two", "three"]
      {:ok, result} = TestEmbedding.embed_batch(texts)

      assert length(result.embeddings) == 3
      assert result.provider == :test
      assert result.dimensions == 768
    end

    test "batch is consistent with individual embeds" do
      texts = ["alpha", "beta"]
      {:ok, batch} = TestEmbedding.embed_batch(texts)
      {:ok, single_a} = TestEmbedding.embed("alpha")
      {:ok, single_b} = TestEmbedding.embed("beta")

      assert Enum.at(batch.embeddings, 0) == single_a.embedding
      assert Enum.at(batch.embeddings, 1) == single_b.embedding
    end

    test "respects custom dimensions" do
      {:ok, result} = TestEmbedding.embed_batch(["x", "y"], dimensions: 128)

      assert result.dimensions == 128
      Enum.each(result.embeddings, fn emb -> assert length(emb) == 128 end)
    end
  end

  describe "hash_embedding/2" do
    test "returns a list of floats" do
      embedding = TestEmbedding.hash_embedding("test")

      assert is_list(embedding)
      assert length(embedding) == 768
      Enum.each(embedding, &assert(is_float(&1)))
    end

    test "custom dimension" do
      embedding = TestEmbedding.hash_embedding("test", 64)

      assert length(embedding) == 64
    end
  end
end
