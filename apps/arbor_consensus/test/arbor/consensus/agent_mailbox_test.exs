defmodule Arbor.Contracts.Consensus.AgentMailboxTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Consensus.AgentMailbox

  describe "new/1" do
    test "creates a mailbox with default options" do
      assert {:ok, mailbox} = AgentMailbox.new()
      assert mailbox.max_size == 100
      assert mailbox.reserved_high_priority == 10
      assert mailbox.high_count == 0
      assert mailbox.normal_count == 0
    end

    test "creates a mailbox with custom options" do
      assert {:ok, mailbox} = AgentMailbox.new(max_size: 50, reserved_high_priority: 5)
      assert mailbox.max_size == 50
      assert mailbox.reserved_high_priority == 5
    end

    test "rejects invalid max_size" do
      assert {:error, :invalid_max_size} = AgentMailbox.new(max_size: 0)
      assert {:error, :invalid_max_size} = AgentMailbox.new(max_size: -1)
    end

    test "rejects invalid reserved_high_priority" do
      assert {:error, :invalid_reserved} = AgentMailbox.new(reserved_high_priority: -1)
    end

    test "rejects reserved exceeding max" do
      assert {:error, :reserved_exceeds_max} = AgentMailbox.new(max_size: 10, reserved_high_priority: 15)
    end
  end

  describe "enqueue/3" do
    test "enqueues normal priority items" do
      {:ok, mailbox} = AgentMailbox.new(max_size: 10, reserved_high_priority: 2)
      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, %{id: 1}, :normal)

      assert mailbox.normal_count == 1
      assert mailbox.high_count == 0
    end

    test "enqueues high priority items" do
      {:ok, mailbox} = AgentMailbox.new(max_size: 10, reserved_high_priority: 2)
      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, %{id: 1}, :high)

      assert mailbox.high_count == 1
      assert mailbox.normal_count == 0
    end

    test "rejects normal items when effective capacity reached" do
      {:ok, mailbox} = AgentMailbox.new(max_size: 10, reserved_high_priority: 3)

      # Fill up to effective max (10 - 3 = 7 slots for normal)
      mailbox =
        Enum.reduce(1..7, mailbox, fn i, mb ->
          {:ok, updated} = AgentMailbox.enqueue(mb, %{id: i}, :normal)
          updated
        end)

      # Next normal should be rejected
      assert {:error, :mailbox_full} = AgentMailbox.enqueue(mailbox, %{id: 8}, :normal)
    end

    test "high priority can use reserved slots" do
      {:ok, mailbox} = AgentMailbox.new(max_size: 10, reserved_high_priority: 3)

      # Fill with 7 normal items
      mailbox =
        Enum.reduce(1..7, mailbox, fn i, mb ->
          {:ok, updated} = AgentMailbox.enqueue(mb, %{id: i}, :normal)
          updated
        end)

      # High priority should still work (uses reserved slots)
      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, %{id: 8}, :high)
      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, %{id: 9}, :high)
      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, %{id: 10}, :high)

      # But now even high priority is full
      assert {:error, :mailbox_full} = AgentMailbox.enqueue(mailbox, %{id: 11}, :high)
    end
  end

  describe "dequeue/1" do
    test "returns empty for empty mailbox" do
      {:ok, mailbox} = AgentMailbox.new()
      assert {:empty, ^mailbox} = AgentMailbox.dequeue(mailbox)
    end

    test "dequeues high priority items first" do
      {:ok, mailbox} = AgentMailbox.new()
      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, %{id: :normal_1}, :normal)
      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, %{id: :high_1}, :high)
      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, %{id: :normal_2}, :normal)

      {:ok, envelope1, mailbox} = AgentMailbox.dequeue(mailbox)
      assert envelope1.id == :high_1

      {:ok, envelope2, mailbox} = AgentMailbox.dequeue(mailbox)
      assert envelope2.id == :normal_1

      {:ok, envelope3, _mailbox} = AgentMailbox.dequeue(mailbox)
      assert envelope3.id == :normal_2
    end

    test "maintains FIFO within priority class" do
      {:ok, mailbox} = AgentMailbox.new()
      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, %{id: 1}, :normal)
      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, %{id: 2}, :normal)
      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, %{id: 3}, :normal)

      {:ok, %{id: 1}, mailbox} = AgentMailbox.dequeue(mailbox)
      {:ok, %{id: 2}, mailbox} = AgentMailbox.dequeue(mailbox)
      {:ok, %{id: 3}, _mailbox} = AgentMailbox.dequeue(mailbox)
    end
  end

  describe "peek/1" do
    test "returns empty for empty mailbox" do
      {:ok, mailbox} = AgentMailbox.new()
      assert :empty = AgentMailbox.peek(mailbox)
    end

    test "peeks at high priority first" do
      {:ok, mailbox} = AgentMailbox.new()
      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, %{id: :normal}, :normal)
      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, %{id: :high}, :high)

      assert {:ok, %{id: :high}} = AgentMailbox.peek(mailbox)
      # Peek doesn't remove
      assert {:ok, %{id: :high}} = AgentMailbox.peek(mailbox)
    end
  end

  describe "size/1" do
    test "returns total size" do
      {:ok, mailbox} = AgentMailbox.new()
      assert AgentMailbox.size(mailbox) == 0

      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, %{id: 1}, :normal)
      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, %{id: 2}, :high)
      assert AgentMailbox.size(mailbox) == 2
    end
  end

  describe "empty?/1" do
    test "returns true for empty mailbox" do
      {:ok, mailbox} = AgentMailbox.new()
      assert AgentMailbox.empty?(mailbox)
    end

    test "returns false for non-empty mailbox" do
      {:ok, mailbox} = AgentMailbox.new()
      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, %{id: 1}, :normal)
      refute AgentMailbox.empty?(mailbox)
    end
  end

  describe "full?/2" do
    test "checks if full for given priority" do
      {:ok, mailbox} = AgentMailbox.new(max_size: 10, reserved_high_priority: 3)

      # Fill normal capacity (7)
      mailbox =
        Enum.reduce(1..7, mailbox, fn i, mb ->
          {:ok, updated} = AgentMailbox.enqueue(mb, %{id: i}, :normal)
          updated
        end)

      assert AgentMailbox.full?(mailbox, :normal)
      refute AgentMailbox.full?(mailbox, :high)

      # Fill remaining high priority slots
      mailbox =
        Enum.reduce(8..10, mailbox, fn i, mb ->
          {:ok, updated} = AgentMailbox.enqueue(mb, %{id: i}, :high)
          updated
        end)

      assert AgentMailbox.full?(mailbox, :high)
    end
  end

  describe "capacity_info/1" do
    test "returns comprehensive capacity information" do
      {:ok, mailbox} = AgentMailbox.new(max_size: 10, reserved_high_priority: 3)
      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, %{id: 1}, :normal)
      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, %{id: 2}, :high)

      info = AgentMailbox.capacity_info(mailbox)

      assert info.size == 2
      assert info.max_size == 10
      assert info.high_count == 1
      assert info.normal_count == 1
      assert info.reserved_high_priority == 3
      assert info.normal_slots_remaining == 5  # 7 - 2 = 5
      assert info.high_slots_remaining == 8    # 10 - 2 = 8
      assert info.utilization == 0.2
    end
  end
end
