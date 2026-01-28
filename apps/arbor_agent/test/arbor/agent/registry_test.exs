defmodule Arbor.Agent.RegistryTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.Registry

  @moduletag :fast

  # The registry is started by the application supervisor, but in tests
  # we may need to ensure it's running
  setup do
    # Wait for registry to be ready (started by application)
    Process.sleep(10)
    # Clean up any stale entries
    {:ok, agents} = Registry.list()

    for agent <- agents do
      Registry.unregister(agent.agent_id)
    end

    :ok
  end

  describe "register/3" do
    test "registers an agent successfully" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      assert :ok = Registry.register("test-agent-1", pid, %{module: TestModule})

      on_exit(fn ->
        Process.exit(pid, :kill)
      end)
    end

    test "returns error for duplicate registration of live process" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      assert :ok = Registry.register("test-agent-dup", pid, %{})
      assert {:error, :already_registered} = Registry.register("test-agent-dup", pid, %{})

      on_exit(fn ->
        Process.exit(pid, :kill)
      end)
    end

    test "allows re-registration after process dies" do
      pid1 = spawn(fn -> :ok end)
      assert :ok = Registry.register("test-agent-reuse", pid1, %{})

      # Wait for pid1 to die
      Process.sleep(50)

      pid2 = spawn(fn -> Process.sleep(:infinity) end)
      assert :ok = Registry.register("test-agent-reuse", pid2, %{})

      on_exit(fn ->
        Process.exit(pid2, :kill)
      end)
    end
  end

  describe "lookup/1" do
    test "finds a registered agent" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Registry.register("test-lookup", pid, %{module: SomeModule})

      assert {:ok, entry} = Registry.lookup("test-lookup")
      assert entry.agent_id == "test-lookup"
      assert entry.pid == pid
      assert entry.module == SomeModule

      on_exit(fn -> Process.exit(pid, :kill) end)
    end

    test "returns not_found for unregistered agent" do
      assert {:error, :not_found} = Registry.lookup("nonexistent")
    end

    test "returns not_found for dead process (cleanup)" do
      pid = spawn(fn -> :ok end)
      :ok = Registry.register("test-dead", pid, %{})
      Process.sleep(50)

      assert {:error, :not_found} = Registry.lookup("test-dead")
    end
  end

  describe "whereis/1" do
    test "returns pid for registered agent" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Registry.register("test-whereis", pid, %{})

      assert {:ok, ^pid} = Registry.whereis("test-whereis")

      on_exit(fn -> Process.exit(pid, :kill) end)
    end

    test "returns not_found for unregistered agent" do
      assert {:error, :not_found} = Registry.whereis("nonexistent")
    end
  end

  describe "list/0" do
    test "returns empty list when no agents" do
      assert {:ok, []} = Registry.list()
    end

    test "returns all registered live agents" do
      pids =
        for i <- 1..3 do
          pid = spawn(fn -> Process.sleep(:infinity) end)
          :ok = Registry.register("test-list-#{i}", pid, %{})
          pid
        end

      assert {:ok, agents} = Registry.list()
      assert length(agents) == 3

      on_exit(fn ->
        for pid <- pids, do: Process.exit(pid, :kill)
      end)
    end

    test "excludes dead processes" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> :ok end)

      :ok = Registry.register("test-alive", pid1, %{})
      :ok = Registry.register("test-dead-list", pid2, %{})

      Process.sleep(50)

      assert {:ok, agents} = Registry.list()
      assert length(agents) == 1
      assert hd(agents).agent_id == "test-alive"

      on_exit(fn -> Process.exit(pid1, :kill) end)
    end
  end

  describe "unregister/1" do
    test "removes a registered agent" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Registry.register("test-unreg", pid, %{})

      assert :ok = Registry.unregister("test-unreg")
      assert {:error, :not_found} = Registry.lookup("test-unreg")

      on_exit(fn -> Process.exit(pid, :kill) end)
    end
  end

  describe "count/0" do
    test "returns zero when empty" do
      assert Registry.count() == 0
    end

    test "counts registered agents" do
      pids =
        for i <- 1..5 do
          pid = spawn(fn -> Process.sleep(:infinity) end)
          :ok = Registry.register("test-count-#{i}", pid, %{})
          pid
        end

      assert Registry.count() == 5

      on_exit(fn ->
        for pid <- pids, do: Process.exit(pid, :kill)
      end)
    end
  end

  describe "find/1" do
    test "filters agents by predicate" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      :ok = Registry.register("find-a", pid1, %{module: ModuleA})
      :ok = Registry.register("find-b", pid2, %{module: ModuleB})

      assert {:ok, [found]} = Registry.find(fn entry -> entry.module == ModuleA end)
      assert found.agent_id == "find-a"

      on_exit(fn ->
        Process.exit(pid1, :kill)
        Process.exit(pid2, :kill)
      end)
    end
  end

  describe "automatic cleanup on process death" do
    test "cleans up entry when monitored process dies" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Registry.register("test-monitor", pid, %{})

      # Kill the process
      Process.exit(pid, :kill)
      # Give the DOWN message time to propagate
      Process.sleep(100)

      assert {:error, :not_found} = Registry.lookup("test-monitor")
    end
  end
end
