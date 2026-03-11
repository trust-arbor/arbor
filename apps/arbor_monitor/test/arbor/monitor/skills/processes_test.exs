defmodule Arbor.Monitor.Skills.ProcessesTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Monitor.Skills.Processes

  describe "name/0" do
    test "returns :processes" do
      assert Processes.name() == :processes
    end
  end

  describe "collect/0" do
    test "returns expected keys with valid types" do
      assert {:ok, metrics} = Processes.collect()

      assert is_list(metrics.top_by_memory)
      assert is_list(metrics.top_by_reductions)
      assert is_list(metrics.top_by_message_queue)
      assert is_integer(metrics.max_message_queue_len) or is_number(metrics.max_message_queue_len)
    end

    test "top_by_memory entries have required fields" do
      assert {:ok, metrics} = Processes.collect()

      assert length(metrics.top_by_memory) > 0

      Enum.each(metrics.top_by_memory, fn proc ->
        assert Map.has_key?(proc, :pid)
        assert Map.has_key?(proc, :value)
        assert Map.has_key?(proc, :info)
        assert is_binary(proc.pid)
        assert is_number(proc.value)
        assert is_map(proc.info)
      end)
    end

    test "top_by_reductions entries have required fields" do
      assert {:ok, metrics} = Processes.collect()

      assert length(metrics.top_by_reductions) > 0

      Enum.each(metrics.top_by_reductions, fn proc ->
        assert Map.has_key?(proc, :pid)
        assert Map.has_key?(proc, :value)
        assert is_binary(proc.pid)
        assert is_number(proc.value)
      end)
    end
  end

  describe "check/1" do
    test "returns :normal for healthy message queues" do
      metrics = %{max_message_queue_len: 5}
      assert :normal = Processes.check(metrics)
    end

    test "detects high message queue length" do
      metrics = %{max_message_queue_len: 15_000}
      assert {:anomaly, :warning, details} = Processes.check(metrics)
      assert details.metric == :message_queue_len
      assert details.value == 15_000
    end
  end
end
