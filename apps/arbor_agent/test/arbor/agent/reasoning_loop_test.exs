defmodule Arbor.Agent.ReasoningLoopTest do
  use ExUnit.Case

  alias Arbor.Agent.ReasoningLoop
  alias Arbor.Contracts.Memory.Intent

  @agent_id "reasoning-loop-test-agent"

  setup do
    ReasoningLoop.stop(@agent_id)
    Process.sleep(50)
    :ok
  end

  describe "start/3 and stop/1" do
    test "starts a reasoning loop in stepped mode" do
      {:ok, pid} =
        ReasoningLoop.start(@agent_id, :stepped,
          think_fn: fn _agent_id, _percept -> Intent.think("test thought") end
        )

      assert Process.alive?(pid)
      ReasoningLoop.stop(@agent_id)
    end

    test "stop is idempotent" do
      assert :ok = ReasoningLoop.stop("nonexistent-loop")
    end
  end

  describe "status/1" do
    test "returns status for running loop" do
      {:ok, _pid} =
        ReasoningLoop.start(@agent_id, :stepped,
          think_fn: fn _agent_id, _percept -> Intent.think("test") end
        )

      {:ok, status} = ReasoningLoop.status(@agent_id)
      assert status.agent_id == @agent_id
      assert status.mode == :stepped
      assert status.iteration == 0

      ReasoningLoop.stop(@agent_id)
    end

    test "returns error for nonexistent loop" do
      assert {:error, :not_found} = ReasoningLoop.status("nonexistent")
    end
  end

  describe "step/1" do
    test "advances one cycle in stepped mode" do
      {:ok, _pid} =
        ReasoningLoop.start(@agent_id, :stepped,
          think_fn: fn _agent_id, _percept ->
            Intent.think("Thinking about step 1")
          end
        )

      {:ok, result} = ReasoningLoop.step(@agent_id)
      assert result.iteration == 1
      assert %Intent{} = result.intent
      assert result.intent.type == :think

      ReasoningLoop.stop(@agent_id)
    end

    test "returns error when not in stepped mode" do
      test_pid = self()
      ref = make_ref()

      {:ok, _pid} =
        ReasoningLoop.start(@agent_id <> "-continuous", :continuous,
          think_fn: fn _agent_id, _percept ->
            send(test_pid, {ref, :ran})
            Intent.think("test")
          end
        )

      # Wait for at least one cycle to confirm it's running
      receive do
        {^ref, :ran} -> :ok
      after
        1_000 -> flunk("Loop didn't run")
      end

      assert {:error, :not_stepped_mode} = ReasoningLoop.step(@agent_id <> "-continuous")

      ReasoningLoop.stop(@agent_id <> "-continuous")
    end

    test "returns error for nonexistent loop" do
      assert {:error, :not_found} = ReasoningLoop.step("nonexistent")
    end
  end

  describe "bounded mode" do
    test "stops after N iterations" do
      ref = make_ref()
      test_pid = self()

      {:ok, pid} =
        ReasoningLoop.start(@agent_id <> "-bounded2", {:bounded, 3},
          think_fn: fn _agent_id, _percept ->
            send(test_pid, {ref, :iteration})
            Intent.think("bounded iteration")
          end
        )

      # Wait for it to complete
      Process.monitor(pid)

      receive do
        {:DOWN, _mref, :process, ^pid, _reason} -> :ok
      after
        5_000 -> flunk("Loop didn't stop in time")
      end

      # Should have received exactly 3 iterations
      iterations = drain_messages(ref, 0)
      assert iterations == 3
    end
  end

  # Helper to count messages
  defp drain_messages(ref, count) do
    receive do
      {^ref, :iteration} -> drain_messages(ref, count + 1)
    after
      100 -> count
    end
  end
end
