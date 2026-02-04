defmodule Arbor.Security.Reflex.RegistryTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Reflex
  alias Arbor.Security.Reflex.Registry

  setup do
    # Clear the registry before each test
    # We use skip_builtin: false since the global registry already has builtins
    # Just clear any test reflexes we add
    :ok
  end

  describe "register/3" do
    test "registers a new reflex" do
      reflex = Reflex.pattern("test_reflex", ~r/test/, id: "test_register")
      assert :ok = Registry.register(:test_register, reflex)

      # Verify it was registered
      assert {:ok, ^reflex} = Registry.get(:test_register)

      # Cleanup
      Registry.unregister(:test_register)
    end

    test "returns error if reflex already exists" do
      reflex = Reflex.pattern("test_dup", ~r/test/, id: "test_dup")
      assert :ok = Registry.register(:test_dup, reflex)
      assert {:error, :already_exists} = Registry.register(:test_dup, reflex)

      # Cleanup
      Registry.unregister(:test_dup)
    end

    test "overwrites with force: true" do
      reflex1 = Reflex.pattern("test_force_1", ~r/test1/, id: "test_force")
      reflex2 = Reflex.pattern("test_force_2", ~r/test2/, id: "test_force")

      assert :ok = Registry.register(:test_force, reflex1)
      assert :ok = Registry.register(:test_force, reflex2, force: true)

      {:ok, stored} = Registry.get(:test_force)
      assert stored.name == "test_force_2"

      # Cleanup
      Registry.unregister(:test_force)
    end
  end

  describe "unregister/1" do
    test "removes a registered reflex" do
      reflex = Reflex.pattern("test_unreg", ~r/test/, id: "test_unreg")
      Registry.register(:test_unreg, reflex)

      assert :ok = Registry.unregister(:test_unreg)
      assert {:error, :not_found} = Registry.get(:test_unreg)
    end

    test "returns error for non-existent reflex" do
      assert {:error, :not_found} = Registry.unregister(:definitely_not_exists)
    end
  end

  describe "get/1" do
    test "retrieves a registered reflex" do
      reflex = Reflex.pattern("test_get", ~r/get/, id: "test_get")
      Registry.register(:test_get, reflex)

      assert {:ok, ^reflex} = Registry.get(:test_get)

      # Cleanup
      Registry.unregister(:test_get)
    end

    test "returns error for non-existent reflex" do
      assert {:error, :not_found} = Registry.get(:nonexistent)
    end
  end

  describe "list/1" do
    test "lists all reflexes including builtins" do
      reflexes = Registry.list()
      # Should have built-in reflexes
      assert length(reflexes) > 0
    end

    test "sorts by priority descending by default" do
      reflexes = Registry.list(sorted: true)
      priorities = Enum.map(reflexes, & &1.priority)
      assert priorities == Enum.sort(priorities, :desc)
    end

    test "filters enabled only when requested" do
      # Add a disabled reflex
      disabled = Reflex.pattern("test_disabled", ~r/disabled/, id: "test_disabled", enabled: false)
      Registry.register(:test_disabled, disabled)

      all = Registry.list()
      enabled_only = Registry.list(enabled_only: true)

      assert length(all) > length(enabled_only)
      refute Enum.any?(enabled_only, &(&1.id == "test_disabled"))

      # Cleanup
      Registry.unregister(:test_disabled)
    end
  end

  describe "stats/0" do
    test "returns registry statistics" do
      stats = Registry.stats()

      assert Map.has_key?(stats, :total)
      assert Map.has_key?(stats, :enabled)
      assert Map.has_key?(stats, :disabled)
      assert Map.has_key?(stats, :by_type)
      assert Map.has_key?(stats, :by_response)

      assert stats.total >= stats.enabled
      assert is_map(stats.by_type)
      assert is_map(stats.by_response)
    end
  end

  describe "built-in reflexes" do
    test "loads built-in reflexes on startup" do
      # Check for some expected built-in reflexes
      assert {:ok, _} = Registry.get(:rm_rf_root)
      assert {:ok, _} = Registry.get(:sudo_su)
      assert {:ok, _} = Registry.get(:ssh_private_keys)
      assert {:ok, _} = Registry.get(:ssrf_metadata)
    end

    test "built-in reflexes have correct structure" do
      {:ok, rm_rf} = Registry.get(:rm_rf_root)

      assert rm_rf.id == "rm_rf_root"
      assert rm_rf.type == :pattern
      assert rm_rf.response == :block
      assert rm_rf.priority == 100
      assert is_binary(rm_rf.message)
    end
  end
end
