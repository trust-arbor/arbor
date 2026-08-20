defmodule Arbor.Common.CapabilityProviders.ActionProviderTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.CapabilityProviders.ActionProvider
  alias Arbor.Common.ActionRegistry
  alias Arbor.Contracts.CapabilityDescriptor

  @moduletag :fast

  defmodule Actions.File.Read do
    @moduledoc false

    def description, do: "Read a file"
    def tags, do: [:file, :read]
  end

  defmodule Actions.Shell.Execute do
    @moduledoc false

    def description, do: "Execute a shell command"
    def tags, do: [:shell]
  end

  defmodule Actions.Git.Status do
    @moduledoc false

    def description, do: "Show repository status"
    def tags, do: [:git]
  end

  setup do
    unless Process.whereis(ActionRegistry) do
      start_supervised!(ActionRegistry)
    end

    snapshot = ActionRegistry.snapshot()

    on_exit(fn ->
      if Process.whereis(ActionRegistry) do
        ActionRegistry.restore(snapshot)
      end
    end)

    :ok = ActionRegistry.reset()
    :ok = ActionRegistry.register_action(Actions.File.Read, %{category: :file})
    :ok = ActionRegistry.register_action(Actions.Shell.Execute, %{category: :shell})

    :ok
  end

  describe "list_capabilities/1" do
    test "returns descriptors for registered actions" do
      capabilities = ActionProvider.list_capabilities()
      assert is_list(capabilities)
      assert length(capabilities) == 2
      assert Enum.all?(capabilities, &match?(%CapabilityDescriptor{kind: :action}, &1))
    end

    test "all descriptors have action: prefix" do
      capabilities = ActionProvider.list_capabilities()
      assert Enum.all?(capabilities, &String.starts_with?(&1.id, "action:"))
    end

    test "deduplicates canonical and Jido aliases" do
      registered_modules =
        ActionRegistry.list_all()
        |> Enum.map(&elem(&1, 1))
        |> Enum.frequencies()

      assert registered_modules == %{
               Actions.File.Read => 2,
               Actions.Shell.Execute => 2
             }

      capabilities = ActionProvider.list_capabilities()

      modules =
        capabilities
        |> Enum.map(& &1.metadata.module)
        |> Enum.frequencies()

      duplicates = Enum.filter(modules, fn {_mod, count} -> count > 1 end)
      assert duplicates == [], "Found duplicate modules: #{inspect(duplicates)}"
    end

    test "test-local actions are present" do
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
          Actions.File.Read,
          %{category: :file}
        )

      assert %CapabilityDescriptor{} = desc
      assert desc.id == "action:file.read"
      assert desc.name == "File Read"
      assert desc.kind == :action
      assert desc.description == "Read a file"
      assert desc.tags == [:file, :read]
      assert desc.metadata.module == Actions.File.Read
      assert desc.metadata.category == :file
    end

    test "humanizes dotted names" do
      desc =
        ActionProvider.module_to_descriptor(
          "git.status",
          Actions.Git.Status,
          %{}
        )

      assert desc.name == "Git Status"
    end
  end
end
