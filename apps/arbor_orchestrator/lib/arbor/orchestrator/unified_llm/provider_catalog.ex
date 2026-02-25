defmodule Arbor.Orchestrator.UnifiedLLM.ProviderCatalog do
  @moduledoc """
  Single source of truth for available LLM providers.

  Discovers providers by querying each adapter's `runtime_contract/0` callback,
  checking whether runtime requirements are met (env vars, CLI tools, HTTP probes),
  and caching results in ETS with a configurable TTL.

  ## Usage

      # All available providers with capabilities
      ProviderCatalog.available()
      # => [{"anthropic", %Capabilities{streaming: true, ...}}, ...]

      # Get a specific provider's contract (for install hints)
      ProviderCatalog.get_contract("claude_cli")
      # => {:ok, %RuntimeContract{...}}

      # Get capabilities for a provider
      ProviderCatalog.capabilities("anthropic")
      # => {:ok, %Capabilities{streaming: true, thinking: true, ...}}

      # Force refresh the cache
      ProviderCatalog.refresh()
  """

  alias Arbor.Contracts.AI.{Capabilities, RuntimeContract}

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.{
    Anthropic,
    ClaudeCli,
    CodexCli,
    Gemini,
    GeminiCli,
    LMStudio,
    Ollama,
    OpenAI,
    OpencodeCli,
    OpenRouter,
    XAI,
    Zai,
    ZaiCodingPlan
  }

  require Logger

  @ets_table :arbor_provider_catalog
  @ttl_ms :timer.minutes(5)

  @all_adapters [
    Anthropic,
    OpenAI,
    Gemini,
    OpenRouter,
    XAI,
    Zai,
    ZaiCodingPlan,
    ClaudeCli,
    CodexCli,
    GeminiCli,
    OpencodeCli,
    LMStudio,
    Ollama
  ]

  @doc """
  Returns all available providers as `{provider_string, %Capabilities{}}` tuples.

  Only includes providers whose runtime requirements are currently satisfied.
  Results are cached for #{div(@ttl_ms, 60_000)} minutes.
  """
  @spec available(keyword()) :: [{String.t(), Capabilities.t()}]
  def available(opts \\ []) do
    ensure_table()
    catalog = get_or_refresh(opts)

    catalog
    |> Enum.filter(fn {_provider, entry} -> entry.available? end)
    |> Enum.map(fn {provider, entry} -> {provider, entry.capabilities} end)
  end

  @doc """
  Returns all known providers (including unavailable ones) with their status.

  Useful for `mix arbor.doctor` style diagnostics.
  """
  @spec all(keyword()) :: [
          %{
            provider: String.t(),
            display_name: String.t(),
            type: RuntimeContract.provider_type(),
            available?: boolean(),
            capabilities: Capabilities.t() | nil,
            check_result: {:ok, map()} | {:error, term()}
          }
        ]
  def all(opts \\ []) do
    ensure_table()
    catalog = get_or_refresh(opts)

    Enum.map(catalog, fn {_provider, entry} -> entry end)
    |> Enum.sort_by(& &1.provider)
  end

  @doc """
  Get the RuntimeContract for a specific provider.

  Returns the contract regardless of whether the provider is currently available.
  """
  @spec get_contract(String.t()) :: {:ok, RuntimeContract.t()} | {:error, :not_found}
  def get_contract(provider) when is_binary(provider) do
    ensure_table()
    catalog = get_or_refresh([])

    case Map.get(catalog, provider) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry.contract}
    end
  end

  @doc """
  Get capabilities for a specific provider.
  """
  @spec capabilities(String.t()) :: {:ok, Capabilities.t()} | {:error, :not_found}
  def capabilities(provider) when is_binary(provider) do
    ensure_table()
    catalog = get_or_refresh([])

    case Map.get(catalog, provider) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry.capabilities}
    end
  end

  @doc """
  Force a refresh of the provider catalog cache.
  """
  @spec refresh() :: :ok
  def refresh do
    ensure_table()
    catalog = discover_all()
    :ets.insert(@ets_table, {:catalog, catalog, System.monotonic_time(:millisecond)})
    :ok
  end

  # ============================================================================
  # Private — Cache Management
  # ============================================================================

  defp ensure_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])
    end
  rescue
    ArgumentError -> :ok
  end

  defp get_or_refresh(opts) do
    force = Keyword.get(opts, :force_refresh, false)

    case :ets.lookup(@ets_table, :catalog) do
      [{:catalog, catalog, timestamp}] when not force ->
        if expired?(timestamp), do: refresh_async()
        catalog

      _ ->
        catalog = discover_all()
        :ets.insert(@ets_table, {:catalog, catalog, System.monotonic_time(:millisecond)})
        catalog
    end
  end

  defp expired?(timestamp) do
    System.monotonic_time(:millisecond) - timestamp > @ttl_ms
  end

  defp refresh_async do
    Task.start(fn -> refresh() end)
  end

  # ============================================================================
  # Private — Discovery
  # ============================================================================

  defp discover_all do
    @all_adapters
    |> Enum.map(&discover_adapter/1)
    |> Enum.reject(&is_nil/1)
    |> Map.new(fn entry -> {entry.provider, entry} end)
  end

  defp discover_adapter(adapter_module) do
    if function_exported?(adapter_module, :runtime_contract, 0) do
      contract = adapter_module.runtime_contract()
      check_result = RuntimeContract.check(contract)
      is_available = match?({:ok, _}, check_result)

      %{
        provider: contract.provider,
        display_name: contract.display_name,
        type: contract.type,
        available?: is_available,
        capabilities: contract.capabilities || Capabilities.new(),
        contract: contract,
        check_result: check_result,
        adapter_module: adapter_module
      }
    else
      # Adapter doesn't declare a contract — build a minimal entry from provider/0
      provider = adapter_module.provider()

      %{
        provider: provider,
        display_name: provider,
        type: :api,
        available?: legacy_available?(adapter_module),
        capabilities: Capabilities.new(),
        contract: nil,
        check_result: {:ok, %{env_vars: :skipped, cli_tools: :skipped, probes: :skipped}},
        adapter_module: adapter_module
      }
    end
  rescue
    e ->
      Logger.warning(
        "ProviderCatalog: error discovering #{inspect(adapter_module)}: #{inspect(e)}"
      )

      nil
  end

  defp legacy_available?(adapter_module) do
    if function_exported?(adapter_module, :available?, 0) do
      adapter_module.available?()
    else
      # API adapters without available?/0 are assumed available if their env key exists
      true
    end
  rescue
    _ -> false
  end
end
