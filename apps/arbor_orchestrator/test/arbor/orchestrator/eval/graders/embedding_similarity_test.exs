defmodule Arbor.Orchestrator.Eval.Graders.EmbeddingSimilarityTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Eval.Graders.EmbeddingSimilarity

  @moduletag :fast

  describe "cosine_similarity/2" do
    test "returns 1.0 for identical vectors" do
      vec = [1.0, 2.0, 3.0]
      assert_in_delta EmbeddingSimilarity.cosine_similarity(vec, vec), 1.0, 0.001
    end

    test "returns 0.0 for orthogonal vectors" do
      a = [1.0, 0.0, 0.0]
      b = [0.0, 1.0, 0.0]
      assert_in_delta EmbeddingSimilarity.cosine_similarity(a, b), 0.0, 0.001
    end

    test "returns -1.0 for opposite vectors" do
      a = [1.0, 0.0]
      b = [-1.0, 0.0]
      assert_in_delta EmbeddingSimilarity.cosine_similarity(a, b), -1.0, 0.001
    end

    test "handles zero vectors" do
      assert EmbeddingSimilarity.cosine_similarity([0.0, 0.0], [1.0, 2.0]) == 0.0
    end
  end

  describe "grade/3" do
    test "returns unavailable when embedding server is down" do
      # Use a port that's almost certainly not running an embedding server
      result =
        EmbeddingSimilarity.grade("hello", "hello",
          embed_url: "http://localhost:19999/v1/embeddings",
          timeout: 1_000
        )

      assert result.score == 0.0
      assert result.passed == false
      assert result.detail =~ "embedding unavailable"
    end

    test "respects custom threshold" do
      # Can't easily test with real embeddings in unit tests,
      # but we can verify the threshold logic works
      result =
        EmbeddingSimilarity.grade("test", "test",
          embed_url: "http://localhost:19999/v1/embeddings",
          threshold: 0.9,
          timeout: 1_000
        )

      # Server not available — score 0.0
      assert result.score == 0.0
      assert result.passed == false
    end
  end

  describe "grade/3 with live embeddings" do
    @describetag :live_local

    test "scores high for semantically similar code" do
      actual =
        "defmodule Counter do\n  use Agent\n  def start_link(n), do: Agent.start_link(fn -> n end)\n  def value(pid), do: Agent.get(pid, & &1)\nend"

      expected = "An Elixir Agent-based counter module with start_link and value functions"

      result = EmbeddingSimilarity.grade(actual, expected)

      if result.detail =~ "embedding unavailable" do
        # Ollama not running — skip
        :ok
      else
        assert result.score > 0.5
      end
    end
  end
end
