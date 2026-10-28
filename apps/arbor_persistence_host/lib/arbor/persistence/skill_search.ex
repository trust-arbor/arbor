defmodule Arbor.Persistence.SkillSearch do
  @moduledoc """
  Hybrid search engine for skills combining BM25 full-text and pgvector semantic search.

  Uses Reciprocal Rank Fusion (RRF) to merge rankings from both search methods
  into a single relevance-ordered result set. Falls back to BM25-only when no
  embedding is available for the query.

  PostgreSQL-only: SQLite and other adapters never execute tsvector/pgvector SQL.

  ## Search Strategy

  1. **BM25** — PostgreSQL `ts_rank` on the generated `searchable` tsvector column,
     weighted across name (A), description (B), tags (C), and body (D).
  2. **pgvector** — Cosine distance on the 768-dimensional `embedding` column,
     restricted to rows whose stored `embedding_space` exactly matches the query space.
  3. **RRF merge** — `score(d) = sum(1 / (k + rank_i(d)))` with `k = 60`.
  """

  import Ecto.Query

  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.SkillRecord

  require Logger

  @rrf_k 60
  @embedding_space_key "embedding_space"

  @type search_meta :: %{
          mode: :hybrid | :bm25_only | :unavailable,
          backend: :postgres | :none,
          capability: :postgres | :ets_only | :unavailable,
          query_embedding: :ok | :skipped_no_query_embedding | :not_attempted,
          bm25_arm: :executed | :empty | :skipped_not_postgres | :failed | :not_attempted,
          vector_arm:
            :executed
            | :empty
            | :skipped_no_query_embedding
            | :skipped_not_postgres
            | :failed
            | :not_attempted,
          fusion: :rrf | :none,
          result_count: non_neg_integer(),
          reason:
            nil
            | :zero_results
            | :sqlite_or_non_postgres
            | :search_error
            | :persistence_unavailable
        }

  @doc """
  Backend class for skill hybrid search.

  * `:postgres` — Repo running on PostgreSQL (BM25 + pgvector available)
  * `:ets_only` — persistence present but skill hybrid SQL unsupported
  * `:unavailable` — Repo not started or not loadable
  """
  @spec skill_search_capability() :: :postgres | :ets_only | :unavailable
  def skill_search_capability do
    cond do
      not Code.ensure_loaded?(Repo) ->
        :unavailable

      is_nil(Process.whereis(Repo)) ->
        :unavailable

      true ->
        adapter_capability(repo_adapter(Repo))
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  defp adapter_capability(Ecto.Adapters.Postgres), do: :postgres
  defp adapter_capability(_adapter), do: :ets_only

  # Keep adapter dispatch dynamic across SQLite and Postgres builds. Calling
  # Repo.__adapter__/0 inline is narrowed to the build adapter by Elixir 1.19.
  defp repo_adapter(repo), do: repo.__adapter__()

  @doc "True when skill hybrid SQL may run."
  @spec postgres_capable?() :: boolean()
  def postgres_capable?, do: skill_search_capability() == :postgres

  @doc """
  Search skills using hybrid BM25 + pgvector with Reciprocal Rank Fusion.

  When `query_embedding` is nil, falls back to BM25-only full-text search.
  On non-Postgres adapters returns `[]` without executing PG operators.
  """
  @spec hybrid_search(String.t(), list() | nil, keyword()) :: [map()]
  def hybrid_search(query_text, query_embedding \\ nil, opts \\ []) do
    case hybrid_search_with_meta(query_text, query_embedding, opts) do
      {:ok, %{results: results}} -> results
    end
  end

  @doc """
  Hybrid search with explicit metadata for all fallback and zero-result states.
  """
  @spec hybrid_search_with_meta(String.t(), list() | nil, keyword()) ::
          {:ok, %{results: [map()], meta: search_meta()}}
  def hybrid_search_with_meta(query_text, query_embedding \\ nil, opts \\ [])
      when is_binary(query_text) do
    capability = skill_search_capability()

    case capability do
      :postgres ->
        do_postgres_hybrid_search(query_text, query_embedding, opts)

      :ets_only ->
        {:ok,
         %{
           results: [],
           meta:
             base_meta(:unavailable, :none, :ets_only,
               query_embedding: :not_attempted,
               bm25_arm: :skipped_not_postgres,
               vector_arm: :skipped_not_postgres,
               fusion: :none,
               reason: :sqlite_or_non_postgres
             )
         }}

      :unavailable ->
        {:ok,
         %{
           results: [],
           meta:
             base_meta(:unavailable, :none, :unavailable,
               query_embedding: :not_attempted,
               bm25_arm: :not_attempted,
               vector_arm: :not_attempted,
               fusion: :none,
               reason: :persistence_unavailable
             )
         }}
    end
  end

  @doc """
  Insert or update a skill record by name.

  When `:embedding` / `:embedding_space` are omitted, existing vector and space
  are preserved. Never pass `embedding: nil` to clear on outage.
  """
  @spec upsert(map()) :: {:ok, SkillRecord.t()} | {:error, Ecto.Changeset.t()}
  def upsert(attrs) when is_map(attrs) do
    name = attrs[:name] || attrs["name"]

    case Repo.get_by(SkillRecord, name: name) do
      nil ->
        id = attrs[:id] || attrs["id"] || generate_id()
        prepared = prepare_attrs(attrs, id)

        %SkillRecord{}
        |> SkillRecord.changeset(prepared)
        |> Repo.insert()

      existing ->
        prepared = prepare_attrs(attrs, existing.id)
        merged = merge_preserve_embedding(existing, prepared)

        existing
        |> SkillRecord.changeset(merged)
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
      Enum.reduce(skills, 0, fn skill, acc ->
        attrs = skill_to_attrs(skill)

        case upsert(attrs) do
          {:ok, _} -> acc + 1
          {:error, _} -> acc
        end
      end)

    {:ok, count}
  end

  @doc "Get a skill record by name."
  @spec get_by_name(String.t()) :: SkillRecord.t() | nil
  def get_by_name(name) when is_binary(name) do
    Repo.get_by(SkillRecord, name: name)
  end

  @doc "Public map form of a skill record (includes embedding_space when present)."
  @spec get_record_map(String.t()) :: map() | nil
  def get_record_map(name) when is_binary(name) do
    case get_by_name(name) do
      nil -> nil
      record -> skill_record_to_map(record)
    end
  end

  @doc "Delete a skill record by name."
  @spec delete(String.t()) :: {:ok, SkillRecord.t()} | {:error, :not_found}
  def delete(name) when is_binary(name) do
    case get_by_name(name) do
      nil -> {:error, :not_found}
      record -> Repo.delete(record)
    end
  end

  # -- Postgres hybrid execution --

  defp do_postgres_hybrid_search(query_text, query_embedding, opts) do
    limit = Keyword.get(opts, :limit, 10)
    category = Keyword.get(opts, :category)
    taint_filter = Keyword.get(opts, :taint_filter)
    min_score = Keyword.get(opts, :min_score, 0.0)

    bm25_outcome = run_bm25_arm(query_text, category, taint_filter, limit * 2)

    # Admit query vector with the same public boundary as write pairs. Malformed
    # facade inputs degrade to BM25-only instead of reaching Pgvector SQL.
    vector_outcome =
      case pair_embedding_write(query_embedding, Keyword.get(opts, :embedding_space)) do
        {:write, embedding, space} ->
          run_vector_arm(
            maybe_pgvector(embedding),
            space,
            category,
            taint_filter,
            limit * 2
          )

        :omit ->
          :skipped
      end

    compose_hybrid_arms(bm25_outcome, vector_outcome, limit, min_score)
  end

  defp run_bm25_arm(query_text, category, taint_filter, limit) do
    results = bm25_search(query_text, category, taint_filter, limit)
    arm = if results == [], do: :empty, else: :executed
    {:ok, results, arm}
  rescue
    e ->
      Logger.warning("[SkillSearch] BM25 arm failed: #{Exception.message(e)}")
      :failed
  catch
    :exit, reason ->
      Logger.warning("[SkillSearch] BM25 arm exit: #{inspect(reason)}")
      :failed
  end

  defp run_vector_arm(query_embedding, space, category, taint_filter, limit) do
    results = vector_search(query_embedding, space, category, taint_filter, limit)
    arm = if results == [], do: :empty, else: :executed
    {:ok, results, arm}
  rescue
    e ->
      Logger.warning("[SkillSearch] vector arm failed: #{Exception.message(e)}")
      :failed
  catch
    :exit, reason ->
      Logger.warning("[SkillSearch] vector arm exit: #{inspect(reason)}")
      :failed
  end

  @doc false
  @spec compose_hybrid_arms(term(), term(), pos_integer(), number()) ::
          {:ok, %{results: [map()], meta: map()}}
  def compose_hybrid_arms(bm25_outcome, vector_outcome, limit, min_score) do
    case {bm25_outcome, vector_outcome} do
      {:failed, :failed} ->
        both_arms_failed_result()

      {:failed, :skipped} ->
        # BM25-only path failed; vector was not attempted.
        {:ok,
         %{
           results: [],
           meta:
             base_meta(:unavailable, :postgres, :postgres,
               query_embedding: :skipped_no_query_embedding,
               bm25_arm: :failed,
               vector_arm: :skipped_no_query_embedding,
               fusion: :none,
               reason: :search_error
             )
         }}

      {{:ok, bm25_results, bm25_arm}, :skipped} ->
        results =
          bm25_results
          |> Enum.take(limit)
          |> Enum.map(&record_to_result_map/1)

        {:ok,
         %{
           results: results,
           meta:
             base_meta(:bm25_only, :postgres, :postgres,
               query_embedding: :skipped_no_query_embedding,
               bm25_arm: bm25_arm,
               vector_arm: :skipped_no_query_embedding,
               fusion: :none,
               result_count: length(results),
               reason: zero_reason(results)
             )
         }}

      {{:ok, bm25_results, bm25_arm}, {:ok, vector_results, vector_arm}} ->
        results = rrf_merge(bm25_results, vector_results, limit, min_score)

        {:ok,
         %{
           results: results,
           meta:
             base_meta(:hybrid, :postgres, :postgres,
               query_embedding: :ok,
               bm25_arm: bm25_arm,
               vector_arm: vector_arm,
               fusion: :rrf,
               result_count: length(results),
               reason: zero_reason(results)
             )
         }}

      {{:ok, bm25_results, bm25_arm}, :failed} ->
        # Vector failed — preserve successful BM25 results.
        results =
          bm25_results
          |> Enum.take(limit)
          |> Enum.map(&record_to_result_map/1)

        {:ok,
         %{
           results: results,
           meta:
             base_meta(:bm25_only, :postgres, :postgres,
               query_embedding: :ok,
               bm25_arm: bm25_arm,
               vector_arm: :failed,
               fusion: :none,
               result_count: length(results),
               reason: zero_reason(results)
             )
         }}

      {:failed, {:ok, vector_results, vector_arm}} ->
        # BM25 failed — preserve successful vector results.
        results =
          vector_results
          |> Enum.take(limit)
          |> Enum.map(&record_to_result_map/1)

        {:ok,
         %{
           results: results,
           meta:
             base_meta(:hybrid, :postgres, :postgres,
               query_embedding: :ok,
               bm25_arm: :failed,
               vector_arm: vector_arm,
               fusion: :none,
               result_count: length(results),
               reason: zero_reason(results)
             )
         }}
    end
  end

  defp both_arms_failed_result do
    {:ok,
     %{
       results: [],
       meta:
         base_meta(:unavailable, :postgres, :postgres,
           query_embedding: :ok,
           bm25_arm: :failed,
           vector_arm: :failed,
           fusion: :none,
           reason: :search_error
         )
     }}
  end

  defp zero_reason([]), do: :zero_results
  defp zero_reason(_), do: nil

  defp record_to_result_map(%SkillRecord{} = record), do: skill_record_to_map(record)
  defp record_to_result_map(%{} = map), do: map

  defp base_meta(mode, backend, capability, overrides) do
    Map.merge(
      %{
        mode: mode,
        backend: backend,
        capability: capability,
        query_embedding: :not_attempted,
        bm25_arm: :not_attempted,
        vector_arm: :not_attempted,
        fusion: :none,
        result_count: 0,
        reason: nil
      },
      Map.new(overrides)
    )
  end

  # -- BM25 full-text search --

  defp bm25_search(query_text, category, taint_filter, limit) do
    # Column `searchable` is Postgres-trigger-maintained and not on the Ecto schema
    # (absent on SQLite). Only invoked after postgres_capable? gate.
    base_query =
      from(s in SkillRecord,
        where: fragment("searchable @@ plainto_tsquery('english', ?)", ^query_text),
        order_by: [
          desc: fragment("ts_rank(searchable, plainto_tsquery('english', ?))", ^query_text)
        ],
        limit: ^limit
      )

    base_query
    |> maybe_filter_category(category)
    |> maybe_filter_taint(taint_filter)
    |> Repo.all()
  end

  # -- pgvector semantic search --

  defp vector_search(query_embedding, space, category, taint_filter, limit) do
    provider = space["provider"]
    model = space["model"]
    dimensions = space["dimensions"]

    base_query =
      from(s in SkillRecord,
        where: not is_nil(s.embedding),
        where:
          fragment(
            """
            (? -> ? ->> 'provider') = ?
            AND (? -> ? ->> 'model') = ?
            AND ((? -> ? ->> 'dimensions')::int = ?)
            """,
            s.metadata,
            ^@embedding_space_key,
            ^provider,
            s.metadata,
            ^@embedding_space_key,
            ^model,
            s.metadata,
            ^@embedding_space_key,
            ^dimensions
          ),
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
      |> Map.new(fn {record, rank} -> {record_id(record), {rank, record}} end)

    vector_ranked =
      vector_results
      |> Enum.with_index(1)
      |> Map.new(fn {record, rank} -> {record_id(record), {rank, record}} end)

    all_ids =
      MapSet.union(MapSet.new(Map.keys(bm25_ranked)), MapSet.new(Map.keys(vector_ranked)))

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
    |> Enum.sort_by(fn {score, record} -> {-score, record_name(record)} end)
    |> Enum.take(limit)
    |> Enum.map(fn {_score, record} -> record_to_result_map(record) end)
  end

  defp record_name(%SkillRecord{name: name}), do: name
  defp record_name(%{name: name}) when is_binary(name), do: name
  defp record_name(%{"name" => name}) when is_binary(name), do: name
  defp record_name(_), do: ""

  defp record_id(%SkillRecord{id: id}), do: id
  defp record_id(%{id: id}), do: id
  defp record_id(%{"id" => id}), do: id
  defp record_id(_), do: nil

  # -- Query helpers --

  defp maybe_filter_category(query, nil), do: query

  defp maybe_filter_category(query, category),
    do: from(s in query, where: s.category == ^category)

  defp maybe_filter_taint(query, nil), do: query

  defp maybe_filter_taint(query, taint),
    do: from(s in query, where: s.taint == ^to_string(taint))

  # -- Attr preparation / preserve semantics --

  defp prepare_attrs(attrs, id) do
    base =
      attrs
      |> skill_to_attrs()
      |> Map.put(:id, id)
      # Never cast orphan embedding; pair write is atomic with embedding_space.
      |> Map.delete(:embedding)
      |> Map.delete(:embedding_space)

    raw_embedding = Map.get(attrs, :embedding) || Map.get(attrs, "embedding")
    raw_space = Map.get(attrs, :embedding_space) || Map.get(attrs, "embedding_space")

    case pair_embedding_write(raw_embedding, raw_space) do
      {:write, embedding, space} ->
        metadata =
          base
          |> Map.get(:metadata, %{})
          |> stringify_keys()
          # Drop any stale space from input metadata; write the validated pair only.
          |> Map.put(@embedding_space_key, space)

        base
        |> Map.put(:embedding, maybe_pgvector(embedding))
        |> Map.put(:metadata, metadata)

      :omit ->
        # Strip any input metadata embedding_space so we do not invent a space
        # without a vector (or a vector without space). merge_preserve keeps legacy.
        metadata =
          base
          |> Map.get(:metadata, %{})
          |> stringify_keys()
          |> Map.delete(@embedding_space_key)

        base
        |> Map.put(:metadata, metadata)
        |> Map.delete(:embedding)
    end
  end

  @doc """
  Public admission boundary for skill embedding + embedding_space pairs.

  Admits only a nonempty numeric vector whose length exactly equals a positive
  `dimensions` value, with nonblank provider and model. Used for both durable
  writes and query-vector execution.
  """
  @spec pair_embedding_write(term(), term()) ::
          {:write, [number()], map()} | :omit
  def pair_embedding_write(embedding, space) do
    normalized = normalize_space(space)

    if valid_embedding_vector?(embedding) and is_map(normalized) and
         length(embedding) == normalized["dimensions"] do
      {:write, embedding, normalized}
    else
      :omit
    end
  end

  defp valid_embedding_vector?(embedding) do
    is_list(embedding) and embedding != [] and Enum.all?(embedding, &is_number/1)
  end

  defp merge_preserve_embedding(%SkillRecord{} = existing, prepared) do
    prepared =
      if Map.has_key?(prepared, :embedding) do
        prepared
      else
        Map.delete(prepared, :embedding)
      end

    # Preserve embedding_space in metadata when not supplied with a new vector.
    case Map.get(prepared, :metadata) do
      meta when is_map(meta) ->
        existing_meta = stringify_keys(existing.metadata || %{})
        new_meta = stringify_keys(meta)

        merged_meta =
          if Map.has_key?(prepared, :embedding) and
               Map.has_key?(new_meta, @embedding_space_key) do
            Map.merge(existing_meta, new_meta)
          else
            # Keep prior space; merge other metadata keys without dropping space.
            existing_meta
            |> Map.merge(Map.delete(new_meta, @embedding_space_key))
            |> maybe_keep_space(existing_meta)
          end

        Map.put(prepared, :metadata, merged_meta)

      _ ->
        if Map.has_key?(prepared, :embedding) do
          prepared
        else
          # No metadata update and no new embedding — leave metadata alone by omitting it.
          Map.delete(prepared, :metadata)
        end
    end
  end

  defp maybe_keep_space(merged, existing_meta) do
    case Map.get(existing_meta, @embedding_space_key) do
      nil -> merged
      space -> Map.put_new(merged, @embedding_space_key, space)
    end
  end

  defp normalize_space(nil), do: nil

  defp normalize_space(space) when is_map(space) do
    provider = space[:provider] || space["provider"]
    model = space[:model] || space["model"]
    dimensions = space[:dimensions] || space["dimensions"]

    cond do
      not nonblank_provider?(provider) ->
        nil

      not nonblank_model?(model) ->
        nil

      not (is_integer(dimensions) and dimensions > 0) ->
        nil

      true ->
        %{
          "provider" => provider_to_string(provider),
          "model" => String.trim(to_string(model)),
          "dimensions" => dimensions
        }
    end
  end

  defp normalize_space(_), do: nil

  defp nonblank_model?(model) when is_binary(model), do: String.trim(model) != ""
  defp nonblank_model?(_), do: false

  defp nonblank_provider?(provider) when is_atom(provider) and not is_nil(provider), do: true

  defp nonblank_provider?(provider) when is_binary(provider), do: String.trim(provider) != ""

  defp nonblank_provider?(_), do: false

  defp provider_to_string(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp provider_to_string(provider) when is_binary(provider), do: String.trim(provider)

  defp maybe_pgvector(embedding) when is_list(embedding) do
    if Code.ensure_loaded?(Pgvector) and function_exported?(Pgvector, :new, 1) do
      Pgvector.new(embedding)
    else
      embedding
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # -- Conversion helpers --

  defp skill_to_attrs(skill) when is_struct(skill), do: skill_to_attrs(Map.from_struct(skill))

  defp skill_to_attrs(skill) when is_map(skill) do
    # Embedding + space are applied only via pair_embedding_write/2 in prepare_attrs/2.
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
      metadata: stringify_keys(get_field(skill, :metadata, %{}) || %{})
    }
  end

  defp get_field(skill, key, default \\ nil) do
    Map.get(skill, key) || Map.get(skill, to_string(key)) || default
  end

  defp skill_record_to_map(%SkillRecord{} = record) do
    metadata = stringify_keys(record.metadata || %{})
    space = Map.get(metadata, @embedding_space_key)

    map = %{
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
      allowed_tools: record.allowed_tools,
      metadata: metadata
    }

    map =
      if is_nil(record.embedding) do
        map
      else
        embedding =
          cond do
            is_list(record.embedding) ->
              record.embedding

            Code.ensure_loaded?(Pgvector) and function_exported?(Pgvector, :to_list, 1) ->
              Pgvector.to_list(record.embedding)

            true ->
              record.embedding
          end

        Map.put(map, :embedding, embedding)
      end

    if is_map(space), do: Map.put(map, :embedding_space, space), else: map
  end

  defp compute_hash(skill) do
    body = Map.get(skill, :body) || Map.get(skill, "body") || ""
    :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  end

  defp generate_id do
    "skill_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end
end
