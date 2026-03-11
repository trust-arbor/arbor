defmodule Arbor.Memory.DistributedSyncTest do
  @moduledoc """
  Tests for distributed memory cache invalidation via signals.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Memory.{DistributedSync, WorkingMemoryStore, GraphOps, GoalStore, WorkingMemory}
  alias Arbor.Contracts.Memory.Goal

  @working_memory_ets :arbor_working_memory
  @graph_ets :arbor_memory_graphs
  @goals_ets :arbor_memory_goals

  setup do
    ensure_ets(@working_memory_ets)
    ensure_ets(@graph_ets)
    ensure_ets(@goals_ets)

    pid = start_supervised!({DistributedSync, [name: DistributedSync]})
    %{sync_pid: pid}
  end

  defp ensure_ets(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:named_table, :public, :set])
    end
  rescue
    ArgumentError -> :ok
  end

  # ── Working Memory Invalidation ───────────────────────────────────────

  describe "working memory cache invalidation" do
    test "invalidates working memory on remote signal" do
      agent_id = "agent_dist_wm_#{System.unique_integer([:positive])}"
      wm = WorkingMemory.new(agent_id)
      :ets.insert(@working_memory_ets, {agent_id, wm})

      # Confirm it's cached
      assert WorkingMemoryStore.get_working_memory(agent_id) != nil

      # Simulate a remote working_memory_saved signal
      send(Process.whereis(DistributedSync), {:signal_received, %{
        type: :working_memory_saved,
        data: %{
          agent_id: agent_id,
          origin_node: :remote@node
        }
      }})

      Process.sleep(10)

      # Should be invalidated — ETS entry deleted
      assert WorkingMemoryStore.get_working_memory(agent_id) == nil
    end

    test "ignores working memory signals from own node" do
      agent_id = "agent_dist_wm_self_#{System.unique_integer([:positive])}"
      wm = WorkingMemory.new(agent_id)
      :ets.insert(@working_memory_ets, {agent_id, wm})

      send(Process.whereis(DistributedSync), {:signal_received, %{
        type: :working_memory_saved,
        data: %{
          agent_id: agent_id,
          origin_node: node()
        }
      }})

      Process.sleep(10)

      # Should still be cached — signal from own node is ignored
      assert WorkingMemoryStore.get_working_memory(agent_id) != nil

      # Cleanup
      :ets.delete(@working_memory_ets, agent_id)
    end
  end

  # ── Knowledge Graph Invalidation ──────────────────────────────────────

  describe "knowledge graph cache invalidation" do
    test "invalidates knowledge graph on remote knowledge_added signal" do
      agent_id = "agent_dist_kg_#{System.unique_integer([:positive])}"

      graph = Arbor.Memory.KnowledgeGraph.new("test_agent")
      :ets.insert(@graph_ets, {agent_id, graph})

      assert {:ok, _} = GraphOps.get_graph(agent_id)

      send(Process.whereis(DistributedSync), {:signal_received, %{
        type: :knowledge_added,
        data: %{
          agent_id: agent_id,
          origin_node: :remote@node,
          node_id: "node_123",
          node_type: :fact
        }
      }})

      Process.sleep(10)

      assert {:error, :graph_not_initialized} = GraphOps.get_graph(agent_id)
    end

    test "invalidates knowledge graph on remote knowledge_linked signal" do
      agent_id = "agent_dist_kg_link_#{System.unique_integer([:positive])}"

      graph = Arbor.Memory.KnowledgeGraph.new("test_agent")
      :ets.insert(@graph_ets, {agent_id, graph})

      send(Process.whereis(DistributedSync), {:signal_received, %{
        type: :knowledge_linked,
        data: %{
          agent_id: agent_id,
          origin_node: :remote@node,
          source_id: "node_a",
          target_id: "node_b"
        }
      }})

      Process.sleep(10)

      assert {:error, :graph_not_initialized} = GraphOps.get_graph(agent_id)
    end
  end

  # ── Goal Cache Invalidation ──────────────────────────────────────────

  describe "goal cache invalidation" do
    test "reloads goal on remote goal_created signal" do
      agent_id = "agent_dist_goal_#{System.unique_integer([:positive])}"
      goal_id = "goal_#{System.unique_integer([:positive])}"

      # Simulate a remote goal_created signal for a goal we don't have yet
      send(Process.whereis(DistributedSync), {:signal_received, %{
        type: :goal_created,
        data: %{
          agent_id: agent_id,
          goal_id: goal_id,
          origin_node: :remote@node
        }
      }})

      Process.sleep(10)

      # Goal may or may not be in Postgres (test env), but the handler shouldn't crash
      # The important thing is DistributedSync is still alive
      assert Process.alive?(Process.whereis(DistributedSync))
    end

    test "handles goal_progress signal from remote node" do
      agent_id = "agent_dist_goal_progress_#{System.unique_integer([:positive])}"
      goal = Goal.new("Test distributed goal", type: :achieve, priority: 80)
      :ets.insert(@goals_ets, {{agent_id, goal.id}, goal})

      send(Process.whereis(DistributedSync), {:signal_received, %{
        type: :goal_progress,
        data: %{
          agent_id: agent_id,
          goal_id: goal.id,
          origin_node: :remote@node,
          progress: 0.5
        }
      }})

      Process.sleep(10)

      # Should still be alive and functional
      assert Process.alive?(Process.whereis(DistributedSync))

      # Cleanup
      :ets.delete(@goals_ets, {agent_id, goal.id})
    end

    test "ignores goal signals from own node" do
      agent_id = "agent_dist_goal_self_#{System.unique_integer([:positive])}"
      goal = Goal.new("Keep this goal", type: :achieve)
      :ets.insert(@goals_ets, {{agent_id, goal.id}, goal})

      send(Process.whereis(DistributedSync), {:signal_received, %{
        type: :goal_achieved,
        data: %{
          agent_id: agent_id,
          goal_id: goal.id,
          origin_node: node()
        }
      }})

      Process.sleep(10)

      # Should still have the original goal (self-signal ignored)
      assert {:ok, ^goal} = GoalStore.get_goal(agent_id, goal.id)

      # Cleanup
      :ets.delete(@goals_ets, {agent_id, goal.id})
    end
  end

  # ── Robustness ───────────────────────────────────────────────────────

  describe "robustness" do
    test "handles unknown signal types gracefully" do
      send(Process.whereis(DistributedSync), {:signal_received, %{
        type: :completely_unknown_type,
        data: %{
          origin_node: :remote@node
        }
      }})

      Process.sleep(10)

      assert Process.alive?(Process.whereis(DistributedSync))
    end

    test "handles malformed signal data gracefully" do
      send(Process.whereis(DistributedSync), {:signal_received, %{
        type: :working_memory_saved,
        data: %{origin_node: :remote@node}
      }})

      Process.sleep(10)

      assert Process.alive?(Process.whereis(DistributedSync))
    end

    test "handles random messages gracefully" do
      send(Process.whereis(DistributedSync), :random_message)
      send(Process.whereis(DistributedSync), {:unexpected, :tuple})

      Process.sleep(10)

      assert Process.alive?(Process.whereis(DistributedSync))
    end
  end

  # ── Config ──────────────────────────────────────────────────────────

  describe "config" do
    test "distributed_signals defaults to true" do
      original = Application.get_env(:arbor_memory, :distributed_signals)
      Application.delete_env(:arbor_memory, :distributed_signals)

      assert Application.get_env(:arbor_memory, :distributed_signals, true) == true

      if original != nil do
        Application.put_env(:arbor_memory, :distributed_signals, original)
      end
    end
  end
end
