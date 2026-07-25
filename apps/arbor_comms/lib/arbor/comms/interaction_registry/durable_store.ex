defmodule Arbor.Comms.InteractionRegistry.DurableStore do
  @moduledoc """
  Stateless persistence adapter for durable interaction records.

  The adapter is deliberately not an authority or lifecycle owner. It resolves
  configuration on every operation so code reloads do not retain a stale backend
  or backend process reference. Persistence is reached only through the public
  `Arbor.Persistence` facade; structured values are validated as contract Records.
  """

  alias Arbor.Comms.Config
  alias Arbor.Contracts.Persistence.Record

  @max_key_bytes 256
  @allowed_list_options [:max_items]
  @durability_class :node_restart

  @type availability ::
          {:ok, %{backend: module(), namespace: atom(), durability: :node_restart}}
          | {:error, atom()}

  @doc "Returns whether the configured backend is ready for durable interaction use."
  @spec readiness() :: availability()
  def readiness do
    with {:ok, config} <- validated_config(),
         true <- Arbor.Persistence.supports_compare_and_swap?(config.backend),
         true <- Arbor.Persistence.supports_durability_class?(config.backend),
         {:ok, @durability_class} <-
           safe_call(fn ->
             Arbor.Persistence.durability_class(
               config.namespace,
               config.backend,
               config.backend_opts
             )
           end) do
      {:ok,
       %{
         backend: config.backend,
         namespace: config.namespace,
         durability: @durability_class
       }}
    else
      false -> {:error, :unsupported}
      {:ok, {:error, _reason}} -> {:error, :unavailable}
      {:ok, _other} -> {:error, :unsupported}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Alias for `readiness/0` used by callers that model this as availability."
  @spec availability() :: availability()
  def availability, do: readiness()

  @doc "Returns true only when CAS and code-attested node-restart durability are ready."
  @spec ready?() :: boolean()
  def ready?, do: match?({:ok, _}, readiness())

  @doc "Returns true only when the durable interaction backend is available."
  @spec available?() :: boolean()
  def available?, do: ready?()

  @doc "Admit an external request key exactly once and return its stored Record."
  @spec insert_once(String.t(), map(), keyword()) :: {:ok, Record.t()} | {:error, atom()}
  def insert_once(request_key, data, opts \\ []) do
    with :ok <- validate_options(opts, []),
         :ok <- validate_key(request_key),
         {:ok, config} <- ready_config(),
         :ok <- validate_data(data, config.max_data_bytes),
         record = Record.new(request_key, data),
         result <-
           safe_call(fn ->
             Arbor.Persistence.compare_and_swap(
               config.namespace,
               config.backend,
               request_key,
               :not_found,
               record,
               config.backend_opts
             )
           end) do
      normalize_record_result(result, request_key, config.max_data_bytes)
    end
  end

  @doc "Read a durable interaction Record by its external request key."
  @spec get(String.t(), keyword()) :: {:ok, Record.t()} | {:error, atom()}
  def get(request_key, opts \\ []) do
    with :ok <- validate_options(opts, []),
         :ok <- validate_key(request_key),
         {:ok, config} <- ready_config(),
         result <-
           safe_call(fn ->
             Arbor.Persistence.get(
               config.namespace,
               config.backend,
               request_key,
               config.backend_opts
             )
           end) do
      normalize_get_result(result, request_key, config.max_data_bytes)
    end
  end

  @doc "Replace a Record only when its exact generation and revision still match."
  @spec compare_and_swap(String.t(), Record.t(), Record.t(), keyword()) ::
          {:ok, Record.t()} | {:error, atom()}
  def compare_and_swap(request_key, expected, replacement, opts \\ []) do
    with :ok <- validate_options(opts, []),
         :ok <- validate_key(request_key),
         {:ok, config} <- ready_config(),
         :ok <- validate_record(request_key, expected, config.max_data_bytes),
         :ok <- validate_record(request_key, replacement, config.max_data_bytes),
         result <-
           safe_call(fn ->
             Arbor.Persistence.compare_and_swap(
               config.namespace,
               config.backend,
               request_key,
               {:value, expected},
               replacement,
               config.backend_opts
             )
           end) do
      normalize_record_result(result, request_key, config.max_data_bytes)
    end
  end

  @doc "Update a Record's data with exact generation/revision CAS fencing."
  @spec update(Record.t(), map(), keyword()) :: {:ok, Record.t()} | {:error, atom()}
  def update(expected, data, opts \\ [])

  def update(%Record{} = expected, data, opts) do
    with :ok <- validate_options(opts, []),
         replacement = Record.update(expected, data),
         result <- compare_and_swap(expected.key, expected, replacement, opts) do
      result
    end
  end

  def update(_expected, _data, _opts), do: {:error, :malformed_record}

  @doc "List durable interaction request keys, failing closed if the bound is exceeded."
  @spec list(keyword()) :: {:ok, [String.t()]} | {:error, atom()}
  def list(opts \\ []) do
    with {:ok, config} <- ready_config(),
         {:ok, list_opts} <- normalize_list_options(opts, config.max_items),
         result <-
           safe_call(fn ->
             Arbor.Persistence.list(config.namespace, config.backend, config.backend_opts)
           end) do
      normalize_inventory_result(result, list_opts.max_items)
    end
  end

  @doc "Alias for `list/1` that names the bounded inventory operation explicitly."
  @spec inventory(keyword()) :: {:ok, [String.t()]} | {:error, atom()}
  def inventory(opts \\ []), do: list(opts)

  @doc "Alias for `compare_and_swap/4`."
  @spec cas(String.t(), Record.t(), Record.t(), keyword()) ::
          {:ok, Record.t()} | {:error, atom()}
  def cas(request_key, expected, replacement, opts \\ []),
    do: compare_and_swap(request_key, expected, replacement, opts)

  defp ready_config do
    case readiness() do
      {:ok, _} -> validated_config()
      {:error, reason} -> {:error, reason}
    end
  end

  defp validated_config do
    backend = Config.durable_interaction_store_backend()
    namespace = Config.durable_interaction_store_namespace()
    backend_opts = Config.durable_interaction_store_opts()
    max_data_bytes = Config.durable_interaction_store_max_data_bytes()
    max_items = Config.durable_interaction_store_max_items()

    cond do
      is_nil(backend) ->
        {:error, :disabled}

      not valid_backend_module?(backend) ->
        {:error, :invalid_backend}

      not valid_namespace?(namespace) ->
        {:error, :invalid_namespace}

      not valid_backend_opts?(backend_opts) ->
        {:error, :invalid_options}

      not valid_positive_integer?(max_data_bytes) ->
        {:error, :invalid_options}

      not valid_positive_integer?(max_items) ->
        {:error, :invalid_options}

      not function_exported?(backend, :get, 2) ->
        {:error, :unsupported}

      not function_exported?(backend, :list, 1) ->
        {:error, :unsupported}

      true ->
        {:ok,
         %{
           backend: backend,
           namespace: namespace,
           backend_opts: backend_opts,
           max_data_bytes: max_data_bytes,
           max_items: max_items
         }}
    end
  end

  defp normalize_list_options(opts, configured_max_items) do
    with :ok <- validate_options(opts, @allowed_list_options),
         max_items = Keyword.get(opts, :max_items, Config.durable_interaction_store_max_items()),
         true <- valid_positive_integer?(max_items),
         true <- max_items <= configured_max_items do
      {:ok, %{max_items: max_items}}
    else
      false -> {:error, :invalid_options}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_record_result({:ok, stored}, request_key, max_data_bytes),
    do: normalize_stored_record(stored, request_key, max_data_bytes)

  defp normalize_record_result({:error, :conflict}, _request_key, _max_data_bytes),
    do: {:error, :conflict}

  defp normalize_record_result({:error, :unsupported}, _request_key, _max_data_bytes),
    do: {:error, :unsupported}

  defp normalize_record_result({:error, _reason}, _request_key, _max_data_bytes),
    do: {:error, :unavailable}

  defp normalize_record_result(_result, _request_key, _max_data_bytes), do: {:error, :unavailable}

  defp normalize_get_result({:ok, stored}, request_key, max_data_bytes),
    do: normalize_stored_record(stored, request_key, max_data_bytes)

  defp normalize_get_result({:error, :not_found}, _request_key, _max_data_bytes),
    do: {:error, :not_found}

  defp normalize_get_result({:error, _reason}, _request_key, _max_data_bytes),
    do: {:error, :unavailable}

  defp normalize_get_result(_result, _request_key, _max_data_bytes), do: {:error, :unavailable}

  defp normalize_stored_record(%Record{} = record, request_key, max_data_bytes) do
    case validate_record(request_key, record, max_data_bytes) do
      :ok -> {:ok, record}
      {:error, _} -> {:error, :malformed_record}
    end
  end

  defp normalize_stored_record(_record, _request_key, _max_data_bytes),
    do: {:error, :malformed_record}

  defp normalize_inventory_result({:ok, keys}, max_items) when is_list(keys) do
    cond do
      length(keys) > max_items -> {:error, :inventory_too_large}
      not Enum.all?(keys, &valid_key?/1) -> {:error, :malformed_inventory}
      length(keys) != length(Enum.uniq(keys)) -> {:error, :malformed_inventory}
      true -> {:ok, keys}
    end
  end

  defp normalize_inventory_result({:error, _reason}, _max_items), do: {:error, :unavailable}
  defp normalize_inventory_result(_result, _max_items), do: {:error, :malformed_inventory}

  defp validate_record(
         request_key,
         %Record{
           id: id,
           key: key,
           data: data,
           metadata: metadata,
           generation: generation,
           revision: revision,
           inserted_at: inserted_at,
           updated_at: updated_at
         },
         max_data_bytes
       ) do
    with :ok <- validate_key(request_key),
         true <- key == request_key,
         true <- is_binary(id) and byte_size(id) > 0,
         true <- valid_non_negative_integer?(generation),
         true <- valid_non_negative_integer?(revision),
         true <- valid_datetime?(inserted_at),
         true <- valid_datetime?(updated_at),
         :ok <- validate_data(data, max_data_bytes),
         :ok <- validate_metadata(metadata) do
      :ok
    else
      false -> {:error, :malformed_record}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_record(_request_key, _record, _max_data_bytes), do: {:error, :malformed_record}

  defp validate_data(data, max_data_bytes) when is_map(data) and is_integer(max_data_bytes) do
    with true <- json_clean?(data),
         {:ok, encoded} <- safe_json_encode(data) do
      if byte_size(encoded) <= max_data_bytes, do: :ok, else: {:error, :data_too_large}
    else
      false -> {:error, :invalid_data}
      {:error, _reason} -> {:error, :invalid_data}
    end
  end

  defp validate_data(_data, _max_data_bytes), do: {:error, :invalid_data}

  defp validate_metadata(metadata) when is_map(metadata) do
    with true <- json_clean?(metadata),
         {:ok, _encoded} <- safe_json_encode(metadata) do
      :ok
    else
      _ -> {:error, :invalid_metadata}
    end
  end

  defp validate_metadata(_metadata), do: {:error, :invalid_metadata}

  defp json_clean?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_clean?(nested) end)
  end

  defp json_clean?(value) when is_list(value), do: Enum.all?(value, &json_clean?/1)
  defp json_clean?(value) when is_binary(value) or is_boolean(value) or is_nil(value), do: true
  defp json_clean?(value) when is_integer(value), do: true
  defp json_clean?(value) when is_float(value), do: true
  defp json_clean?(_value), do: false

  defp safe_json_encode(data) do
    case Jason.encode(data) do
      {:ok, encoded} when is_binary(encoded) -> {:ok, encoded}
      _ -> {:error, :invalid_data}
    end
  rescue
    _ -> {:error, :invalid_data}
  end

  defp validate_options(opts, allowed) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) -> {:error, :invalid_options}
      true -> validate_keyword_options(opts, allowed)
    end
  end

  defp validate_options(_opts, _allowed), do: {:error, :invalid_options}

  defp validate_keyword_options(opts, allowed) do
    keys = Keyword.keys(opts)

    cond do
      length(keys) != length(Enum.uniq(keys)) -> {:error, :invalid_options}
      Enum.any?(keys, &(&1 not in allowed)) -> {:error, :invalid_options}
      true -> :ok
    end
  end

  defp valid_backend_module?(backend) when is_atom(backend),
    do: Code.ensure_loaded?(backend)

  defp valid_backend_module?(_backend), do: false

  defp valid_namespace?(namespace), do: is_atom(namespace) and not is_nil(namespace)

  defp valid_backend_opts?(opts) when is_list(opts) do
    Keyword.keyword?(opts) and
      length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
      :name not in Keyword.keys(opts)
  end

  defp valid_backend_opts?(_opts), do: false

  defp valid_key?(key), do: validate_key(key) == :ok

  defp validate_key(key)
       when is_binary(key) and byte_size(key) > 0 and byte_size(key) <= @max_key_bytes do
    if String.valid?(key), do: :ok, else: {:error, :invalid_key}
  end

  defp validate_key(_key), do: {:error, :invalid_key}

  defp valid_positive_integer?(value), do: is_integer(value) and value > 0
  defp valid_non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp valid_datetime?(nil), do: true
  defp valid_datetime?(%DateTime{}), do: true
  defp valid_datetime?(_value), do: false

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end
end
