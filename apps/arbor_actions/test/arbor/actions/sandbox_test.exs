defmodule Arbor.Actions.SandboxTest do
  use Arbor.Actions.ActionCase, async: true

  alias Arbor.Actions.Sandbox

  @moduletag :fast

  describe "Create" do
    test "schema validates correctly" do
      # Test that schema rejects missing required fields
      assert {:error, _} = Sandbox.Create.validate_params(%{})

      # Test that schema accepts valid params
      assert {:ok, _} = Sandbox.Create.validate_params(%{agent_id: "agent_001"})

      # Test with optional level
      assert {:ok, _} =
               Sandbox.Create.validate_params(%{
                 agent_id: "agent_001",
                 level: "limited"
               })
    end

    test "schema rejects invalid level" do
      assert {:error, _} =
               Sandbox.Create.validate_params(%{
                 agent_id: "agent_001",
                 level: "invalid_level"
               })
    end

    test "validates action metadata" do
      assert Sandbox.Create.name() == "sandbox_create"
      assert Sandbox.Create.category() == "sandbox"
      assert "sandbox" in Sandbox.Create.tags()
      assert "create" in Sandbox.Create.tags()
    end

    test "generates tool schema" do
      tool = Sandbox.Create.to_tool()
      assert is_map(tool)
      assert tool[:name] == "sandbox_create"
      assert tool[:description] =~ "sandbox"
    end
  end

  describe "Destroy" do
    test "schema validates correctly" do
      # Test that schema rejects missing required fields
      assert {:error, _} = Sandbox.Destroy.validate_params(%{})

      # Test that schema accepts valid params
      assert {:ok, _} = Sandbox.Destroy.validate_params(%{sandbox_id: "sbx_abc123"})
    end

    test "validates action metadata" do
      assert Sandbox.Destroy.name() == "sandbox_destroy"
      assert Sandbox.Destroy.category() == "sandbox"
      assert "sandbox" in Sandbox.Destroy.tags()
      assert "destroy" in Sandbox.Destroy.tags()
    end

    test "generates tool schema" do
      tool = Sandbox.Destroy.to_tool()
      assert is_map(tool)
      assert tool[:name] == "sandbox_destroy"
      assert tool[:description] =~ "Destroy"
    end
  end

  describe "module structure" do
    test "modules compile and are usable" do
      assert Code.ensure_loaded?(Sandbox.Create)
      assert Code.ensure_loaded?(Sandbox.Destroy)

      assert function_exported?(Sandbox.Create, :run, 2)
      assert function_exported?(Sandbox.Destroy, :run, 2)
    end
  end
end
