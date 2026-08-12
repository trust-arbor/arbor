defmodule Arbor.Actions.MemoryTestBootstrapTest do
  @moduledoc """
  Contract guard for `Arbor.Memory.TestBootstrap`, the shared setup that four
  consumer apps' `test_helper.exs` files depend on.

  This lives in a CONSUMER app deliberately. Calling `TestBootstrap.start!/0`
  from arbor_memory's own suite would register a process-wide
  `:arbor_memory_durable`, which is exactly what
  `Arbor.Memory.Test.DurableGraphAuthority.assert_unowned!/0` refuses — its
  graph tests own that name per-test to stay isolated. The fixture and this
  module are for different callers and must not meet.

  What this pins: after bootstrap, `Arbor.Memory.init_for_agent/1` works **with
  the knowledge graph enabled**. That is the exact call that started returning
  `{:error, :store_unavailable}` on 2026-08-05 and took 103 tests in this app
  alone with it.
  """

  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Memory.TestBootstrap

  @moduletag :fast

  describe "TestBootstrap contract (regression)" do
    test "init_for_agent/1 succeeds with the knowledge graph ENABLED" do
      agent_id = "bootstrap_contract_#{System.unique_integer([:positive])}"

      # graph_enabled defaults to true — the path that broke. A test passing
      # only with graph_enabled: false would not catch a regression here.
      assert {:ok, pid} = Arbor.Memory.init_for_agent(agent_id)
      assert is_pid(pid)

      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
    end

    test "the durable graph authority is registered" do
      assert Process.whereis(:arbor_memory_durable),
             "TestBootstrap must register :arbor_memory_durable; without it " <>
               "KnowledgeGraphStore fails closed and every memory test fails " <>
               "with a misleading :store_unavailable"
    end

    test "graph reads reach the store rather than failing closed" do
      agent_id = "bootstrap_graph_#{System.unique_integer([:positive])}"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)
      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)

      # Starting the PROCESSES is not sufficient — they can all be alive while
      # this still returns :store_unavailable, because the real failure is the
      # BufferedStore backend config, inside the call behind a catch-all rescue.
      refute match?({:error, :store_unavailable}, Arbor.Memory.export_knowledge_graph(agent_id))
    end

    test "start!/0 is idempotent" do
      assert :ok = TestBootstrap.start!()
      assert :ok = TestBootstrap.start!()

      agent_id = "bootstrap_idempotent_#{System.unique_integer([:positive])}"
      assert {:ok, _} = Arbor.Memory.init_for_agent(agent_id)
      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
    end

    test "default start is admission-ready" do
      assert :ok = TestBootstrap.start!()
      assert {:ok, %{durability: :node_restart}} = Arbor.Memory.MutationAdmission.readiness()
      assert is_pid(Process.whereis(Arbor.Memory.AsyncWriter.Supervisor))
    end

    test "GoalStore owns its ETS table, so no external table-owner is needed" do
      # arbor_agent used to hand-roll a MemoryGoalsTableOwner purely to create
      # this table. Starting the real store is what makes that unnecessary.
      assert :ets.whereis(:arbor_memory_goals) != :undefined
    end
  end
end
