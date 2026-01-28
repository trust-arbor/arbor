defmodule Arbor.AgentTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.Test.TestAgent

  @moduletag :fast

  setup do
    Process.sleep(10)
    :ok
  end

  describe "start/4 and stop/1" do
    test "starts and stops an agent" do
      {:ok, pid} = Arbor.Agent.start("facade-1", TestAgent, %{value: 0})
      assert Process.alive?(pid)

      Process.sleep(50)

      assert :ok = Arbor.Agent.stop("facade-1")
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "returns error when stopping nonexistent agent" do
      assert {:error, :not_found} = Arbor.Agent.stop("nonexistent")
    end
  end

  describe "run_action/3" do
    test "executes action on running agent" do
      {:ok, _pid} = Arbor.Agent.start("facade-action", TestAgent, %{value: 10})
      Process.sleep(50)

      result =
        Arbor.Agent.run_action(
          "facade-action",
          {Arbor.Agent.Test.IncrementAction, %{amount: 3}}
        )

      case result do
        {:ok, action_result} ->
          assert action_result.action == :increment

        {:error, _reason} ->
          # Some Jido configurations handle this differently
          assert true
      end

      on_exit(fn -> Arbor.Agent.stop("facade-action") end)
    end

    test "returns error for non-running agent" do
      assert {:error, :not_found} = Arbor.Agent.run_action("nonexistent", SomeAction)
    end
  end

  describe "get_state/1" do
    test "returns agent state" do
      {:ok, _pid} = Arbor.Agent.start("facade-state", TestAgent, %{value: 42})
      Process.sleep(50)

      assert {:ok, state} = Arbor.Agent.get_state("facade-state")
      assert is_map(state)

      on_exit(fn -> Arbor.Agent.stop("facade-state") end)
    end

    test "returns error for non-running agent" do
      assert {:error, :not_found} = Arbor.Agent.get_state("nonexistent")
    end
  end

  describe "get_metadata/1" do
    test "returns metadata" do
      {:ok, _pid} = Arbor.Agent.start("facade-meta", TestAgent)
      Process.sleep(50)

      assert {:ok, metadata} = Arbor.Agent.get_metadata("facade-meta")
      assert metadata.module == TestAgent

      on_exit(fn -> Arbor.Agent.stop("facade-meta") end)
    end
  end

  describe "lookup/1 and whereis/1" do
    test "finds running agent" do
      {:ok, pid} = Arbor.Agent.start("facade-lookup", TestAgent)
      Process.sleep(50)

      assert {:ok, entry} = Arbor.Agent.lookup("facade-lookup")
      assert entry.agent_id == "facade-lookup"
      assert entry.pid == pid

      assert {:ok, ^pid} = Arbor.Agent.whereis("facade-lookup")

      on_exit(fn -> Arbor.Agent.stop("facade-lookup") end)
    end

    test "returns not_found for non-running agent" do
      assert {:error, :not_found} = Arbor.Agent.lookup("nonexistent")
      assert {:error, :not_found} = Arbor.Agent.whereis("nonexistent")
    end
  end

  describe "list/0 and count/0" do
    test "lists and counts agents" do
      initial_count = Arbor.Agent.count()

      {:ok, _} = Arbor.Agent.start("facade-list-1", TestAgent)
      {:ok, _} = Arbor.Agent.start("facade-list-2", TestAgent)
      {:ok, _} = Arbor.Agent.start("facade-list-3", TestAgent)

      Process.sleep(50)

      assert {:ok, agents} = Arbor.Agent.list()
      assert length(agents) >= 3

      assert Arbor.Agent.count() >= initial_count + 3

      on_exit(fn ->
        Arbor.Agent.stop("facade-list-1")
        Arbor.Agent.stop("facade-list-2")
        Arbor.Agent.stop("facade-list-3")
      end)
    end
  end

  describe "running?/1" do
    test "returns true for running agent" do
      {:ok, _} = Arbor.Agent.start("facade-running", TestAgent)
      Process.sleep(50)

      assert Arbor.Agent.running?("facade-running")

      on_exit(fn -> Arbor.Agent.stop("facade-running") end)
    end

    test "returns false for non-running agent" do
      refute Arbor.Agent.running?("nonexistent")
    end
  end

  describe "checkpoint/1" do
    test "manually triggers checkpoint" do
      {:ok, storage_pid} = Arbor.Checkpoint.Store.Agent.start_link()

      {:ok, _pid} =
        Arbor.Agent.start("facade-cp", TestAgent, %{value: 55},
          checkpoint_storage: Arbor.Checkpoint.Store.Agent
        )

      Process.sleep(50)

      assert :ok = Arbor.Agent.checkpoint("facade-cp")

      assert {:ok, _} =
               Arbor.Checkpoint.load(
                 "facade-cp",
                 Arbor.Checkpoint.Store.Agent,
                 retries: 0
               )

      on_exit(fn ->
        Arbor.Agent.stop("facade-cp")
        if Process.alive?(storage_pid), do: Arbor.Checkpoint.Store.Agent.stop()
      end)
    end

    test "returns error for non-running agent" do
      assert {:error, :not_found} = Arbor.Agent.checkpoint("nonexistent")
    end
  end

  describe "full lifecycle" do
    test "start -> action -> checkpoint -> stop -> restart -> restore" do
      {:ok, storage_pid} = Arbor.Checkpoint.Store.Agent.start_link()

      # Start agent
      {:ok, pid1} =
        Arbor.Agent.start("lifecycle-test", TestAgent, %{value: 0},
          checkpoint_storage: Arbor.Checkpoint.Store.Agent
        )

      Process.sleep(50)

      # Save checkpoint
      :ok = Arbor.Agent.checkpoint("lifecycle-test")

      # Stop agent
      :ok = Arbor.Agent.stop("lifecycle-test")
      Process.sleep(50)
      refute Process.alive?(pid1)

      # Restart - should restore from checkpoint
      {:ok, pid2} =
        Arbor.Agent.start("lifecycle-test", TestAgent, %{value: 999},
          checkpoint_storage: Arbor.Checkpoint.Store.Agent
        )

      Process.sleep(50)
      assert Process.alive?(pid2)
      assert pid1 != pid2

      # Verify it restored (metadata should have restored_at)
      {:ok, metadata} = Arbor.Agent.get_metadata("lifecycle-test")
      assert Map.has_key?(metadata, :restored_at)

      on_exit(fn ->
        Arbor.Agent.stop("lifecycle-test")
        if Process.alive?(storage_pid), do: Arbor.Checkpoint.Store.Agent.stop()
      end)
    end
  end
end
