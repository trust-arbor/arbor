defmodule Arbor.AI.ProviderModelCatalogStore do
  @moduledoc """
  Exact-route, AI-owned cache of currently validated `ProviderModelCatalog` evidence.

  Owns at most one contract-valid catalog per exact OAuth route (`openai_oauth`,
  `xai_oauth`). Never holds tokens, account IDs, credential paths, raw provider
  bodies, or free-form provider text.

  ## Guarantees

  * Writes re-validate through `ProviderModelCatalog.new/1` before mutation.
  * Rejected or malformed puts leave the last valid catalog untouched.
  * Process unavailability (`{:error, :unavailable}`) is distinct from an empty
    cache (`{:error, :miss}` / empty snapshot).
  * Supervised only — callers must not lazy-start this process.
  * In-memory only; a restart yields an empty cache (no durable recovery in this
    slice). Network and credential work stay outside this module.

  ## Mutating call timeouts (load-bearing)

  Side-effecting `put` / `clear` MUST NOT use a finite `GenServer.call` timeout.
  A timed-out put is an indeterminate commit: the store can accept the catalog
  after the caller has already reported `:unavailable`. This process only
  performs bounded in-memory validation, so `:infinity` is unambiguous.
  Read-only `fetch` / `snapshot` remain bounded.
  """

  use GenServer

  alias Arbor.Contracts.LLM.ProviderModelCatalog

  @routes ~w(openai_oauth xai_oauth)
  @max_routes 2
  # Side-effecting put/clear: never finite (reply/commit must stay coupled).
  @mutate_call_timeout :infinity
  @read_timeout_ms 500

  defstruct routes: %{}

  @type public_catalog :: map()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc false
  def child_spec(opts) do
    opts = if is_list(opts), do: opts, else: []
    id = Keyword.get(opts, :name, __MODULE__)

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Synchronously publish one contract-valid catalog for its exact route.

  Replaces any prior valid catalog for that route. Rejected writes do not erase
  or replace the last valid entry.

  Uses an infinite GenServer call timeout so a successful in-process commit is
  never reported as `:unavailable` after the fact.
  """
  @spec put_sync(ProviderModelCatalog.t() | map() | keyword()) ::
          :ok | {:error, :rejected | :unavailable}
  def put_sync(catalog) do
    case admit_catalog(catalog) do
      {:ok, valid} ->
        call_store({:put, valid}, @mutate_call_timeout)

      :error ->
        {:error, :rejected}
    end
  rescue
    _ -> {:error, :rejected}
  catch
    _, _ -> {:error, :rejected}
  end

  @doc """
  Synchronously fetch the currently cached catalog for one exact OAuth route.

  Returns:
  * `{:ok, catalog}` — contract-valid cached entry
  * `{:error, :miss}` — store up, no entry for route
  * `{:error, :unavailable}` — store process missing or not responding
  * `{:error, :rejected}` — route identity rejected (alias / non-OAuth)
  * `{:error, :malformed}` — stored slot fails re-validation (state preserved)
  """
  @spec fetch_sync(atom() | String.t()) ::
          {:ok, ProviderModelCatalog.t()}
          | {:error, :miss | :unavailable | :rejected | :malformed}
  def fetch_sync(route) do
    case admit_route(route) do
      {:ok, route} ->
        case call_store({:fetch, route}, @read_timeout_ms) do
          {:ok, %ProviderModelCatalog{} = catalog} -> {:ok, catalog}
          {:error, :miss} -> {:error, :miss}
          {:error, :malformed} -> {:error, :malformed}
          {:error, :unavailable} -> {:error, :unavailable}
          {:error, :rejected} -> {:error, :rejected}
          _ -> {:error, :unavailable}
        end

      :error ->
        {:error, :rejected}
    end
  rescue
    _ -> {:error, :rejected}
  catch
    _, _ -> {:error, :rejected}
  end

  @doc """
  Bounded snapshot of currently cached catalogs keyed by exact route string.

  Values are JSON-clean maps from `ProviderModelCatalog.to_map/1`.
  """
  @spec snapshot_sync(keyword()) ::
          {:ok, %{optional(String.t()) => public_catalog()}}
          | {:error, :unavailable | :malformed}
  def snapshot_sync(opts \\ [])

  def snapshot_sync(opts) when is_list(opts) do
    case call_store(:snapshot, @read_timeout_ms) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, :malformed} -> {:error, :malformed}
      _ -> {:error, :unavailable}
    end
  end

  def snapshot_sync(_opts), do: {:error, :malformed}

  @doc """
  Synchronously clear one exact route (tests / recovery). No-op when store is down.

  Uses an infinite GenServer call timeout so clear commit and reply stay coupled.
  """
  @spec clear_sync(atom() | String.t()) :: :ok
  def clear_sync(route) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        case admit_route(route) do
          {:ok, route} ->
            try do
              GenServer.call(pid, {:clear, route}, @mutate_call_timeout)
            catch
              :exit, _ -> :ok
            end

          :error ->
            :ok
        end

      _ ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{routes: %{}}}
  end

  @impl true
  def handle_call({:put, %ProviderModelCatalog{} = catalog}, _from, state) do
    # Re-validate at the write boundary so corrupt callers cannot inject state.
    case revalidate(catalog) do
      {:ok, valid} ->
        if map_size(state.routes) >= @max_routes and not Map.has_key?(state.routes, valid.route) do
          {:reply, {:error, :rejected}, state}
        else
          {:reply, :ok, %{state | routes: Map.put(state.routes, valid.route, valid)}}
        end

      :error ->
        # Last-good preservation: never erase on rejected write.
        {:reply, {:error, :rejected}, state}
    end
  end

  def handle_call({:fetch, route}, _from, state) when is_binary(route) do
    case Map.fetch(state.routes, route) do
      :error ->
        {:reply, {:error, :miss}, state}

      {:ok, entry} ->
        case revalidate(entry) do
          {:ok, valid} ->
            {:reply, {:ok, valid}, state}

          :error ->
            # Distinguish corrupt slots from empty; do not silently erase.
            {:reply, {:error, :malformed}, state}
        end
    end
  end

  def handle_call(:snapshot, _from, state) do
    case build_snapshot(state.routes) do
      {:ok, snap} -> {:reply, {:ok, snap}, state}
      {:error, :malformed} -> {:reply, {:error, :malformed}, state}
    end
  end

  def handle_call({:clear, route}, _from, state) when is_binary(route) do
    {:reply, :ok, %{state | routes: Map.delete(state.routes, route)}}
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp call_store(message, timeout) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          try do
            GenServer.call(pid, message, timeout)
          catch
            :exit, _ -> {:error, :unavailable}
          end
        else
          {:error, :unavailable}
        end

      _ ->
        {:error, :unavailable}
    end
  end

  defp build_snapshot(routes) when is_map(routes) do
    Enum.reduce_while(routes, {:ok, %{}}, fn {route_key, entry}, {:ok, acc} ->
      case revalidate(entry) do
        {:ok, %ProviderModelCatalog{route: route} = valid} when route == route_key ->
          case ProviderModelCatalog.to_map(valid) do
            map when is_map(map) ->
              {:cont, {:ok, Map.put(acc, route, map)}}

            _ ->
              {:halt, {:error, :malformed}}
          end

        _ ->
          {:halt, {:error, :malformed}}
      end
    end)
  end

  defp build_snapshot(_), do: {:error, :malformed}

  defp admit_catalog(%ProviderModelCatalog{} = catalog), do: revalidate(catalog)

  defp admit_catalog(attrs) when is_map(attrs) or is_list(attrs) do
    case ProviderModelCatalog.new(attrs) do
      {:ok, catalog} -> admit_route_catalog(catalog)
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp admit_catalog(_), do: :error

  defp revalidate(%ProviderModelCatalog{} = catalog) do
    case ProviderModelCatalog.new(ProviderModelCatalog.to_map(catalog)) do
      {:ok, valid} -> admit_route_catalog(valid)
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp revalidate(attrs) when is_map(attrs) or is_list(attrs) do
    case ProviderModelCatalog.new(attrs) do
      {:ok, valid} -> admit_route_catalog(valid)
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp revalidate(_), do: :error

  defp admit_route_catalog(%ProviderModelCatalog{route: route} = catalog)
       when route in @routes do
    {:ok, catalog}
  end

  defp admit_route_catalog(_), do: :error

  defp admit_route(route) when route in @routes, do: {:ok, route}
  defp admit_route(:openai_oauth), do: {:ok, "openai_oauth"}
  defp admit_route(:xai_oauth), do: {:ok, "xai_oauth"}
  defp admit_route(_), do: :error
end
