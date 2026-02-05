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
      {:ok, pid} = MessageQueueFlood.inject(interval_ms: 10, batch_size: 50)
      assert Process.alive?(pid)

      # Wait for messages to accumulate
      Process.sleep(100)
      {:message_queue_len, len} = Process.info(pid, :message_queue_len)
      assert len > 50

      MessageQueueFlood.clear(pid)
    end
  end

  describe "clear/1" do
    test "stops the flood process" do
      {:ok, pid} = MessageQueueFlood.inject(interval_ms: 50, batch_size: 5)
      assert Process.alive?(pid)

      Process.unlink(pid)
      :ok = MessageQueueFlood.clear(pid)
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "handles nil reference" do
      assert :ok = MessageQueueFlood.clear(nil)
    end
  end
end
