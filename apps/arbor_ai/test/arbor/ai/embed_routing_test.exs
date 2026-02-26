defmodule Arbor.AI.EmbedRoutingTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  describe "embed/2 routing" do
    test "embed with :test provider falls back to legacy TestEmbedding" do
      # The :test provider is not in the UnifiedBridge provider map,
      # so it should fall through to legacy backends
      Application.put_env(:arbor_ai, :embedding_test_fallback, true)

      on_exit(fn ->
        Application.put_env(:arbor_ai, :embedding_test_fallback, false)
      end)

      {:ok, result} = Arbor.AI.embed("test text", provider: :test)

      assert is_list(result.embedding)
      assert result.provider == :test
      assert result.dimensions == 768
      assert is_map(result.usage)
    end

    test "embed_batch with :test provider falls back to legacy TestEmbedding" do
      Application.put_env(:arbor_ai, :embedding_test_fallback, true)

      on_exit(fn ->
        Application.put_env(:arbor_ai, :embedding_test_fallback, false)
      end)

      {:ok, result} = Arbor.AI.embed_batch(["hello", "world"], provider: :test)

      assert length(result.embeddings) == 2
      assert result.provider == :test
      assert result.dimensions == 768
    end

    test "embed returns error when no providers available" do
      # Ensure no fallback is configured
      Application.put_env(:arbor_ai, :embedding_test_fallback, false)

      on_exit(fn ->
        Application.delete_env(:arbor_ai, :embedding_test_fallback)
      end)

      # Use an unknown provider that won't be in the unified bridge
      result = Arbor.AI.embed("test", provider: :nonexistent_provider)

      assert {:error, _} = result
    end

    test "snapshot_embedding_config sets default model for known providers" do
      Application.put_env(:arbor_ai, :embedding_test_fallback, true)

      on_exit(fn ->
        Application.put_env(:arbor_ai, :embedding_test_fallback, false)
      end)

      # When provider is :test, model should default to test-hash-768d
      {:ok, result} = Arbor.AI.embed("test", provider: :test)
      assert result.model =~ "test-hash"
    end
  end
end
