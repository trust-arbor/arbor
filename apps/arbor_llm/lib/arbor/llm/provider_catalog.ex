defmodule Arbor.LLM.ProviderCatalog do
  @moduledoc """
  Single source of truth for available LLM providers.

  After the Session 6 cutover, traffic for every API + local-LM
  provider routes through `Arbor.LLM.Adapter.ReqLLM`. The per-provider
  HTTP modules that used to host `runtime_contract/0` are gone, so the
  catalog is now driven by a static map carrying the same data the
  legacy adapters used to declare. ACP still has its own adapter
  (`Arbor.AI.LLM.Adapter.Acp`) and contributes its contract dynamically.

  ## Usage

      ProviderCatalog.available()
      # => [{"anthropic", %Capabilities{streaming: true, ...}}, ...]

      ProviderCatalog.get_contract("ollama")
      # => {:ok, %RuntimeContract{...}}

      ProviderCatalog.capabilities("anthropic")
      # => {:ok, %Capabilities{streaming: true, thinking: true, ...}}

      ProviderCatalog.refresh()

  Results are cached in ETS with a 5-minute TTL. The check phase
  (env-var / HTTP probe lookups) is what's actually cached;
  availability can change minute-to-minute as keys are set/unset or
  servers come up.
  """

  alias Arbor.Contracts.AI.{Capabilities, RuntimeContract}

  require Logger

  @ets_table :arbor_provider_catalog
  @ttl_ms :timer.minutes(5)

  # Provider definitions previously sourced from each per-provider
  # adapter's `runtime_contract/0`. Lifted verbatim during the
  # Session 6 cutover so consumers of `available/0`, `all/0`,
  # `capabilities/1`, and `get_contract/1` see the same shape as
  # before — only the source-of-truth moved.
  @cloud_providers [
    %{
      provider: "openai",
      display_name: "OpenAI API",
      type: :api,
      env_vars: [%{name: "OPENAI_API_KEY", required: true}],
      capabilities: [
        streaming: true,
        tool_calls: true,
        thinking: true,
        vision: true,
        structured_output: true
      ]
    },
    %{
      provider: "anthropic",
      display_name: "Anthropic API",
      type: :api,
      env_vars: [%{name: "ANTHROPIC_API_KEY", required: true}],
      capabilities: [
        streaming: true,
        tool_calls: true,
        thinking: true,
        extended_thinking: true,
        vision: true,
        structured_output: true
      ]
    },
    %{
      provider: "gemini",
      display_name: "Google Gemini API",
      type: :api,
      env_vars: [%{name: "GEMINI_API_KEY", required: true}],
      capabilities: [
        streaming: true,
        tool_calls: true,
        thinking: true,
        vision: true,
        structured_output: true
      ]
    },
    %{
      provider: "xai",
      display_name: "x.ai (Grok)",
      type: :api,
      env_vars: [%{name: "XAI_API_KEY", required: true}],
      capabilities: [streaming: true, tool_calls: true, thinking: true, vision: true]
    },
    %{
      provider: "openrouter",
      display_name: "OpenRouter",
      type: :api,
      env_vars: [%{name: "OPENROUTER_API_KEY", required: true}],
      capabilities: [
        streaming: true,
        tool_calls: true,
        thinking: true,
        vision: true,
        structured_output: true
      ]
    },
    %{
      provider: "zai",
      display_name: "Z.ai",
      type: :api,
      env_vars: [%{name: "ZAI_API_KEY", required: true}],
      capabilities: [streaming: true, tool_calls: true, thinking: true, structured_output: true]
    },
    %{
      provider: "zai_coding_plan",
      display_name: "Z.ai Coding Plan",
      type: :api,
      env_vars: [%{name: "ZAI_CODING_PLAN_API_KEY", required: true}],
      capabilities: [streaming: true, tool_calls: true, thinking: true, structured_output: true]
    }
  ]

  # Local-LM providers carry an HTTP probe instead of an env var. The
  # base_url defaults match `Arbor.LLM.Adapter.ReqLLM`'s
  # `default_base_url_for/1` so operator overrides via
  # `config :arbor_orchestrator, <provider>, base_url:` flow through
  # consistently.
  @local_providers [
    %{
      provider: "ollama",
      display_name: "Ollama",
      type: :local,
      default_base_url: "http://localhost:11434/v1",
      config_key: :ollama,
      capabilities: [streaming: true, tool_calls: true, embeddings: true]
    },
    %{
      provider: "lm_studio",
      display_name: "LM Studio",
      type: :local,
      default_base_url: "http://localhost:1234/v1",
      config_key: :lm_studio,
      capabilities: [streaming: true, tool_calls: true, structured_output: true]
    }
  ]

  # ACP keeps its own adapter (it's a subprocess runtime, not an LLM
  # transport). We resolve its contract dynamically via runtime
  # indirection — same Module.concat atom-list pattern Client uses so
  # arbor_llm doesn't compile-time-depend on arbor_ai.
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
    cloud = Enum.map(@cloud_providers, &build_cloud_entry/1)
    local = Enum.map(@local_providers, &build_local_entry/1)
    acp = build_acp_entry()
    entries = cloud ++ local ++ List.wrap(acp)
    Map.new(entries, fn entry -> {entry.provider, entry} end)
  end

  defp build_cloud_entry(spec) do
    {:ok, contract} =
      RuntimeContract.new(
        provider: spec.provider,
        display_name: spec.display_name,
        type: spec.type,
        env_vars: spec.env_vars,
        capabilities: Capabilities.new(spec.capabilities)
      )

    check_result = RuntimeContract.check(contract)

    %{
      provider: spec.provider,
      display_name: spec.display_name,
      type: spec.type,
      available?: match?({:ok, _}, check_result),
      capabilities: contract.capabilities,
      contract: contract,
      check_result: check_result,
      adapter_module: Arbor.LLM.Adapter.ReqLLM
    }
  end

  defp build_local_entry(spec) do
    base_url = configured_base_url(spec)

    {:ok, contract} =
      RuntimeContract.new(
        provider: spec.provider,
        display_name: spec.display_name,
        type: spec.type,
        probes: [%{type: :http, url: base_url <> "/models", timeout_ms: 2_000}],
        capabilities: Capabilities.new(spec.capabilities)
      )

    check_result = RuntimeContract.check(contract)

    %{
      provider: spec.provider,
      display_name: spec.display_name,
      type: spec.type,
      available?: match?({:ok, _}, check_result),
      capabilities: contract.capabilities,
      contract: contract,
      check_result: check_result,
      adapter_module: Arbor.LLM.Adapter.ReqLLM
    }
  end

  defp build_acp_entry do
    # Variable indirection hides the module from compile-time analysis
    # (per arbor's runtime-indirection rule — Code.ensure_loaded? alone
    # doesn't suppress the warning; we need apply/3 against a variable
    # target).
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

  defp configured_base_url(spec) do
    config = Application.get_env(:arbor_orchestrator, spec.config_key, [])
    Keyword.get(config, :base_url, spec.default_base_url)
  end
end
