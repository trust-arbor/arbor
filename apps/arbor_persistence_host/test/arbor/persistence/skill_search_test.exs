defmodule Arbor.Persistence.SkillSearchTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Persistence
  alias Arbor.Persistence.SkillSearch

  describe "skill_search_capability/0" do
    test "returns a known capability atom" do
      assert SkillSearch.skill_search_capability() in [:postgres, :ets_only, :unavailable]
      assert Persistence.skill_search_capability() == SkillSearch.skill_search_capability()
    end

    test "non-postgres hybrid_search does not raise and returns empty with meta" do
      # Default umbrella test adapter is SQLite → :ets_only (or :unavailable if Repo down).
      cap = SkillSearch.skill_search_capability()

      if cap == :postgres do
        # When this suite runs under ARBOR_DB=postgres the SQL path is covered elsewhere.
        assert true
      else
        assert {:ok, %{results: [], meta: meta}} =
                 SkillSearch.hybrid_search_with_meta("alpha beta", nil, [])

        assert meta.mode == :unavailable
        assert meta.bm25_arm == :skipped_not_postgres or meta.bm25_arm == :not_attempted
        assert meta.vector_arm == :skipped_not_postgres or meta.vector_arm == :not_attempted
        assert meta.reason in [:sqlite_or_non_postgres, :persistence_unavailable]
        assert SkillSearch.hybrid_search("alpha beta") == []
      end
    end
  end

  describe "compose_hybrid_arms/4 partial-arm isolation" do
    test "vector failure preserves BM25 results and reports arms truthfully" do
      bm25 = {:ok, [%{id: "b1", name: "bm25-hit", description: "x"}], :executed}

      assert {:ok, %{results: results, meta: meta}} =
               SkillSearch.compose_hybrid_arms(bm25, :failed, 5, 0.0)

      assert Enum.map(results, & &1.name) == ["bm25-hit"]
      assert meta.bm25_arm == :executed
      assert meta.vector_arm == :failed
      assert meta.mode == :bm25_only
      assert meta.fusion == :none
      assert meta.query_embedding == :ok
      assert meta.reason == nil
      refute meta.reason == :search_error
    end

    test "BM25 failure preserves vector results and reports arms truthfully" do
      vector = {:ok, [%{id: "v1", name: "vector-hit", description: "y"}], :executed}

      assert {:ok, %{results: results, meta: meta}} =
               SkillSearch.compose_hybrid_arms(:failed, vector, 5, 0.0)

      assert Enum.map(results, & &1.name) == ["vector-hit"]
      assert meta.bm25_arm == :failed
      assert meta.vector_arm == :executed
      assert meta.mode == :hybrid
      assert meta.fusion == :none
      assert meta.query_embedding == :ok
      refute meta.reason == :search_error
    end

    test "both arms failed yields unavailable search_error with empty results" do
      assert {:ok, %{results: [], meta: meta}} =
               SkillSearch.compose_hybrid_arms(:failed, :failed, 5, 0.0)

      assert meta.bm25_arm == :failed
      assert meta.vector_arm == :failed
      assert meta.mode == :unavailable
      assert meta.reason == :search_error
    end

    test "both arms ok uses RRF fusion" do
      bm25 =
        {:ok,
         [
           %{id: "shared", name: "overlap", description: "both"},
           %{id: "lex", name: "lexical-only", description: "lex"}
         ], :executed}

      vector =
        {:ok,
         [
           %{id: "shared", name: "overlap", description: "both"},
           %{id: "sem", name: "semantic-only", description: "sem"}
         ], :executed}

      assert {:ok, %{results: results, meta: meta}} =
               SkillSearch.compose_hybrid_arms(bm25, vector, 10, 0.0)

      assert meta.mode == :hybrid
      assert meta.fusion == :rrf
      assert meta.bm25_arm == :executed
      assert meta.vector_arm == :executed
      assert hd(results).name == "overlap"
    end
  end

  describe "pair_embedding_write/2 atomic pair" do
    test "writes only when embedding and valid space are both present" do
      space = %{"provider" => "test", "model" => "m", "dimensions" => 3}

      assert {:write, [0.1, 0.2, 0.3], written_space} =
               SkillSearch.pair_embedding_write([0.1, 0.2, 0.3], space)

      assert written_space == space
    end

    test "omits embedding without space" do
      assert :omit = SkillSearch.pair_embedding_write([0.1, 0.2, 0.3], nil)
    end

    test "omits embedding with invalid space" do
      assert :omit =
               SkillSearch.pair_embedding_write(
                 [0.1, 0.2, 0.3],
                 %{"provider" => "x", "model" => "y"}
               )
    end

    test "omits space without embedding" do
      space = %{"provider" => "test", "model" => "m", "dimensions" => 3}
      assert :omit = SkillSearch.pair_embedding_write(nil, space)
    end

    test "omits non-numeric embedding even with valid space" do
      space = %{"provider" => "test", "model" => "m", "dimensions" => 2}
      assert :omit = SkillSearch.pair_embedding_write(["a", "b"], space)
    end

    test "omits when vector length does not match space dimensions" do
      space = %{"provider" => "test", "model" => "m", "dimensions" => 3}
      assert :omit = SkillSearch.pair_embedding_write([0.1, 0.2], space)
      assert :omit = SkillSearch.pair_embedding_write([0.1, 0.2, 0.3, 0.4], space)
    end

    test "omits nonpositive dimensions" do
      assert :omit =
               SkillSearch.pair_embedding_write(
                 [0.1],
                 %{"provider" => "test", "model" => "m", "dimensions" => 0}
               )

      assert :omit =
               SkillSearch.pair_embedding_write(
                 [0.1],
                 %{"provider" => "test", "model" => "m", "dimensions" => -1}
               )
    end

    test "omits blank provider or model" do
      assert :omit =
               SkillSearch.pair_embedding_write(
                 [0.1, 0.2, 0.3],
                 %{"provider" => "  ", "model" => "m", "dimensions" => 3}
               )

      assert :omit =
               SkillSearch.pair_embedding_write(
                 [0.1, 0.2, 0.3],
                 %{"provider" => "test", "model" => "", "dimensions" => 3}
               )

      assert :omit =
               SkillSearch.pair_embedding_write(
                 [0.1, 0.2, 0.3],
                 %{"provider" => nil, "model" => "m", "dimensions" => 3}
               )
    end

    test "malformed query pair degrades compose path to BM25-only via omit" do
      # pair_embedding_write is the public query admission gate used by hybrid search.
      assert :omit =
               SkillSearch.pair_embedding_write(
                 [0.1, 0.2],
                 %{"provider" => "test", "model" => "m", "dimensions" => 3}
               )

      bm25 = {:ok, [%{id: "b1", name: "bm25-hit", description: "x"}], :executed}

      assert {:ok, %{results: results, meta: meta}} =
               SkillSearch.compose_hybrid_arms(bm25, :skipped, 5, 0.0)

      assert Enum.map(results, & &1.name) == ["bm25-hit"]
      assert meta.mode == :bm25_only
      assert meta.vector_arm == :skipped_no_query_embedding
    end
  end
end
