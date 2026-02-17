defmodule Arbor.Contracts.Consensus.AgentMailboxTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Consensus.AgentMailbox

  describe "new/1" do
    test "creates mailbox with defaults" do
      assert {:ok, %AgentMailbox{} = mb} = AgentMailbox.new()
      assert mb.max_size == 100
      assert mb.reserved_high_priority == 10
      assert mb.high_count == 0
      assert mb.normal_count == 0
    end

    test "accepts custom sizes" do
      assert {:ok, mb} = AgentMailbox.new(max_size: 50, reserved_high_priority: 5)
      assert mb.max_size == 50
      assert mb.reserved_high_priority == 5
    end

    test "rejects max_size < 1" do
      assert {:error, :invalid_max_size} = AgentMailbox.new(max_size: 0)
    end

    test "rejects negative reserved" do
      assert {:error, :invalid_reserved} = AgentMailbox.new(reserved_high_priority: -1)
    end

    test "rejects reserved > max_size" do
      assert {:error, :reserved_exceeds_max} =
               AgentMailbox.new(max_size: 5, reserved_high_priority: 10)
    end
  end

  describe "enqueue/3 and dequeue/1" do
    test "enqueue and dequeue normal items FIFO" do
      {:ok, mb} = AgentMailbox.new()
      {:ok, mb} = AgentMailbox.enqueue(mb, %{id: 1}, :normal)
      {:ok, mb} = AgentMailbox.enqueue(mb, %{id: 2}, :normal)
      {:ok, item, mb} = AgentMailbox.dequeue(mb)
      assert item.id == 1
      {:ok, item, _mb} = AgentMailbox.dequeue(mb)
      assert item.id == 2
    end

    test "high priority dequeued before normal" do
      {:ok, mb} = AgentMailbox.new()
      {:ok, mb} = AgentMailbox.enqueue(mb, %{id: :normal}, :normal)
      {:ok, mb} = AgentMailbox.enqueue(mb, %{id: :high}, :high)
      {:ok, item, _mb} = AgentMailbox.dequeue(mb)
      assert item.id == :high
    end

    test "dequeue from empty mailbox returns :empty" do
      {:ok, mb} = AgentMailbox.new()
      assert {:empty, ^mb} = AgentMailbox.dequeue(mb)
    end

    test "normal items rejected when effective max reached" do
      {:ok, mb} = AgentMailbox.new(max_size: 5, reserved_high_priority: 2)
      # effective max for normal = 3
      {:ok, mb} = AgentMailbox.enqueue(mb, %{id: 1}, :normal)
      {:ok, mb} = AgentMailbox.enqueue(mb, %{id: 2}, :normal)
      {:ok, mb} = AgentMailbox.enqueue(mb, %{id: 3}, :normal)
      assert {:error, :mailbox_full} = AgentMailbox.enqueue(mb, %{id: 4}, :normal)
    end

    test "high priority can use reserved slots" do
      {:ok, mb} = AgentMailbox.new(max_size: 5, reserved_high_priority: 2)
      {:ok, mb} = AgentMailbox.enqueue(mb, %{id: 1}, :normal)
      {:ok, mb} = AgentMailbox.enqueue(mb, %{id: 2}, :normal)
      {:ok, mb} = AgentMailbox.enqueue(mb, %{id: 3}, :normal)
      # Normal is full at 3, but high can still enqueue
      {:ok, mb} = AgentMailbox.enqueue(mb, %{id: 4}, :high)
      {:ok, _mb} = AgentMailbox.enqueue(mb, %{id: 5}, :high)
    end

    test "high priority rejected when absolute max reached" do
      {:ok, mb} = AgentMailbox.new(max_size: 2, reserved_high_priority: 1)
      {:ok, mb} = AgentMailbox.enqueue(mb, %{id: 1}, :high)
      {:ok, mb} = AgentMailbox.enqueue(mb, %{id: 2}, :high)
      assert {:error, :mailbox_full} = AgentMailbox.enqueue(mb, %{id: 3}, :high)
    end
  end

  describe "peek/1" do
    test "peeks at high priority first" do
      {:ok, mb} = AgentMailbox.new()
      {:ok, mb} = AgentMailbox.enqueue(mb, %{id: :normal}, :normal)
      {:ok, mb} = AgentMailbox.enqueue(mb, %{id: :high}, :high)
      assert {:ok, %{id: :high}} = AgentMailbox.peek(mb)
    end

    test "peeks at normal when no high priority" do
      {:ok, mb} = AgentMailbox.new()
      {:ok, mb} = AgentMailbox.enqueue(mb, %{id: :normal}, :normal)
      assert {:ok, %{id: :normal}} = AgentMailbox.peek(mb)
    end

    test "returns :empty on empty mailbox" do
      {:ok, mb} = AgentMailbox.new()
      assert :empty = AgentMailbox.peek(mb)
    end
  end

  describe "size/1 and empty?/1" do
    test "size tracks total items" do
      {:ok, mb} = AgentMailbox.new()
      assert AgentMailbox.size(mb) == 0
      {:ok, mb} = AgentMailbox.enqueue(mb, %{}, :normal)
      assert AgentMailbox.size(mb) == 1
      {:ok, mb} = AgentMailbox.enqueue(mb, %{}, :high)
      assert AgentMailbox.size(mb) == 2
    end

    test "empty? on empty mailbox" do
      {:ok, mb} = AgentMailbox.new()
      assert AgentMailbox.empty?(mb) == true
    end

    test "empty? on non-empty mailbox" do
      {:ok, mb} = AgentMailbox.new()
      {:ok, mb} = AgentMailbox.enqueue(mb, %{}, :normal)
      assert AgentMailbox.empty?(mb) == false
    end
  end

  describe "full?/2" do
    test "full? for normal respects effective max" do
      {:ok, mb} = AgentMailbox.new(max_size: 3, reserved_high_priority: 1)
      {:ok, mb} = AgentMailbox.enqueue(mb, %{}, :normal)
      {:ok, mb} = AgentMailbox.enqueue(mb, %{}, :normal)
      assert AgentMailbox.full?(mb, :normal) == true
      assert AgentMailbox.full?(mb, :high) == false
    end

    test "full? for high respects absolute max" do
      {:ok, mb} = AgentMailbox.new(max_size: 2, reserved_high_priority: 0)
      {:ok, mb} = AgentMailbox.enqueue(mb, %{}, :normal)
      {:ok, mb} = AgentMailbox.enqueue(mb, %{}, :normal)
      assert AgentMailbox.full?(mb, :high) == true
    end
  end

  describe "capacity_info/1" do
    test "returns capacity information" do
      {:ok, mb} = AgentMailbox.new(max_size: 10, reserved_high_priority: 2)
      {:ok, mb} = AgentMailbox.enqueue(mb, %{}, :high)
      {:ok, mb} = AgentMailbox.enqueue(mb, %{}, :normal)

      info = AgentMailbox.capacity_info(mb)
      assert info.size == 2
      assert info.max_size == 10
      assert info.high_count == 1
      assert info.normal_count == 1
      assert info.reserved_high_priority == 2
      assert info.normal_slots_remaining == 6
      assert info.high_slots_remaining == 8
      assert info.utilization == 0.2
    end
  end
end
