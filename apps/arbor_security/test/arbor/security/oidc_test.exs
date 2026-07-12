defmodule Arbor.Security.OIDCTest do
  # async: false because config-clearing tests mutate Application env
  use ExUnit.Case, async: false

  alias Arbor.Security.OIDC
  alias Arbor.Security.OIDC.Config

  @moduletag :fast

  describe "Config" do
    setup do
      prev = Application.get_env(:arbor_security, :oidc)
      Application.delete_env(:arbor_security, :oidc)
      on_exit(fn -> if prev, do: Application.put_env(:arbor_security, :oidc, prev) end)
      :ok
    end

    test "enabled? returns false when not configured" do
      refute Config.enabled?()
    end

    test "providers returns empty list by default" do
      assert Config.providers() == []
    end

    test "device_flow returns nil by default" do
      assert Config.device_flow() == nil
    end

    test "token_cache_path has sensible default" do
      path = Config.token_cache_path()
      assert String.contains?(path, ".arbor")
      assert String.contains?(path, "oidc_tokens.enc")
    end
  end

  describe "load_cached_token/0" do
    setup do
      # Point token_cache_path to a non-existent temp file so real cached
      # tokens from previous OIDC sessions don't interfere
      prev = Application.get_env(:arbor_security, :oidc)
      tmp_path = Path.join(System.tmp_dir!(), "arbor_test_oidc_#{:rand.uniform(1_000_000)}.enc")
      Application.put_env(:arbor_security, :oidc, token_cache_path: tmp_path)

      on_exit(fn ->
        File.rm(tmp_path)

        if prev,
          do: Application.put_env(:arbor_security, :oidc, prev),
          else: Application.delete_env(:arbor_security, :oidc)
      end)

      :ok
    end

    test "returns error when no cache exists" do
      assert {:error, :no_cached_token} = OIDC.load_cached_token()
    end
  end

  describe "authenticate_device_flow/1" do
    setup do
      prev = Application.get_env(:arbor_security, :oidc)
      Application.delete_env(:arbor_security, :oidc)
      on_exit(fn -> if prev, do: Application.put_env(:arbor_security, :oidc, prev) end)
      :ok
    end

    test "returns error when no device flow configured" do
      assert {:error, :no_device_flow_configured} = OIDC.authenticate_device_flow(nil)
    end
  end

  describe "authenticate_token/2" do
    test "returns error when no matching provider" do
      # A well-formed but unverifiable token
      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256"}), padding: false)

      payload =
        Base.url_encode64(
          Jason.encode!(%{
            "iss" => "https://unknown-provider.invalid",
            "sub" => "1",
            "exp" => System.os_time(:second) + 3600
          }),
          padding: false
        )

      sig = Base.url_encode64("sig", padding: false)
      token = "#{header}.#{payload}.#{sig}"

      assert {:error, :no_matching_provider} = OIDC.authenticate_token(token, nil)
    end
  end

  describe "Security facade" do
    test "human_identity?/1 detects human prefix" do
      assert Arbor.Security.human_identity?("human_abc123")
      refute Arbor.Security.human_identity?("agent_abc123")
      refute Arbor.Security.human_identity?("system")
    end
  end

  describe "operator signing authority" do
    test "opens a caller-owned authority after token-verified human registration" do
      oidc = Arbor.Security.OIDCTestHelper.issue_identity()
      human_id = oidc.identity.agent_id

      assert :ok =
               Arbor.Security.register_oidc_identity(
                 oidc.identity,
                 oidc.id_token,
                 oidc.provider
               )

      assert :ok = Arbor.Security.store_signing_key(human_id, oidc.identity.private_key)

      on_exit(fn ->
        oidc.cleanup.()
        _ = Arbor.Security.delete_signing_key(human_id)
        _ = Arbor.Security.deregister_identity(human_id)
      end)

      assert {:ok, authority} = OIDC.open_operator_authority(oidc.identity)
      refute is_function(authority)
      assert authority.principal_id == human_id

      assert {:ok, signed} = Arbor.Security.sign_with_authority(authority, "oidc-test")
      assert signed.agent_id == human_id
      assert signed.payload == "oidc-test"
    end
  end
end
