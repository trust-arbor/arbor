defmodule Arbor.Security.OIDC.ConfigTest do
  use ExUnit.Case, async: true

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

  test "runtime.exs and arbor.orchestrate wire allow_http through Config.allow_http?" do
    root = find_root(__DIR__)
    runtime = File.read!(Path.join(root, "config/runtime.exs"))

    orchestrate =
      File.read!(Path.join(root, "apps/arbor_orchestrator/lib/mix/tasks/arbor.orchestrate.ex"))

    assert runtime =~ "Arbor.Security.OIDC.Config.allow_http?"
    assert runtime =~ "allow_http: allow_http"
    assert orchestrate =~ "Arbor.Security.OIDC.Config.allow_http?"
    assert orchestrate =~ "allow_http: allow_http"
  end

  defp find_root(dir) do
    cond do
      File.exists?(Path.join([dir, "apps", "arbor_kernel", "mix.exs"])) ->
        dir

      Path.dirname(dir) == dir ->
        flunk("umbrella root not found from #{__DIR__}")

      true ->
        find_root(Path.dirname(dir))
    end
  end
end
