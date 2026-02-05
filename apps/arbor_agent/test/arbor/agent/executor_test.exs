defmodule Arbor.Agent.ExecutorTest do
  use ExUnit.Case

  alias Arbor.Agent.Executor
  alias Arbor.Contracts.Memory.Intent

  @agent_id "executor-test-agent"

  setup do
    # Clean up any lingering executor from previous tests
    Executor.stop(@agent_id)
    Process.sleep(50)
    :ok
  end

  describe "start/2 and stop/1" do
    test "starts an executor" do
      assert {:ok, pid} = Executor.start(@agent_id, trust_tier: :probationary)
      assert Process.alive?(pid)
      Executor.stop(@agent_id)
    end

    test "stop is idempotent" do
      assert :ok = Executor.stop("nonexistent-executor")
    end

    test "returns error when already started" do
      {:ok, _pid} = Executor.start(@agent_id, trust_tier: :probationary)
      assert {:error, {:already_started, _}} = Executor.start(@agent_id)
      Executor.stop(@agent_id)
    end
  end

  describe "status/1" do
    test "returns status for running executor" do
      {:ok, _pid} = Executor.start(@agent_id, trust_tier: :probationary)

      {:ok, status} = Executor.status(@agent_id)
      assert status.agent_id == @agent_id
      assert status.status == :running
      assert status.trust_tier == :probationary
      assert status.pending_count == 0
      assert status.stats.intents_received == 0

      Executor.stop(@agent_id)
    end

    test "returns error for nonexistent executor" do
      assert {:error, :not_found} = Executor.status("nonexistent")
    end
  end

  describe "pause/1 and resume/1" do
    test "pause transitions from running to paused" do
      {:ok, _pid} = Executor.start(@agent_id, trust_tier: :probationary)

      assert :ok = Executor.pause(@agent_id)
      {:ok, status} = Executor.status(@agent_id)
      assert status.status == :paused

      Executor.stop(@agent_id)
    end

    test "resume transitions from paused to running" do
      {:ok, _pid} = Executor.start(@agent_id, trust_tier: :probationary)

      Executor.pause(@agent_id)
      assert :ok = Executor.resume(@agent_id)

      {:ok, status} = Executor.status(@agent_id)
      assert status.status == :running

      Executor.stop(@agent_id)
    end

    test "pause when not running returns error" do
      {:ok, _pid} = Executor.start(@agent_id, trust_tier: :probationary)
      Executor.pause(@agent_id)

      assert {:error, :not_running} = Executor.pause(@agent_id)

      Executor.stop(@agent_id)
    end

    test "resume when not paused returns error" do
      {:ok, _pid} = Executor.start(@agent_id, trust_tier: :probationary)

      assert {:error, :not_paused} = Executor.resume(@agent_id)

      Executor.stop(@agent_id)
    end
  end

  describe "execute/2" do
    test "executes a think intent" do
      {:ok, _pid} = Executor.start(@agent_id, trust_tier: :probationary)

      intent = Intent.think("Considering the situation")
      assert :ok = Executor.execute(@agent_id, intent)

      # Give it a moment to process
      Process.sleep(100)

      {:ok, status} = Executor.status(@agent_id)
      assert status.stats.intents_received == 1
      assert status.stats.intents_executed == 1

      Executor.stop(@agent_id)
    end

    test "queues intents when paused" do
      {:ok, _pid} = Executor.start(@agent_id, trust_tier: :probationary)
      Executor.pause(@agent_id)

      intent = Intent.think("Queued thought")
      Executor.execute(@agent_id, intent)

      Process.sleep(50)

      {:ok, status} = Executor.status(@agent_id)
      assert status.pending_count == 1
      assert status.stats.intents_received == 1
      assert status.stats.intents_executed == 0

      Executor.stop(@agent_id)
    end

    test "processes queued intents on resume" do
      {:ok, _pid} = Executor.start(@agent_id, trust_tier: :probationary)
      Executor.pause(@agent_id)

      intent = Intent.think("Queued thought")
      Executor.execute(@agent_id, intent)
      Process.sleep(50)

      Executor.resume(@agent_id)
      Process.sleep(100)

      {:ok, status} = Executor.status(@agent_id)
      assert status.pending_count == 0
      assert status.stats.intents_executed == 1

      Executor.stop(@agent_id)
    end

    test "returns error for nonexistent executor" do
      intent = Intent.think("Lost thought")
      assert {:error, :not_found} = Executor.execute("nonexistent", intent)
    end
  end
end
