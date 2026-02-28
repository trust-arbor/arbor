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
      Application.put_env(:arbor_security, :oidc, [token_cache_path: tmp_path])

      on_exit(fn ->
        File.rm(tmp_path)
        if prev, do: Application.put_env(:arbor_security, :oidc, prev), else: Application.delete_env(:arbor_security, :oidc)
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
end
