defmodule Arbor.Demo.Faults.MessageQueueFloodTest do
  use ExUnit.Case, async: true

  alias Arbor.Demo.Faults.MessageQueueFlood

  describe "behaviour" do
    test "name returns :message_queue_flood" do
      assert MessageQueueFlood.name() == :message_queue_flood
    end

    test "description returns a string" do
      assert is_binary(MessageQueueFlood.description())
    end

    test "detectable_by includes :processes" do
      assert :processes in MessageQueueFlood.detectable_by()
    end
  end

  describe "inject/1" do
    test "spawns a process that accumulates messages" do
      {:ok, pid, correlation_id} = MessageQueueFlood.inject(interval_ms: 10, batch_size: 50)
      assert Process.alive?(pid)
      assert is_binary(correlation_id)
      assert String.starts_with?(correlation_id, "fault_mqf_")

      # Wait for messages to accumulate
      Process.sleep(100)
      {:message_queue_len, len} = Process.info(pid, :message_queue_len)
      assert len > 50

      # Clean up by killing the process directly
      Process.exit(pid, :shutdown)
    end

    test "stores correlation_id in process dictionary" do
      {:ok, pid, correlation_id} = MessageQueueFlood.inject(interval_ms: 50)

      # No sleep needed - inject/1 waits for process initialization
      {:dictionary, dict} = Process.info(pid, :dictionary)
      assert Keyword.get(dict, :arbor_correlation_id) == correlation_id
      assert Keyword.get(dict, :arbor_fault_type) == :message_queue_flood

      Process.exit(pid, :shutdown)
    end
  end
end
