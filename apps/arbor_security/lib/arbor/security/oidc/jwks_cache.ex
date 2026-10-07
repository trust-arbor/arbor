defmodule Arbor.Security.OIDC.JwksCache do
  @moduledoc false

  use GenServer

  alias Arbor.Common.OAuth.HttpClient
  alias Arbor.Security.OIDC.Config
  alias Arbor.Security.OIDC.TokenVerifier
  alias Arbor.Security.SupervisedOwner

  @table :arbor_oidc_jwks_cache
  @cleanup_interval_ms :timer.minutes(10)
  @default_ttl_ms :timer.hours(1)
  @max_entries 256
  @max_issuer_bytes 2_048
  @max_client_id_bytes 256
  @max_uri_bytes 4_096
  @max_origins 32
  @call_timeout_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  @spec get_or_fetch(map()) :: {:ok, map()} | {:error, term()}
  def get_or_fetch(provider) when is_map(provider) do
    safe_call({:get_or_fetch, provider, false})
  end

  def get_or_fetch(_provider), do: {:error, :invalid_provider_config}

  @doc false
  @spec refresh(map()) :: {:ok, map()} | {:error, term()}
  def refresh(provider) when is_map(provider) do
    safe_call({:get_or_fetch, provider, true})
  end

  def refresh(_provider), do: {:error, :invalid_provider_config}

  if Mix.env() == :test do
    @doc false
    @spec put_fixture(map(), map(), pos_integer()) :: :ok | {:error, atom()}
    def put_fixture(provider, jwks, ttl_ms \\ 60_000) do
      safe_call({:put_fixture, provider, jwks, ttl_ms})
    end

    @doc false
    @spec delete_fixture(map()) :: :ok
    def delete_fixture(provider) do
      case safe_call({:delete_fixture, provider}) do
        :ok -> :ok
        _ -> :ok
      end
    end
  end

  @impl true
  def init(_opts) do
    case :ets.whereis(@table) do
      :undefined ->
        _table =
          :ets.new(@table, [
            :named_table,
            :protected,
            :set,
            read_concurrency: true
          ])

        schedule_cleanup()
        {:ok, %{fixture_keys: MapSet.new()}}

      _existing ->
        {:stop, :jwks_cache_table_already_exists}
    end
  end

  @impl true
  def handle_call({:get_or_fetch, provider, force?}, _from, state) do
    with {:ok, key} <- cache_key(provider) do
      if force?, do: :ets.delete(@table, key)

      case lookup(key) do
        {:ok, jwks} ->
          {:reply, {:ok, jwks}, state}

        :miss ->
          fetch_owned(provider, key, state)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  if Mix.env() == :test do
    def handle_call({:put_fixture, provider, jwks, ttl_ms}, _from, state) do
      with {:ok, key} <- cache_key(provider),
           :ok <- validate_entry(jwks, ttl_ms),
           :ok <- ensure_capacity(key) do
        insert(key, jwks, ttl_ms)
        {:reply, :ok, %{state | fixture_keys: MapSet.put(state.fixture_keys, key)}}
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end

    def handle_call({:delete_fixture, provider}, _from, state) do
      next =
        case cache_key(provider) do
          {:ok, key} ->
            :ets.delete(@table, key)
            %{state | fixture_keys: MapSet.delete(state.fixture_keys, key)}

          {:error, _reason} ->
            state
        end

      {:reply, :ok, next}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    expired = expired_keys()
    Enum.each(expired, &:ets.delete(@table, &1))
    schedule_cleanup()

    {:noreply,
     %{state | fixture_keys: MapSet.difference(state.fixture_keys, MapSet.new(expired))}}
  end

  defp fetch_owned(provider, key, state) do
    case TokenVerifier.fetch_jwks_uncached(provider) do
      {:ok, jwks} ->
        if cache_authorized?(provider, key, state) do
          case ensure_capacity(key) do
            :ok ->
              insert(key, jwks, @default_ttl_ms)
              {:reply, {:ok, jwks}, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        else
          # Ad-hoc verifier configurations may fetch, but cannot consume or
          # mutate the shared cache used by configured identity providers.
          {:reply, {:ok, jwks}, state}
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  defp lookup(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, jwks, expires_at}] when expires_at > now ->
        {:ok, jwks}

      [{^key, _jwks, _expires_at}] ->
        :ets.delete(@table, key)
        :miss

      [] ->
        :miss
    end
  end

  defp cache_authorized?(_provider, key, %{fixture_keys: fixture_keys}) do
    MapSet.member?(fixture_keys, key) or configured_provider_key?(key)
  end

  defp configured_provider_key?(key) do
    configured = Config.providers() ++ List.wrap(Config.device_flow())

    Enum.any?(configured, fn provider ->
      case cache_key(provider) do
        {:ok, ^key} -> true
        _ -> false
      end
    end)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp cache_key(provider) when is_map(provider) do
    issuer = field(provider, :issuer)
    client_id = field(provider, :client_id)
    endpoints = field(provider, :endpoints)
    trusted_origins = field(provider, :trusted_origins, [])
    http_client = field(provider, :http_client)

    with :ok <- bounded_string(issuer, @max_issuer_bytes),
         :ok <- bounded_string(client_id, @max_client_id_bytes),
         {:ok, jwks_uri} <- normalized_jwks_uri(endpoints),
         {:ok, origins} <- normalized_origins(trusted_origins),
         {:ok, adapter} <- normalized_adapter(http_client),
         {:ok, timeout_ms} <- optional_positive_integer(field(provider, :discovery_timeout_ms)),
         {:ok, max_bytes} <-
           optional_positive_integer(field(provider, :discovery_max_response_bytes)) do
      descriptor = {
        :arbor_oidc_jwks_cache_v2,
        issuer,
        client_id,
        field(provider, :allow_http, false) == true,
        jwks_uri,
        origins,
        adapter,
        timeout_ms,
        max_bytes
      }

      key = :crypto.hash(:sha256, :erlang.term_to_binary(descriptor, [:deterministic]))
      {:ok, key}
    else
      _ -> {:error, :invalid_provider_config}
    end
  end

  defp cache_key(_provider), do: {:error, :invalid_provider_config}

  defp normalized_jwks_uri(nil), do: {:ok, nil}

  defp normalized_jwks_uri(endpoints) when is_map(endpoints) do
    case field(endpoints, :jwks_uri) do
      nil -> {:ok, nil}
      uri -> with :ok <- bounded_string(uri, @max_uri_bytes), do: {:ok, uri}
    end
  end

  defp normalized_jwks_uri(_endpoints), do: {:error, :invalid_provider_config}

  defp normalized_origins(origins) when is_list(origins) and length(origins) <= @max_origins do
    if Enum.all?(origins, &(bounded_string(&1, @max_uri_bytes) == :ok)) do
      {:ok, origins |> Enum.uniq() |> Enum.sort()}
    else
      {:error, :invalid_provider_config}
    end
  end

  defp normalized_origins(_origins), do: {:error, :invalid_provider_config}

  defp normalized_adapter(nil), do: {:ok, HttpClient.adapter()}
  defp normalized_adapter(adapter) when is_atom(adapter), do: {:ok, adapter}
  defp normalized_adapter(_adapter), do: {:error, :invalid_provider_config}

  defp optional_positive_integer(nil), do: {:ok, nil}
  defp optional_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp optional_positive_integer(_value), do: {:error, :invalid_provider_config}

  defp bounded_string(value, maximum)
       when is_binary(value) and byte_size(value) in 1..maximum//1 do
    if String.valid?(value), do: :ok, else: {:error, :invalid_provider_config}
  end

  defp bounded_string(_value, _maximum), do: {:error, :invalid_provider_config}

  if Mix.env() == :test do
    @max_ttl_ms :timer.hours(24)

    defp validate_entry(%{"keys" => keys}, ttl_ms)
         when is_list(keys) and length(keys) in 1..128 and ttl_ms in 1..@max_ttl_ms do
      if Enum.all?(keys, &is_map/1), do: :ok, else: {:error, :invalid_cache_entry}
    end

    defp validate_entry(_jwks, _ttl_ms), do: {:error, :invalid_cache_entry}
  end

  defp ensure_capacity(key) do
    if :ets.member(@table, key) or :ets.info(@table, :size) < @max_entries do
      :ok
    else
      Enum.each(expired_keys(), &:ets.delete(@table, &1))

      if :ets.info(@table, :size) < @max_entries,
        do: :ok,
        else: {:error, :cache_full}
    end
  end

  defp insert(key, jwks, ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    true = :ets.insert(@table, {key, jwks, expires_at})
    :ok
  end

  defp expired_keys do
    now = System.monotonic_time(:millisecond)
    :ets.select(@table, [{{:"$1", :"$2", :"$3"}, [{:"=<", :"$3", now}], [:"$1"]}])
  end

  defp field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp safe_call(request) do
    case SupervisedOwner.registered_child(__MODULE__, :arbor_security, [__MODULE__]) do
      pid when is_pid(pid) -> GenServer.call(pid, request, @call_timeout_ms)
      nil -> {:error, :cache_unavailable}
    end
  catch
    :exit, _reason -> {:error, :cache_unavailable}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
