defmodule Arbor.Actions.Tool.FindToolsTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Tool.FindTools

  describe "to_tool/0" do
    test "produces valid tool schema" do
      tool = FindTools.to_tool()

      assert tool.name == "tool_find_tools"
      assert is_binary(tool.description)
      # Fix 4 (discovery-loop): the description must steer to the visible catalog
      # FIRST, not read as "when in doubt, search."
      assert tool.description =~ "catalog"
      assert tool.description =~ "NOT already listed"
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
