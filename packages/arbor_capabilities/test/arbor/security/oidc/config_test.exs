defmodule Arbor.Security.OIDC.ConfigTest do
  use ExUnit.Case, async: false

  alias Arbor.Security.OIDC.Config

  @moduletag :fast

  describe "allow_http?/2" do
    test "prod stays closed for loopback HTTP unless OIDC_ALLOW_HTTP is true" do
      assert Config.allow_http?("http://localhost:8080", env: nil, config_env: :prod) == false

      assert Config.allow_http?("http://localhost:8080", env: "true", config_env: :prod) ==
               true

      assert Config.allow_http?("http://localhost:8080", env: "false", config_env: :dev) ==
               false
    end

    test "non-prod loopback HTTP issuers default open" do
      assert Config.allow_http?("http://localhost:8080", env: nil, config_env: :dev) == true
      assert Config.allow_http?("http://127.0.0.1:8080", env: nil, config_env: :test) == true
      assert Config.allow_http?("http://[::1]:8080", env: nil, config_env: :dev) == true
      assert Config.allow_http?("http://LOCALHOST:8080", env: "", config_env: :dev) == true
    end

    test "does not default-open non-loopback or https issuers" do
      assert Config.allow_http?("http://idp.example", env: nil, config_env: :dev) == false
      assert Config.allow_http?("https://localhost:8080", env: nil, config_env: :dev) == false
      assert Config.allow_http?(nil, env: nil, config_env: :dev) == false
    end

    test "unknown OIDC_ALLOW_HTTP values fail closed" do
      assert Config.allow_http?("http://localhost:8080", env: "maybe", config_env: :dev) ==
               false
    end
  end

  describe "configured entries" do
    setup do
      previous_config = Application.get_env(:arbor_capabilities, :oidc)
      previous_allow_http = System.get_env("OIDC_ALLOW_HTTP")

      on_exit(fn ->
        if previous_config do
          Application.put_env(:arbor_capabilities, :oidc, previous_config)
        else
          Application.delete_env(:arbor_capabilities, :oidc)
        end

        if previous_allow_http do
          System.put_env("OIDC_ALLOW_HTTP", previous_allow_http)
        else
          System.delete_env("OIDC_ALLOW_HTTP")
        end
      end)

      :ok
    end

    test "materializes omitted provider and device-flow policy through the authority" do
      System.put_env("OIDC_ALLOW_HTTP", "true")

      Application.put_env(:arbor_capabilities, :oidc,
        providers: [%{issuer: "http://localhost:8080", client_id: "dashboard"}],
        device_flow: %{issuer: "http://localhost:8080", client_id: "device"}
      )

      assert [%{allow_http: true}] = Config.providers()
      assert %{allow_http: true} = Config.device_flow()
    end

    test "preserves an explicit fail-closed setting" do
      System.put_env("OIDC_ALLOW_HTTP", "true")

      Application.put_env(:arbor_capabilities, :oidc,
        providers: [
          %{issuer: "http://localhost:8080", client_id: "dashboard", allow_http: false}
        ]
      )

      assert [%{allow_http: false}] = Config.providers()
    end
  end
end
