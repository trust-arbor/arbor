defmodule Arbor.Orchestrator.Session.ToolDisclosureTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Orchestrator.Session.ToolDisclosure

  describe "core_tools/0" do
    test "includes find_tools and core file/memory/skill/git tools" do
      tools = ToolDisclosure.core_tools()

      assert "tool_find_tools" in tools
      assert "file_read" in tools
      assert "file_write" in tools
      assert "file_edit" in tools
      assert "memory_recall" in tools
      assert "memory_remember" in tools
      assert "skill_search" in tools
      assert "skill_activate" in tools
      assert "git_status" in tools
      assert "git_diff" in tools
    end

    test "exposes the full tool set (tool exposure is not trust-gated)" do
      # The trust-tier band was retired — core_tools/0 returns the full base
      # set. Tool *exposure* is not gated by trust; capabilities still gate
      # execution.
      tools = ToolDisclosure.core_tools()

      assert "shell_execute" in tools
      assert "code_compile_and_test" in tools
      assert "ai_generate_text" in tools
      assert "git_commit" in tools
      assert "git_log" in tools
      assert "shell_execute_script" in tools
      assert "code_hot_load" in tools
    end
  end

  describe "resolve_tools/2" do
    test "returns core tools when no explicit config" do
      config = %{}
      tools = ToolDisclosure.resolve_tools(config, MapSet.new())
      assert "tool_find_tools" in tools
      assert "file_read" in tools
    end

    test "uses explicit config when set, returns exactly those tools" do
      config = %{"tools" => ["custom_tool_a", "custom_tool_b"]}
      tools = ToolDisclosure.resolve_tools(config, MapSet.new())

      assert "custom_tool_a" in tools
      assert "custom_tool_b" in tools
      # Explicit tool lists are used as-is — find_tools is NOT force-injected.
      # This allows workers with scoped trust profiles to get exactly the tools
      # they need without discovery overhead.
      assert length(tools) == 2
    end

    test "explicit config with find_tools already present doesn't duplicate" do
      config = %{"tools" => ["tool_find_tools", "custom_tool"]}
      tools = ToolDisclosure.resolve_tools(config, MapSet.new())

      assert Enum.count(tools, &(&1 == "tool_find_tools")) == 1
    end

    test "explicit config with legacy find_tools name doesn't add duplicate" do
      config = %{"tools" => ["find_tools", "custom_tool"]}
      tools = ToolDisclosure.resolve_tools(config, MapSet.new())

      # find_tools is recognized as a valid name, so tool_find_tools is NOT added
      refute "tool_find_tools" in tools
      assert "find_tools" in tools
    end

    test "merges discovered tools with core tools" do
      discovered = MapSet.new(["web_browse", "ai_generate_text"])
      tools = ToolDisclosure.resolve_tools(%{}, discovered)

      assert "web_browse" in tools
      assert "ai_generate_text" in tools
      assert "file_read" in tools
    end

    test "deduplicates core + discovered" do
      # file_read is already in core
      discovered = MapSet.new(["file_read", "web_browse"])
      tools = ToolDisclosure.resolve_tools(%{}, discovered)

      assert Enum.count(tools, &(&1 == "file_read")) == 1
    end
  end

  describe "profile_tools/1" do
    setup :start_trust_infrastructure

    test "includes profile-mintable tools without granting capabilities", %{agent_id: agent_id} do
      set_policy_enforcer_enabled(true)
      create_profile_with_rules(agent_id, :ask, %{"arbor://fs/read" => :auto})

      {:ok, caps_before} = Arbor.Security.list_capabilities(agent_id)
      cap_ids_before = Enum.map(caps_before, & &1.id)
      refute Enum.any?(caps_before, &(&1.resource_uri == "arbor://fs/read"))

      assert {:ok, tools} = ToolDisclosure.profile_tools(agent_id)
      assert "file_read" in tools

      {:ok, caps_after} = Arbor.Security.list_capabilities(agent_id)
      assert Enum.map(caps_after, & &1.id) == cap_ids_before
      refute Enum.any?(caps_after, &(&1.resource_uri == "arbor://fs/read"))
    end
  end

  describe "merge_discovered/2" do
    test "adds new names to set" do
      existing = MapSet.new(["a", "b"])
      merged = ToolDisclosure.merge_discovered(existing, ["c", "d"])

      assert MapSet.member?(merged, "a")
      assert MapSet.member?(merged, "c")
      assert MapSet.member?(merged, "d")
    end

    test "deduplicates existing names" do
      existing = MapSet.new(["a", "b"])
      merged = ToolDisclosure.merge_discovered(existing, ["b", "c"])

      assert MapSet.size(merged) == 3
    end

    test "respects max_discovered_tools cap" do
      existing = MapSet.new(Enum.map(1..35, &"tool_#{&1}"))
      new_names = Enum.map(36..50, &"tool_#{&1}")
      merged = ToolDisclosure.merge_discovered(existing, new_names)

      assert MapSet.size(merged) <= ToolDisclosure.max_discovered_tools()
    end

    test "empty new_names returns existing unchanged" do
      existing = MapSet.new(["a"])
      assert ToolDisclosure.merge_discovered(existing, []) == existing
    end
  end

  describe "max_discovered_tools/0" do
    test "returns 40" do
      assert ToolDisclosure.max_discovered_tools() == 40
    end
  end

  describe "ensure_tool_capabilities/2" do
    test "returns :ok without crashing even when modules unavailable" do
      # In test env, Security/Actions may not be running, but it should not crash
      assert :ok ==
               ToolDisclosure.ensure_tool_capabilities("test_agent", [
                 "file_read",
                 "memory_recall"
               ])
    end

    test "handles empty tool list" do
      assert :ok == ToolDisclosure.ensure_tool_capabilities("test_agent", [])
    end

    test "handles unknown tool names gracefully" do
      assert :ok ==
               ToolDisclosure.ensure_tool_capabilities("test_agent", ["nonexistent_tool_xyz"])
    end
  end

  defp start_trust_infrastructure(_context) do
    ensure_started(Arbor.Security.Identity.Registry)
    ensure_started(Arbor.Security.SystemAuthority)
    ensure_started(Arbor.Security.CapabilityStore)
    ensure_started(Arbor.Security.Reflex.Registry)
    ensure_started(Arbor.Security.Constraint.RateLimiter)

    ensure_started(Arbor.Trust.EventStore)
    ensure_started(Arbor.Trust.Store)

    ensure_started(Arbor.Trust.Manager,
      circuit_breaker: false,
      decay: false,
      event_store: true
    )

    agent_id = "agent_tool_disclosure_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if Process.whereis(Arbor.Security.CapabilityStore) do
        case Arbor.Security.list_capabilities(agent_id) do
          {:ok, caps} -> Enum.each(caps, &Arbor.Security.revoke(&1.id))
          _ -> :ok
        end
      end
    end)

    {:ok, agent_id: agent_id}
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
