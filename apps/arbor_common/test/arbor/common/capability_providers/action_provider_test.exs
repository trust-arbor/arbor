defmodule Arbor.Common.CapabilityProviders.ActionProviderTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.CapabilityProviders.ActionProvider
  alias Arbor.Common.ActionRegistry
  alias Arbor.Contracts.CapabilityDescriptor

  @moduletag :fast

  setup do
    # Ensure ActionRegistry is started and has actions registered
    case :ets.info(:action_registry) do
      :undefined ->
        start_supervised!(ActionRegistry)

      _ ->
        :ok
    end

    # Register core actions if the table is empty
    if ActionRegistry.list_all() == [] do
      for {category, modules} <- Arbor.Actions.list_actions(), module <- modules do
        ActionRegistry.register_action(module, %{category: category})
      end
    end

    :ok
  end

  describe "list_capabilities/1" do
    test "returns descriptors for registered actions" do
      capabilities = ActionProvider.list_capabilities()
      assert is_list(capabilities)
      assert length(capabilities) > 0
      assert Enum.all?(capabilities, &match?(%CapabilityDescriptor{kind: :action}, &1))
    end

    test "all descriptors have action: prefix" do
      capabilities = ActionProvider.list_capabilities()
      assert Enum.all?(capabilities, &String.starts_with?(&1.id, "action:"))
    end

    test "no duplicate modules in results" do
      capabilities = ActionProvider.list_capabilities()

      modules =
        capabilities
        |> Enum.map(& &1.metadata.module)
        |> Enum.frequencies()

      duplicates = Enum.filter(modules, fn {_mod, count} -> count > 1 end)
      assert duplicates == [], "Found duplicate modules: #{inspect(duplicates)}"
    end

    test "known actions are present" do
      capabilities = ActionProvider.list_capabilities()
      ids = Enum.map(capabilities, & &1.id)
      assert "action:file.read" in ids
      assert "action:shell.execute" in ids
    end

    test "descriptors have string descriptions" do
      capabilities = ActionProvider.list_capabilities()

      for cap <- capabilities do
        assert is_binary(cap.description), "#{cap.id} description should be string"
      end
    end
  end

  describe "describe/1" do
    test "returns descriptor for valid action ID" do
      assert {:ok, %CapabilityDescriptor{} = desc} =
               ActionProvider.describe("action:file.read")

      assert desc.kind == :action
      assert desc.id == "action:file.read"
    end

    test "returns error for non-existent action" do
      assert {:error, :not_found} = ActionProvider.describe("action:nonexistent.action")
    end

    test "returns error for wrong ID prefix" do
      assert {:error, :not_found} = ActionProvider.describe("skill:file.read")
    end
  end

  describe "module_to_descriptor/3" do
    test "converts module info to descriptor" do
      desc =
        ActionProvider.module_to_descriptor(
          "file.read",
          Arbor.Actions.File.Read,
          %{category: :file}
        )

      assert %CapabilityDescriptor{} = desc
      assert desc.id == "action:file.read"
      assert desc.name == "File Read"
      assert desc.kind == :action
      assert desc.metadata.module == Arbor.Actions.File.Read
      assert desc.metadata.category == :file
    end

    test "humanizes dotted names" do
      desc =
        ActionProvider.module_to_descriptor(
          "git.status",
          Arbor.Actions.Git.Status,
          %{}
        )

      assert desc.name == "Git Status"
    end
  end
end
