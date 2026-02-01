defmodule Arbor.AI.Backends.OllamaEmbeddingTest do
  @moduledoc """
  Integration tests for the Ollama embedding provider.

  Requires a running Ollama instance with nomic-embed-text:

      ollama pull nomic-embed-text
      ollama serve
  """
  use ExUnit.Case, async: true

  alias Arbor.AI.Backends.OllamaEmbedding

  @moduletag :external

  describe "embed/2" do
    test "generates embedding for a single text" do
      {:ok, result} = OllamaEmbedding.embed("Hello, world!")

      assert is_list(result.embedding)
      assert result.embedding != []
      assert result.provider == :ollama
      assert is_binary(result.model)
      assert result.dimensions == length(result.embedding)
      assert is_map(result.usage)
    end

    test "generates deterministic embeddings for same input" do
      {:ok, result1} = OllamaEmbedding.embed("test content")
      {:ok, result2} = OllamaEmbedding.embed("test content")

      assert result1.embedding == result2.embedding
    end

    test "generates different embeddings for different input" do
      {:ok, result1} = OllamaEmbedding.embed("cats are fluffy")
      {:ok, result2} = OllamaEmbedding.embed("quantum physics equations")

      refute result1.embedding == result2.embedding
    end

    test "respects model option" do
      {:ok, result} = OllamaEmbedding.embed("test", model: "nomic-embed-text")

      assert is_list(result.embedding)
      assert result.model =~ "nomic"
    end
  end

  describe "embed_batch/2" do
    test "generates embeddings for multiple texts" do
      texts = ["Hello", "World", "Test"]
      {:ok, result} = OllamaEmbedding.embed_batch(texts)

      assert length(result.embeddings) == 3
      assert result.provider == :ollama
      assert is_binary(result.model)
      assert result.dimensions > 0

      Enum.each(result.embeddings, fn embedding ->
        assert is_list(embedding)
        assert length(embedding) == result.dimensions
      end)
    end

    test "batch of one matches single embed" do
      text = "single item batch"
      {:ok, single} = OllamaEmbedding.embed(text)
      {:ok, batch} = OllamaEmbedding.embed_batch([text])

      assert [batch_embedding] = batch.embeddings
      assert single.embedding == batch_embedding
    end
  end
end
