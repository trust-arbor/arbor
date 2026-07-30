defmodule Arbor.Contracts.LLM.ProviderModelCatalogTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.LLM.ProviderModelCatalog

  @observed "2026-07-29T12:00:00Z"
  @expires "2026-07-29T12:05:00Z"

  describe "new/1" do
    test "accepts exact openai_oauth/openai/arbor triple with bounded model ids" do
      assert {:ok, %ProviderModelCatalog{} = catalog} =
               ProviderModelCatalog.new(%{
                 version: 1,
                 route: "openai_oauth",
                 backend: "openai",
                 runtime: "arbor",
                 model_ids: ["gpt-5.6-sol", "gpt-5"],
                 observed_at: @observed,
                 expires_at: @expires,
                 credential_generation: 7
               })

      assert catalog.route == "openai_oauth"
      assert catalog.backend == "openai"
      assert catalog.runtime == "arbor"
      assert catalog.model_ids == ["gpt-5.6-sol", "gpt-5"]
      assert catalog.credential_generation == 7
    end

    test "accepts exact xai_oauth/xai/arbor triple and empty selectable model list" do
      assert {:ok, %ProviderModelCatalog{} = catalog} =
               ProviderModelCatalog.new(%{
                 route: "xai_oauth",
                 backend: "xai",
                 runtime: "arbor",
                 model_ids: [],
                 observed_at: @observed,
                 expires_at: @expires,
                 credential_generation: 0
               })

      assert catalog.model_ids == []
      assert catalog.route == "xai_oauth"
    end

    test "rejects route/backend/runtime mismatches" do
      assert {:error, {:invalid_provider_model_catalog, :route_backend_runtime_mismatch}} =
               ProviderModelCatalog.new(%{
                 route: "openai_oauth",
                 backend: "xai",
                 runtime: "arbor",
                 model_ids: ["m"],
                 observed_at: @observed,
                 expires_at: @expires,
                 credential_generation: 1
               })

      assert {:error, {:invalid_field, "runtime"}} =
               ProviderModelCatalog.new(%{
                 route: "openai_oauth",
                 backend: "openai",
                 runtime: "acp",
                 model_ids: ["m"],
                 observed_at: @observed,
                 expires_at: @expires,
                 credential_generation: 1
               })
    end

    test "rejects duplicate model ids, oversized ids, and bad expiry" do
      assert {:error, {:invalid_provider_model_catalog, :duplicate_model_id}} =
               ProviderModelCatalog.new(%{
                 route: "openai_oauth",
                 backend: "openai",
                 runtime: "arbor",
                 model_ids: ["a", "a"],
                 observed_at: @observed,
                 expires_at: @expires,
                 credential_generation: 1
               })

      assert {:error, {:invalid_field, "model_ids"}} =
               ProviderModelCatalog.new(%{
                 route: "openai_oauth",
                 backend: "openai",
                 runtime: "arbor",
                 model_ids: [String.duplicate("x", 257)],
                 observed_at: @observed,
                 expires_at: @expires,
                 credential_generation: 1
               })

      assert {:error, {:invalid_field, "expires_at"}} =
               ProviderModelCatalog.new(%{
                 route: "openai_oauth",
                 backend: "openai",
                 runtime: "arbor",
                 model_ids: ["a"],
                 observed_at: @expires,
                 expires_at: @observed,
                 credential_generation: 1
               })
    end

    test "security regression: aggregate canonical oversize is rejected at new/1" do
      # 512 max-length IDs exceed the 32768-byte canonical ceiling.
      ids =
        for i <- 1..512 do
          prefix = Integer.to_string(i) <> "-"
          prefix <> String.duplicate("x", 256 - byte_size(prefix))
        end

      assert {:error, {:invalid_provider_model_catalog, :object_too_large}} =
               ProviderModelCatalog.new(%{
                 route: "openai_oauth",
                 backend: "openai",
                 runtime: "arbor",
                 model_ids: ids,
                 observed_at: @observed,
                 expires_at: @expires,
                 credential_generation: 1
               })
    end
  end

  describe "to_map/1 and canonical_bytes/1" do
    test "projects closed fields only and encodes under byte ceiling" do
      assert {:ok, catalog} =
               ProviderModelCatalog.new(%{
                 route: "openai_oauth",
                 backend: "openai",
                 runtime: "arbor",
                 model_ids: ["gpt-5"],
                 observed_at: @observed,
                 expires_at: @expires,
                 credential_generation: 3
               })

      map = ProviderModelCatalog.to_map(catalog)
      refute Map.has_key?(map, "account_id")
      refute Map.has_key?(map, "access_token")
      refute Map.has_key?(map, "path")
      assert map["route"] == "openai_oauth"
      assert map["model_ids"] == ["gpt-5"]

      assert {:ok, bytes} = ProviderModelCatalog.canonical_bytes(catalog)
      assert is_binary(bytes)
      assert byte_size(bytes) <= 32_768
      assert ProviderModelCatalog.valid?(catalog)
    end
  end
end
