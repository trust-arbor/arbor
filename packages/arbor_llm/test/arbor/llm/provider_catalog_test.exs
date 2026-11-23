defmodule Arbor.LLM.ProviderCatalogTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.AI.{Capabilities, RuntimeContract}
  alias Arbor.LLM.ProviderCatalog

  # Clean ETS table between tests
  setup do
    if :ets.whereis(:arbor_provider_catalog) != :undefined do
      :ets.delete_all_objects(:arbor_provider_catalog)
    end

    :ok
  end

  describe "available/0" do
    test "returns list of {provider_string, capabilities} tuples" do
      results = ProviderCatalog.available()
      assert is_list(results)

      # Each entry should be a {string, Capabilities} tuple
      for {provider, caps} <- results do
        assert is_binary(provider)
        assert %Capabilities{} = caps
      end
    end

    test "only includes providers whose requirements are met" do
      capabilities = Capabilities.new()

      {:ok, keyless} =
        RuntimeContract.new(
          provider: "fixture_keyless",
          display_name: "Fixture Keyless",
          type: :api,
          env_vars: [],
          capabilities: capabilities
        )

      {:ok, local} =
        RuntimeContract.new(
          provider: "ollama",
          display_name: "Ollama",
          type: :local,
          probes: [%{type: :http, url: "http://127.0.0.1:9/models", timeout_ms: 1}],
          capabilities: capabilities
        )

      # Local availability is Preflight.loaded_models/3 (/api/tags for Ollama).
      # RuntimeContract.available?/1 probes a different URL (base <> "/models").
      # A live server can pass one and fail the other. This fixture never
      # contacts localhost: an answering Ollama must stay excluded.
      registry = Arbor.LLM.Config.external_provider_adapters([])
      key = {:catalog, registry}

      if :ets.whereis(:arbor_provider_catalog) == :undefined do
        :ets.new(:arbor_provider_catalog, [:named_table, :set, :public, read_concurrency: true])
      end

      :ets.insert(:arbor_provider_catalog, {
        key,
        %{
          "fixture_keyless" => %{
            provider: "fixture_keyless",
            display_name: "Fixture Keyless",
            type: :api,
            available?: true,
            capabilities: capabilities,
            contract: keyless,
            check_result: {:ok, %{env_vars: :ok, cli_tools: :skipped, probes: :skipped}},
            adapter_module: Arbor.LLM.Adapter.ReqLLM
          },
          "ollama" => %{
            provider: "ollama",
            display_name: "Ollama",
            type: :local,
            available?: false,
            capabilities: capabilities,
            contract: local,
            check_result: {:error, :fixture_down},
            adapter_module: Arbor.LLM.Adapter.ReqLLM
          }
        },
        System.monotonic_time(:millisecond)
      })

      on_exit(fn ->
        if :ets.whereis(:arbor_provider_catalog) != :undefined do
          :ets.delete(:arbor_provider_catalog, key)
        end
      end)

      results = ProviderCatalog.available()
      assert Enum.map(results, &elem(&1, 0)) == ["fixture_keyless"]

      for {provider, caps} <- results do
        assert %Capabilities{} = caps
        {:ok, contract} = ProviderCatalog.get_contract(provider)

        if contract.type != :local do
          assert RuntimeContract.available?(contract),
                 "#{provider} returned as available but contract check fails"
        end
      end
    end
  end

  describe "all/0" do
    test "returns all known providers including unavailable ones" do
      results = ProviderCatalog.all()
      assert is_list(results)
      assert length(results) >= 9

      # Each entry should have the expected shape
      for entry <- results do
        assert is_binary(entry.provider)
        assert is_binary(entry.display_name)
        assert entry.type in [:api, :cli, :local]
        assert is_boolean(entry.available?)
      end
    end

    test "includes both available and unavailable providers" do
      results = ProviderCatalog.all()
      providers = Enum.map(results, & &1.provider)

      # Core providers should always be listed (even if not available)
      assert "anthropic" in providers
      assert "openai" in providers
      assert "ollama" in providers
      assert "opencode_zen" in providers
    end

    test "opencode_zen is available without an API key" do
      assert {:ok, contract} = ProviderCatalog.get_contract("opencode_zen")
      assert contract.type == :api
      assert contract.env_vars == []
      assert contract.display_name == "OpenCode Zen (free)"

      entry = Enum.find(ProviderCatalog.all(), &(&1.provider == "opencode_zen"))
      assert entry.available?
    end

    test "entries have capabilities" do
      results = ProviderCatalog.all()

      for entry <- results do
        assert %Capabilities{} = entry.capabilities
      end
    end
  end

  describe "get_contract/1" do
    test "returns contract for known provider" do
      assert {:ok, %RuntimeContract{} = contract} = ProviderCatalog.get_contract("anthropic")
      assert contract.provider == "anthropic"
      # Session 6.6 dropped per-provider display_name aliases (was
      # "Anthropic API"); names now come from a small override table
      # or get computed by capitalizing the atom string.
      assert contract.display_name == "Anthropic"
      assert contract.type == :api
    end

    test "returns :not_found for unknown provider" do
      assert {:error, :not_found} = ProviderCatalog.get_contract("nonexistent_provider")
    end

    test "ollama has HTTP probe requirement" do
      assert {:ok, contract} = ProviderCatalog.get_contract("ollama")
      assert contract.type == :local
      assert length(contract.probes) == 1
    end
  end

  describe "capabilities/1" do
    test "returns capabilities for known provider" do
      assert {:ok, %Capabilities{} = caps} = ProviderCatalog.capabilities("anthropic")
      assert caps.streaming == true
      assert caps.thinking == true
      assert caps.tool_calls == true
      assert caps.extended_thinking == true
    end

    test "returns :not_found for unknown provider" do
      assert {:error, :not_found} = ProviderCatalog.capabilities("nonexistent_provider")
    end

    test "ollama has embeddings capability" do
      assert {:ok, caps} = ProviderCatalog.capabilities("ollama")
      assert caps.embeddings == true
    end
  end

  describe "refresh/0" do
    test "forces a cache refresh" do
      # First call populates cache
      _results = ProviderCatalog.available()

      # Refresh should not error
      assert :ok = ProviderCatalog.refresh()

      # Results should still be available after refresh
      results = ProviderCatalog.available()
      assert is_list(results)
    end
  end

  describe "caching" do
    test "subsequent calls return cached results" do
      # Two calls should return the same data
      results1 = ProviderCatalog.all()
      results2 = ProviderCatalog.all()
      assert results1 == results2
    end

    test "force_refresh bypasses cache" do
      _results1 = ProviderCatalog.all()
      results2 = ProviderCatalog.all(force_refresh: true)
      assert is_list(results2)
    end
  end
end
