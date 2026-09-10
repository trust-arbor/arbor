defmodule Arbor.Memory.HybridKeywordScoringTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.KnowledgeGraph.GraphSearch

  @moduletag :fast

  test "whole-token membership excludes longer names and incidental substrings" do
    for content <- ["Anna", "channel", "cannot", "annex"] do
      assert keyword("Ann", content) == 0.0
    end

    assert keyword("ANN!", "Ann") == 1.0
  end

  test "coverage counts distinct query tokens so repetition cannot change their weight" do
    assert keyword("read write", "read") == 0.5
    assert keyword("read read write", "read read") == 0.5
    assert keyword("read READ read", "Read") == 1.0
  end

  test "punctuation, hyphens, underscores and apostrophes separate tokens" do
    assert keyword("SQL-safe, cache_key's", "sql safe cache key s") == 1.0
    assert keyword("SQL-safe", "SQL safety") == 0.5
    assert keyword("-- ... !", "punctuation") == 0.0
    assert keyword("", "content") == 0.0
  end

  test "Unicode normalization preserves whole-token identity without stemming or segmentation" do
    assert keyword("CAFE\u0301", "café") == 1.0
    assert keyword("ÁRBOL", "árbol") == 1.0
    assert keyword("árbol", "arboleda") == 0.0
    assert keyword("東京", "東京") == 1.0
    assert keyword("東", "東京") == 0.0
  end

  test "keyword correction leaves cosine and the configured weight calculation intact" do
    scores = GraphSearch.hybrid_scores("Ann", [1.0, 0.0], %{content: "Anna"}, [0.0, 1.0], 0.7)
    assert scores == %{semantic: 0.0, keyword: 0.0, combined: 0.0}

    scores = GraphSearch.hybrid_scores("Ann", [1.0, 0.0], %{content: "Anna"}, [1.0, 0.0], 0.7)
    assert scores == %{semantic: 1.0, keyword: 0.0, combined: 0.7}
  end

  defp keyword(query, content) do
    GraphSearch.hybrid_scores(query, [1.0], %{content: content}, [1.0], 0.7).keyword
  end
end
