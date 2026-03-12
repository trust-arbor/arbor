defmodule Arbor.Common.CapabilityIndex do
  @moduledoc """
  Materialized capability index backed by ETS.

  Stores `CapabilityDescriptor` entries from all registered providers.
  Supports keyword search with trust-tier filtering. Updated at boot
  time by syncing from all providers, and incrementally via `index/1`
  and `remove/1`.

  ## Architecture

  Providers push capability descriptors into this index at registration
  time. Discovery queries hit the ETS table directly — no fan-out to
  registries at query time. This gives O(1) exact lookups and fast
  keyword search.

  ## Trust Filtering

  All search operations accept an optional `:trust_tier` option. When
  provided, only capabilities whose `trust_required` is at or below
  the given tier are returned. This implements "invisible by default" —
  agents never see capabilities they can't use.
  """

  use GenServer

  alias Arbor.Contracts.{CapabilityDescriptor, CapabilityMatch}

  require Logger

  @table :capability_index
  @token_table :capability_index_tokens

  # Trust tier ordering (lowest to highest privilege)
  @trust_order [:new, :provisional, :established, :trusted, :full_partner, :system]

  ## Public API

  @doc """
  Starts the capability index.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Add or update a capability descriptor in the index.
  """
  @spec index(CapabilityDescriptor.t()) :: :ok
  def index(%CapabilityDescriptor{} = descriptor) do
    GenServer.call(__MODULE__, {:index, descriptor})
  end

  @doc """
  Remove a capability from the index by ID.
  """
  @spec remove(String.t()) :: :ok
  def remove(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:remove, id})
  end

  @doc """
  Get a capability descriptor by exact ID.
  """
  @spec get(String.t()) :: {:ok, CapabilityDescriptor.t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case :ets.lookup(@table, id) do
      [{^id, descriptor}] -> {:ok, descriptor}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Search the index by keyword query with optional trust filtering.

  Tokenizes the query and matches against capability name, description,
  and tags. Returns results sorted by relevance score.

  ## Options

  - `:trust_tier` — only return capabilities at or below this tier
  - `:limit` — maximum results (default: 10)
  - `:kind` — filter by capability kind (e.g., `:action`, `:skill`)
  """
  @spec search(String.t(), keyword()) :: [CapabilityMatch.t()]
  def search(query, opts \\ []) do
    trust_tier = Keyword.get(opts, :trust_tier)
    limit = Keyword.get(opts, :limit, 10)
    kind_filter = Keyword.get(opts, :kind)

    query_tokens = tokenize(query)

    if query_tokens == [] do
      []
    else
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, descriptor} ->
        score = score_match(descriptor, query_tokens)
        {descriptor, score}
      end)
      |> Enum.filter(fn {descriptor, score} ->
        score > 0.0 and
          trust_visible?(descriptor.trust_required, trust_tier) and
          kind_matches?(descriptor.kind, kind_filter)
      end)
      |> Enum.sort_by(fn {_d, score} -> score end, :desc)
      |> Enum.take(limit)
      |> Enum.map(fn {descriptor, score} ->
        %CapabilityMatch{descriptor: descriptor, score: score, tier: 1}
      end)
    end
  end

  @doc """
  List all capabilities in the index, optionally filtered.

  ## Options

  - `:trust_tier` — only return capabilities at or below this tier
  - `:kind` — filter by capability kind
  - `:provider` — filter by provider module
  """
  @spec list(keyword()) :: [CapabilityDescriptor.t()]
  def list(opts \\ []) do
    trust_tier = Keyword.get(opts, :trust_tier)
    kind_filter = Keyword.get(opts, :kind)
    provider_filter = Keyword.get(opts, :provider)

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, descriptor} -> descriptor end)
    |> Enum.filter(fn descriptor ->
      trust_visible?(descriptor.trust_required, trust_tier) and
        kind_matches?(descriptor.kind, kind_filter) and
        provider_matches?(descriptor.provider, provider_filter)
    end)
  end

  @doc """
  Sync all descriptors from a provider into the index.

  Calls `provider.list_capabilities(opts)` and indexes each result.
  Returns the count of capabilities indexed.
  """
  @spec sync_provider(module(), keyword()) :: {:ok, non_neg_integer()}
  def sync_provider(provider, opts \\ []) do
    GenServer.call(__MODULE__, {:sync_provider, provider, opts}, 30_000)
  end

  @doc """
  Returns the count of capabilities in the index.
  """
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table, :size)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    tokens = :ets.new(@token_table, [:named_table, :bag, :public, read_concurrency: true])

    providers = Keyword.get(opts, :providers, [])

    # Boot sync from registered providers
    for provider <- providers do
      sync_provider_internal(provider, [])
    end

    {:ok, %{table: table, tokens: tokens, providers: providers}}
  end

  @impl true
  def handle_call({:index, descriptor}, _from, state) do
    do_index(descriptor)
    {:reply, :ok, state}
  end

  def handle_call({:remove, id}, _from, state) do
    :ets.delete(@table, id)
    :ets.delete(@token_table, id)
    {:reply, :ok, state}
  end

  def handle_call({:sync_provider, provider, opts}, _from, state) do
    count = sync_provider_internal(provider, opts)
    {:reply, {:ok, count}, state}
  end

  ## Internal

  defp do_index(descriptor) do
    # Store the descriptor
    :ets.insert(@table, {descriptor.id, descriptor})

    # Update inverted token index
    :ets.delete(@token_table, descriptor.id)
    tokens = build_tokens(descriptor)

    for token <- tokens do
      :ets.insert(@token_table, {descriptor.id, token})
    end
  end

  defp sync_provider_internal(provider, opts) do
    try do
      descriptors = provider.list_capabilities(opts)

      Enum.each(descriptors, &do_index/1)

      length(descriptors)
    rescue
      e ->
        Logger.warning(
          "[CapabilityIndex] Failed to sync provider #{inspect(provider)}: #{Exception.message(e)}"
        )

        0
    end
  end

  defp build_tokens(descriptor) do
    text =
      [
        descriptor.name,
        descriptor.description,
        descriptor.id | descriptor.tags
      ]
      |> List.flatten()
      |> Enum.join(" ")

    tokenize(text)
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.uniq()
  end

  defp score_match(descriptor, query_tokens) do
    descriptor_tokens = build_tokens(descriptor) |> MapSet.new()
    query_set = MapSet.new(query_tokens)

    matched = MapSet.intersection(descriptor_tokens, query_set) |> MapSet.size()
    total = MapSet.size(query_set)

    base_score = if total == 0, do: 0.0, else: matched / total

    # Boost exact name match
    name_lower = String.downcase(descriptor.name)
    query_lower = Enum.join(query_tokens, " ")

    cond do
      name_lower == query_lower -> min(base_score + 0.3, 1.0)
      String.contains?(name_lower, query_lower) -> min(base_score + 0.15, 1.0)
      true -> base_score
    end
  end

  defp trust_visible?(_required, nil), do: true

  defp trust_visible?(required, agent_tier) do
    trust_level(required) <= trust_level(agent_tier)
  end

  defp trust_level(tier) do
    Enum.find_index(@trust_order, &(&1 == tier)) || 0
  end

  defp kind_matches?(_kind, nil), do: true
  defp kind_matches?(kind, filter), do: kind == filter

  defp provider_matches?(_provider, nil), do: true
  defp provider_matches?(provider, filter), do: provider == filter
end
