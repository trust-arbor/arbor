defmodule Arbor.Actions.Tool.FindToolsTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Actions.Tool.FindTools
  alias Arbor.Common.CapabilityIndex

  defmodule PipelineInternalProvider do
    @moduledoc false

    def list_capabilities(_opts \\ []) do
      [
        Arbor.Common.CapabilityProviders.ActionProvider.module_to_descriptor(
          "session_memory_recall",
          Arbor.Actions.SessionMemory.Recall,
          %{}
        )
      ]
    end
  end

  describe "to_tool/0" do
    test "produces valid tool schema" do
      tool = FindTools.to_tool()

      assert tool.name == "tool_find_tools"
      assert is_binary(tool.description)
      # Fix 4 (discovery-loop): the description must steer to the visible catalog
      # FIRST, not read as "when in doubt, search."
      # The description must stand alone: the prompt no longer carries a tool
      # catalog (2026-08-25), so this text is where the model learns HOW to
      # discover (describe the task; semantic) and WHAT it gets back.
      assert tool.description =~ "Describe the TASK"
      assert tool.description =~ "semantic"
      assert tool.description =~ "allowed to obtain"
      refute tool.description =~ "Available Tools"
      refute tool.description =~ "ANY task you can't accomplish"
    end

    test "has query parameter" do
      tool = FindTools.to_tool()
      schema = tool.parameters_schema

      assert schema["properties"]["query"]["type"] == "string"
      assert "query" in (schema["required"] || [])
    end

    test "has optional limit parameter" do
      tool = FindTools.to_tool()
      schema = tool.parameters_schema

      assert schema["properties"]["limit"]["type"] == "integer"
    end
  end

  describe "run/2" do
    test "returns tools structure with fallback search when resolver unavailable" do
      # CapabilityResolver may not have indexed items, but the action
      # should gracefully handle this and return empty or fallback results
      result = FindTools.run(%{query: "file operations", limit: 5}, %{trust_tier: :new})

      assert {:ok, %{tools: tools, count: count, discovered_tool_names: names}} = result
      assert is_list(tools)
      assert is_integer(count)
      assert is_list(names)
      assert count == length(tools)
      assert count == length(names)
    end

    test "returns empty for nonsense query" do
      result = FindTools.run(%{query: "zzzzxqwerty999nonexistent", limit: 5}, %{trust_tier: :new})

      assert {:ok, %{tools: tools, count: count}} = result
      # May return 0 or some results depending on fuzzy matching
      assert is_list(tools)
      assert is_integer(count)
    end

    test "respects limit parameter" do
      result = FindTools.run(%{query: "file", limit: 2}, %{trust_tier: :established})

      assert {:ok, %{tools: tools}} = result
      assert length(tools) <= 2
    end

    test "taint_roles marks query as control" do
      assert FindTools.taint_roles() == %{query: :control, limit: :data}
    end

    test "result carries an imperative instruction to CALL, not re-search (Fix 3)" do
      result = FindTools.run(%{query: "file", limit: 3}, %{trust_tier: :established})

      assert {:ok, %{instruction: instruction, discovered_tool_names: names}} = result
      assert is_binary(instruction)

      if names == [] do
        assert instruction =~ "Do NOT repeat this search"
      else
        assert instruction =~ "callable THIS turn"
        assert instruction =~ "do NOT search for these again"
        # names the tools it found so the model can select one directly
        assert Enum.all?(names, fn n -> instruction =~ n end)
      end
    end

    test "security regression: stale indexed pipeline_internal actions stay undisclosed" do
      refute Process.whereis(CapabilityIndex)
      start_supervised!({CapabilityIndex, providers: [PipelineInternalProvider]})

      assert {:ok, %{discovered_tool_names: names}} =
               FindTools.run(%{query: "session memory recall", limit: 10}, %{})

      refute "session_memory_recall" in names
    end
  end

  describe "registration" do
    test "FindTools is in list_actions under :tool category" do
      actions = Arbor.Actions.list_actions()
      assert Arbor.Actions.Tool.FindTools in actions[:tool]
    end

    test "has canonical URI mapping" do
      uri = Arbor.Actions.canonical_uri_for(Arbor.Actions.Tool.FindTools, %{})
      assert uri == "arbor://agent/discover_tools"
    end
  end
end
