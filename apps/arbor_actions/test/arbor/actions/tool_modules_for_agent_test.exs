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

    test "includes profile-mintable actions without granting capabilities", %{agent_id: agent_id} do
      start_trust_infrastructure()
      set_policy_enforcer_enabled(true)
      create_profile_with_rules(agent_id, :ask, %{"arbor://fs/read" => :auto})

      {:ok, caps_before} = Security.list_capabilities(agent_id)
      cap_ids_before = Enum.map(caps_before, & &1.id)
      refute Enum.any?(caps_before, &(&1.resource_uri == "arbor://fs/read"))

      modules = Arbor.Actions.tool_modules_for_agent(agent_id)

      assert Arbor.Actions.File.Read in modules

      {:ok, caps_after} = Security.list_capabilities(agent_id)
      assert Enum.map(caps_after, & &1.id) == cap_ids_before
      refute Enum.any?(caps_after, &(&1.resource_uri == "arbor://fs/read"))
    end

    test "is a subset of all_actions/0", %{agent_id: agent_id} do
      {:ok, _} = Security.grant(principal: agent_id, resource: "arbor://fs/read")

      all = MapSet.new(Arbor.Actions.all_actions())
      exposed = MapSet.new(Arbor.Actions.tool_modules_for_agent(agent_id))

      assert MapSet.subset?(exposed, all)
    end
  end

  defp start_trust_infrastructure do
    ensure_started(Arbor.Trust.EventStore)
    ensure_started(Arbor.Trust.Store)

    ensure_started(Arbor.Trust.Manager,
      circuit_breaker: false,
      decay: false,
      event_store: true
    )
  end

  defp ensure_started(module, opts \\ []) do
    if Process.whereis(module) do
      :already_running
    else
      start_supervised!({module, opts})
    end
  end

  defp create_profile_with_rules(agent_id, baseline, rules) do
    case Arbor.Trust.create_trust_profile(agent_id) do
      {:ok, _} -> :ok
      {:error, :already_exists} -> :ok
    end

    Arbor.Trust.Store.update_profile(agent_id, fn profile ->
      %{profile | baseline: baseline, rules: rules}
    end)
  end

  defp set_policy_enforcer_enabled(value) do
    previous = Application.get_env(:arbor_trust, :policy_enforcer_enabled)
    Application.put_env(:arbor_trust, :policy_enforcer_enabled, value)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:arbor_trust, :policy_enforcer_enabled)
      else
        Application.put_env(:arbor_trust, :policy_enforcer_enabled, previous)
      end
    end)
  end
end
