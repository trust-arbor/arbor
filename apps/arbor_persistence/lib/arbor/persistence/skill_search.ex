defmodule Arbor.Persistence.SkillSearch do
  @moduledoc """
  Hybrid search engine for skills combining BM25 full-text and pgvector semantic search.

  Uses Reciprocal Rank Fusion (RRF) to merge rankings from both search methods
  into a single relevance-ordered result set. Falls back to BM25-only when no
  embedding is available for the query.

  ## Search Strategy

  1. **BM25** — PostgreSQL `ts_rank` on the generated `searchable` tsvector column,
     weighted across name (A), description (B), tags (C), and body (D).
  2. **pgvector** — Cosine distance on the 768-dimensional `embedding` column.
  3. **RRF merge** — `score(d) = sum(1 / (k + rank_i(d)))` with `k = 60`.

  ## Usage

      # BM25-only search
      SkillSearch.hybrid_search("code quality")

      # Hybrid with embedding
      SkillSearch.hybrid_search("code quality", embedding_vector, limit: 5)

      # Sync skills from ETS to Postgres
      SkillSearch.upsert_batch(skills)
  """

  import Ecto.Query

  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.SkillRecord

  require Logger

  # Reciprocal Rank Fusion constant — standard value from literature
  @rrf_k 60

  @doc """
  Search skills using hybrid BM25 + pgvector with Reciprocal Rank Fusion.

  When `query_embedding` is nil, falls back to BM25-only full-text search.

  ## Options

  - `:limit` — max results (default: 10)
  - `:category` — filter by category
  - `:taint_filter` — filter by taint level (e.g., "trusted")
  - `:min_score` — minimum RRF score threshold (default: 0.0)
  """
  @spec hybrid_search(String.t(), Pgvector.Ecto.Vector.t() | nil, keyword()) :: [map()]
  def hybrid_search(query_text, query_embedding \\ nil, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    category = Keyword.get(opts, :category)
    taint_filter = Keyword.get(opts, :taint_filter)
    min_score = Keyword.get(opts, :min_score, 0.0)

    bm25_results = bm25_search(query_text, category, taint_filter, limit * 2)

    if query_embedding do
      vector_results = vector_search(query_embedding, category, taint_filter, limit * 2)
      rrf_merge(bm25_results, vector_results, limit, min_score)
    else
      bm25_results
      |> Enum.take(limit)
      |> Enum.map(&skill_record_to_map/1)
    end
  rescue
    e ->
      Logger.warning("[SkillSearch] hybrid_search failed: #{inspect(e)}")
      []
  end

  @doc """
  Insert or update a skill record by name.
  """
  @spec upsert(map()) :: {:ok, SkillRecord.t()} | {:error, Ecto.Changeset.t()}
  def upsert(attrs) when is_map(attrs) do
    id = attrs[:id] || generate_id()
    attrs = Map.put(attrs, :id, id)

    case Repo.get_by(SkillRecord, name: attrs[:name]) do
      nil ->
        %SkillRecord{}
        |> SkillRecord.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> SkillRecord.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Batch upsert skills from a list of skill structs or maps.

  Returns `{:ok, count}` with the number of skills synced.
  """
  @spec upsert_batch([map() | struct()]) :: {:ok, non_neg_integer()}
  def upsert_batch(skills) when is_list(skills) do
    count =
      skills
      |> Enum.reduce(0, fn skill, acc ->
        attrs = skill_to_attrs(skill)

        case upsert(attrs) do
          {:ok, _} -> acc + 1
          {:error, _} -> acc
        end
      end)

    {:ok, count}
  end

  @doc """
  Get a skill record by name.
  """
  @spec get_by_name(String.t()) :: SkillRecord.t() | nil
  def get_by_name(name) when is_binary(name) do
    Repo.get_by(SkillRecord, name: name)
  end

  @doc """
  Delete a skill record by name.
  """
  @spec delete(String.t()) :: {:ok, SkillRecord.t()} | {:error, :not_found}
  def delete(name) when is_binary(name) do
    case get_by_name(name) do
      nil -> {:error, :not_found}
      record -> Repo.delete(record)
    end
  end

  # -- BM25 full-text search --

  defp bm25_search(query_text, category, taint_filter, limit) do
    base_query =
      from(s in SkillRecord,
        where:
          fragment(
            "? @@ plainto_tsquery('english', ?)",
            s.searchable,
            ^query_text
          ),
        order_by: [
          desc:
            fragment(
              "ts_rank(?, plainto_tsquery('english', ?))",
              s.searchable,
              ^query_text
            )
        ],
        limit: ^limit
      )

    base_query
    |> maybe_filter_category(category)
    |> maybe_filter_taint(taint_filter)
    |> Repo.all()
  end

  # -- pgvector semantic search --

  defp vector_search(query_embedding, category, taint_filter, limit) do
    base_query =
      from(s in SkillRecord,
        where: not is_nil(s.embedding),
        order_by: fragment("? <=> ?", s.embedding, ^query_embedding),
        limit: ^limit
      )

    base_query
    |> maybe_filter_category(category)
    |> maybe_filter_taint(taint_filter)
    |> Repo.all()
  end

  # -- Reciprocal Rank Fusion --

  defp rrf_merge(bm25_results, vector_results, limit, min_score) do
    bm25_ranked =
      bm25_results
      |> Enum.with_index(1)
      |> Map.new(fn {record, rank} -> {record.id, {rank, record}} end)

    vector_ranked =
      vector_results
      |> Enum.with_index(1)
      |> Map.new(fn {record, rank} -> {record.id, {rank, record}} end)

    all_ids = MapSet.union(MapSet.new(Map.keys(bm25_ranked)), MapSet.new(Map.keys(vector_ranked)))

    all_ids
    |> Enum.map(fn id ->
      bm25_score =
        case Map.get(bm25_ranked, id) do
          {rank, _} -> 1.0 / (@rrf_k + rank)
          nil -> 0.0
        end

      vector_score =
        case Map.get(vector_ranked, id) do
          {rank, _} -> 1.0 / (@rrf_k + rank)
          nil -> 0.0
        end

      score = bm25_score + vector_score

      record =
        case Map.get(bm25_ranked, id) do
          {_, r} -> r
          nil -> elem(Map.get(vector_ranked, id), 1)
        end

      {score, record}
    end)
    |> Enum.filter(fn {score, _} -> score >= min_score end)
    |> Enum.sort_by(fn {score, _} -> score end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {_score, record} -> skill_record_to_map(record) end)
  end

  # -- Query helpers --

  defp maybe_filter_category(query, nil), do: query
  defp maybe_filter_category(query, category), do: from(s in query, where: s.category == ^category)

  defp maybe_filter_taint(query, nil), do: query
  defp maybe_filter_taint(query, taint), do: from(s in query, where: s.taint == ^to_string(taint))

  # -- Conversion helpers --

  defp skill_to_attrs(skill) when is_struct(skill), do: skill_to_attrs(Map.from_struct(skill))

  defp skill_to_attrs(skill) when is_map(skill) do
    %{
      name: get_field(skill, :name),
      description: get_field(skill, :description, ""),
      body: get_field(skill, :body, ""),
      tags: get_field(skill, :tags, []),
      category: get_field(skill, :category),
      source: to_string(get_field(skill, :source, "skill")),
      path: get_field(skill, :path),
      license: get_field(skill, :license),
      compatibility: get_field(skill, :compatibility),
      allowed_tools: get_field(skill, :allowed_tools, []),
      content_hash: get_field(skill, :content_hash) || compute_hash(skill),
      taint: to_string(get_field(skill, :taint, "trusted")),
      provenance: get_field(skill, :provenance, %{}),
      metadata: get_field(skill, :metadata, %{})
    }
  end

  defp get_field(skill, key, default \\ nil) do
    Map.get(skill, key) || Map.get(skill, to_string(key)) || default
  end

  defp skill_record_to_map(%SkillRecord{} = record) do
    %{
      name: record.name,
      description: record.description,
      body: record.body,
      tags: record.tags,
      category: record.category,
      source: record.source,
      taint: record.taint,
      content_hash: record.content_hash,
      license: record.license,
      compatibility: record.compatibility,
      allowed_tools: record.allowed_tools
    }
  end

  defp compute_hash(skill) do
    body = Map.get(skill, :body) || Map.get(skill, "body") || ""
    :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  end

  defp generate_id do
    "skill_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end
end
