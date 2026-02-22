defmodule Arbor.Actions.RelationshipTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Relationship.{Browse, Get, Moment, Save, Summarize}

  # No setup needed — these tests validate action metadata and facade registration.
  # Integration tests requiring the memory system should be tagged :integration.

  describe "Get" do
    test "has correct action metadata" do
      assert Get.name() == "relationship_get"
      assert Get.category() == "relationship"
    end

    test "requires name parameter" do
      schema = Get.schema()
      name_spec = Keyword.get(schema, :name)
      assert name_spec[:required] == true
    end

    test "defines taint_roles" do
      assert Get.taint_roles() == %{name: :data}
    end

    test "returns error without agent_id" do
      result = Get.run(%{name: "Unknown Person"}, %{})
      assert {:error, :missing_agent_id} = result
    end
  end

  describe "Save" do
    test "has correct action metadata" do
      assert Save.name() == "relationship_save"
      assert Save.category() == "relationship"
    end

    test "requires name parameter" do
      schema = Save.schema()
      name_spec = Keyword.get(schema, :name)
      assert name_spec[:required] == true
    end

    test "defines taint_roles for all parameters" do
      roles = Save.taint_roles()
      assert roles[:name] == :data
      assert roles[:background] == :data
      assert roles[:values] == :data
      assert roles[:relationship_dynamic] == :data
    end

    test "returns error without agent_id" do
      result = Save.run(%{name: "Test"}, %{})
      assert {:error, :missing_agent_id} = result
    end
  end

  describe "Moment" do
    test "has correct action metadata" do
      assert Moment.name() == "relationship_moment"
      assert Moment.category() == "relationship"
    end

    test "requires name and summary parameters" do
      schema = Moment.schema()
      assert Keyword.get(schema, :name)[:required] == true
      assert Keyword.get(schema, :summary)[:required] == true
    end

    test "defines taint_roles" do
      roles = Moment.taint_roles()
      assert roles[:name] == :data
      assert roles[:summary] == :data
      assert roles[:emotional_markers] == :data
    end
  end

  describe "Browse" do
    test "has correct action metadata" do
      assert Browse.name() == "relationship_browse"
      assert Browse.category() == "relationship"
    end

    test "sort_by is a control parameter" do
      roles = Browse.taint_roles()
      assert roles[:sort_by] == :control
    end

    test "has default limit of 20" do
      schema = Browse.schema()
      assert Keyword.get(schema, :limit)[:default] == 20
    end
  end

  describe "Summarize" do
    test "has correct action metadata" do
      assert Summarize.name() == "relationship_summarize"
      assert Summarize.category() == "relationship"
    end

    test "requires name parameter" do
      schema = Summarize.schema()
      assert Keyword.get(schema, :name)[:required] == true
    end

    test "has full as default format" do
      schema = Summarize.schema()
      assert Keyword.get(schema, :format)[:default] == "full"
    end

    test "format is a control parameter" do
      roles = Summarize.taint_roles()
      assert roles[:format] == :control
      assert roles[:name] == :data
    end
  end

  describe "facade registration" do
    test "relationship category exists in list_actions" do
      actions = Arbor.Actions.list_actions()
      assert Map.has_key?(actions, :relationship)
      assert length(actions[:relationship]) == 5
    end

    test "name_to_module resolves relationship actions via generated names" do
      assert {:ok, Get} == Arbor.Actions.name_to_module("relationship.get")
      assert {:ok, Save} == Arbor.Actions.name_to_module("relationship.save")
      assert {:ok, Moment} == Arbor.Actions.name_to_module("relationship.moment")
      assert {:ok, Browse} == Arbor.Actions.name_to_module("relationship.browse")
      assert {:ok, Summarize} == Arbor.Actions.name_to_module("relationship.summarize")
    end

    test "name_to_module resolves underscore-separated names" do
      # Underscore-only names get underscores converted to dots
      assert {:ok, Get} == Arbor.Actions.name_to_module("relationship_get")
      assert {:ok, Save} == Arbor.Actions.name_to_module("relationship_save")
      assert {:ok, Browse} == Arbor.Actions.name_to_module("relationship_browse")
      assert {:ok, Summarize} == Arbor.Actions.name_to_module("relationship_summarize")
    end
  end
end
