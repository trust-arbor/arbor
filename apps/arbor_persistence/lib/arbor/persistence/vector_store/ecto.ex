defmodule Arbor.Persistence.VectorStore.Ecto do
  @moduledoc """
  Ecto-backed durable vector store.

  Mutations and their exact receipts commit in one transaction. Logical row
  identity is `{agent_id, source_namespace, source_key}`; the legacy embedding
  columns are compatibility mirrors and are not provenance authority.
  """

  @behaviour Arbor.Persistence.VectorStore

  import Ecto.Query

  alias Arbor.Contracts.Persistence.{VectorOperation, VectorReceipt, VectorRecord}
  alias __MODULE__.{Codec, OperationReceiptRow, VectorRow}

  @encoding Atom.to_string(VectorRecord.encoding())
  @repo_config_key :vector_store_repo
  @known_transaction_errors [:backend_failure, :conflict, :indeterminate]

  @impl true
  def execute(%VectorOperation{} = operation, []) do
    with {:ok, ^operation} <- VectorOperation.validate(operation),
         {:ok, repo} <- configured_repo() do
      run_transaction(repo, operation.fingerprint, fn ->
        execute_in_transaction(repo, operation)
      end)
    else
      _invalid -> {:error, :backend_failure}
    end
  rescue
    _error -> {:error, :indeterminate}
  catch
    _kind, _reason -> {:error, :indeterminate}
  end

  def execute(_operation, _opts), do: {:error, :backend_failure}

  @impl true
  def reconcile(%VectorOperation{} = operation, []) do
    with {:ok, ^operation} <- VectorOperation.validate(operation),
         {:ok, repo} <- configured_repo() do
      run_transaction(repo, operation.fingerprint, fn -> read_ledger(repo, operation) end)
    else
      _invalid -> {:error, :backend_failure}
    end
  rescue
    _error -> {:error, :indeterminate}
  catch
    _kind, _reason -> {:error, :indeterminate}
  end

  def reconcile(_operation, _opts), do: {:error, :backend_failure}

  @impl true
  def fetch(
        {agent_id, source_namespace, source_key} = identity,
        include_tombstone: include_tombstone
      )
      when is_boolean(include_tombstone) do
    with {:ok, ^identity} <-
           VectorRecord.validate_identity(agent_id, source_namespace, source_key),
         {:ok, repo} <- configured_repo(),
         %VectorRow{} = row <- repo.one(identity_query(identity)),
         {:ok, record} <- row_to_record(row, repo),
         true <- include_tombstone or not record.tombstone do
      {:ok, record}
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
      {:error, :malformed_row} -> {:error, :backend_failure}
      _invalid -> {:error, :backend_failure}
    end
  rescue
    _error -> {:error, :backend_failure}
  catch
    _kind, _reason -> {:error, :backend_failure}
  end

  def fetch(_identity, _opts), do: {:error, :backend_failure}

  @impl true
  def list(
        agent_id,
        category: category,
        source_namespace: source_namespace,
        include_tombstones: include_tombstones,
        limit: limit
      )
      when is_binary(agent_id) and is_boolean(include_tombstones) and is_integer(limit) and
             limit > 0 and limit <= 1_000 do
    with {:ok, repo} <- configured_repo() do
      query =
        from(row in VectorRow,
          where: row.agent_id == ^agent_id,
          where: not is_nil(row.source_namespace),
          order_by: [asc: row.source_namespace, asc: row.source_key, asc: row.id],
          limit: ^limit
        )
        |> maybe_filter_category(category)
        |> maybe_filter_namespace(source_namespace)
        |> maybe_filter_tombstones(include_tombstones)

      query
      |> repo.all()
      |> decode_rows(repo, [])
    else
      _invalid -> {:error, :backend_failure}
    end
  rescue
    _error -> {:error, :backend_failure}
  catch
    _kind, _reason -> {:error, :backend_failure}
  end

  def list(_agent_id, _opts), do: {:error, :backend_failure}

  @impl true
  def search(_agent_id, _vector, _opts), do: {:error, :unsupported}

  defp execute_in_transaction(repo, operation) do
    case read_ledger(repo, operation) do
      {:ok, %VectorReceipt{} = receipt} ->
        {:ok, receipt}

      {:ok, :absent} ->
        with {:ok, receipt} <- apply_operation(repo, operation),
             :ok <- insert_ledger(repo, operation, receipt) do
          {:ok, receipt}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_operation(repo, %VectorOperation{kind: :batch} = operation) do
    with {:ok, receipts} <- apply_batch_operations(repo, operation.operations, []),
         {:ok, receipt} <- VectorReceipt.new(%{operation: operation, receipts: receipts}) do
      {:ok, receipt}
    else
      {:error, reason} when reason in @known_transaction_errors -> {:error, reason}
      _invalid -> {:error, :backend_failure}
    end
  end

  defp apply_operation(repo, %VectorOperation{} = operation) do
    with {:ok, result} <- result_record(operation),
         :ok <- persist_result(repo, operation, result),
         {:ok, receipt} <- VectorReceipt.new(%{operation: operation, record: result}) do
      {:ok, receipt}
    else
      {:error, reason} when reason in @known_transaction_errors -> {:error, reason}
      _invalid -> {:error, :backend_failure}
    end
  end

  defp apply_batch_operations(_repo, [], receipts), do: {:ok, Enum.reverse(receipts)}

  defp apply_batch_operations(repo, [operation | rest], receipts) do
    case apply_operation(repo, operation) do
      {:ok, receipt} -> apply_batch_operations(repo, rest, [receipt | receipts])
      {:error, reason} -> {:error, reason}
    end
  end

  defp result_record(%VectorOperation{} = operation) do
    fence =
      case operation.kind do
        :insert ->
          %{generation: 1, revision: 1, tombstone: false}

        :update ->
          %{
            generation: operation.expected_generation,
            revision: operation.expected_revision + 1,
            tombstone: false
          }

        :delete ->
          %{
            generation: operation.expected_generation,
            revision: operation.expected_revision + 1,
            tombstone: true
          }

        :reinsert ->
          %{generation: operation.expected_generation + 1, revision: 1, tombstone: false}
      end

    operation.record
    |> Map.from_struct()
    |> Map.merge(fence)
    |> VectorRecord.new()
  end

  defp persist_result(repo, %VectorOperation{kind: :insert}, result) do
    with {:ok, attrs} <- insert_attrs(result, repo),
         {1, _rows} <- repo.insert_all(VectorRow, [attrs], on_conflict: :nothing),
         {:ok, ^result} <- load_record(repo, VectorRecord.identity(result)) do
      :ok
    else
      {0, _rows} -> {:error, :conflict}
      {:error, :malformed_row} -> {:error, :indeterminate}
      _invalid -> {:error, :backend_failure}
    end
  end

  defp persist_result(repo, %VectorOperation{} = operation, result) do
    expected_tombstone = operation.kind == :reinsert

    query =
      from(row in VectorRow,
        where: row.agent_id == ^operation.record.agent_id,
        where: row.source_namespace == ^operation.record.source_namespace,
        where: row.source_key == ^operation.record.source_key,
        where: row.id == ^operation.record.id,
        where: row.generation == ^operation.expected_generation,
        where: row.revision == ^operation.expected_revision,
        where: row.tombstone == ^expected_tombstone
      )

    with {:ok, attrs} <- update_attrs(result, repo),
         {1, _rows} <- repo.update_all(query, set: Map.to_list(attrs)),
         {:ok, ^result} <- load_record(repo, VectorRecord.identity(result)) do
      :ok
    else
      {0, _rows} -> {:error, :conflict}
      {:error, :malformed_row} -> {:error, :indeterminate}
      _invalid -> {:error, :backend_failure}
    end
  end

  defp insert_attrs(record, repo) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, attrs} <- value_attrs(record, repo) do
      {:ok,
       Map.merge(attrs, %{
         id: record.id,
         agent_id: record.agent_id,
         source_namespace: record.source_namespace,
         source_key: record.source_key,
         memory_type: nil,
         source: nil,
         metadata: %{},
         inserted_at: now,
         updated_at: now
       })}
    end
  end

  defp update_attrs(record, repo) do
    with {:ok, attrs} <- value_attrs(record, repo) do
      {:ok, Map.put(attrs, :updated_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))}
    end
  end

  defp value_attrs(record, repo) do
    with {:ok, payload_bytes} <- VectorRecord.canonical_payload_bytes(record.payload),
         {:ok, vector_bytes} <- VectorRecord.vector_bytes(record.vector),
         {:ok, stored_vector} <- stored_vector(repo, record.vector) do
      {:ok,
       %{
         content: payload_bytes,
         content_hash: compatibility_hash(record),
         embedding: stored_vector,
         canonical_payload: payload_bytes,
         payload_digest: record.payload_digest,
         vector_768: stored_vector,
         vector_bytes: vector_bytes,
         vector_digest: record.vector_digest,
         model_id: record.model_id,
         dimensions: record.dimensions,
         encoding: @encoding,
         category: record.category,
         generation: record.generation,
         revision: record.revision,
         tombstone: record.tombstone
       }}
    else
      _invalid -> {:error, :backend_failure}
    end
  end

  defp stored_vector(repo, vector) do
    if postgres_repo?(repo) do
      {:ok, Pgvector.new(vector)}
    else
      Jason.encode(vector)
    end
  end

  defp load_record(repo, identity) do
    case repo.one(identity_query(identity)) do
      %VectorRow{} = row -> row_to_record(row, repo)
      nil -> {:error, :malformed_row}
    end
  end

  defp identity_query({agent_id, source_namespace, source_key}) do
    from(row in VectorRow,
      where: row.agent_id == ^agent_id,
      where: row.source_namespace == ^source_namespace,
      where: row.source_key == ^source_key,
      limit: 1
    )
  end

  defp row_to_record(%VectorRow{} = row, repo) do
    with true <- is_binary(row.canonical_payload),
         {:ok, payload} <- Jason.decode(row.canonical_payload),
         {:ok, canonical_payload} <- VectorRecord.canonical_payload_bytes(payload),
         true <- canonical_payload == row.canonical_payload,
         true <- row.content == canonical_payload,
         {:ok, vector} <- Codec.vector_from_bytes(row.vector_bytes),
         {:ok, stored_vector} <- load_stored_vector(repo, row.vector_768),
         {:ok, legacy_vector} <- load_stored_vector(repo, row.embedding),
         true <- stored_vector == vector,
         true <- legacy_vector == vector,
         true <- row.content_hash == compatibility_hash(row),
         {:ok, record} <-
           VectorRecord.new(%{
             id: row.id,
             agent_id: row.agent_id,
             source_namespace: row.source_namespace,
             source_key: row.source_key,
             payload: payload,
             vector: vector,
             payload_digest: row.payload_digest,
             vector_digest: row.vector_digest,
             model_id: row.model_id,
             dimensions: row.dimensions,
             encoding: row.encoding,
             category: row.category,
             generation: row.generation,
             revision: row.revision,
             tombstone: row.tombstone
           }) do
      {:ok, record}
    else
      _invalid -> {:error, :malformed_row}
    end
  end

  defp load_stored_vector(repo, stored) do
    vector =
      if postgres_repo?(repo) do
        Pgvector.to_list(stored)
      else
        case Jason.decode(stored) do
          {:ok, decoded} -> decoded
          _invalid -> :invalid
        end
      end

    case VectorRecord.normalize_vector(vector) do
      {:ok, normalized} -> {:ok, normalized}
      _invalid -> {:error, :malformed_row}
    end
  rescue
    _error -> {:error, :malformed_row}
  end

  defp compatibility_hash(%{
         agent_id: agent_id,
         source_namespace: namespace,
         source_key: key,
         payload_digest: digest
       }) do
    ["arbor_vector_legacy_v1", agent_id, namespace, key, digest]
    |> Enum.map(fn part -> [<<byte_size(part)::unsigned-size(32)>>, part] end)
    |> Codec.digest()
  end

  defp insert_ledger(repo, operation, receipt) do
    with {:ok, operation_json} <- Codec.encode_operation(operation),
         {:ok, receipt_json} <- Codec.encode_receipt(receipt, operation),
         attrs = %{
           operation_fingerprint: operation.fingerprint,
           agent_id: VectorOperation.agent_id(operation),
           operation_kind: Atom.to_string(operation.kind),
           operation_json: operation_json,
           operation_digest: Codec.digest(operation_json),
           receipt_json: receipt_json,
           receipt_digest: Codec.digest(receipt_json),
           inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
         },
         {1, _rows} <- repo.insert_all(OperationReceiptRow, [attrs], on_conflict: :nothing) do
      :ok
    else
      {0, _rows} -> verify_existing_ledger(repo, operation, receipt)
      _invalid -> {:error, :backend_failure}
    end
  end

  defp verify_existing_ledger(repo, operation, receipt) do
    case read_ledger(repo, operation) do
      {:ok, ^receipt} -> :ok
      _missing_or_malformed -> {:error, :indeterminate}
    end
  end

  defp read_ledger(repo, operation) do
    query =
      from(row in OperationReceiptRow,
        where: row.operation_fingerprint == ^operation.fingerprint,
        limit: 1
      )

    case repo.one(query) do
      nil -> {:ok, :absent}
      %OperationReceiptRow{} = row -> decode_ledger(row, operation)
    end
  end

  defp decode_ledger(%OperationReceiptRow{} = row, operation) do
    with true <- row.agent_id == VectorOperation.agent_id(operation),
         true <- row.operation_kind == Atom.to_string(operation.kind),
         true <- row.operation_digest == Codec.digest(row.operation_json),
         true <- row.receipt_digest == Codec.digest(row.receipt_json),
         {:ok, persisted_operation} <- Codec.decode_operation(row.operation_json),
         true <- persisted_operation == operation,
         true <- persisted_operation.fingerprint == row.operation_fingerprint,
         {:ok, receipt} <- Codec.decode_receipt(row.receipt_json, persisted_operation),
         {:ok, ^receipt} <- VectorReceipt.validate_for_operation(receipt, operation) do
      {:ok, receipt}
    else
      _invalid -> {:error, :indeterminate}
    end
  end

  defp run_transaction(repo, operation_fingerprint, callback) do
    options = if sqlite_repo?(repo), do: [mode: :immediate], else: []

    result =
      repo.transaction(
        fn ->
          :ok = lock_operation(repo, operation_fingerprint)

          case callback.() do
            {:ok, value} -> value
            {:error, reason} -> repo.rollback(reason)
          end
        end,
        options
      )

    case result do
      {:ok, value} -> {:ok, value}
      {:error, reason} when reason in @known_transaction_errors -> {:error, reason}
      {:error, _reason} -> {:error, :indeterminate}
    end
  end

  defp lock_operation(repo, fingerprint) do
    if postgres_repo?(repo) do
      repo.query!(
        "SELECT pg_advisory_xact_lock(hashtextextended($1, 20260805))",
        [fingerprint]
      )
    end

    :ok
  end

  defp decode_rows([], _repo, records), do: {:ok, Enum.reverse(records)}

  defp decode_rows([row | rows], repo, records) do
    case row_to_record(row, repo) do
      {:ok, record} -> decode_rows(rows, repo, [record | records])
      {:error, :malformed_row} -> {:error, :backend_failure}
    end
  end

  defp maybe_filter_category(query, nil), do: query
  defp maybe_filter_category(query, category), do: where(query, [row], row.category == ^category)

  defp maybe_filter_namespace(query, nil), do: query

  defp maybe_filter_namespace(query, source_namespace),
    do: where(query, [row], row.source_namespace == ^source_namespace)

  defp maybe_filter_tombstones(query, true), do: query
  defp maybe_filter_tombstones(query, false), do: where(query, [row], row.tombstone == false)

  defp configured_repo do
    case Application.get_env(:arbor_persistence, @repo_config_key, Arbor.Persistence.Repo) do
      repo when is_atom(repo) and not is_nil(repo) -> {:ok, repo}
      _invalid -> {:error, :invalid_config}
    end
  end

  defp postgres_repo?(repo), do: repo.__adapter__() == Ecto.Adapters.Postgres
  defp sqlite_repo?(repo), do: repo.__adapter__() == Ecto.Adapters.SQLite3
end
