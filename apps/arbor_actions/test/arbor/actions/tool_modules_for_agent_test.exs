defmodule Arbor.Actions.ToolModulesForAgentTest do
  @moduledoc """
  Unit tests for `Arbor.Actions.tool_modules_for_agent/1` — the helper
  that filters the action surface to what an agent can actually run,
  used by `Runtime.Acp` to populate the ACP `mcpServers` tool list.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security

  setup do
    {:ok, identity} = Identity.generate(name: "tool-exposure-test")
    agent_id = identity.agent_id
    :ok = Security.register_identity(identity)

    on_exit(fn ->
      case Security.list_capabilities(agent_id) do
        {:ok, caps} -> Enum.each(caps, &Security.revoke(&1.id))
        _ -> :ok
      end
    end)

    %{agent_id: agent_id}
  end

  describe "tool_modules_for_agent/1" do
    test "returns [] for nil or empty agent id" do
      assert Arbor.Actions.tool_modules_for_agent(nil) == []
      assert Arbor.Actions.tool_modules_for_agent("") == []
    end

    test "returns [] for an agent with no granted capabilities", %{agent_id: agent_id} do
      assert Arbor.Actions.tool_modules_for_agent(agent_id) == []
    end

    test "includes an action after its canonical URI is granted", %{agent_id: agent_id} do
      {:ok, _} = Security.grant(principal: agent_id, resource: "arbor://fs/read")

      modules = Arbor.Actions.tool_modules_for_agent(agent_id)

      assert Arbor.Actions.File.Read in modules,
             "expected File.Read to be exposed after granting arbor://fs/read, got: " <>
               inspect(modules)
    end

    test "excludes actions whose URI was not granted", %{agent_id: agent_id} do
      {:ok, _} = Security.grant(principal: agent_id, resource: "arbor://fs/read")

      modules = Arbor.Actions.tool_modules_for_agent(agent_id)

      refute Arbor.Actions.Shell.Execute in modules,
             "Shell.Execute should NOT be exposed without arbor://shell/exec grant"
    end

    test "is a subset of all_actions/0", %{agent_id: agent_id} do
      {:ok, _} = Security.grant(principal: agent_id, resource: "arbor://fs/read")

      all = MapSet.new(Arbor.Actions.all_actions())
      exposed = MapSet.new(Arbor.Actions.tool_modules_for_agent(agent_id))

      assert MapSet.subset?(exposed, all)
    end
  end
end
