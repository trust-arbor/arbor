defmodule Arbor.Monitor.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias Arbor.Monitor.Diagnostics

  describe "inspect_process/1" do
    test "returns process info for valid pid" do
      pid = spawn(fn -> Process.sleep(1000) end)
      result = Diagnostics.inspect_process(pid)

      assert result.pid == pid
      assert is_integer(result.message_queue_len)
      assert is_integer(result.memory)
      assert is_integer(result.reductions)
      assert is_list(result.links)
      assert is_map(result.dictionary)

      Process.exit(pid, :kill)
    end

    test "returns nil for dead process" do
      pid = spawn(fn -> :ok end)
      Process.sleep(10)
      assert Diagnostics.inspect_process(pid) == nil
    end

    test "returns nil for invalid input" do
      assert Diagnostics.inspect_process(:not_a_pid) == nil
      assert Diagnostics.inspect_process("pid") == nil
    end

    test "extracts arbor metadata from dictionary" do
      correlation_id = "test_123"
      fault_type = :test_fault

      pid =
        spawn(fn ->
          Process.put(:arbor_correlation_id, correlation_id)
          Process.put(:arbor_fault_type, fault_type)
          receive do
            :stop -> :ok
          end
        end)

      # Wait for process to initialize
      Process.sleep(5)

      result = Diagnostics.inspect_process(pid)
      assert result.dictionary.correlation_id == correlation_id
      assert result.dictionary.fault_type == fault_type

      send(pid, :stop)
    end
  end

  describe "inspect_supervisor/1" do
    test "returns supervisor info for valid supervisor" do
      {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one)
      result = Diagnostics.inspect_supervisor(sup)

      assert result.pid == sup
      assert is_list(result.children)
      assert result.child_count == 0
      assert is_integer(result.active)
      assert is_integer(result.workers)

      Supervisor.stop(sup)
    end

    test "returns nil for non-supervisor process" do
      pid = spawn(fn -> Process.sleep(1000) end)
      assert Diagnostics.inspect_supervisor(pid) == nil
      Process.exit(pid, :kill)
    end

    test "includes child information" do
      child_spec = %{
        id: :test_worker,
        start: {Task, :start_link, [fn -> Process.sleep(10_000) end]}
      }

      {:ok, sup} = Supervisor.start_link([child_spec], strategy: :one_for_one)
      result = Diagnostics.inspect_supervisor(sup)

      assert result.child_count == 1
      assert length(result.children) == 1

      [child] = result.children
      assert child.id == :test_worker
      assert child.alive == true
      assert is_pid(child.pid)

      Supervisor.stop(sup)
    end
  end

  describe "top_processes_by/2" do
    test "returns top processes by memory" do
      result = Diagnostics.top_processes_by(:memory, 5)

      assert is_list(result)
      assert length(result) <= 5
      assert Enum.all?(result, fn p -> is_map(p) and Map.has_key?(p, :pid) end)
    end

    test "returns top processes by message_queue" do
      result = Diagnostics.top_processes_by(:message_queue, 5)

      assert is_list(result)
      assert Enum.all?(result, fn p -> p.metric == :message_queue end)
    end

    test "returns top processes by reductions" do
      result = Diagnostics.top_processes_by(:reductions, 5)

      assert is_list(result)
      assert Enum.all?(result, fn p -> p.metric == :reductions end)
    end
  end

  describe "process_tree/1" do
    test "returns tree for valid pid" do
      parent = self()
      result = Diagnostics.process_tree(parent)

      assert result.pid == parent
      assert is_list(result.children)
    end

    test "returns nil for dead process" do
      pid = spawn(fn -> :ok end)
      Process.sleep(10)
      assert Diagnostics.process_tree(pid) == nil
    end
  end

  describe "scheduler_utilization/0" do
    test "returns utilization as float" do
      result = Diagnostics.scheduler_utilization()

      assert is_float(result)
      assert result >= 0.0
      assert result <= 1.0
    end
  end

  describe "memory_info/0" do
    test "returns memory information" do
      result = Diagnostics.memory_info()

      assert is_map(result)
      assert is_integer(result.total)
      assert is_integer(result.allocated)
      assert is_float(result.usage_ratio)
      assert is_integer(result.process_memory)
      assert is_integer(result.ets_memory)
    end
  end

  describe "find_bloated_queues/1" do
    test "returns empty list when no queues exceed threshold" do
      result = Diagnostics.find_bloated_queues(1_000_000)
      assert is_list(result)
    end

    test "finds processes with large message queues" do
      # Create a process with a bloated queue
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      # Send many messages
      for _ <- 1..100 do
        send(pid, :flood)
      end

      result = Diagnostics.find_bloated_queues(50)
      assert Enum.any?(result, fn p -> p.pid == pid end)

      send(pid, :stop)
    end
  end

  describe "trace_arbor_metadata/1" do
    test "returns empty map for process without metadata" do
      pid = spawn(fn -> Process.sleep(1000) end)
      result = Diagnostics.trace_arbor_metadata(pid)

      assert result == %{}

      Process.exit(pid, :kill)
    end

    test "returns metadata for process with arbor data" do
      pid =
        spawn(fn ->
          Process.put(:arbor_correlation_id, "corr_123")
          Process.put(:arbor_fault_type, :test)
          receive do
            :stop -> :ok
          end
        end)

      Process.sleep(5)
      result = Diagnostics.trace_arbor_metadata(pid)

      assert result.correlation_id == "corr_123"
      assert result.fault_type == :test

      send(pid, :stop)
    end
  end
end
