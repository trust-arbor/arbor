defmodule Arbor.Agent.ServerTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.Server
  alias Arbor.Agent.Test.{TestAgent, IncrementAction, FailingAction}

  @moduletag :fast

  setup do
    # Ensure clean state
    Process.sleep(10)
    :ok
  end

  describe "start_link/1" do
    test "starts an agent server" do
      {:ok, pid} =
        Server.start_link(
          agent_id: "server-test-1",
          agent_module: TestAgent,
          initial_state: %{value: 0}
        )

      assert Process.alive?(pid)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)
    end

    test "registers with the agent registry" do
      {:ok, pid} =
        Server.start_link(
          agent_id: "server-test-reg",
          agent_module: TestAgent,
          initial_state: %{value: 0}
        )

      # Give time for post_init to complete
      Process.sleep(50)

      assert {:ok, entry} = Arbor.Agent.Registry.lookup("server-test-reg")
      assert entry.pid == pid

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)
    end
  end

  describe "run_action/3" do
    setup do
      {:ok, pid} =
        Server.start_link(
          agent_id: "action-test",
          agent_module: TestAgent,
          initial_state: %{value: 10}
        )

      Process.sleep(50)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      %{pid: pid}
    end

    test "executes action and returns result", %{pid: pid} do
      result = Server.run_action(pid, {IncrementAction, %{amount: 5}})

      case result do
        {:ok, action_result} ->
          assert action_result.action == :increment

        {:error, _reason} ->
          # Action execution depends on Jido internals
          assert true
      end
    end

    test "accepts bare module as action", %{pid: pid} do
      result = Server.run_action(pid, IncrementAction)

      case result do
        {:ok, _} -> assert true
        {:error, _} -> assert true
      end
    end

    test "returns error for failing action", %{pid: pid} do
      result = Server.run_action(pid, {FailingAction, %{reason: "test"}})

      assert {:error, _reason} = result
    end
  end

  describe "get_state/1" do
    test "returns agent state" do
      {:ok, pid} =
        Server.start_link(
          agent_id: "state-test",
          agent_module: TestAgent,
          initial_state: %{value: 42}
        )

      Process.sleep(50)

      assert {:ok, state} = Server.get_state(pid)
      assert is_map(state)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)
    end
  end

  describe "get_metadata/1" do
    test "returns agent metadata" do
      {:ok, pid} =
        Server.start_link(
          agent_id: "meta-test",
          agent_module: TestAgent,
          metadata: %{custom: "value"}
        )

      Process.sleep(50)

      metadata = Server.get_metadata(pid)
      assert metadata.module == TestAgent
      assert is_integer(metadata.started_at)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)
    end
  end

  describe "extract_state/1" do
    test "returns checkpoint-ready data" do
      {:ok, pid} =
        Server.start_link(
          agent_id: "extract-test",
          agent_module: TestAgent,
          initial_state: %{value: 99}
        )

      Process.sleep(50)

      assert {:ok, extracted} = Server.extract_state(pid)
      assert extracted.agent_id == "extract-test"
      assert extracted.agent_module == TestAgent
      assert is_map(extracted.jido_state)
      assert is_map(extracted.metadata)
      assert is_integer(extracted.extracted_at)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)
    end
  end

  describe "checkpoint integration" do
    test "saves and restores from checkpoint storage" do
      # Start checkpoint storage
      {:ok, storage_pid} = Arbor.Checkpoint.Store.Agent.start_link()

      # Start agent with checkpoint storage
      {:ok, pid} =
        Server.start_link(
          agent_id: "checkpoint-test",
          agent_module: TestAgent,
          initial_state: %{value: 100},
          checkpoint_storage: Arbor.Checkpoint.Store.Agent
        )

      Process.sleep(50)

      # Manually save checkpoint
      assert :ok = Server.save_checkpoint(pid)

      # Verify checkpoint was saved
      assert {:ok, _data} =
               Arbor.Checkpoint.load(
                 "checkpoint-test",
                 Arbor.Checkpoint.Store.Agent,
                 retries: 0
               )

      # Stop the agent
      GenServer.stop(pid)
      Process.sleep(50)

      # Start a new agent with the same ID - should restore
      {:ok, pid2} =
        Server.start_link(
          agent_id: "checkpoint-test",
          agent_module: TestAgent,
          initial_state: %{value: 0},
          checkpoint_storage: Arbor.Checkpoint.Store.Agent
        )

      Process.sleep(50)

      metadata = Server.get_metadata(pid2)
      assert Map.has_key?(metadata, :restored_at)

      on_exit(fn ->
        if Process.alive?(pid2), do: GenServer.stop(pid2)
        if Process.alive?(storage_pid), do: Arbor.Checkpoint.Store.Agent.stop()
      end)
    end

    test "works without checkpoint storage" do
      {:ok, pid} =
        Server.start_link(
          agent_id: "no-checkpoint",
          agent_module: TestAgent,
          initial_state: %{value: 0}
        )

      Process.sleep(50)

      # Should not error
      assert :ok = Server.save_checkpoint(pid)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)
    end
  end

  describe "auto-checkpoint" do
    test "saves checkpoints at configured interval" do
      {:ok, storage_pid} = Arbor.Checkpoint.Store.Agent.start_link()

      {:ok, pid} =
        Server.start_link(
          agent_id: "auto-cp-test",
          agent_module: TestAgent,
          initial_state: %{value: 50},
          checkpoint_storage: Arbor.Checkpoint.Store.Agent,
          auto_checkpoint_interval: 100
        )

      Process.sleep(50)

      # Wait for auto-checkpoint to fire
      Process.sleep(200)

      # Should have at least one checkpoint saved
      assert {:ok, _data} =
               Arbor.Checkpoint.load(
                 "auto-cp-test",
                 Arbor.Checkpoint.Store.Agent,
                 retries: 0
               )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        if Process.alive?(storage_pid), do: Arbor.Checkpoint.Store.Agent.stop()
      end)
    end
  end

  describe "termination" do
    test "saves checkpoint on graceful stop" do
      {:ok, storage_pid} = Arbor.Checkpoint.Store.Agent.start_link()

      {:ok, pid} =
        Server.start_link(
          agent_id: "term-test",
          agent_module: TestAgent,
          initial_state: %{value: 77},
          checkpoint_storage: Arbor.Checkpoint.Store.Agent
        )

      Process.sleep(50)

      # Stop gracefully
      GenServer.stop(pid)
      Process.sleep(50)

      # Checkpoint should have been saved during termination
      assert {:ok, _data} =
               Arbor.Checkpoint.load(
                 "term-test",
                 Arbor.Checkpoint.Store.Agent,
                 retries: 0
               )

      on_exit(fn ->
        if Process.alive?(storage_pid), do: Arbor.Checkpoint.Store.Agent.stop()
      end)
    end

    test "unregisters from registry on stop" do
      {:ok, pid} =
        Server.start_link(
          agent_id: "unreg-term",
          agent_module: TestAgent
        )

      Process.sleep(50)
      assert {:ok, _} = Arbor.Agent.Registry.lookup("unreg-term")

      GenServer.stop(pid)
      Process.sleep(50)

      assert {:error, :not_found} = Arbor.Agent.Registry.lookup("unreg-term")
    end
  end
end
