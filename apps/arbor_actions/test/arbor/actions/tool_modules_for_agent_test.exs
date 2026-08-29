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

    test "memory_remember is exposed wherever memory_recall is", %{agent_id: agent_id} do
      start_trust_infrastructure()
      set_policy_enforcer_enabled(true)
      create_profile_with_rules(agent_id, :ask, %{})

      modules = Arbor.Actions.tool_modules_for_agent(agent_id)

      # Recall without Remember leaves an agent able to search its memory but
      # never to record one deliberately. `arbor://memory/add_knowledge` had no
      # capability profile, so trust reported it :unprofiled -> not mintable ->
      # never exposed, and an agent asked to remember something looped calling
      # recall instead (found 2026-08-25 on the onboarding path).
      assert Arbor.Actions.Memory.Recall in modules
      assert Arbor.Actions.Memory.Remember in modules
    end

    test "session graph syscalls never surface as ordinary tools" do
      # session_memory/goals/exec/llm appear ONLY as DOT pipeline node targets
      # (heartbeat-bare/full/goals, bdi-cycle, turn) and route through
      # `arbor://orchestrator/execute`. Untagged, pipeline_internal_action?/1
      # said false and graph syscalls sat in the conversational tool menu —
      # exactly what the exposure index claims to prevent ("capability grants
      # alone cannot surface graph syscalls as ordinary tools").
      #
      # The Engine path sets allow_pipeline_internal: true, so the graphs that
      # legitimately call these are unaffected.
      for module <- [
            Arbor.Actions.SessionMemory.Recall,
            Arbor.Actions.SessionMemory.Update,
            Arbor.Actions.SessionMemory.Checkpoint,
            Arbor.Actions.SessionMemory.Consolidate,
            Arbor.Actions.SessionMemory.UpdateWorkingMemory,
            Arbor.Actions.SessionMemory.BackgroundChecks,
            Arbor.Actions.SessionGoals.UpdateGoals,
            Arbor.Actions.SessionGoals.StoreDecompositions,
            Arbor.Actions.SessionGoals.ProcessProposalDecisions,
            Arbor.Actions.SessionGoals.StoreIdentity,
            Arbor.Actions.SessionGoals.PruneStaleIntents,
            Arbor.Actions.SessionExecution.RouteActions,
            Arbor.Actions.SessionExecution.ExecuteActions,
            Arbor.Actions.SessionLlm.BuildPrompt
          ] do
        assert Arbor.Actions.pipeline_internal_action?(module),
               "#{inspect(module)} is a graph syscall and must be pipeline_internal"

        refute module in Arbor.Actions.exposed_actions(),
               "#{inspect(module)} leaked into the exposed tool catalog"
      end
    end

    test "APIAgent exposure keeps dual-use graph actions and hides session syscalls even with orchestrator grant",
         %{agent_id: agent_id} do
      {:ok, _} = Security.grant(principal: agent_id, resource: "arbor://fs/read")
      {:ok, _} = Security.grant(principal: agent_id, resource: "arbor://orchestrator/execute")

      modules = Arbor.Actions.tool_modules_for_agent(agent_id)

      assert Arbor.Actions.File.Read in modules
      refute Arbor.Actions.SessionGoals.UpdateGoals in modules
      refute Arbor.Actions.SessionExecution.RouteActions in modules
      refute Arbor.Actions.SessionLlm.BuildPrompt in modules
    end

    test "is a subset of all_actions/0", %{agent_id: agent_id} do
      {:ok, _} = Security.grant(principal: agent_id, resource: "arbor://fs/read")

      all = MapSet.new(Arbor.Actions.all_actions())
      exposed = MapSet.new(Arbor.Actions.tool_modules_for_agent(agent_id))

      assert MapSet.subset?(exposed, all)
    end
  end

  describe "discoverable_tool_names/1 and tool_find_tools" do
    test "discovery returns only tools the agent can obtain", %{agent_id: agent_id} do
      start_trust_infrastructure()
      set_policy_enforcer_enabled(true)

      create_profile_with_rules(agent_id, :ask, %{
        "arbor://fs/read" => :auto,
        "arbor://fs/list" => :auto,
        "arbor://shell/exec" => :block
      })

      {:ok, _} = Security.grant(principal: agent_id, resource: "arbor://fs/list")

      assert {:ok, names} = Arbor.Actions.discoverable_tool_names(agent_id)
      assert "file_read" in names
      refute "file_list" in names
      refute "shell_execute" in names
      refute "session_memory_recall" in names
      refute "session_goals_update" in names
      refute "session_exec_route_actions" in names
      refute "session_llm_build_prompt" in names

      # tool_find_tools honours the same set. Exact-name queries so the test
      # exercises the FILTER, not search ranking in an isolated test BEAM.
      find = fn q ->
        {:ok, %{discovered_tool_names: hits}} =
          Arbor.Actions.Tool.FindTools.run(%{query: q, limit: 10}, %{agent_id: agent_id})

        hits
      end

      assert "file_read" in find.("file_read")
      # held → attached already, so discovery does not return it
      refute "file_list" in find.("file_list")
      # blocked → never
      refute "shell_execute" in find.("shell_execute")
      # pipeline_internal graph syscalls stay undisclosed even on exact-name search
      refute "session_goals_update" in find.("session_goals_update")
      refute "session_exec_route_actions" in find.("session_exec_route_actions")
      refute "session_llm_build_prompt" in find.("session_llm_build_prompt")
    end
  end

  describe "self-scoped child rules at the action layer (security regression)" do
    test "a :block rule on the agent's own scoped resource wins over a parent :auto",
         %{agent_id: agent_id} do
      start_trust_infrastructure()
      set_policy_enforcer_enabled(true)

      create_profile_with_rules(agent_id, :ask, %{
        "arbor://memory/recall" => :auto,
        "arbor://memory/read/#{agent_id}" => :block
      })

      # Facades accept the minted parent for self-scoped children, so the only
      # place this rule can bite is before Trust authorizes the parent.
      assert {:error, :unauthorized} =
               Arbor.Actions.authorize_and_execute(
                 agent_id,
                 Arbor.Actions.Memory.Recall,
                 %{query: "anything"},
                 %{agent_id: agent_id}
               )
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
