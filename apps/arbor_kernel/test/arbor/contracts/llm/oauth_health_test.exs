defmodule Arbor.Contracts.LLM.OAuthHealthTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.LLM.OAuthHealth

  describe "new/1" do
    test "accepts local OAuth health with exact route-backend pair and bounded metadata" do
      assert {:ok, %OAuthHealth{} = health} =
               OAuthHealth.new(%{
                 version: 1,
                 route: "openai_oauth",
                 backend: "openai",
                 status: "ready",
                 owner: "arbor_owned",
                 origin: "arbor_login",
                 source: "arbor_oauth_store",
                 generation: 7
               })

      assert health.version == 1
      assert health.route == "openai_oauth"
      assert health.backend == "openai"
      assert health.status == "ready"
    end

    test "bounds source-unsupported to xAI backend only and keeps owner metadata" do
      assert {:ok, %OAuthHealth{} = health} =
               OAuthHealth.new(%{
                 version: 1,
                 route: "xai_oauth",
                 backend: "xai",
                 status: "source_unsupported",
                 owner: "source_owned",
                 origin: "external_cli",
                 source: "grok_file",
                 generation: 3
               })

      assert health.status == "source_unsupported"
      assert health.owner == "source_owned"
    end
  end

  describe "validation rejects non-bounded combinations" do
    test "rejects malformed route/backend pair" do
      assert {:error, {:invalid_oauth_health, :route_backend_mismatch}} =
               OAuthHealth.new(%{
                 route: "openai_oauth",
                 backend: "xai",
                 status: "ready"
               })
    end

    test "rejects unknown error-status combinations and claims metadata for metadata-free status" do
      assert {:error, {:invalid_oauth_health, :metadata_without_envelope}} =
               OAuthHealth.new(%{
                 version: 1,
                 route: "openai_oauth",
                 backend: "openai",
                 status: "login_required",
                 owner: "arbor_owned",
                 origin: "arbor_login",
                 source: "arbor_oauth_store"
               })
    end

    test "rejects unknown routes and statuses" do
      assert {:error, {:invalid_field, "route"}} =
               OAuthHealth.new(%{
                 version: 1,
                 route: "chatgpt_oauth",
                 backend: "openai",
                 status: "ready"
               })
    end
  end

  describe "to_map/1 and canonical_bytes/1" do
    test "excludes sensitive/private fields from map projection" do
      assert {:ok, health} =
               OAuthHealth.new(%{
                 version: 1,
                 route: "openai_oauth",
                 backend: "openai",
                 status: "ready",
                 owner: "arbor_owned",
                 origin: "arbor_login",
                 source: "arbor_oauth_store",
                 generation: 5
               })

      map = OAuthHealth.to_map(health)
      refute Map.has_key?(map, "account_id")
      assert map["route"] == "openai_oauth"

      assert {:ok, bytes} = OAuthHealth.canonical_bytes(map)
      assert is_binary(bytes)
      assert byte_size(bytes) < 1_024
    end

    test "canonical_bytes revalidates structs and rejects malformed combinations" do
      invalid_struct = %OAuthHealth{
        version: 1,
        route: "openai_oauth",
        backend: "openai",
        status: "ready",
        owner: nil,
        origin: "arbor_login",
        source: "arbor_oauth_store"
      }

      assert {:error, {:invalid_oauth_health, :partial_ownership}} =
               OAuthHealth.canonical_bytes(invalid_struct)
    end
  end
end
