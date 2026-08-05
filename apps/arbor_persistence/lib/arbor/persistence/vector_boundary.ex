defmodule Arbor.Persistence.VectorBoundary do
  @moduledoc false

  alias Arbor.Contracts.Persistence.{VectorMatch, VectorOperation, VectorReceipt, VectorRecord}
  alias Arbor.Persistence.Config

  @default_list_limit 100
  @max_list_limit 1_000
  @default_search_limit 20
  @max_search_limit 100
  @mutation_errors [:backend_failure, :conflict, :indeterminate, :unsupported]
  @read_errors [:backend_failure, :not_found, :unsupported]
  @collection_errors [:backend_failure, :unsupported]
  @fetch_option_keys [:include_tombstone]
  @list_option_keys [:category, :source_namespace, :include_tombstones, :limit]
  @search_option_keys [:model_id, :dimensions, :encoding, :category, :limit]

  @type vector_error ::
          :backend_failure
          | :conflict
          | :indeterminate
          | :invalid_backend_result
          | :invalid_request
          | :not_found
          | :tenant_mismatch
          | :unsupported

  @spec execute(term(), term(), term()) ::
          {:ok, VectorReceipt.t()} | {:error, vector_error()}
  def execute(agent_id, operation, opts) do
    with {:ok, operation} <- validate_operation_for_agent(agent_id, operation),
         {:ok, %{}} <- normalize_options(opts, []),
         {:ok, backend_result} <-
           dispatch(fn backend -> backend.execute(operation, []) end) do
      validate_mutation_result(backend_result, operation)
    end
  end

  @spec reconcile(term(), term(), term()) ::
          {:ok, VectorReceipt.t()} | {:ok, :absent} | {:error, vector_error()}
  def reconcile(agent_id, operation, opts) do
    with {:ok, operation} <- validate_operation_for_agent(agent_id, operation),
         {:ok, %{}} <- normalize_options(opts, []),
         {:ok, backend_result} <-
           dispatch(fn backend -> backend.reconcile(operation, []) end) do
      validate_reconcile_result(backend_result, operation)
    end
  end

  @spec fetch(term(), term(), term(), term()) ::
          {:ok, VectorRecord.t()} | {:error, vector_error()}
  def fetch(agent_id, source_namespace, source_key, opts) do
    with {:ok, identity} <- validate_identity(agent_id, source_namespace, source_key),
         {:ok, backend_opts} <- normalize_fetch_options(opts),
         {:ok, backend_result} <-
           dispatch(fn backend -> backend.fetch(identity, backend_opts) end) do
      validate_fetch_result(backend_result, identity, backend_opts)
    end
  end

  @spec list(term(), term()) :: {:ok, [VectorRecord.t()]} | {:error, vector_error()}
  def list(agent_id, opts) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, backend_opts} <- normalize_list_options(opts),
         {:ok, backend_result} <-
           dispatch(fn backend -> backend.list(agent_id, backend_opts) end) do
      validate_list_result(backend_result, agent_id, backend_opts)
    end
  end

  @spec search(term(), term(), term()) ::
          {:ok, [VectorMatch.t()]} | {:error, vector_error()}
  def search(agent_id, vector, opts) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, normalized_vector} <- normalize_query_vector(vector),
         {:ok, backend_opts} <- normalize_search_options(opts),
         {:ok, backend_result} <-
           dispatch(fn backend -> backend.search(agent_id, normalized_vector, backend_opts) end) do
      validate_search_result(backend_result, agent_id, backend_opts)
    end
  end

  defp validate_operation_for_agent(agent_id, operation) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, operation} <- VectorOperation.validate(operation),
         true <- VectorOperation.agent_id(operation) == agent_id do
      {:ok, operation}
    else
      false -> {:error, :tenant_mismatch}
      {:error, :invalid_vector_operation} -> {:error, :invalid_request}
      {:error, :invalid_request} = error -> error
    end
  end

  defp validate_identity(agent_id, source_namespace, source_key) do
    case VectorRecord.validate_identity(agent_id, source_namespace, source_key) do
      {:ok, identity} -> {:ok, identity}
      {:error, :invalid_vector_identity} -> {:error, :invalid_request}
    end
  end

  defp validate_agent_id(agent_id) do
    max_bytes = VectorRecord.limits().agent_id_bytes

    if valid_text?(agent_id, max_bytes), do: :ok, else: {:error, :invalid_request}
  end

  defp normalize_query_vector(vector) do
    case VectorRecord.normalize_vector(vector) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, :invalid_vector} -> {:error, :invalid_request}
    end
  end

  defp normalize_fetch_options(opts) do
    with {:ok, values} <- normalize_options(opts, @fetch_option_keys),
         include_tombstone = Map.get(values, :include_tombstone, false),
         true <- is_boolean(include_tombstone) do
      {:ok, [include_tombstone: include_tombstone]}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp normalize_list_options(opts) do
    with {:ok, values} <- normalize_options(opts, @list_option_keys),
         category = Map.get(values, :category),
         source_namespace = Map.get(values, :source_namespace),
         include_tombstones = Map.get(values, :include_tombstones, false),
         limit = Map.get(values, :limit, @default_list_limit),
         true <- valid_optional_text?(category, VectorRecord.limits().category_bytes),
         true <-
           valid_optional_text?(source_namespace, VectorRecord.limits().source_namespace_bytes),
         true <- is_boolean(include_tombstones),
         true <- valid_limit?(limit, @max_list_limit) do
      {:ok,
       [
         category: category,
         source_namespace: source_namespace,
         include_tombstones: include_tombstones,
         limit: limit
       ]}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp normalize_search_options(opts) do
    with {:ok, values} <- normalize_options(opts, @search_option_keys),
         {:ok, model_id} <- Map.fetch(values, :model_id),
         {:ok, dimensions} <- Map.fetch(values, :dimensions),
         {:ok, encoding} <- Map.fetch(values, :encoding),
         {:ok, category} <- Map.fetch(values, :category),
         limit = Map.get(values, :limit, @default_search_limit),
         true <- valid_limit?(limit, @max_search_limit),
         {:ok, {model_id, dimensions, encoding, category}} <-
           VectorRecord.validate_descriptor(model_id, dimensions, encoding, category) do
      {:ok,
       [
         model_id: model_id,
         dimensions: dimensions,
         encoding: encoding,
         category: category,
         limit: limit
       ]}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp normalize_options(opts, allowed_keys) when is_list(opts) do
    collect_options(opts, allowed_keys, %{}, 0)
  end

  defp normalize_options(_opts, _allowed_keys), do: {:error, :invalid_request}

  defp collect_options([], _allowed_keys, values, _count), do: {:ok, values}

  defp collect_options(_remaining, allowed_keys, _values, count)
       when count >= length(allowed_keys),
       do: {:error, :invalid_request}

  defp collect_options([{key, value} | rest], allowed_keys, values, count)
       when is_atom(key) and not is_nil(key) do
    if key in allowed_keys and not Map.has_key?(values, key) do
      collect_options(rest, allowed_keys, Map.put(values, key, value), count + 1)
    else
      {:error, :invalid_request}
    end
  end

  defp collect_options(_improper, _allowed_keys, _values, _count),
    do: {:error, :invalid_request}

  defp validate_mutation_result({:ok, %VectorReceipt{} = receipt}, operation) do
    case VectorReceipt.validate_for_operation(receipt, operation) do
      {:ok, receipt} -> {:ok, receipt}
      {:error, :invalid_vector_receipt} -> {:error, :invalid_backend_result}
    end
  end

  defp validate_mutation_result({:error, reason}, _operation)
       when reason in @mutation_errors,
       do: {:error, reason}

  defp validate_mutation_result({:error, _reason}, _operation), do: {:error, :backend_failure}
  defp validate_mutation_result(_result, _operation), do: {:error, :invalid_backend_result}

  defp validate_reconcile_result({:ok, :absent}, _operation), do: {:ok, :absent}

  defp validate_reconcile_result({:ok, %VectorReceipt{} = receipt}, operation),
    do: validate_mutation_result({:ok, receipt}, operation)

  defp validate_reconcile_result({:error, reason}, _operation)
       when reason in @mutation_errors,
       do: {:error, reason}

  defp validate_reconcile_result({:error, _reason}, _operation), do: {:error, :backend_failure}
  defp validate_reconcile_result(_result, _operation), do: {:error, :invalid_backend_result}

  defp validate_fetch_result({:ok, %VectorRecord{} = record}, identity, opts) do
    include_tombstone = Keyword.fetch!(opts, :include_tombstone)

    with {:ok, record} <- VectorRecord.validate(record),
         true <- VectorRecord.identity(record) == identity,
         true <- include_tombstone or not record.tombstone do
      {:ok, record}
    else
      _invalid -> {:error, :invalid_backend_result}
    end
  end

  defp validate_fetch_result({:error, reason}, _identity, _opts)
       when reason in @read_errors,
       do: {:error, reason}

  defp validate_fetch_result({:error, _reason}, _identity, _opts),
    do: {:error, :backend_failure}

  defp validate_fetch_result(_result, _identity, _opts),
    do: {:error, :invalid_backend_result}

  defp validate_list_result({:ok, records}, agent_id, opts) do
    collect_records(records, agent_id, opts, [], MapSet.new(), 0)
  end

  defp validate_list_result({:error, reason}, _agent_id, _opts)
       when reason in @collection_errors,
       do: {:error, reason}

  defp validate_list_result({:error, _reason}, _agent_id, _opts),
    do: {:error, :backend_failure}

  defp validate_list_result(_result, _agent_id, _opts),
    do: {:error, :invalid_backend_result}

  defp collect_records([], _agent_id, _opts, records, _identities, _count),
    do: {:ok, Enum.reverse(records)}

  defp collect_records(
         [%VectorRecord{} = record | rest],
         agent_id,
         opts,
         records,
         identities,
         count
       ) do
    if count >= opts[:limit] do
      {:error, :invalid_backend_result}
    else
      with {:ok, record} <- VectorRecord.validate(record),
           true <- record.agent_id == agent_id,
           true <- is_nil(opts[:category]) or record.category == opts[:category],
           true <-
             is_nil(opts[:source_namespace]) or
               record.source_namespace == opts[:source_namespace],
           true <- opts[:include_tombstones] or not record.tombstone,
           identity = VectorRecord.identity(record),
           false <- MapSet.member?(identities, identity) do
        collect_records(
          rest,
          agent_id,
          opts,
          [record | records],
          MapSet.put(identities, identity),
          count + 1
        )
      else
        _invalid -> {:error, :invalid_backend_result}
      end
    end
  end

  defp collect_records(_improper, _agent_id, _opts, _records, _identities, _count),
    do: {:error, :invalid_backend_result}

  defp validate_search_result({:ok, matches}, agent_id, opts) do
    collect_matches(matches, agent_id, opts, [], MapSet.new(), 0)
  end

  defp validate_search_result({:error, reason}, _agent_id, _opts)
       when reason in @collection_errors,
       do: {:error, reason}

  defp validate_search_result({:error, _reason}, _agent_id, _opts),
    do: {:error, :backend_failure}

  defp validate_search_result(_result, _agent_id, _opts),
    do: {:error, :invalid_backend_result}

  defp collect_matches([], _agent_id, _opts, matches, _identities, _count),
    do: {:ok, Enum.reverse(matches)}

  defp collect_matches(
         [%VectorMatch{} = match | rest],
         agent_id,
         opts,
         matches,
         identities,
         count
       ) do
    if count >= opts[:limit] do
      {:error, :invalid_backend_result}
    else
      with {:ok, match} <- VectorMatch.validate(match),
           record = match.record,
           true <- record.agent_id == agent_id,
           true <- record.model_id == opts[:model_id],
           true <- record.dimensions == opts[:dimensions],
           true <- record.encoding == opts[:encoding],
           true <- record.category == opts[:category],
           identity = VectorRecord.identity(record),
           false <- MapSet.member?(identities, identity) do
        collect_matches(
          rest,
          agent_id,
          opts,
          [match | matches],
          MapSet.put(identities, identity),
          count + 1
        )
      else
        _invalid -> {:error, :invalid_backend_result}
      end
    end
  end

  defp collect_matches(_improper, _agent_id, _opts, _matches, _identities, _count),
    do: {:error, :invalid_backend_result}

  defp dispatch(callback) do
    with {:ok, backend} <- Config.vector_store_backend() do
      try do
        {:ok, callback.(backend)}
      rescue
        _error -> {:error, :backend_failure}
      catch
        _kind, _reason -> {:error, :backend_failure}
      end
    else
      {:error, :invalid_config} -> {:error, :backend_failure}
    end
  end

  defp valid_optional_text?(nil, _max_bytes), do: true
  defp valid_optional_text?(value, max_bytes), do: valid_text?(value, max_bytes)

  defp valid_text?(value, max_bytes) when is_binary(value) do
    byte_size(value) > 0 and byte_size(value) <= max_bytes and String.valid?(value) and
      String.trim(value) != ""
  end

  defp valid_text?(_value, _max_bytes), do: false

  defp valid_limit?(limit, max), do: is_integer(limit) and limit > 0 and limit <= max
end
