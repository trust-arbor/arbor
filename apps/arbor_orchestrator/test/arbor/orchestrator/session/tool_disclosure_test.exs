defmodule Arbor.Orchestrator.Session.ToolDisclosureTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Orchestrator.Session.ToolDisclosure

  describe "core_tools/0" do
    test "is the universal floor: memory, skills, discovery, generation" do
      tools = ToolDisclosure.core_tools()

      # Memory is foundational to being an agent, so the recall/remember pair
      # is floor, not an opt-in.
      assert "memory_recall" in tools
      assert "memory_remember" in tools
      assert "skill_search" in tools
      assert "skill_activate" in tools
      assert "tool_find_tools" in tools
      assert "ai_generate_text" in tools
    end

    test "does not carry development tooling" do
      # These used to be in the base list, so EVERY agent — a conversationalist
      # included — carried a coding agent's toolkit as its permanent floor.
      # They are a granted collection now. Exposure is still not trust-gated;
      # the point is that dev tools are not UNIVERSAL, not that trust hides them.
      tools = ToolDisclosure.core_tools()

      for dev_tool <- ~w(file_read file_write file_edit git_status git_diff
                         git_commit git_log shell_execute shell_execute_script
                         code_compile_and_test code_hot_load) do
        refute dev_tool in tools, "#{dev_tool} should be in the coding collection, not the floor"
      end
    end

    test "coding_tools/0 holds the development collection, including code patterns" do
      tools = ToolDisclosure.coding_tools()

      assert "file_read" in tools
      assert "shell_execute" in tools
      assert "git_commit" in tools
      assert "code_hot_load" in tools

      # Memory-BACKED but code-domain: useful to exactly the agents holding the
      # rest of this collection, not to every agent with memory.
      assert "code_pattern_store" in tools
      assert "code_pattern_view" in tools

      # The floor and the collection are disjoint.
      assert MapSet.disjoint?(MapSet.new(tools), MapSet.new(ToolDisclosure.core_tools()))
    end
  end

  describe "resolve_tools/2" do
    test "returns core tools when no explicit config" do
      config = %{}
      tools = ToolDisclosure.resolve_tools(config, MapSet.new())
      assert "tool_find_tools" in tools
      assert "memory_recall" in tools
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
      assert "memory_recall" in tools
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

    test "leaves policy-mintable tools to discovery and mints nothing", %{agent_id: agent_id} do
      set_policy_enforcer_enabled(true)
      create_profile_with_rules(agent_id, :ask, %{"arbor://fs/read" => :auto})

      {:ok, caps_before} = Arbor.Security.list_capabilities(agent_id)
      cap_ids_before = Enum.map(caps_before, & &1.id)
      refute Enum.any?(caps_before, &(&1.resource_uri == "arbor://fs/read"))

      assert {:ok, tools} = ToolDisclosure.profile_tools(agent_id)

      # Mintable-but-not-held is reachable through tool_find_tools, not shown by
      # default. Disclosing every mintable URI is what put a 12-capability
      # conversationalist at 151 tools (2026-08-25).
      refute "file_read" in tools
      assert "tool_find_tools" in tools

      # The floor is always there.
      for floor <- ToolDisclosure.core_tools(), do: assert(floor in tools)

      # Still read-only.
      {:ok, caps_after} = Arbor.Security.list_capabilities(agent_id)
      assert Enum.map(caps_after, & &1.id) == cap_ids_before
    end

    test "discloses a tool whose exact canonical capability is held", %{agent_id: agent_id} do
      set_policy_enforcer_enabled(true)
      create_profile_with_rules(agent_id, :ask, %{})
      grant!(agent_id, "arbor://fs/read")

      assert {:ok, tools} = ToolDisclosure.profile_tools(agent_id)
      assert "file_read" in tools
      refute "file_write" in tools
    end

    test "discloses a tool held under an ancestor wildcard grant", %{agent_id: agent_id} do
      set_policy_enforcer_enabled(true)
      create_profile_with_rules(agent_id, :ask, %{})
      grant!(agent_id, "arbor://fs/**")

      assert {:ok, tools} = ToolDisclosure.profile_tools(agent_id)
      assert "file_read" in tools
      assert "file_write" in tools
    end

    test "discloses a tool held under a SCOPED grant (regression: exact match drops it)",
         %{agent_id: agent_id} do
      set_policy_enforcer_enabled(true)
      create_profile_with_rules(agent_id, :ask, %{})

      # This is the shape ACP and self-memory grants actually take. It does not
      # authorize the bare `arbor://fs/read` resource, so Trust's own
      # per-candidate `held` flag is false for it — an exact-match mapping
      # silently hides file_read from every agent that holds only scoped paths.
      grant!(agent_id, "arbor://fs/read/tmp/tool_disclosure_test/**")

      {:ok, snapshot} = Arbor.Trust.enumerate_authority(agent_id, ["arbor://fs/read"])
      [entry] = snapshot.candidate_entries
      refute entry.held, "precondition: scoped grant is not exact authority for the bare URI"

      assert {:ok, tools} = ToolDisclosure.profile_tools(agent_id)
      assert "file_read" in tools
      refute "file_list" in tools
    end

    test "never discloses a pipeline_internal graph syscall, even when its capability is held",
         %{agent_id: agent_id} do
      set_policy_enforcer_enabled(true)
      create_profile_with_rules(agent_id, :ask, %{})

      # session_memory_* are exec-node syscalls under arbor://orchestrator/**,
      # which ordinary agents hold. The LLM handler resolves disclosed names
      # through the registry with no pipeline_internal filter, so disclosure is
      # the gate. 28d2b32ff closed this on the APIAgent path only; the DOT
      # session path still showed 15 graph syscalls live (2026-08-25).
      {:ok, uri} = Arbor.Actions.tool_name_to_canonical_uri("session_memory_recall")
      grant!(agent_id, uri)

      assert {:ok, tools} = ToolDisclosure.profile_tools(agent_id)
      refute "session_memory_recall" in tools
      assert "memory_recall" in tools
    end

    test "the disclosed find_tools is actually executable under an :auto rule (regression: unprofiled)",
         %{agent_id: agent_id} do
      set_policy_enforcer_enabled(true)
      {:ok, uri} = Arbor.Actions.tool_name_to_canonical_uri("tool_find_tools")
      create_profile_with_rules(agent_id, :ask, %{uri => :auto})

      assert {:ok, tools} = ToolDisclosure.profile_tools(agent_id)
      assert "tool_find_tools" in tools

      # Disclosure is floor ∪ held, so discovery is the only path to everything
      # else. It was disclosed but unmintable (:unprofiled) on the live
      # onboarding node 2026-08-25: the agent called it correctly, was refused,
      # and the turn failed.
      assert {:ok, _} = Arbor.Trust.authorize(agent_id, uri, :execute)
    end

    test "a :block rule hides the tool even when it is in the floor", %{agent_id: agent_id} do
      set_policy_enforcer_enabled(true)
      create_profile_with_rules(agent_id, :ask, %{"arbor://memory/recall" => :block})

      assert "memory_recall" in ToolDisclosure.core_tools()
      assert {:ok, tools} = ToolDisclosure.profile_tools(agent_id)
      refute "memory_recall" in tools
      assert "memory_remember" in tools
    end
  end

  defp grant!(agent_id, resource) do
    {:ok, cap} = Arbor.Security.grant(principal: agent_id, resource: resource)
    cap
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

  describe "truncation priority" do
    test "curated tools survive when the authorized set overflows the cap" do
      # A default-baseline agent is authorized for far more than it HOLDS: every
      # low-risk/reversible/cheap URI is policy-mintable, so a real
      # conversationalist reached 151 tools from 12 held capabilities
      # (2026-08-25). That overflows @max_tools_for_llm and the list is cut.
      #
      # `core` arrives in Map.keys/1 order — arbitrary — so before prioritising,
      # whether `memory_recall` survived the cut was luck. Reproduce the bad
      # ordering directly: bury the curated tools past the cap.
      filler = for i <- 1..200, do: "filler_tool_#{i}"
      core = filler ++ ["memory_recall", "memory_remember", "file_read"]

      prioritized = ToolDisclosure.prioritize_base_tools(core)
      kept = Enum.take(prioritized, 120)

      assert "memory_recall" in kept
      assert "memory_remember" in kept
      assert "file_read" in kept

      # Ordering only — nothing added, nothing dropped.
      assert Enum.sort(prioritized) == Enum.sort(core)

      # Without prioritising, these are exactly the ones that fall off.
      refute "memory_recall" in Enum.take(core, 120)
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
