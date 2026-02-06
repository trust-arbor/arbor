defmodule Arbor.AI.AgentSDKTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.AgentSDK

  describe "cli_available?/0" do
    test "returns boolean" do
      result = AgentSDK.cli_available?()
      assert is_boolean(result)
    end
  end

  describe "cli_version/0" do
    @tag :external
    test "returns version string when CLI is available" do
      case AgentSDK.cli_version() do
        {:ok, version} ->
          assert is_binary(version)
          assert String.contains?(version, "claude") or String.match?(version, ~r/\d+\.\d+/)

        {:error, _} ->
          # CLI not available, skip
          :ok
      end
    end
  end

  describe "module structure" do
    test "AgentSDK module exists" do
      assert Code.ensure_loaded?(Arbor.AI.AgentSDK)
    end

    test "Client module exists" do
      assert Code.ensure_loaded?(Arbor.AI.AgentSDK.Client)
    end

    test "Transport module exists" do
      assert Code.ensure_loaded?(Arbor.AI.AgentSDK.Transport)
    end

    test "Tool module exists" do
      assert Code.ensure_loaded?(Arbor.AI.AgentSDK.Tool)
    end

    test "ToolServer module exists" do
      assert Code.ensure_loaded?(Arbor.AI.AgentSDK.ToolServer)
    end

    test "Hooks module exists" do
      assert Code.ensure_loaded?(Arbor.AI.AgentSDK.Hooks)
    end

    test "Permissions module exists" do
      assert Code.ensure_loaded?(Arbor.AI.AgentSDK.Permissions)
    end

    test "Error module exists" do
      assert Code.ensure_loaded?(Arbor.AI.AgentSDK.Error)
    end
  end
end
