defmodule Arbor.Checkpoint.EdgeCasesTest do
  use ExUnit.Case, async: false

  alias Arbor.Checkpoint
  alias Arbor.Checkpoint.Store.Agent, as: AgentStorage

  import Arbor.Checkpoint.TestHelpers, only: [safe_stop: 1]

  @moduletag :fast

  setup do
    {:ok, pid} = AgentStorage.start_link()
    on_exit(fn -> safe_stop(pid) end)
    :ok
  end

  describe "checkpoint IDs" do
    test "supports string IDs" do
      assert :ok = Checkpoint.save("string_id", %{data: 1}, AgentStorage)
      assert {:ok, %{data: 1}} = Checkpoint.load("string_id", AgentStorage)
    end

    test "supports atom IDs" do
      assert :ok = Checkpoint.save(:atom_id, %{data: 2}, AgentStorage)
      assert {:ok, %{data: 2}} = Checkpoint.load(:atom_id, AgentStorage)
    end

    test "supports tuple IDs" do
      id = {:agent, "user_123"}
      assert :ok = Checkpoint.save(id, %{data: 3}, AgentStorage)
      assert {:ok, %{data: 3}} = Checkpoint.load(id, AgentStorage)
    end
  end

  describe "checkpoint data types" do
    test "supports map data" do
      data = %{nested: %{deep: %{value: 42}}}
      assert :ok = Checkpoint.save("test", data, AgentStorage)
      assert {:ok, ^data} = Checkpoint.load("test", AgentStorage)
    end

    test "supports list data" do
      data = [1, 2, 3, {:tuple, "value"}]
      assert :ok = Checkpoint.save("test", data, AgentStorage)
      assert {:ok, ^data} = Checkpoint.load("test", AgentStorage)
    end

    test "supports struct data" do
      data = %URI{host: "example.com", port: 443, scheme: "https"}
      assert :ok = Checkpoint.save("test", data, AgentStorage)
      assert {:ok, ^data} = Checkpoint.load("test", AgentStorage)
    end

    test "supports binary data" do
      data = <<1, 2, 3, 4, 5>>
      assert :ok = Checkpoint.save("test", data, AgentStorage)
      assert {:ok, ^data} = Checkpoint.load("test", AgentStorage)
    end

    test "supports nil data" do
      assert :ok = Checkpoint.save("test", nil, AgentStorage)
      assert {:ok, nil} = Checkpoint.load("test", AgentStorage)
    end
  end

  describe "concurrent operations" do
    test "handles concurrent saves to different IDs" do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            Checkpoint.save("concurrent_#{i}", %{index: i}, AgentStorage)
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == :ok))
      assert AgentStorage.count() == 10
    end

    test "handles concurrent save and load" do
      # Pre-save a checkpoint
      :ok = Checkpoint.save("concurrent", %{version: 0}, AgentStorage)

      # Spawn concurrent writers first, then readers
      write_tasks =
        for i <- 1..5 do
          Task.async(fn ->
            Checkpoint.save("concurrent", %{version: i}, AgentStorage)
          end)
        end

      write_results = Task.await_many(write_tasks)
      assert Enum.all?(write_results, &(&1 == :ok))

      # Now read concurrently - data should exist
      read_tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            Checkpoint.load("concurrent", AgentStorage, retries: 0)
          end)
        end

      read_results = Task.await_many(read_tasks)

      assert Enum.all?(read_results, fn
        {:ok, _} -> true
        _ -> false
      end)
    end
  end

  describe "enable_auto_save edge cases" do
    test "allows multiple schedules to same process" do
      :ok = Checkpoint.enable_auto_save(self(), 50)
      :ok = Checkpoint.enable_auto_save(self(), 50)
      :ok = Checkpoint.enable_auto_save(self(), 50)

      # Should receive 3 messages
      assert_receive :checkpoint, 200
      assert_receive :checkpoint, 200
      assert_receive :checkpoint, 200
    end

    test "message received after process does other work" do
      :ok = Checkpoint.enable_auto_save(self(), 10)

      # Do some work
      _result = Enum.map(1..100, &(&1 * 2))

      # Should still receive the message
      assert_receive :checkpoint, 100
    end
  end

  describe "attempt_recovery with various initial_args" do
    alias Arbor.Checkpoint.Test.StatefulModule

    test "handles empty map initial_args" do
      checkpoint_data = %{counter: 42, important_data: "test"}
      :ok = Checkpoint.save("agent", checkpoint_data, AgentStorage)

      assert {:ok, recovered} = Checkpoint.attempt_recovery(
        StatefulModule,
        "agent",
        %{},
        AgentStorage
      )

      assert recovered.counter == 42
    end

    test "handles nil initial_args" do
      checkpoint_data = %{counter: 42, important_data: "test"}
      :ok = Checkpoint.save("agent", checkpoint_data, AgentStorage)

      assert {:ok, recovered} = Checkpoint.attempt_recovery(
        StatefulModule,
        "agent",
        nil,
        AgentStorage
      )

      assert recovered.counter == 42
    end
  end
end
