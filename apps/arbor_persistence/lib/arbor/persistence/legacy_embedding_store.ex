defmodule Arbor.Persistence.LegacyEmbeddingStore do
  @moduledoc false

  import Ecto.Query

  alias Arbor.Contracts.Persistence.VectorRecord
  alias Arbor.Identifiers
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.MemoryEmbedding

  require Logger

  @legacy_id_constraints ["memory_embeddings_pkey", "memory_embeddings_id_index"]
  @verify_hook_key {__MODULE__, :post_delete_remaining_override}

  @type legacy_cleanup_error ::
          :invalid_request | :invalid_options | :backend_failure | :indeterminate

  @spec store(String.t(), String.t(), [float()], map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def store(agent_id, content, embedding, metadata, opts \\ []) do
    with {:ok, repo} <- repo_from_opts(opts),
         {:ok, normalized_embedding} <- validate(agent_id, content, embedding, metadata) do
      content_hash = compute_content_hash(content)
      id = Map.get(metadata, :id) || Map.get(metadata, "id") || Identifiers.generate_id("emb_")

      if protected_vector_global_id?(repo, id) do
        {:error, :protected_vector_row}
      else
        store_legacy_embedding(
          repo,
          agent_id,
          id,
          content,
          content_hash,
          normalized_embedding,
          metadata
        )
      end
    end
  end

  @spec validate(String.t(), String.t(), [float()], map()) ::
          {:ok, [float()]} | {:error, {:invalid_legacy_embedding, atom()}}
  def validate(agent_id, content, embedding, metadata) do
    with :ok <- validate_agent_id(agent_id),
         :ok <- validate_content(content),
         :ok <- validate_metadata(metadata),
         :ok <- validate_requested_id(metadata),
         :ok <- validate_metadata_column(metadata, :type, 50),
         :ok <- validate_metadata_column(metadata, :source, 255),
         {:ok, normalized_embedding} <- normalize_embedding(embedding) do
      {:ok, normalized_embedding}
    end
  end

  @spec search(String.t(), [float()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(agent_id, query_embedding, opts) do
    limit = Keyword.get(opts, :limit, 10)
    threshold = Keyword.get(opts, :threshold, 0.3)
    type_filter = Keyword.get(opts, :type_filter)
    query_vector = Pgvector.new(query_embedding)

    base_query =
      from(e in legacy_rows(),
        where: e.agent_id == ^agent_id,
        select: %{
          id: e.id,
          content: e.content,
          cosine_distance: fragment("embedding <=> ?", ^query_vector),
          metadata: e.metadata,
          memory_type: e.memory_type,
          inserted_at: e.inserted_at
        }
      )

    query =
      if type_filter do
        from(e in base_query, where: e.memory_type == ^type_filter)
      else
        base_query
      end

    max_distance = 1.0 - threshold

    query =
      from(q in query,
        where: fragment("embedding <=> ?", ^query_vector) <= ^max_distance,
        order_by: fragment("embedding <=> ?", ^query_vector),
        limit: ^limit
      )

    try do
      results =
        Repo.all(query)
        |> Enum.map(fn row ->
          %{
            id: row.id,
            content: row.content,
            similarity: 1.0 - row.cosine_distance,
            metadata: row.metadata || %{},
            memory_type: row.memory_type,
            indexed_at: row.inserted_at
          }
        end)

      {:ok, results}
    rescue
      error ->
        Logger.error("Embedding search failed: #{inspect(error)}")
        {:error, error}
    end
  end

  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(agent_id, embedding_id) do
    query =
      from(e in legacy_rows(),
        where: e.agent_id == ^agent_id and e.id == ^embedding_id
      )

    case Repo.delete_all(query) do
      {1, _} ->
        Logger.debug("Deleted embedding #{embedding_id} for agent #{agent_id}")
        :ok

      {0, _} ->
        if protected_vector_agent_id?(agent_id, embedding_id),
          do: {:error, :protected_vector_row},
          else: {:error, :not_found}
    end
  end

  @spec count(String.t(), keyword()) :: non_neg_integer() | {:error, :invalid_options}
  def count(agent_id, opts \\ []) do
    with {:ok, repo} <- repo_from_opts(opts) do
      query =
        from(e in legacy_rows(),
          where: e.agent_id == ^agent_id,
          select: count(e.id)
        )

      repo.one(query) || 0
    end
  end

  @spec stats(String.t()) :: map()
  def stats(agent_id) do
    total_query =
      from(e in legacy_rows(),
        where: e.agent_id == ^agent_id,
        select: count(e.id)
      )

    type_query =
      from(e in legacy_rows(),
        where: e.agent_id == ^agent_id and not is_nil(e.memory_type),
        group_by: e.memory_type,
        select: {e.memory_type, count(e.id)}
      )

    bounds_query =
      from(e in legacy_rows(),
        where: e.agent_id == ^agent_id,
        select: {min(e.inserted_at), max(e.inserted_at)}
      )

    {oldest, newest} = Repo.one(bounds_query) || {nil, nil}

    %{
      total: Repo.one(total_query) || 0,
      by_type: Repo.all(type_query) |> Map.new(),
      oldest: oldest,
      newest: newest
    }
  end

  @spec store_batch(String.t(), [{String.t(), [float()], map()}]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def store_batch(agent_id, entries) do
    with {:ok, ids} <- store_batch_with_ids(agent_id, entries) do
      {:ok, length(ids)}
    end
  end

  @spec store_batch_with_ids(String.t(), [{String.t(), [float()], map()}], keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def store_batch_with_ids(agent_id, entries, opts \\ [])

  def store_batch_with_ids(_agent_id, [], opts) do
    with {:ok, _repo} <- repo_from_opts(opts), do: {:ok, []}
  end

  def store_batch_with_ids(agent_id, entries, opts)
      when is_binary(agent_id) and is_list(entries) do
    with {:ok, repo} <- repo_from_opts(opts),
         {:ok, normalized_entries} <- validate_batch(agent_id, entries),
         {:ok, rows} <- build_batch_rows(agent_id, normalized_entries),
         :ok <- validate_distinct_batch_hashes(rows) do
      transact_batch(repo, agent_id, rows)
    end
  end

  def store_batch_with_ids(_agent_id, _entries, _opts), do: {:error, :invalid_batch}

  @spec get(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found | :invalid_options}
  def get(agent_id, embedding_id, opts \\ []) do
    with {:ok, repo} <- repo_from_opts(opts) do
      query =
        from(e in legacy_rows(),
          where: e.agent_id == ^agent_id and e.id == ^embedding_id
        )

      case repo.one(query) do
        nil ->
          {:error, :not_found}

        record ->
          {:ok,
           %{
             id: record.id,
             agent_id: record.agent_id,
             content: record.content,
             content_hash: record.content_hash,
             embedding: record.embedding,
             memory_type: record.memory_type,
             source: record.source,
             metadata: record.metadata,
             inserted_at: record.inserted_at,
             updated_at: record.updated_at
           }}
      end
    end
  end

  @spec delete_all(String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_options}
  def delete_all(agent_id, opts \\ []) do
    with {:ok, repo} <- repo_from_opts(opts) do
      query =
        from(e in legacy_rows(),
          where: e.agent_id == ^agent_id
        )

      {count, _} = repo.delete_all(query)
      Logger.info("Deleted #{count} embeddings for agent #{agent_id}")
      {:ok, count}
    end
  end

  @doc """
  Idempotently destroy every legacy embedding row for exactly one agent and
  confirm zero remaining rows under the same repository and legacy predicate.

  Content-only: does not touch strict V1 vector rows, receipts, fences,
  provenance, or other domains. C3I0B `destroy_vector_agent` is a separate
  authority and is never called here.
  """
  @spec destroy_legacy_embeddings(String.t(), keyword()) ::
          :ok | {:error, legacy_cleanup_error()}
  def destroy_legacy_embeddings(agent_id, opts \\ []) do
    with :ok <- validate_cleanup_agent_id(agent_id),
         {:ok, repo} <- repo_from_opts(opts) do
      do_destroy_legacy_embeddings(repo, agent_id)
    end
  rescue
    _ -> {:error, :backend_failure}
  catch
    _, _ -> {:error, :backend_failure}
  end

  @doc """
  Authoritative absence check for exact-agent legacy embedding rows.

  Returns `{:ok, true}` only when the confirming count under the legacy
  predicate and exact agent equality is zero.
  """
  @spec legacy_embeddings_absent?(String.t(), keyword()) ::
          {:ok, true} | {:ok, false} | {:error, legacy_cleanup_error()}
  def legacy_embeddings_absent?(agent_id, opts \\ []) do
    with :ok <- validate_cleanup_agent_id(agent_id),
         {:ok, repo} <- repo_from_opts(opts) do
      case authoritative_legacy_count(repo, agent_id) do
        0 -> {:ok, true}
        n when is_integer(n) and n > 0 -> {:ok, false}
        _ -> {:error, :backend_failure}
      end
    end
  rescue
    _ -> {:error, :backend_failure}
  catch
    _, _ -> {:error, :backend_failure}
  end

  # Test-only process-local seam for post-delete confirming-count failure.
  if Mix.env() == :test do
    @doc false
    def __set_post_delete_remaining_override__(n) when is_integer(n) and n >= 0 do
      Process.put(@verify_hook_key, n)
      :ok
    end

    @doc false
    def __clear_post_delete_remaining_override__ do
      Process.delete(@verify_hook_key)
      :ok
    end
  end

  defp do_destroy_legacy_embeddings(repo, agent_id) do
    case repo.transaction(fn -> destroy_inside_transaction(repo, agent_id) end) do
      {:ok, :ok} -> :ok
      {:error, :indeterminate} -> {:error, :indeterminate}
      {:error, :backend_failure} -> {:error, :backend_failure}
      {:error, _reason} -> {:error, :backend_failure}
      _other -> {:error, :backend_failure}
    end
  rescue
    _ -> {:error, :backend_failure}
  catch
    _, _ -> {:error, :backend_failure}
  end

  defp destroy_inside_transaction(repo, agent_id) do
    delete_query =
      from(e in legacy_rows(),
        where: e.agent_id == ^agent_id
      )

    case repo.delete_all(delete_query) do
      {count, _result} when is_integer(count) and count >= 0 ->
        case post_delete_remaining(repo, agent_id) do
          0 ->
            :ok

          n when is_integer(n) and n > 0 ->
            repo.rollback(:indeterminate)

          _malformed ->
            repo.rollback(:backend_failure)
        end

      _malformed_delete ->
        repo.rollback(:backend_failure)
    end
  end

  defp post_delete_remaining(repo, agent_id) do
    if Mix.env() == :test do
      case Process.get(@verify_hook_key) do
        n when is_integer(n) and n >= 0 -> n
        _ -> authoritative_legacy_count(repo, agent_id)
      end
    else
      authoritative_legacy_count(repo, agent_id)
    end
  end

  defp authoritative_legacy_count(repo, agent_id) do
    query =
      from(e in legacy_rows(),
        where: e.agent_id == ^agent_id,
        select: count(e.id)
      )

    case repo.one(query) do
      n when is_integer(n) and n >= 0 -> n
      _malformed -> :malformed
    end
  end

  defp validate_cleanup_agent_id(agent_id) do
    case VectorRecord.validate_identity(agent_id, "legacy", "legacy") do
      {:ok, _identity} -> :ok
      {:error, :invalid_vector_identity} -> {:error, :invalid_request}
    end
  end

  defp store_legacy_embedding(repo, agent_id, id, content, content_hash, embedding, metadata) do
    attrs = %{
      id: id,
      agent_id: agent_id,
      content: content,
      content_hash: content_hash,
      embedding: Pgvector.new(embedding),
      memory_type: safe_to_string(get_in(metadata, [:type]) || Map.get(metadata, "type")),
      source: safe_to_string(get_in(metadata, [:source]) || Map.get(metadata, "source")),
      metadata: metadata
    }

    changeset = MemoryEmbedding.changeset(%MemoryEmbedding{}, attrs)

    case insert_legacy_changeset(repo, changeset, agent_id, content_hash) do
      {:ok, %MemoryEmbedding{} = record} ->
        if is_nil(record.vector_protocol) and is_nil(record.source_namespace) do
          Logger.debug("Stored embedding #{record.id} for agent #{agent_id}")
          {:ok, record.id}
        else
          {:error, :protected_vector_row}
        end

      {:error, :protected_vector_row} ->
        {:error, :protected_vector_row}

      {:error, %Ecto.Changeset{} = changeset} ->
        if legacy_id_conflict_changeset?(changeset) do
          {:error, :legacy_embedding_id_conflict}
        else
          Logger.warning("Failed to store embedding: #{inspect(changeset.errors)}")
          {:error, changeset.errors}
        end

      {:error, :legacy_embedding_id_conflict} ->
        {:error, :legacy_embedding_id_conflict}
    end
  end

  defp build_batch_rows(agent_id, entries) do
    now = DateTime.utc_now()

    entries
    |> Enum.reduce_while({:ok, []}, fn
      {content, embedding, metadata}, {:ok, rows}
      when is_binary(content) and is_list(embedding) and is_map(metadata) ->
        id = Map.get(metadata, :id) || Map.get(metadata, "id") || Identifiers.generate_id("emb_")

        if is_binary(id) do
          row = %{
            id: id,
            agent_id: agent_id,
            content: content,
            content_hash: compute_content_hash(content),
            embedding: Pgvector.new(embedding),
            memory_type: safe_to_string(get_in(metadata, [:type]) || Map.get(metadata, "type")),
            source: safe_to_string(get_in(metadata, [:source]) || Map.get(metadata, "source")),
            metadata: metadata,
            inserted_at: now,
            updated_at: now
          }

          {:cont, {:ok, [row | rows]}}
        else
          {:halt, {:error, :invalid_batch}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_batch}}
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  rescue
    _error -> {:error, :invalid_batch}
  end

  defp validate_distinct_batch_hashes(rows) do
    hashes = Enum.map(rows, & &1.content_hash)
    if length(hashes) == length(Enum.uniq(hashes)), do: :ok, else: {:error, :invalid_batch}
  end

  defp transact_batch(repo, agent_id, rows) do
    case repo.transaction(fn -> insert_batch_or_rollback(repo, rows) end) do
      {:ok, ids} ->
        Logger.debug("Batch stored #{length(ids)} embeddings for agent #{agent_id}")
        {:ok, ids}

      {:error, :protected_vector_row} ->
        {:error, :protected_vector_row}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      if legacy_id_conflict_exception?(error) do
        {:error, :legacy_embedding_id_conflict}
      else
        Logger.error("Batch store failed: #{inspect(error)}")
        {:error, error}
      end
  end

  defp insert_batch_or_rollback(repo, rows) do
    if Enum.any?(rows, &protected_vector_global_id?(repo, &1.id)) do
      repo.rollback(:protected_vector_row)
    end

    {count, returned_rows} =
      repo.insert_all(MemoryEmbedding, rows,
        on_conflict: legacy_conflict_query(),
        conflict_target: [:agent_id, :content_hash],
        returning: [:id, :content_hash]
      )

    with true <- count == length(rows),
         true <- length(returned_rows) == length(rows),
         {:ok, ids} <- authoritative_batch_ids(rows, returned_rows) do
      ids
    else
      _protected_or_malformed -> repo.rollback(:protected_vector_row)
    end
  end

  defp authoritative_batch_ids(rows, returned_rows) do
    ids_by_hash = Map.new(returned_rows, &{&1.content_hash, &1.id})

    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, ids} ->
      case Map.fetch(ids_by_hash, row.content_hash) do
        {:ok, id} when is_binary(id) -> {:cont, {:ok, [id | ids]}}
        _missing -> {:halt, {:error, :malformed_return}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp legacy_rows do
    from(e in MemoryEmbedding,
      where: is_nil(e.vector_protocol) and is_nil(e.source_namespace)
    )
  end

  defp insert_legacy_changeset(repo, changeset, agent_id, content_hash) do
    repo.insert(changeset,
      on_conflict: legacy_conflict_query(),
      conflict_target: [:agent_id, :content_hash],
      returning: true
    )
  rescue
    error in Ecto.StaleEntryError ->
      if protected_vector_hash?(repo, agent_id, content_hash) do
        {:error, :protected_vector_row}
      else
        reraise(error, __STACKTRACE__)
      end

    error ->
      if legacy_id_conflict_exception?(error) do
        {:error, :legacy_embedding_id_conflict}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp legacy_id_conflict_changeset?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:id, {_message, metadata}} ->
        Keyword.get(metadata, :constraint) == :unique and
          to_string(Keyword.get(metadata, :constraint_name)) in @legacy_id_constraints

      _other ->
        false
    end)
  end

  defp legacy_id_conflict_exception?(%Ecto.ConstraintError{
         type: :unique,
         constraint: constraint
       })
       when constraint in @legacy_id_constraints,
       do: true

  defp legacy_id_conflict_exception?(%Postgrex.Error{
         postgres: %{code: :unique_violation, constraint: "memory_embeddings_pkey"}
       }),
       do: true

  defp legacy_id_conflict_exception?(%Exqlite.Error{
         message: "UNIQUE constraint failed: memory_embeddings.id"
       }),
       do: true

  defp legacy_id_conflict_exception?(_error), do: false

  defp protected_vector_hash?(repo, agent_id, content_hash) do
    repo.exists?(
      from(e in MemoryEmbedding,
        where: e.agent_id == ^agent_id and e.content_hash == ^content_hash,
        where: not is_nil(e.vector_protocol) or not is_nil(e.source_namespace)
      )
    )
  end

  defp protected_vector_agent_id?(agent_id, id) do
    Repo.exists?(
      from(e in MemoryEmbedding,
        where: e.agent_id == ^agent_id and e.id == ^id,
        where: not is_nil(e.vector_protocol) or not is_nil(e.source_namespace)
      )
    )
  end

  defp protected_vector_global_id?(repo, id) do
    repo.exists?(
      from(e in MemoryEmbedding,
        where: e.id == ^id,
        where: not is_nil(e.vector_protocol) or not is_nil(e.source_namespace)
      )
    )
  end

  defp repo_from_opts([]), do: {:ok, Repo}
  defp repo_from_opts(repo: repo) when is_atom(repo), do: {:ok, repo}
  defp repo_from_opts(_opts), do: {:error, :invalid_options}

  defp validate_batch(agent_id, entries) do
    Enum.reduce_while(entries, {:ok, []}, fn
      {content, embedding, metadata}, {:ok, normalized} ->
        case validate(agent_id, content, embedding, metadata) do
          {:ok, normalized_embedding} ->
            {:cont, {:ok, [{content, normalized_embedding, metadata} | normalized]}}

          {:error, _reason} = error ->
            {:halt, error}
        end

      _invalid, _acc ->
        {:halt, invalid(:invalid_batch)}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  rescue
    _error -> invalid(:invalid_batch)
  catch
    _kind, _reason -> invalid(:invalid_batch)
  end

  defp validate_agent_id(agent_id) do
    case VectorRecord.validate_identity(agent_id, "legacy", "legacy") do
      {:ok, _identity} -> :ok
      {:error, :invalid_vector_identity} -> invalid(:invalid_agent_id)
    end
  end

  defp validate_content(content) when is_binary(content) do
    with true <- String.valid?(content),
         true <- String.trim(content) != "",
         {:ok, _bytes} <- VectorRecord.canonical_payload_bytes(content) do
      :ok
    else
      _invalid -> invalid(:invalid_content)
    end
  end

  defp validate_content(_content), do: invalid(:invalid_content)

  defp validate_metadata(metadata) when is_map(metadata) and not is_struct(metadata) do
    case VectorRecord.canonical_payload_bytes(metadata) do
      {:ok, _bytes} -> :ok
      {:error, _reason} -> invalid(:invalid_metadata)
    end
  end

  defp validate_metadata(_metadata), do: invalid(:invalid_metadata)

  defp validate_requested_id(metadata) do
    case aliased_metadata_value(metadata, :id) do
      :missing ->
        :ok

      {:ok, id} ->
        if valid_text?(id, VectorRecord.limits().id_bytes),
          do: :ok,
          else: invalid(:invalid_id)

      :collision ->
        invalid(:invalid_metadata)
    end
  end

  defp validate_metadata_column(metadata, key, max_bytes) do
    case aliased_metadata_value(metadata, key) do
      :missing ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, value} ->
        case bounded_legacy_text(value, max_bytes) do
          {:ok, _text} -> :ok
          :error -> invalid(legacy_column_error(key))
        end

      :collision ->
        invalid(:invalid_metadata)
    end
  end

  defp normalize_embedding(embedding) do
    case VectorRecord.normalize_vector(embedding) do
      {:ok, normalized_embedding} -> {:ok, normalized_embedding}
      {:error, :invalid_vector} -> invalid(:invalid_embedding)
    end
  end

  defp aliased_metadata_value(metadata, key) do
    string_key = Atom.to_string(key)

    case {Map.fetch(metadata, key), Map.fetch(metadata, string_key)} do
      {:error, :error} -> :missing
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {{:ok, _atom_value}, {:ok, _string_value}} -> :collision
    end
  end

  defp bounded_legacy_text(value, max_bytes)
       when is_binary(value) or is_atom(value) or is_integer(value) or is_float(value) or
              is_boolean(value) do
    text = to_string(value)

    if byte_size(text) <= max_bytes and String.valid?(text), do: {:ok, text}, else: :error
  rescue
    _error -> :error
  end

  defp bounded_legacy_text(_value, _max_bytes), do: :error

  defp valid_text?(value, max_bytes) when is_binary(value) do
    byte_size(value) > 0 and byte_size(value) <= max_bytes and String.valid?(value) and
      String.trim(value) != ""
  end

  defp valid_text?(_value, _max_bytes), do: false

  defp legacy_column_error(:type), do: :invalid_memory_type
  defp legacy_column_error(:source), do: :invalid_source

  defp invalid(reason), do: {:error, {:invalid_legacy_embedding, reason}}

  defp legacy_conflict_query do
    from(e in MemoryEmbedding,
      update: [
        set: [
          embedding: fragment("EXCLUDED.embedding"),
          memory_type: fragment("EXCLUDED.memory_type"),
          source: fragment("EXCLUDED.source"),
          metadata: fragment("EXCLUDED.metadata"),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ],
      where: is_nil(e.vector_protocol) and is_nil(e.source_namespace)
    )
  end

  defp compute_content_hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp safe_to_string(nil), do: nil
  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_to_string(value), do: to_string(value)
end
