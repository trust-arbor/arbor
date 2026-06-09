defmodule Arbor.Gateway.MCP.BridgeAuthorizeFailClosedTest do
  @moduledoc """
  Security regression: the MCP tool/resource bridges must FAIL CLOSED when the
  security capability check raises or exits. Before the 2026-06-09 fix, their
  `authorize/3` rescued/caught to `:ok`, so any exception (or a Security
  GenServer timeout → `:exit`) silently authorized an external MCP tool call or
  resource read.

  These tests fail on `git checkout HEAD~1` of the fix (the rescue/catch returns
  `:ok`) and pass on HEAD.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Gateway.MCP.{ResourceBridge, ToolBridge}

  defmodule RaisingSecurity do
    @moduledoc false
    def authorize(_agent_id, _uri, _opts), do: raise("boom in capability check")
  end

  defmodule ExitingSecurity do
    @moduledoc false
    def authorize(_agent_id, _uri, _opts), do: exit(:timeout)
  end

  setup do
    on_exit(fn -> Application.delete_env(:arbor_gateway, :security_module) end)
    :ok
  end

  describe "ToolBridge.authorize/3 fails closed" do
    test "denies when the security check raises" do
      Application.put_env(:arbor_gateway, :security_module, RaisingSecurity)

      assert {:error, :unauthorized, _msg} =
               ToolBridge.authorize("agent_x", "github", "create_issue")
    end

    test "denies when the security check exits (e.g. GenServer timeout)" do
      Application.put_env(:arbor_gateway, :security_module, ExitingSecurity)

      assert {:error, :unauthorized, _msg} =
               ToolBridge.authorize("agent_x", "github", "create_issue")
    end
  end

  describe "ResourceBridge.authorize/3 fails closed" do
    test "denies when the security check raises" do
      Application.put_env(:arbor_gateway, :security_module, RaisingSecurity)

      assert {:error, :unauthorized, _msg} =
               ResourceBridge.authorize("agent_x", "github", "readme")
    end

    test "denies when the security check exits" do
      Application.put_env(:arbor_gateway, :security_module, ExitingSecurity)

      assert {:error, :unauthorized, _msg} =
               ResourceBridge.authorize("agent_x", "github", "readme")
    end
  end
end
