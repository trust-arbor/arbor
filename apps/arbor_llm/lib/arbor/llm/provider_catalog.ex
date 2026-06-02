defmodule Arbor.LLM.ProviderCatalog do
  @moduledoc """
  Single source of truth for available LLM providers.

  Driven by `Arbor.LLM.ProviderRegistry`, which itself derives provider
  identity / env keys / base URLs from req_llm and per-provider
  capabilities from llm_db. The Catalog adds the availability-check +
  caching layer on top.

  ## Usage

      ProviderCatalog.available()
      # => [{"anthropic", %Capabilities{streaming: true, ...}}, ...]

      ProviderCatalog.get_contract("ollama")
      # => {:ok, %RuntimeContract{...}}

      ProviderCatalog.capabilities("anthropic")
      # => {:ok, %Capabilities{streaming: true, thinking: true, ...}}

      ProviderCatalog.refresh()

  Results are cached in ETS with a 5-minute TTL. The check phase
  (env-var lookup / HTTP probe) is what's cached; availability can
  change minute-to-minute as keys are set/unset or servers come up.
  """

  alias Arbor.Contracts.AI.{Capabilities, RuntimeContract}
  alias Arbor.LLM.ProviderRegistry

  require Logger

  @ets_table :arbor_provider_catalog
  @ttl_ms :timer.minutes(5)

  # ACP keeps its own adapter at Arbor.AI.LLM.Adapter.Acp; we resolve
  # its contract dynamically via runtime indirection (Module.concat
  # atom-list hides the cross-app reference from compile-time analysis
  # so arbor_llm doesn't compile-time-depend on arbor_ai).
  @acp_adapter Module.concat([:Arbor, :AI, :LLM, :Adapter, :Acp])

  @doc """
  Returns all available providers as `{provider_string, %Capabilities{}}` tuples.

  Only includes providers whose runtime requirements are currently
  satisfied. Results are cached for #{div(@ttl_ms, 60_000)} minutes.
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

  # ── Cache ──────────────────────────────────────────────────────────

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

  # ── Discovery ──────────────────────────────────────────────────────

  defp discover_all do
    cloud = Enum.map(ProviderRegistry.list_cloud(), &build_cloud_entry/1)
    local = Enum.map(ProviderRegistry.list_local(), &build_local_entry/1)
    acp = build_acp_entry()
    entries = cloud ++ local ++ List.wrap(acp)
    Map.new(entries, fn entry -> {entry.provider, entry} end)
  end

  defp build_cloud_entry(provider) do
    env_key = ProviderRegistry.default_env_key(provider)
    capabilities = ProviderRegistry.capabilities(provider)

    {:ok, contract} =
      RuntimeContract.new(
        provider: provider,
        display_name: ProviderRegistry.display_name(provider),
        type: :api,
        env_vars: List.wrap(env_key && %{name: env_key, required: true}),
        capabilities: capabilities
      )

    check_result = RuntimeContract.check(contract)

    %{
      provider: provider,
      display_name: ProviderRegistry.display_name(provider),
      type: :api,
      available?: match?({:ok, _}, check_result),
      capabilities: capabilities,
      contract: contract,
      check_result: check_result,
      adapter_module: Arbor.LLM.Adapter.ReqLLM
    }
  end

  defp build_local_entry(provider) do
    base_url = ProviderRegistry.default_base_url(provider)
    capabilities = ProviderRegistry.capabilities(provider)

    {:ok, contract} =
      RuntimeContract.new(
        provider: provider,
        display_name: ProviderRegistry.display_name(provider),
        type: :local,
        probes: [%{type: :http, url: base_url <> "/models", timeout_ms: 2_000}],
        capabilities: capabilities
      )

    check_result = RuntimeContract.check(contract)

    %{
      provider: provider,
      display_name: ProviderRegistry.display_name(provider),
      type: :local,
      available?: match?({:ok, _}, check_result),
      capabilities: capabilities,
      contract: contract,
      check_result: check_result,
      adapter_module: Arbor.LLM.Adapter.ReqLLM
    }
  end

  defp build_acp_entry do
    acp_mod = @acp_adapter
    Code.ensure_loaded(acp_mod)

    if function_exported?(acp_mod, :runtime_contract, 0) do
      contract = apply(acp_mod, :runtime_contract, [])
      check_result = RuntimeContract.check(contract)

      %{
        provider: contract.provider,
        display_name: contract.display_name,
        type: contract.type,
        available?: match?({:ok, _}, check_result),
        capabilities: contract.capabilities || Capabilities.new(),
        contract: contract,
        check_result: check_result,
        adapter_module: acp_mod
      }
    end
  rescue
    e ->
      Logger.warning("ProviderCatalog: error discovering ACP adapter: #{inspect(e)}")
      nil
  end
end
