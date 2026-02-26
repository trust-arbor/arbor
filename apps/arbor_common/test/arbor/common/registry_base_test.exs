defmodule Arbor.Common.RegistryBaseTest do
  use ExUnit.Case, async: false

  # Define a test behaviour
  defmodule TestBehaviour do
    @callback do_something() :: :ok
  end

  # Define modules implementing the behaviour
  defmodule GoodImpl do
    @behaviour TestBehaviour
    def do_something, do: :ok
  end

  defmodule AvailableImpl do
    @behaviour TestBehaviour
    def do_something, do: :ok
    def available?, do: true
  end

  defmodule UnavailableImpl do
    @behaviour TestBehaviour
    def do_something, do: :ok
    def available?, do: false
  end

  defmodule NoBehaviourImpl do
    def do_something, do: :ok
  end

  # Define test registries
  defmodule BasicRegistry do
    use Arbor.Common.RegistryBase,
      table_name: :test_basic_registry
  end

  defmodule StrictRegistry do
    use Arbor.Common.RegistryBase,
      table_name: :test_strict_registry,
      require_behaviour: TestBehaviour
  end

  defmodule OverwriteRegistry do
    use Arbor.Common.RegistryBase,
      table_name: :test_overwrite_registry,
      allow_overwrite: true
  end

  defmodule CircuitBreakerRegistry do
    use Arbor.Common.RegistryBase,
      table_name: :test_cb_registry,
      max_failures: 3
  end

  defmodule CustomValidationRegistry do
    use Arbor.Common.RegistryBase,
      table_name: :test_custom_validation_registry

    def validate_entry(name, _module, _metadata) do
      if String.starts_with?(name, "valid_") do
        :ok
      else
        {:error, :invalid_name_prefix}
      end
    end
  end

  defp stop_registry(registry) do
    # Erase persistent_term snapshot before stopping
    try do
      :persistent_term.erase({registry, :core_snapshot})
    rescue
      ArgumentError -> :ok
    end

    case GenServer.whereis(registry) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    # Give heir a moment to receive ETS-TRANSFER, then delete the table
    Process.sleep(10)

    for table <- [
          :test_strict_registry,
          :test_overwrite_registry,
          :test_cb_registry,
          :test_custom_validation_registry
        ] do
      try do
        :ets.delete(table)
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp ensure_started(registry) do
    case GenServer.whereis(registry) do
      nil -> {:ok, _} = registry.start_link()
      _pid -> registry.reset()
    end
  end

  defp ensure_basic_registry do
    case GenServer.whereis(BasicRegistry) do
      nil ->
        {:ok, _} = BasicRegistry.start_link()

      _pid ->
        :ok
    end
  rescue
    _ ->
      Process.sleep(50)
      {:ok, _} = BasicRegistry.start_link()
  catch
    :exit, _ ->
      Process.sleep(50)
      {:ok, _} = BasicRegistry.start_link()
  end

  defp safe_basic_reset do
    BasicRegistry.reset()
  catch
    :exit, _ ->
      Process.sleep(50)
      ensure_basic_registry()
      BasicRegistry.reset()
  end

  setup do
    ensure_basic_registry()
    safe_basic_reset()

    on_exit(fn ->
      # Don't stop — let the process persist across tests to avoid heir issues.
      # reset/0 in setup handles isolation.
      :ok
    end)

    :ok
  end

  describe "register/3 and resolve/1" do
    test "registers and resolves a module" do
      assert :ok = BasicRegistry.register("test", GoodImpl)
      assert {:ok, GoodImpl} = BasicRegistry.resolve("test")
    end

    test "resolves with metadata via resolve_entry/1" do
      meta = %{cost: 0.01, provider: "local"}
      assert :ok = BasicRegistry.register("test", GoodImpl, meta)
      assert {:ok, {"test", GoodImpl, ^meta}} = BasicRegistry.resolve_entry("test")
    end

    test "returns :not_found for unregistered name" do
      assert {:error, :not_found} = BasicRegistry.resolve("nonexistent")
    end

    test "returns :not_found for entry resolve" do
      assert {:error, :not_found} = BasicRegistry.resolve_entry("nonexistent")
    end

    test "default metadata is empty map" do
      :ok = BasicRegistry.register("test", GoodImpl)
      {:ok, {"test", GoodImpl, meta}} = BasicRegistry.resolve_entry("test")
      assert meta == %{}
    end
  end

  describe "deregister/1" do
    test "removes a registered entry" do
      :ok = BasicRegistry.register("test", GoodImpl)
      assert {:ok, GoodImpl} = BasicRegistry.resolve("test")

      assert :ok = BasicRegistry.deregister("test")
      assert {:error, :not_found} = BasicRegistry.resolve("test")
    end

    test "returns :not_found for unregistered name" do
      assert {:error, :not_found} = BasicRegistry.deregister("nonexistent")
    end
  end

  describe "list_all/0 and list_available/0" do
    test "lists all registered entries" do
      :ok = BasicRegistry.register("a", GoodImpl, %{order: 1})
      :ok = BasicRegistry.register("b", GoodImpl, %{order: 2})

      entries = BasicRegistry.list_all()
      assert length(entries) == 2

      names = Enum.map(entries, fn {name, _mod, _meta} -> name end) |> Enum.sort()
      assert names == ["a", "b"]
    end

    test "list_available excludes unavailable modules" do
      :ok = BasicRegistry.register("available", AvailableImpl)
      :ok = BasicRegistry.register("unavailable", UnavailableImpl)
      :ok = BasicRegistry.register("no_check", GoodImpl)

      available = BasicRegistry.list_available()
      names = Enum.map(available, fn {name, _mod, _meta} -> name end) |> Enum.sort()
      assert "available" in names
      assert "no_check" in names
      refute "unavailable" in names
    end
  end

  describe "namespace sovereignty" do
    test "lock_core prevents overwriting core entries" do
      :ok = BasicRegistry.register("core_source", GoodImpl)
      :ok = BasicRegistry.lock_core()

      assert BasicRegistry.core_locked?()
      assert {:error, :core_locked} = BasicRegistry.register("core_source", AvailableImpl)

      # But the original is still resolvable
      assert {:ok, GoodImpl} = BasicRegistry.resolve("core_source")
    end

    test "lock_core prevents deregistering core entries" do
      :ok = BasicRegistry.register("core_source", GoodImpl)
      :ok = BasicRegistry.lock_core()

      assert {:error, :core_locked} = BasicRegistry.deregister("core_source")
    end

    test "new entries can be registered after lock" do
      :ok = BasicRegistry.register("core_source", GoodImpl)
      :ok = BasicRegistry.lock_core()

      assert :ok = BasicRegistry.register("plugin.new_source", AvailableImpl)
      assert {:ok, AvailableImpl} = BasicRegistry.resolve("plugin.new_source")
    end

    test "new entries registered after lock can be deregistered" do
      :ok = BasicRegistry.register("core_source", GoodImpl)
      :ok = BasicRegistry.lock_core()
      :ok = BasicRegistry.register("plugin.new_source", AvailableImpl)

      assert :ok = BasicRegistry.deregister("plugin.new_source")
    end
  end

  describe "overwrite protection" do
    test "default: duplicate registration is rejected" do
      :ok = BasicRegistry.register("test", GoodImpl)
      assert {:error, :already_registered} = BasicRegistry.register("test", AvailableImpl)
    end

    test "allow_overwrite: duplicate registration overwrites" do
      ensure_started(OverwriteRegistry)

      :ok = OverwriteRegistry.register("test", GoodImpl)
      :ok = OverwriteRegistry.register("test", AvailableImpl)
      assert {:ok, AvailableImpl} = OverwriteRegistry.resolve("test")

      stop_registry(OverwriteRegistry)
    end

    test "allow_overwrite still respects core lock" do
      ensure_started(OverwriteRegistry)

      :ok = OverwriteRegistry.register("test", GoodImpl)
      :ok = OverwriteRegistry.lock_core()
      assert {:error, :core_locked} = OverwriteRegistry.register("test", AvailableImpl)

      stop_registry(OverwriteRegistry)
    end
  end

  describe "behaviour enforcement" do
    test "strict registry accepts modules with required behaviour" do
      ensure_started(StrictRegistry)

      assert :ok = StrictRegistry.register("test", GoodImpl)

      stop_registry(StrictRegistry)
    end

    test "strict registry rejects modules without required behaviour" do
      ensure_started(StrictRegistry)

      assert {:error, {:missing_behaviour, TestBehaviour}} =
               StrictRegistry.register("test", NoBehaviourImpl)

      stop_registry(StrictRegistry)
    end
  end

  describe "circuit breaker" do
    test "record_failure increments failure count" do
      ensure_started(CircuitBreakerRegistry)

      :ok = CircuitBreakerRegistry.register("test", GoodImpl)
      :ok = CircuitBreakerRegistry.record_failure("test")
      :ok = CircuitBreakerRegistry.record_failure("test")

      # Still available (2 < 3 threshold)
      available = CircuitBreakerRegistry.list_available()
      assert length(available) == 1

      stop_registry(CircuitBreakerRegistry)
    end

    test "entry becomes unstable after max_failures" do
      ensure_started(CircuitBreakerRegistry)

      :ok = CircuitBreakerRegistry.register("test", GoodImpl)
      :ok = CircuitBreakerRegistry.record_failure("test")
      :ok = CircuitBreakerRegistry.record_failure("test")
      :ok = CircuitBreakerRegistry.record_failure("test")

      # Not in available list (3 >= 3 threshold)
      available = CircuitBreakerRegistry.list_available()
      assert length(available) == 0

      # But still resolvable
      assert {:ok, GoodImpl} = CircuitBreakerRegistry.resolve("test")

      stop_registry(CircuitBreakerRegistry)
    end

    test "reset_failures restores availability" do
      ensure_started(CircuitBreakerRegistry)

      :ok = CircuitBreakerRegistry.register("test", GoodImpl)

      for _ <- 1..3, do: CircuitBreakerRegistry.record_failure("test")

      assert CircuitBreakerRegistry.list_available() == []

      :ok = CircuitBreakerRegistry.reset_failures("test")
      assert length(CircuitBreakerRegistry.list_available()) == 1

      stop_registry(CircuitBreakerRegistry)
    end

    test "record_failure on nonexistent entry returns error" do
      ensure_started(CircuitBreakerRegistry)

      assert {:error, :not_found} = CircuitBreakerRegistry.record_failure("nope")

      stop_registry(CircuitBreakerRegistry)
    end
  end

  describe "snapshot/restore" do
    test "snapshot captures state and restore replays it" do
      :ok = BasicRegistry.register("a", GoodImpl, %{v: 1})
      :ok = BasicRegistry.register("b", AvailableImpl, %{v: 2})

      snapshot = BasicRegistry.snapshot()

      # Modify state
      :ok = BasicRegistry.deregister("a")
      assert {:error, :not_found} = BasicRegistry.resolve("a")

      # Restore
      :ok = BasicRegistry.restore(snapshot)
      assert {:ok, GoodImpl} = BasicRegistry.resolve("a")
      assert {:ok, AvailableImpl} = BasicRegistry.resolve("b")
    end

    test "snapshot preserves core_locked state" do
      :ok = BasicRegistry.register("core", GoodImpl)
      :ok = BasicRegistry.lock_core()

      {_entries, core_locked} = BasicRegistry.snapshot()
      assert core_locked == true
    end
  end

  describe "custom validation" do
    test "custom validate_entry is called" do
      ensure_started(CustomValidationRegistry)

      assert :ok = CustomValidationRegistry.register("valid_source", GoodImpl)
      assert {:error, :invalid_name_prefix} = CustomValidationRegistry.register("bad", GoodImpl)

      stop_registry(CustomValidationRegistry)
    end
  end

  describe "plugin namespace enforcement" do
    test "before core lock, any name is allowed" do
      :ok = BasicRegistry.register("simple_name", GoodImpl)
      assert {:ok, GoodImpl} = BasicRegistry.resolve("simple_name")
    end

    test "after core lock, plugin names must contain a dot" do
      :ok = BasicRegistry.register("core_entry", GoodImpl)
      :ok = BasicRegistry.lock_core()

      # Plugin with dot prefix succeeds
      assert :ok = BasicRegistry.register("myplugin.custom", AvailableImpl)

      # Plugin without dot is rejected
      assert {:error, {:plugin_namespace_required, "bare_name"}} =
               BasicRegistry.register("bare_name", AvailableImpl)
    end

    test "core entries can still be registered before lock" do
      :ok = BasicRegistry.register("no_dot_name", GoodImpl)
      assert {:ok, GoodImpl} = BasicRegistry.resolve("no_dot_name")
    end
  end

  describe "resolve_stable" do
    test "returns module for healthy entries" do
      ensure_started(CircuitBreakerRegistry)

      :ok = CircuitBreakerRegistry.register("healthy", GoodImpl)
      assert {:ok, GoodImpl} = CircuitBreakerRegistry.resolve_stable("healthy")

      stop_registry(CircuitBreakerRegistry)
    end

    test "returns :unstable for entries over failure threshold" do
      ensure_started(CircuitBreakerRegistry)

      :ok = CircuitBreakerRegistry.register("flaky", GoodImpl)

      for _ <- 1..3, do: CircuitBreakerRegistry.record_failure("flaky")

      # resolve still works
      assert {:ok, GoodImpl} = CircuitBreakerRegistry.resolve("flaky")

      # resolve_stable blocks unstable entries
      assert {:error, :unstable} = CircuitBreakerRegistry.resolve_stable("flaky")

      stop_registry(CircuitBreakerRegistry)
    end

    test "returns :not_found for missing entries" do
      ensure_started(CircuitBreakerRegistry)

      assert {:error, :not_found} = CircuitBreakerRegistry.resolve_stable("nope")

      stop_registry(CircuitBreakerRegistry)
    end

    test "reset_failures restores resolve_stable" do
      ensure_started(CircuitBreakerRegistry)

      :ok = CircuitBreakerRegistry.register("recovered", GoodImpl)

      for _ <- 1..3, do: CircuitBreakerRegistry.record_failure("recovered")

      assert {:error, :unstable} = CircuitBreakerRegistry.resolve_stable("recovered")

      :ok = CircuitBreakerRegistry.reset_failures("recovered")
      assert {:ok, GoodImpl} = CircuitBreakerRegistry.resolve_stable("recovered")

      stop_registry(CircuitBreakerRegistry)
    end
  end

  describe "persistent_term fast path" do
    test "resolve uses persistent_term after lock_core" do
      :ok = BasicRegistry.register("fast", GoodImpl)
      :ok = BasicRegistry.lock_core()

      # persistent_term should be populated
      pt_key = {BasicRegistry, :core_snapshot}
      snapshot = :persistent_term.get(pt_key, nil)
      assert is_map(snapshot)
      assert Map.has_key?(snapshot, "fast")

      # Resolve should still work (via fast path)
      assert {:ok, GoodImpl} = BasicRegistry.resolve("fast")
      assert {:ok, GoodImpl} = BasicRegistry.resolve_stable("fast")
    end

    test "reset clears persistent_term" do
      :ok = BasicRegistry.register("temp", GoodImpl)
      :ok = BasicRegistry.lock_core()

      pt_key = {BasicRegistry, :core_snapshot}
      assert :persistent_term.get(pt_key, nil) != nil

      BasicRegistry.reset()
      assert :persistent_term.get(pt_key, nil) == nil
    end

    test "record_failure invalidates persistent_term" do
      ensure_started(CircuitBreakerRegistry)

      :ok = CircuitBreakerRegistry.register("failing", GoodImpl)
      :ok = CircuitBreakerRegistry.lock_core()

      pt_key = {CircuitBreakerRegistry, :core_snapshot}
      assert :persistent_term.get(pt_key, nil) != nil

      :ok = CircuitBreakerRegistry.record_failure("failing")
      # Snapshot invalidated after failure
      assert :persistent_term.get(pt_key, nil) == nil

      stop_registry(CircuitBreakerRegistry)
    end
  end

  describe "ETS heir protection" do
    test "table data survives registry restart via heir" do
      :ok = BasicRegistry.register("persistent", GoodImpl)

      # Stop the GenServer gracefully
      GenServer.stop(BasicRegistry)

      # Table should still exist (held by heir)
      assert [{_name, _mod, _meta, _failures, _core?}] =
               :ets.lookup(:test_basic_registry, "persistent")

      # Restart — init should reclaim the existing table
      {:ok, _pid} = BasicRegistry.start_link()

      # Data should still be there
      assert {:ok, GoodImpl} = BasicRegistry.resolve("persistent")
    end
  end
end
