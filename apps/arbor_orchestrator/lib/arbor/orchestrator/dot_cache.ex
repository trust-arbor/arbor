defmodule Arbor.Orchestrator.DotCache do
  @moduledoc """
  ETS-backed cache for parsed DOT graphs.

  Avoids redundant parsing of identical DOT source strings by caching
  the parsed `Graph` keyed on the SHA-256 hash of the source.

  Eviction: LRU-style — when the cache exceeds `max_entries`, the oldest
  entry (by insertion time) is evicted.
  """

  use GenServer

  @table :arbor_orchestrator_dot_cache
  @default_max_entries 100

  # ── Public API ──

  @doc "Look up a cached graph by source hash."
  @spec get(String.t()) :: {:ok, Arbor.Orchestrator.Graph.t()} | :miss
  def get(source_hash) do
    case :ets.lookup(@table, source_hash) do
      [{^source_hash, graph, _inserted_at}] -> {:ok, graph}
      [] -> :miss
    end
  end

  @doc "Cache a parsed graph keyed by source hash."
  @spec put(String.t(), Arbor.Orchestrator.Graph.t()) :: :ok
  def put(source_hash, graph) do
    GenServer.call(__MODULE__, {:put, source_hash, graph})
  end

  @doc "Remove a specific entry from the cache."
  @spec invalidate(String.t()) :: :ok
  def invalidate(source_hash) do
    :ets.delete(@table, source_hash)
    :ok
  end

  @doc "Clear all cached entries."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Return cache statistics."
  @spec stats() :: %{size: non_neg_integer(), max: non_neg_integer()}
  def stats do
    max = Application.get_env(:arbor_orchestrator, :dot_cache_max_entries, @default_max_entries)
    %{size: :ets.info(@table, :size), max: max}
  end

  @doc "Compute the cache key for a DOT source string."
  @spec cache_key(String.t()) :: String.t()
  def cache_key(source) when is_binary(source) do
    :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
  end

  # ── GenServer ──

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true
      ])

    max = Keyword.get(opts, :max_entries, @default_max_entries)
    {:ok, %{table: table, max_entries: max}}
  end

  @impl true
  def handle_call({:put, source_hash, graph}, _from, state) do
    now = System.monotonic_time(:millisecond)
    :ets.insert(@table, {source_hash, graph, now})
    maybe_evict(state.max_entries)
    {:reply, :ok, state}
  end

  # ── Private ──

  defp maybe_evict(max_entries) do
    size = :ets.info(@table, :size)

    if size > max_entries do
      # Find and delete the oldest entry
      oldest =
        :ets.foldl(
          fn {key, _graph, inserted_at}, acc ->
            case acc do
              nil -> {key, inserted_at}
              {_k, t} when inserted_at < t -> {key, inserted_at}
              _ -> acc
            end
          end,
          nil,
          @table
        )

      case oldest do
        {key, _} -> :ets.delete(@table, key)
        nil -> :ok
      end
    end
  end
end
