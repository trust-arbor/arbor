defmodule Arbor.Agent.RegistryConcurrencyTest do
  @moduledoc """
  Tests for concurrent agent registration — identity collision,
  race conditions on register/unregister, and stale entry cleanup
  under concurrent access.
  """
  use ExUnit.Case, async: false

  alias Arbor.Agent.Registry

  @moduletag :fast

  setup do
    Process.sleep(10)
    {:ok, agents} = Registry.list()

    for agent <- agents do
      Registry.unregister(agent.agent_id)
    end

    :ok
  end

  # ============================================================================
  # Concurrent registration — identity collision
  # ============================================================================

  describe "concurrent registration (identity collision)" do
    test "only one registration wins when multiple processes race for same agent_id" do
      agent_id = "race-agent-#{System.unique_integer([:positive])}"
      parent = self()

      # Spawn 10 processes that all try to register the same agent_id
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            pid = spawn(fn -> Process.sleep(:infinity) end)
            result = Registry.register(agent_id, pid, %{index: i})
            send(parent, {:registration_result, i, result, pid})
            {i, result, pid}
          end)
        end

      results = Task.await_many(tasks, 5_000)

      # Exactly one should succeed, the rest should get :already_registered
      successes = Enum.filter(results, fn {_i, result, _pid} -> result == :ok end)
      failures = Enum.filter(results, fn {_i, result, _pid} -> result == {:error, :already_registered} end)

      assert length(successes) == 1, "Expected exactly 1 successful registration, got #{length(successes)}"
      assert length(failures) == 9, "Expected exactly 9 failures, got #{length(failures)}"

      # Verify the winner is actually in the registry
      assert {:ok, entry} = Registry.lookup(agent_id)
      assert entry.agent_id == agent_id

      # Cleanup
      {_i, _result, winning_pid} = hd(successes)
      Process.exit(winning_pid, :kill)

      for {_i, _result, pid} <- results do
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end
    end

    test "concurrent registration of distinct agent_ids all succeed" do
      base = System.unique_integer([:positive])

      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            agent_id = "distinct-agent-#{base}-#{i}"
            pid = spawn(fn -> Process.sleep(:infinity) end)
            result = Registry.register(agent_id, pid, %{index: i})
            {agent_id, result, pid}
          end)
        end

      results = Task.await_many(tasks, 5_000)

      # All should succeed since IDs are unique
      for {_agent_id, result, _pid} <- results do
        assert result == :ok
      end

      # Verify all are in the registry
      {:ok, agents} = Registry.list()
      registered_ids = Enum.map(agents, & &1.agent_id) |> MapSet.new()

      for {agent_id, _result, _pid} <- results do
        assert MapSet.member?(registered_ids, agent_id)
      end

      # Cleanup
      for {_agent_id, _result, pid} <- results do
        Process.exit(pid, :kill)
      end
    end
  end

  # ============================================================================
  # Register/unregister race
  # ============================================================================

  describe "register/unregister race conditions" do
    test "rapid register-unregister cycles do not corrupt registry" do
      agent_id = "rapid-cycle-#{System.unique_integer([:positive])}"

      for _cycle <- 1..20 do
        pid = spawn(fn -> Process.sleep(:infinity) end)
        assert :ok = Registry.register(agent_id, pid, %{})
        assert :ok = Registry.unregister(agent_id)
        Process.exit(pid, :kill)
        # Small sleep to let DOWN messages propagate
        Process.sleep(5)
      end

      # After all cycles, registry should be clean
      assert {:error, :not_found} = Registry.lookup(agent_id)
    end

    test "concurrent unregister does not crash the registry" do
      agent_id = "concurrent-unreg-#{System.unique_integer([:positive])}"
      pid = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Registry.register(agent_id, pid, %{})

      # Multiple processes try to unregister simultaneously
      tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            Registry.unregister(agent_id)
          end)
        end

      results = Task.await_many(tasks, 5_000)

      # All should return :ok (idempotent)
      for result <- results do
        assert result == :ok
      end

      Process.exit(pid, :kill)
    end
  end

  # ============================================================================
  # Re-registration after process death under contention
  # ============================================================================

  describe "re-registration after process death" do
    test "re-registration succeeds after original process exits under concurrent access" do
      agent_id = "reuse-race-#{System.unique_integer([:positive])}"
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Registry.register(agent_id, pid1, %{gen: 1})

      # Kill the original process
      Process.exit(pid1, :kill)
      # Allow the DOWN monitor and cleanup to propagate
      Process.sleep(100)

      # Multiple processes try to re-register simultaneously
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            pid = spawn(fn -> Process.sleep(:infinity) end)
            result = Registry.register(agent_id, pid, %{gen: 2, attempt: i})
            {result, pid}
          end)
        end

      results = Task.await_many(tasks, 5_000)

      successes = Enum.filter(results, fn {result, _pid} -> result == :ok end)
      assert successes != [], "At least one re-registration should succeed"

      # The registry should have exactly one live entry
      assert {:ok, entry} = Registry.lookup(agent_id)
      assert entry.agent_id == agent_id

      # Cleanup
      for {_result, pid} <- results do
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end
    end
  end

  # ============================================================================
  # Stale entry cleanup under load
  # ============================================================================

  describe "stale entry cleanup under concurrent load" do
    test "lookup cleans up stale entries even under concurrent reads" do
      agent_id = "stale-cleanup-#{System.unique_integer([:positive])}"
      pid = spawn(fn -> :ok end)

      # Register a process that immediately exits
      :ok = Registry.register(agent_id, pid, %{})
      Process.sleep(50)

      # Multiple concurrent lookups should all see :not_found
      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            Registry.lookup(agent_id)
          end)
        end

      results = Task.await_many(tasks, 5_000)

      for result <- results do
        assert result == {:error, :not_found}
      end
    end

    test "list excludes dead processes even when many processes die concurrently" do
      base = System.unique_integer([:positive])

      # Register 10 agents: 5 that stay alive, 5 that die immediately
      alive_pids =
        for i <- 1..5 do
          pid = spawn(fn -> Process.sleep(:infinity) end)
          :ok = Registry.register("alive-#{base}-#{i}", pid, %{})
          pid
        end

      dead_pids =
        for i <- 1..5 do
          pid = spawn(fn -> :ok end)
          :ok = Registry.register("dead-#{base}-#{i}", pid, %{})
          pid
        end

      # Let dead processes terminate
      Process.sleep(100)

      {:ok, agents} = Registry.list()
      alive_ids = Enum.map(agents, & &1.agent_id) |> MapSet.new()

      for i <- 1..5 do
        assert MapSet.member?(alive_ids, "alive-#{base}-#{i}")
        refute MapSet.member?(alive_ids, "dead-#{base}-#{i}")
      end

      # Cleanup
      for pid <- alive_pids ++ dead_pids do
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end
    end
  end
end
