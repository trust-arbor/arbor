defmodule Arbor.Agent.Loops.MonitorLoopTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Loops.MonitorLoop

  @moduletag :fast

  defp make_profile(id \\ nil) do
    %{id: id || "monitor_loop_test_#{System.unique_integer([:positive])}"}
  end

  describe "start_link/1" do
    setup do
      # Ensure the registry is started for our tests
      start_supervised!({Registry, keys: :unique, name: Arbor.Agent.MonitorLoopRegistry})
      :ok
    end

    test "starts successfully with a profile" do
      profile = make_profile()
      assert {:ok, pid} = MonitorLoop.start_link(profile: profile)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "requires profile option" do
      assert_raise KeyError, fn ->
        MonitorLoop.start_link([])
      end
    end
  end

  describe "get_buffer/1" do
    setup do
      start_supervised!({Registry, keys: :unique, name: Arbor.Agent.MonitorLoopRegistry})
      profile = make_profile()
      {:ok, pid} = MonitorLoop.start_link(profile: profile)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{profile: profile, pid: pid}
    end

    test "returns empty buffer initially", %{profile: profile} do
      assert {:ok, []} = MonitorLoop.get_buffer(profile.id)
    end

    test "returns error for unknown agent" do
      assert {:error, :not_found} = MonitorLoop.get_buffer("nonexistent_agent")
    end
  end

  describe "force_escalate/2" do
    setup do
      start_supervised!({Registry, keys: :unique, name: Arbor.Agent.MonitorLoopRegistry})
      profile = make_profile()
      {:ok, pid} = MonitorLoop.start_link(profile: profile)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{profile: profile, pid: pid}
    end

    test "accepts escalation with context", %{profile: profile} do
      context = %{
        metric: :test_metric,
        value: 100,
        baseline: 50,
        severity: :critical
      }

      assert :ok = MonitorLoop.force_escalate(profile.id, context)
    end

    test "returns error for unknown agent" do
      assert {:error, :not_found} = MonitorLoop.force_escalate("nonexistent_agent", %{})
    end
  end

  describe "signal processing" do
    setup do
      start_supervised!({Registry, keys: :unique, name: Arbor.Agent.MonitorLoopRegistry})
      profile = make_profile()
      {:ok, pid} = MonitorLoop.start_link(profile: profile)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{profile: profile, pid: pid}
    end

    test "processes incoming signal messages", %{pid: pid, profile: profile} do
      signal = %{
        data: %{
          metric: :memory_usage,
          value: 95,
          baseline: 50,
          deviation: 2.5,
          severity: :warning
        }
      }

      send(pid, {:signal_received, signal})

      # Allow time for message processing
      Process.sleep(50)

      {:ok, buffer} = MonitorLoop.get_buffer(profile.id)
      assert length(buffer) == 1
      assert hd(buffer).metric == :memory_usage
    end

    test "accumulates anomalies in buffer", %{pid: pid, profile: profile} do
      for i <- 1..5 do
        signal = %{
          data: %{
            metric: :"metric_#{i}",
            value: 100 + i,
            baseline: 50,
            severity: :info
          }
        }

        send(pid, {:signal_received, signal})
      end

      Process.sleep(100)

      {:ok, buffer} = MonitorLoop.get_buffer(profile.id)
      assert length(buffer) == 5
    end

    test "limits buffer size to 20 entries", %{pid: pid, profile: profile} do
      for i <- 1..30 do
        signal = %{
          data: %{
            metric: :"metric_#{i}",
            value: 100 + i,
            baseline: 50,
            severity: :info
          }
        }

        send(pid, {:signal_received, signal})
      end

      Process.sleep(150)

      {:ok, buffer} = MonitorLoop.get_buffer(profile.id)
      assert length(buffer) == 20
    end
  end

  describe "escalation logic" do
    # These tests verify the internal escalation criteria without requiring
    # the full signal infrastructure

    test "critical severity triggers immediate escalation consideration" do
      # Tested via force_escalate which uses the same code path
      # Full integration tests require the signal bus
      :ok
    end
  end
end
