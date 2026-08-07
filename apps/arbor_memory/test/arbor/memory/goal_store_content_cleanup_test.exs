defmodule Arbor.Memory.GoalStoreContentCleanupTest do
  @moduledoc """
  Content-only GoalStore cleanup primitives (VP-05D2C3I0C1).
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Memory.Goal
  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.{GoalStore, MemoryStore, Provenance}
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag spec: "VP-05D2C3I0C1"
  @store_name :arbor_memory_durable
  @goals_ets :arbor_memory_goals

  setup do
    start_supervised!({BufferedStore, name: @store_name, backend: nil, write_mode: :sync})

    uid = System.unique_integer([:positive])
    target = "agent_a_#{uid}"
    child = "agent_a_#{uid}_child"
    survivor = "agent_b_#{uid}"

    for agent <- [target, child, survivor] do
      _ = GoalStore.clear_goals(agent)
      _ = Provenance.delete_agent(agent)
    end

    on_exit(fn ->
      for agent <- [target, child, survivor] do
        _ = GoalStore.clear_goals(agent)
        _ = Provenance.delete_agent(agent)
      end
    end)

    %{target: target, child: child, survivor: survivor}
  end

  test "delete_agent_content removes target durable/projection/deferred and retains provenance",
       %{
         target: target,
         child: child,
         survivor: survivor
       } do
    taint = taint(:trusted, :internal, "goal_content_cleanup")
    target_goal = Goal.new("target goal", id: "goal_target_#{System.unique_integer([:positive])}")
    child_goal = Goal.new("child goal", id: "goal_child_#{System.unique_integer([:positive])}")

    survivor_goal =
      Goal.new("survivor goal", id: "goal_surv_#{System.unique_integer([:positive])}")

    assert {:ok, ^target_goal} = GoalStore.add_goal_tainted(target, target_goal, taint)
    assert {:ok, ^child_goal} = GoalStore.add_goal_tainted(child, child_goal, taint)
    assert {:ok, ^survivor_goal} = GoalStore.add_goal_tainted(survivor, survivor_goal, taint)

    payload = goal_payload(target_goal)
    assert {:ok, ^taint, :verified} = Provenance.resolve(:goal, target, target_goal.id, payload)
    assert {:ok, ids_before} = Provenance.list_item_ids(:goal, target)
    assert target_goal.id in ids_before

    assert {:ok, false} = GoalStore.agent_content_absent?(target)

    assert :ok = GoalStore.delete_agent_content(target)
    assert {:ok, true} = GoalStore.agent_content_absent?(target)

    # Idempotent retry
    assert :ok = GoalStore.delete_agent_content(target)
    assert {:ok, true} = GoalStore.agent_content_absent?(target)

    # Prove content gone without rehydrate paths that may rewrite live labels.
    assert [] = :ets.lookup(@goals_ets, {target, target_goal.id})

    assert {:error, :not_found} =
             MemoryStore.load_tainted_authoritative_with_status(
               "goals",
               "#{target}:#{target_goal.id}"
             )

    # Survivors (including prefix-related agent id) unchanged
    assert {:ok, ^child_goal} = GoalStore.get_goal(child, child_goal.id)
    assert {:ok, ^survivor_goal} = GoalStore.get_goal(survivor, survivor_goal.id)
    assert {:ok, false} = GoalStore.agent_content_absent?(child)
    assert {:ok, false} = GoalStore.agent_content_absent?(survivor)

    # Provenance retained byte-for-byte after delete and retry
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:goal, target)
    assert {:ok, ^taint, :verified} = Provenance.resolve(:goal, target, target_goal.id, payload)

    # Hostile sidecar remains even when content already absent
    hostile_payload = %{"hostile" => true, "id" => "hostile-goal"}
    hostile = taint(:hostile, :restricted, "hostile_sidecar")
    assert :ok = Provenance.put(:goal, target, "hostile-goal", hostile_payload, hostile)
    assert :ok = GoalStore.delete_agent_content(target)

    assert {:ok, ^hostile, :verified} =
             Provenance.resolve(:goal, target, "hostile-goal", hostile_payload)
  end

  test "pending convergence makes absence false until cleared", %{target: target} do
    assert {:ok, true} = GoalStore.agent_content_absent?(target)

    :sys.replace_state(GoalStore, fn state ->
      pending = MapSet.put(Map.get(state, :pending_convergence, MapSet.new()), target)
      Map.put(state, :pending_convergence, pending)
    end)

    assert {:ok, false} = GoalStore.agent_content_absent?(target)

    assert :ok = GoalStore.delete_agent_content(target)
    assert {:ok, true} = GoalStore.agent_content_absent?(target)
  end

  test "stale mark/converge messages after content-only delete do not purge provenance", %{
    target: target
  } do
    taint = taint(:trusted, :internal, "goal_stale_converge")
    goal = Goal.new("stale converge goal", id: "goal_stale_#{System.unique_integer([:positive])}")
    assert {:ok, ^goal} = GoalStore.add_goal_tainted(target, goal, taint)
    payload = goal_payload(goal)

    assert {:ok, ^taint, :verified} = Provenance.resolve(:goal, target, goal.id, payload)
    assert {:ok, ids_before} = Provenance.list_item_ids(:goal, target)

    pid = Process.whereis(GoalStore)
    assert is_pid(pid)

    # Queue mark + converge before cleanup; suspend so they run after content-only delete.
    :sys.suspend(pid)
    send(pid, {:mark_goal_convergence, target})
    send(pid, {:converge_goal_agent, target, 4})

    assert :ok =
             MemoryStore.delete_tainted_authoritative("goals", "#{target}:#{goal.id}")

    true = :ets.delete(@goals_ets, {target, goal.id})

    :sys.replace_state(pid, fn state ->
      state
      |> Map.update!(:projected_ids, &Map.delete(&1, target))
      |> Map.update!(:pending_convergence, &MapSet.delete(&1, target))
      |> Map.update!(:scheduled_convergence, &MapSet.delete(&1, target))
      |> Map.update!(:content_cleaned, &MapSet.put(&1, target))
    end)

    :sys.resume(pid)
    _ = :sys.get_state(pid)

    assert {:ok, true} = GoalStore.agent_content_absent?(target)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:goal, target)
    assert {:ok, ^taint, :verified} = Provenance.resolve(:goal, target, goal.id, payload)

    send(pid, {:mark_goal_convergence, target})
    send(pid, {:converge_goal_agent, target, 4})
    _ = :sys.get_state(pid)

    assert {:ok, ^ids_before} = Provenance.list_item_ids(:goal, target)
    assert {:ok, true} = GoalStore.agent_content_absent?(target)
  end

  test "invalid agent id fails closed", %{} do
    assert {:error, :invalid_provenance} = GoalStore.delete_agent_content("")
    assert {:error, :invalid_provenance} = GoalStore.agent_content_absent?("has:colon")

    assert {:error, :invalid_provenance} =
             GoalStore.delete_agent_content(String.duplicate("a", 300))
  end

  test "compatibility clear_goals still purges provenance", %{target: target} do
    taint = taint(:trusted, :internal, "clear_compat")
    goal = Goal.new("compat clear", id: "goal_clear_#{System.unique_integer([:positive])}")
    assert {:ok, ^goal} = GoalStore.add_goal_tainted(target, goal, taint)
    payload = goal_payload(goal)

    assert {:ok, ^taint, :verified} = Provenance.resolve(:goal, target, goal.id, payload)
    assert :ok = GoalStore.clear_goals(target)
    assert [] = GoalStore.get_all_goals(target)

    # After clear, domain agent inventory should be empty for goals
    assert {:ok, ids} = Provenance.list_item_ids(:goal, target)
    refute goal.id in ids
  end

  defp taint(level, sensitivity, source) do
    {:ok, taint} =
      Taint.new(%{
        level: level,
        sensitivity: sensitivity,
        sanitizations: 0,
        confidence: :verified,
        source: source,
        chain: []
      })

    taint
  end

  defp goal_payload(goal) do
    goal
    |> Map.from_struct()
    |> Map.update!(:created_at, &DateTime.to_iso8601/1)
    |> Map.update!(:achieved_at, &datetime_to_string/1)
    |> Map.update!(:deadline, &datetime_to_string/1)
    |> Map.update!(:referenced_date, &datetime_to_string/1)
  end

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
