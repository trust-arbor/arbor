defmodule Arbor.Agent.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Capabilities

  describe "resolve/2" do
    test "resolves physical capability to action module" do
      assert {:ok, {:action, Arbor.Actions.File.Read}} = Capabilities.resolve("fs", :read)

      assert {:ok, {:action, Arbor.Actions.Shell.Execute}} =
               Capabilities.resolve("shell", :execute)

      assert {:ok, {:action, Arbor.Actions.Git.Status}} = Capabilities.resolve("git", :status)
      assert {:ok, {:action, Arbor.Actions.Git.Commit}} = Capabilities.resolve("git", :commit)
    end

    test "resolves mental action-backed capability" do
      assert {:ok, {:action, Arbor.Actions.Memory.Recall}} =
               Capabilities.resolve("memory", :recall)

      assert {:ok, {:action, Arbor.Actions.Memory.Remember}} =
               Capabilities.resolve("memory", :remember)

      assert {:ok, {:action, Arbor.Actions.MemoryIdentity.ReadSelf}} =
               Capabilities.resolve("memory", :read_self)
    end

    test "resolves mental store-backed capability" do
      assert {:ok, {:mental, :goal_add}} = Capabilities.resolve("goal", :add)
      assert {:ok, {:mental, :goal_list}} = Capabilities.resolve("goal", :list)
      assert {:ok, {:mental, :plan_add}} = Capabilities.resolve("plan", :add)
      assert {:ok, {:mental, :compute_run}} = Capabilities.resolve("compute", :run)
      assert {:ok, {:mental, :think_reflect}} = Capabilities.resolve("think", :reflect)
      assert {:ok, {:mental, :think_describe}} = Capabilities.resolve("think", :describe)
    end

    test "resolves host-only capability" do
      assert {:ok, {:host_only, Arbor.Actions.Sandbox.Create}} =
               Capabilities.resolve("sandbox", :create)

      assert {:ok, {:host_only, Arbor.Actions.BackgroundChecks.Run}} =
               Capabilities.resolve("background_checks", :run)
    end

    test "returns error for unknown capability" do
      assert {:error, :unknown_capability} = Capabilities.resolve("nonexistent", :nope)
    end

    test "returns error for unknown op on known capability" do
      assert {:error, :unknown_capability} = Capabilities.resolve("fs", :teleport)
    end

    test "council.propose maps to Proposal.Submit" do
      assert {:ok, {:action, Arbor.Actions.Proposal.Submit}} =
               Capabilities.resolve("council", :propose)
    end

    test "code.compile and code.test both map to CompileAndTest" do
      assert {:ok, {:action, Arbor.Actions.Code.CompileAndTest}} =
               Capabilities.resolve("code", :compile)

      assert {:ok, {:action, Arbor.Actions.Code.CompileAndTest}} =
               Capabilities.resolve("code", :test)
    end

    test "code.analyze maps to AI.AnalyzeCode" do
      assert {:ok, {:action, Arbor.Actions.AI.AnalyzeCode}} =
               Capabilities.resolve("code", :analyze)
    end

    test "pipeline.compile_skill maps to Skill.Compile" do
      assert {:ok, {:action, Arbor.Actions.Skill.Compile}} =
               Capabilities.resolve("pipeline", :compile_skill)
    end
  end

  describe "resolve_action/2" do
    test "returns module for action-backed capabilities" do
      assert {:ok, Arbor.Actions.File.Read} = Capabilities.resolve_action("fs", :read)
      assert {:ok, Arbor.Actions.Memory.Recall} = Capabilities.resolve_action("memory", :recall)
    end

    test "returns error for mental store-backed capabilities" do
      assert {:error, :mental_not_action} = Capabilities.resolve_action("goal", :add)
    end

    test "returns error for host-only capabilities" do
      assert {:error, :host_only} = Capabilities.resolve_action("sandbox", :create)
    end

    test "returns error for unknown capabilities" do
      assert {:error, :unknown_capability} = Capabilities.resolve_action("nope", :nope)
    end
  end

  describe "classification" do
    test "physical? identifies physical capabilities" do
      assert Capabilities.physical?("fs")
      assert Capabilities.physical?("shell")
      assert Capabilities.physical?("git")
      assert Capabilities.physical?("council")
      refute Capabilities.physical?("memory")
      refute Capabilities.physical?("goal")
    end

    test "mental? identifies mental capabilities" do
      assert Capabilities.mental?("memory")
      assert Capabilities.mental?("goal")
      assert Capabilities.mental?("plan")
      assert Capabilities.mental?("proposal")
      assert Capabilities.mental?("compute")
      assert Capabilities.mental?("think")
      refute Capabilities.mental?("fs")
      refute Capabilities.mental?("shell")
    end

    test "host_only? identifies host-only capabilities" do
      assert Capabilities.host_only?("sandbox")
      assert Capabilities.host_only?("background_checks")
      assert Capabilities.host_only?("eval")
      refute Capabilities.host_only?("fs")
      refute Capabilities.host_only?("memory")
    end

    test "category returns correct category" do
      assert :physical = Capabilities.category("fs")
      assert :mental = Capabilities.category("goal")
      assert :host_only = Capabilities.category("sandbox")
      assert nil == Capabilities.category("nonexistent")
    end
  end

  describe "discovery" do
    test "mind_capabilities includes physical and mental" do
      caps = Capabilities.mind_capabilities()
      assert "fs" in caps
      assert "shell" in caps
      assert "memory" in caps
      assert "goal" in caps
      assert "think" in caps
      refute "sandbox" in caps
      refute "background_checks" in caps
    end

    test "physical_capabilities returns only physical" do
      caps = Capabilities.physical_capabilities()
      assert "fs" in caps
      assert "shell" in caps
      refute "memory" in caps
      refute "goal" in caps
    end

    test "mental_capabilities returns only mental" do
      caps = Capabilities.mental_capabilities()
      assert "memory" in caps
      assert "goal" in caps
      assert "think" in caps
      refute "fs" in caps
      refute "shell" in caps
    end

    test "all_capability_names includes everything" do
      caps = Capabilities.all_capability_names()
      assert "fs" in caps
      assert "memory" in caps
      assert "sandbox" in caps
    end

    test "ops returns all operations for a capability" do
      fs_ops = Capabilities.ops("fs")
      assert :read in fs_ops
      assert :write in fs_ops
      assert :edit in fs_ops
      assert :list in fs_ops
      assert :glob in fs_ops
      assert :search in fs_ops
      assert :exists in fs_ops
    end

    test "ops returns empty for unknown capability" do
      assert [] = Capabilities.ops("nonexistent")
    end

    test "count returns total capability/op pairs" do
      assert Capabilities.count() > 0
    end
  end

  describe "progressive disclosure" do
    test "level 0 returns just the name" do
      assert "fs" = Capabilities.describe("fs", 0)
    end

    test "level 1 returns name with operations" do
      result = Capabilities.describe("fs", 1)
      assert String.starts_with?(result, "fs:")
      assert String.contains?(result, "read")
      assert String.contains?(result, "write")
    end

    test "level 2 returns full description" do
      result = Capabilities.describe("fs", 2)
      assert String.contains?(result, "File System")
      assert String.contains?(result, "read")
      assert String.contains?(result, "path")
    end

    test "unknown capability returns just the name at any level" do
      assert "unknown" = Capabilities.describe("unknown", 0)
      assert "unknown" = Capabilities.describe("unknown", 1)
      assert "unknown" = Capabilities.describe("unknown", 2)
    end

    test "all mind capabilities have descriptions" do
      for cap <- Capabilities.mind_capabilities() do
        result = Capabilities.describe(cap, 1)

        assert String.contains?(result, ":"),
               "Missing description for #{cap}: got #{inspect(result)}"
      end
    end
  end

  describe "prompt/2" do
    test "level 0 prompt is compact" do
      prompt = Capabilities.prompt(0)
      assert String.contains?(prompt, "Available:")
      assert String.contains?(prompt, "fs")
      assert String.contains?(prompt, "think")
      assert String.contains?(prompt, "describe")
      # Should be under ~200 chars
      assert String.length(prompt) < 500
    end

    test "level 1 prompt shows operations" do
      prompt = Capabilities.prompt(1)
      assert String.contains?(prompt, "fs:")
      assert String.contains?(prompt, "read")
    end

    test "level 2 prompt shows full details" do
      prompt = Capabilities.prompt(2)
      assert String.contains?(prompt, "File System")
      assert String.contains?(prompt, "Read file contents")
    end

    test "only: :physical filters to physical only" do
      prompt = Capabilities.prompt(1, only: :physical)
      assert String.contains?(prompt, "fs:")
      refute String.contains?(prompt, "goal:")
    end

    test "only: :mental filters to mental only" do
      prompt = Capabilities.prompt(1, only: :mental)
      assert String.contains?(prompt, "goal:")
      refute String.contains?(prompt, "fs:")
    end
  end

  describe "goal_aware_prompt/1" do
    test "expands capabilities relevant to goals" do
      goals = ["Read the configuration file and fix the bug"]
      prompt = Capabilities.goal_aware_prompt(goals)
      # "file" and "read" should trigger fs expansion
      assert String.contains?(prompt, "fs:")
    end

    test "leaves irrelevant capabilities compact" do
      goals = ["Send a message to the team"]
      prompt = Capabilities.goal_aware_prompt(goals)
      # comms should be expanded (message, send)
      assert String.contains?(prompt, "comms:")
      # fs shouldn't be expanded (no file keywords)
      refute String.contains?(prompt, "fs:")
    end

    test "handles empty goals" do
      prompt = Capabilities.goal_aware_prompt([])
      assert String.contains?(prompt, "Available:")
    end

    test "handles map-based goals" do
      goals = [%{description: "Compile and test the module", title: "Testing"}]
      prompt = Capabilities.goal_aware_prompt(goals)
      # "compile" and "test" should trigger code expansion
      assert String.contains?(prompt, "code:")
    end
  end
end
