defmodule Arbor.Memory.HistoricalAccumulationFormatTest do
  @moduledoc """
  Synthetic JSON records from the historical serializers named in the fixture
  README. These are format compatibility tests, not a reproduction of the August
  production incident. The backend survives owner-process restarts in this BEAM;
  this file does not prove database, node, or host restart durability.
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Memory.{Goal, Intent}
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{TaintedValue, TaintEnvelope}
  alias Arbor.Memory
  alias Arbor.Memory.{GoalStore, IntentStore, KnowledgeGraphStore, Provenance}
  alias Arbor.Memory.Test.{DurableGraphAuthority, NodeRestartBackend}
  alias Arbor.Persistence
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag :integration
  @store_name :arbor_memory_durable
  @fixtures Path.expand("../../fixtures/historical_accumulation", __DIR__)
  @owners [KnowledgeGraphStore, GoalStore, IntentStore, Provenance]

  setup do
    # Goal/Intent writes also enqueue semantic projections. The test config pins
    # their embedding entry point to the deterministic local hash provider.
    assert Application.get_env(:arbor_ai, :embedding_test_fallback) == true
    fixture = DurableGraphAuthority.start!()
    existing_writers = writer_pids()
    agent_id = "agent_historical_format_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      await_new_writers(existing_writers)
      ensure_owners_running!()
      _ = GoalStore.clear_goals(agent_id)
      _ = IntentStore.clear(agent_id)
      _ = KnowledgeGraphStore.delete_graph(agent_id)
      _ = Memory.cleanup_for_agent(agent_id)
    end)

    Map.merge(fixture, %{agent_id: agent_id, existing_writers: existing_writers})
  end

  test "legacy JSON graph remains readable and accumulates a new fact across owner restart",
       ctx do
    legacy = fixture("knowledge_graph.json") |> Map.put("agent_id", ctx.agent_id)
    seed_record!("knowledge_graph:#{ctx.agent_id}", legacy)

    assert {:ok, graph} = Memory.export_knowledge_graph(ctx.agent_id)
    assert graph.nodes["node_legacy_a"].content == "Synthetic legacy orchard fact"
    assert graph.nodes["node_legacy_b"].content == "Synthetic legacy pruning fact"
    assert [%{id: "edge_legacy"}] = graph.edges["node_legacy_a"]
    assert [%{id: "pend_legacy"}] = graph.pending_learnings

    # This exact source atom was rejected before 5b7080b20. Its successful write
    # is separate from AgentSeed's semantic-index DateTime metadata rejection.
    assert {:ok, new_id} =
             Memory.add_knowledge(ctx.agent_id, %{
               type: :fact,
               content: "Synthetic new irrigation fact",
               metadata: %{source: :agent_tool}
             })

    assert {:ok, before_restart} = Memory.export_knowledge_graph(ctx.agent_id)
    assert map_size(before_restart.nodes) == 3
    restart_owners!(ctx)
    assert {:ok, ^before_restart} = Memory.export_knowledge_graph(ctx.agent_id)
    assert before_restart.nodes[new_id].content == "Synthetic new irrigation fact"

    # A caller-controlled compatibility import cannot replace existing authority.
    assert {:error, :conflict} = Memory.import_knowledge_graph(ctx.agent_id, legacy)
    assert {:ok, ^before_restart} = Memory.export_knowledge_graph(ctx.agent_id)
  end

  test "legacy goal dates and new progress survive current writes and owner restart", ctx do
    legacy = fixture("goal.json")
    seed_record!("goals:#{ctx.agent_id}:#{legacy["id"]}", legacy)

    assert {:ok, old_goal} = Memory.get_goal(ctx.agent_id, "goal_legacy")
    assert old_goal.created_at == ~U[2026-07-28 12:00:00Z]
    assert old_goal.deadline == ~U[2026-12-01 00:00:00Z]
    assert old_goal.progress == 0.25
    assert_missing_goal_label(ctx.agent_id)

    assert {:ok, changed} = Memory.update_goal_progress(ctx.agent_id, old_goal.id, 0.75)
    assert changed.progress == 0.75
    fresh = Goal.new("Synthetic newly accumulated goal", id: "goal_new")
    assert {:ok, ^fresh} = Memory.add_goal(ctx.agent_id, fresh)
    restart_owners!(ctx)

    assert {:ok, ^changed} = Memory.get_goal(ctx.agent_id, old_goal.id)
    assert {:ok, ^fresh} = Memory.get_goal(ctx.agent_id, fresh.id)
    assert length(Memory.get_all_goals(ctx.agent_id)) == 2
    assert_missing_goal_label(ctx.agent_id)
  end

  test "legacy intent aggregate retains status and percept while current writes survive restart",
       ctx do
    seed_record!("intents:#{ctx.agent_id}", fixture("intents.json"))

    assert {:ok, legacy, status} = Memory.get_intent(ctx.agent_id, "intent_legacy")
    assert legacy.reasoning == "Synthetic historical reasoning"
    assert legacy.created_at == ~U[2026-07-28 12:00:00Z]
    assert status == %{status: :locked, locked_at: ~U[2026-07-28 12:00:00Z], retry_count: 3}
    assert {:ok, percept} = Memory.get_percept_for_intent(ctx.agent_id, legacy.id)
    assert percept.summary == "Synthetic result"
    assert_missing_intent_label(ctx.agent_id, legacy.id)

    assert :ok = Memory.complete_intent(ctx.agent_id, legacy.id)
    assert {:ok, ^legacy, completed_status} = Memory.get_intent(ctx.agent_id, legacy.id)
    assert completed_status.status == :completed
    fresh = Intent.think("Synthetic newly accumulated intention")
    assert {:ok, ^fresh} = Memory.record_intent(ctx.agent_id, fresh)
    restart_owners!(ctx)

    assert {:ok, ^legacy, ^completed_status} = Memory.get_intent(ctx.agent_id, legacy.id)
    assert {:ok, ^percept} = Memory.get_percept_for_intent(ctx.agent_id, legacy.id)
    assert {:ok, ^fresh, %{status: :pending}} = Memory.get_intent(ctx.agent_id, fresh.id)
    assert length(Memory.recent_intents(ctx.agent_id)) == 2
    assert_missing_intent_label(ctx.agent_id, legacy.id)
  end

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  # Fixture installation only: an old physical record has no current envelope.
  # All domain observations and mutations above use the public Memory APIs.
  defp seed_record!(key, payload) do
    record = Record.new(key, payload, id: "memory:#{key}", metadata: %{})
    assert :ok = Persistence.put(@store_name, BufferedStore, key, record)
  end

  defp restart_owners!(ctx) do
    # Wait for this test's secondary projection workers before dropping owners;
    # their completion is cleanup, not evidence of semantic vector durability.
    await_new_writers(ctx.existing_writers)

    for owner <- @owners do
      assert :ok = Supervisor.terminate_child(Memory.Supervisor, owner)
    end

    assert :ok = stop_supervised(BufferedStore)

    start_supervised!(
      {BufferedStore,
       name: @store_name,
       backend: NodeRestartBackend,
       collection: ctx.backend_name,
       write_mode: :sync,
       ack_mode: :backend}
    )

    for owner <- Enum.reverse(@owners) do
      assert {:ok, _pid} = Supervisor.restart_child(Memory.Supervisor, owner)
    end
  end

  defp ensure_owners_running! do
    for owner <- Enum.reverse(@owners), Process.whereis(owner) == nil do
      assert {:ok, _pid} = Supervisor.restart_child(Memory.Supervisor, owner)
    end
  end

  defp writer_pids do
    Memory.AsyncWriter.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_, pid, _, _} when is_pid(pid) -> [pid]
      _ -> []
    end)
    |> MapSet.new()
  end

  defp await_new_writers(existing) do
    for pid <- MapSet.difference(writer_pids(), existing) do
      monitor = Process.monitor(pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 5_000
    end
  end

  # The owning stores expose provenance-rich reads beyond the compatibility
  # facade. They prove format conversion did not upgrade unlabeled source data.
  defp assert_missing_goal_label(agent_id) do
    assert {:ok, %TaintedValue{taint: taint}, :legacy_unlabeled} =
             GoalStore.get_goal_tainted(agent_id, "goal_legacy")

    assert taint == TaintEnvelope.missing_fallback()
  end

  defp assert_missing_intent_label(agent_id, intent_id) do
    assert {:ok, entries} = IntentStore.recent_intents_tainted(agent_id)

    assert {%TaintedValue{taint: taint}, :legacy_unlabeled} =
             Enum.find(entries, fn {value, _status} -> value.value.id == intent_id end)

    assert taint == TaintEnvelope.missing_fallback()
  end
end
