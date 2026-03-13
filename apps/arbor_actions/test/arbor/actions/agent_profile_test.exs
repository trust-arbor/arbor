defmodule Arbor.Actions.AgentProfileTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Actions.AgentProfile.SetDisplayName

  describe "SetDisplayName" do
    test "validates empty name" do
      result = SetDisplayName.run(%{agent_id: "test", display_name: ""}, %{})
      assert {:error, "Display name must be a non-empty string"} = result
    end

    test "validates name too long" do
      long_name = String.duplicate("x", 101)
      result = SetDisplayName.run(%{agent_id: "test", display_name: long_name}, %{})
      assert {:error, "Display name must be 100 characters or fewer"} = result
    end

    test "returns error when profile not found" do
      result = SetDisplayName.run(%{agent_id: "nonexistent_agent", display_name: "NewName"}, %{})
      assert {:error, msg} = result
      assert msg =~ "not found" or msg =~ "not available"
    end

    test "has correct action metadata" do
      assert SetDisplayName.name() == "agent_profile_set_display_name"
      assert SetDisplayName.category() == "agent_profile"
      assert "agent" in SetDisplayName.tags()
      assert "name" in SetDisplayName.tags()
    end

    test "taint roles mark display_name as data" do
      roles = SetDisplayName.taint_roles()
      assert roles.agent_id == :control
      assert roles.display_name == :data
    end
  end
end
