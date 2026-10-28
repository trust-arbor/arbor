defmodule Arbor.Persistence.SkillSearchPostgresTest do
  use Arbor.Persistence.DatabaseCase, async: false

  @moduletag :database
  @moduletag :integration
  @moduletag :postgres

  alias Arbor.Persistence
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.SkillRecord
  alias Arbor.Persistence.SkillSearch

  if Repo.__adapter__() != Ecto.Adapters.Postgres do
    @moduletag skip: "PostgreSQL skill hybrid coverage requires ARBOR_DB=postgres"
  end

  @space %{
    "provider" => "test",
    "model" => "fixture-model",
    "dimensions" => 768
  }

  setup do
    # Clean skills table between tests (sandbox-isolated).
    Repo.delete_all(SkillRecord)
    :ok
  end

  defp unit_vector(hot_index) do
    for i <- 0..767 do
      if i == hot_index, do: 1.0, else: 0.0
    end
  end

  # Exact match for the query embedding (vector rank 1 when present).
  defp query_vector, do: unit_vector(10)
  defp overlap_vector, do: unit_vector(10)

  # Distinct non-tied distance: aligned with query dim but not identical.
  # Guarantees semantic-only is in the vector arm after overlap, never tied.
  defp semantic_vector do
    for i <- 0..767 do
      cond do
        i == 10 -> 0.85
        i == 20 -> 0.15
        true -> 0.0
      end
    end
  end

  defp upsert_skill!(attrs) do
    assert {:ok, _} = SkillSearch.upsert(attrs)
  end

  test "stores a non-nil 768-dimensional embedding with embedding_space" do
    vec = overlap_vector()

    upsert_skill!(%{
      name: "stored-embed",
      description: "stores a vector",
      body: "body",
      content_hash: hash("body"),
      embedding: vec,
      embedding_space: @space
    })

    record = SkillSearch.get_by_name("stored-embed")
    assert record
    assert record.embedding
    stored = Pgvector.to_list(record.embedding)
    assert length(stored) == 768
    assert get_in(record.metadata, ["embedding_space", "model"]) == "fixture-model"

    map = Persistence.get_skill_record("stored-embed")
    assert is_list(map.embedding)
    assert map.embedding_space["dimensions"] == 768
  end

  test "backfills nil embedding row and preserves vector on omit" do
    upsert_skill!(%{
      name: "backfill-me",
      description: "no vector yet",
      body: "body",
      content_hash: hash("body")
    })

    record = SkillSearch.get_by_name("backfill-me")
    assert is_nil(record.embedding)

    upsert_skill!(%{
      name: "backfill-me",
      description: "no vector yet",
      body: "body",
      content_hash: hash("body"),
      embedding: overlap_vector(),
      embedding_space: @space
    })

    record = SkillSearch.get_by_name("backfill-me")
    assert record.embedding
    before = Pgvector.to_list(record.embedding)

    # Outage path: omit embedding and space keys entirely.
    upsert_skill!(%{
      name: "backfill-me",
      description: "updated description only",
      body: "body",
      content_hash: hash("body")
    })

    preserved = SkillSearch.get_by_name("backfill-me")
    assert Pgvector.to_list(preserved.embedding) == before
    assert get_in(preserved.metadata, ["embedding_space", "provider"]) == "test"
    assert preserved.description == "updated description only"
  end

  test "lexical-only, semantic-only, and overlap: overlap ranks first via dual RRF" do
    # Query terms: "alpha beta"
    # Lexical-only: strong BM25, absent from vector arm (nil embedding — no vector credit).
    upsert_skill!(%{
      name: "skill-lexical-only",
      description: "alpha beta lexical specialist for ranking",
      body: "alpha beta alpha beta",
      content_hash: hash("lex")
    })

    # Semantic-only: no query tokens in indexed text; in vector arm at non-tied distance.
    upsert_skill!(%{
      name: "skill-semantic-only",
      description: "quantum continuum navigator toolkit",
      body: "orthogonal vocabulary without the markers",
      content_hash: hash("sem"),
      embedding: semantic_vector(),
      embedding_space: @space
    })

    # Overlap: BM25 hit + exact query vector (vector rank 1) → dual RRF credit.
    upsert_skill!(%{
      name: "skill-overlap",
      description: "alpha beta hybrid champion",
      body: "alpha beta overlap body",
      content_hash: hash("over"),
      embedding: overlap_vector(),
      embedding_space: @space
    })

    # Prove BM25 arm membership: lexical + overlap; semantic absent (no query tokens).
    assert {:ok, %{results: bm25_only}} =
             SkillSearch.hybrid_search_with_meta("alpha beta", nil, limit: 10)

    bm25_names = Enum.map(bm25_only, & &1.name)
    assert "skill-lexical-only" in bm25_names
    assert "skill-overlap" in bm25_names
    refute "skill-semantic-only" in bm25_names

    # Hybrid: both arms executed; overlap rank 1 via dual credit; all three present.
    assert {:ok, %{results: results, meta: meta}} =
             SkillSearch.hybrid_search_with_meta(
               "alpha beta",
               query_vector(),
               embedding_space: @space,
               limit: 10
             )

    assert meta.mode == :hybrid
    assert meta.bm25_arm == :executed
    assert meta.vector_arm == :executed
    assert meta.fusion == :rrf
    assert meta.capability == :postgres

    names = Enum.map(results, & &1.name)
    assert hd(names) == "skill-overlap"
    assert "skill-lexical-only" in names
    assert "skill-semantic-only" in names

    # Semantic appears only when the vector arm runs (membership proof).
    refute "skill-semantic-only" in bm25_names
    assert "skill-semantic-only" in names
  end

  test "mismatched embedding_space is excluded from vector arm" do
    upsert_skill!(%{
      name: "wrong-space",
      description: "alpha beta wrong space",
      body: "alpha beta",
      content_hash: hash("ws"),
      embedding: overlap_vector(),
      embedding_space: %{
        "provider" => "other",
        "model" => "other-model",
        "dimensions" => 768
      }
    })

    assert {:ok, %{results: results, meta: meta}} =
             SkillSearch.hybrid_search_with_meta(
               "zzzz-no-lexical",
               query_vector(),
               embedding_space: @space,
               limit: 5
             )

    # No BM25 hit and vector arm filters wrong space → empty hybrid.
    assert results == []
    assert meta.mode == :hybrid
    assert meta.vector_arm == :empty
  end

  test "malformed query vector degrades through the public facade to BM25-only" do
    upsert_skill!(%{
      name: "malformed-query-lexical",
      description: "malformed vector lexical sentinel",
      body: "lexical fallback remains available",
      content_hash: hash("malformed-query")
    })

    assert {:ok, %{results: results, meta: meta}} =
             Persistence.hybrid_search_skills_with_meta(
               "malformed vector lexical sentinel",
               [0.1, 0.2],
               embedding_space: @space,
               limit: 5
             )

    assert Enum.any?(results, &(&1.name == "malformed-query-lexical"))
    assert meta.mode == :bm25_only
    assert meta.bm25_arm == :executed
    assert meta.vector_arm == :skipped_no_query_embedding
    assert meta.fusion == :none
  end

  defp hash(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
end
