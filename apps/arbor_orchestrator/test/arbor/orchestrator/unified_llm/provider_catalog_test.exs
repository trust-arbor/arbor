defmodule Arbor.Orchestrator.UnifiedLLM.ProviderCatalogTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.AI.{Capabilities, RuntimeContract}
  alias Arbor.Orchestrator.UnifiedLLM.ProviderCatalog

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
      results = ProviderCatalog.available()

      # All returned providers should have their requirements satisfied
      for {provider, _caps} <- results do
        {:ok, contract} = ProviderCatalog.get_contract(provider)

        if contract do
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
      assert contract.display_name == "Anthropic API"
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
