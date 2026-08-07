defmodule Arbor.Memory.GoalStoreContentCleanupTest do
  @moduledoc """
  Content-only GoalStore cleanup primitives (VP-05D2C3I0C1).
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Memory.Goal
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.{GoalStore, MemoryStore, Provenance}
  alias Arbor.Persistence.BufferedStore

  require Supervisor

  @moduletag :fast
  @moduletag spec: "VP-05D2C3I0C1"
  @store_name :arbor_memory_durable
  @goals_ets :arbor_memory_goals

  @delete_errors [
    :invalid_provenance,
    :persistence_failed,
    :projection_failed,
    :store_unavailable,
    :outcome_unknown
  ]

  @absence_errors [
    :invalid_provenance,
    :projection_failed,
    :store_unavailable
  ]

  setup do
    ensure_durable_store!()
    ensure_goal_store!()
    ensure_provenance!()

    uid = System.unique_integer([:positive])
    target = "agent_a_#{uid}"
    child = "agent_a_#{uid}_child"
    survivor = "agent_b_#{uid}"

    for agent <- [target, child, survivor] do
      _ = GoalStore.clear_goals(agent)
      _ = Provenance.delete_agent(agent)
    end

    on_exit(fn ->
      # Never call start_supervised!/2 from on_exit — ExUnit already stopped
      # supervised children. Restore durable store only from the test process.
      ensure_provenance!()
      ensure_goal_store!()

      # Sidecar cleanup is independent of durable availability.
      for agent <- [target, child, survivor] do
        _ = Provenance.delete_agent(agent)
      end

      if MemoryStore.available?() do
        for agent <- [target, child, survivor] do
          _ = GoalStore.clear_goals(agent)
        end
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
    assert :ok = GoalStore.delete_agent_content(target)
    assert {:ok, true} = GoalStore.agent_content_absent?(target)

    assert [] = :ets.lookup(@goals_ets, {target, target_goal.id})

    assert {:error, :not_found} =
             MemoryStore.load_tainted_authoritative_with_status(
               "goals",
               "#{target}:#{target_goal.id}"
             )

    assert {:ok, ^child_goal} = GoalStore.get_goal(child, child_goal.id)
    assert {:ok, ^survivor_goal} = GoalStore.get_goal(survivor, survivor_goal.id)
    assert {:ok, false} = GoalStore.agent_content_absent?(child)
    assert {:ok, false} = GoalStore.agent_content_absent?(survivor)

    assert {:ok, ^ids_before} = Provenance.list_item_ids(:goal, target)
    assert {:ok, ^taint, :verified} = Provenance.resolve(:goal, target, target_goal.id, payload)

    hostile_payload = %{"hostile" => true, "id" => "hostile-goal"}
    hostile = taint(:hostile, :restricted, "hostile_sidecar")
    assert :ok = Provenance.put(:goal, target, "hostile-goal", hostile_payload, hostile)
    assert :ok = GoalStore.delete_agent_content(target)

    assert {:ok, ^hostile, :verified} =
             Provenance.resolve(:goal, target, "hostile-goal", hostile_payload)
  end

  test "stale pre-cleanup token messages do not purge provenance", %{target: target} do
    taint = taint(:trusted, :internal, "goal_stale_converge")

    goal =
      Goal.new("stale converge goal",
        id: "goal_stale_#{System.unique_integer([:positive])}"
      )

    assert {:ok, ^goal} = GoalStore.add_goal_tainted(target, goal, taint)
    payload = goal_payload(goal)
    assert {:ok, ids_before} = Provenance.list_item_ids(:goal, target)

    # Real post-commit projection miss arms a generation token.
    # Unregister (do not terminate) Provenance so ETS sidecars survive.
    old_token =
      with_provenance_unregistered(fn ->
        note = "arm pending while sidecar down"
        assert {:ok, _noted} = GoalStore.add_note_tainted(target, goal.id, note, taint)

        state = :sys.get_state(GoalStore)
        assert MapSet.member?(state.pending_convergence, target)
        assert Map.has_key?(state.active_tokens, target)
        Map.fetch!(state.active_tokens, target)
      end)

    # Public cleanup (not suspended) disarms; then deliver the captured token.
    assert :ok = GoalStore.delete_agent_content(target)
    refute Map.has_key?(:sys.get_state(GoalStore).active_tokens, target)

    pid = Process.whereis(GoalStore)
    send(pid, {:mark_goal_convergence, target, old_token})
    send(pid, {:converge_goal_agent, target, 4, old_token})
    send(pid, {:mark_goal_convergence, target})
    send(pid, {:converge_goal_agent, target, 4})
    send(pid, {:arm_goal_convergence, target})
    _ = :sys.get_state(pid)

    assert {:ok, true} = GoalStore.agent_content_absent?(target)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:goal, target)
    assert {:ok, ^taint, :verified} = Provenance.resolve(:goal, target, goal.id, payload)
  end

  test "cleanup then new write with projection miss still converges", %{
    target: target
  } do
    taint = taint(:trusted, :internal, "goal_post_cleanup_converge")
    goal1 = Goal.new("first", id: "goal_first_#{System.unique_integer([:positive])}")
    assert {:ok, ^goal1} = GoalStore.add_goal_tainted(target, goal1, taint)
    payload1 = goal_payload(goal1)
    assert {:ok, ids_before} = Provenance.list_item_ids(:goal, target)

    assert :ok = GoalStore.delete_agent_content(target)
    assert {:ok, true} = GoalStore.agent_content_absent?(target)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:goal, target)

    # Force real post-commit projection miss via Provenance unregister (not terminate).
    {goal2, payload2, token} =
      with_provenance_unregistered(fn ->
        goal2 = Goal.new("second", id: "goal_second_#{System.unique_integer([:positive])}")
        assert {:ok, ^goal2} = GoalStore.add_goal_tainted(target, goal2, taint)
        payload2 = goal_payload(goal2)

        state = :sys.get_state(GoalStore)
        assert MapSet.member?(state.pending_convergence, target)
        assert Map.has_key?(state.active_tokens, target)
        token = Map.fetch!(state.active_tokens, target)
        {goal2, payload2, token}
      end)

    # Deliver tokened converge (or wait for scheduled retry).
    send(Process.whereis(GoalStore), {:converge_goal_agent, target, 4, token})
    _ = :sys.get_state(GoalStore)

    assert eventually(fn ->
             match?(
               {:ok, %Goal{id: id}} when id == goal2.id,
               GoalStore.get_goal(target, goal2.id)
             )
           end)

    assert {:ok, ^taint, :verified} = Provenance.resolve(:goal, target, goal1.id, payload1)
    assert {:ok, ^taint, :verified} = Provenance.resolve(:goal, target, goal2.id, payload2)
  end

  test "old token cannot match after cleanup then new write", %{target: target} do
    taint = taint(:trusted, :internal, "goal_token_reuse")
    goal = Goal.new("token reuse", id: "goal_reuse_#{System.unique_integer([:positive])}")
    assert {:ok, ^goal} = GoalStore.add_goal_tainted(target, goal, taint)
    payload = goal_payload(goal)
    assert {:ok, ids_before} = Provenance.list_item_ids(:goal, target)

    old_token =
      with_provenance_unregistered(fn ->
        assert {:ok, _} = GoalStore.add_note_tainted(target, goal.id, "arm", taint)
        Map.fetch!(:sys.get_state(GoalStore).active_tokens, target)
      end)

    assert :ok = GoalStore.delete_agent_content(target)

    {goal2, new_token} =
      with_provenance_unregistered(fn ->
        goal2 = Goal.new("after", id: "goal_after_#{System.unique_integer([:positive])}")
        assert {:ok, ^goal2} = GoalStore.add_goal_tainted(target, goal2, taint)
        new_token = Map.fetch!(:sys.get_state(GoalStore).active_tokens, target)
        assert new_token != old_token
        {goal2, new_token}
      end)

    pid = Process.whereis(GoalStore)
    send(pid, {:converge_goal_agent, target, 4, old_token})
    send(pid, {:arm_goal_convergence, target})
    _ = :sys.get_state(pid)

    assert {:ok, ids_after} = Provenance.list_item_ids(:goal, target)
    assert goal.id in ids_after
    Enum.each(ids_before, fn id -> assert id in ids_after end)
    assert {:ok, ^taint, :verified} = Provenance.resolve(:goal, target, goal.id, payload)

    # New write still converges under its own token.
    send(pid, {:converge_goal_agent, target, 4, new_token})
    _ = :sys.get_state(pid)

    assert eventually(fn ->
             match?(
               {:ok, %Goal{id: id}} when id == goal2.id,
               GoalStore.get_goal(target, goal2.id)
             )
           end)
  end

  test "malformed inventory fails closed, disarms, and stale retry keeps provenance", %{
    target: target,
    survivor: survivor
  } do
    taint = taint(:trusted, :internal, "goal_malformed_inventory")
    good = Goal.new("good goal", id: "goal_good_#{System.unique_integer([:positive])}")
    bad_id = "goal_bad_#{System.unique_integer([:positive])}"
    survivor_goal = Goal.new("surv", id: "goal_surv_#{System.unique_integer([:positive])}")

    assert {:ok, ^good} = GoalStore.add_goal_tainted(target, good, taint)
    assert {:ok, ^survivor_goal} = GoalStore.add_goal_tainted(survivor, survivor_goal, taint)
    payload = goal_payload(good)
    assert {:ok, ids_before} = Provenance.list_item_ids(:goal, target)

    # Arm real deferred work, then plant malformed durable inventory.
    # add_note_tainted commits the updated Goal before projection failure.
    {noted, old_token} =
      with_provenance_unregistered(fn ->
        assert {:ok, noted} = GoalStore.add_note_tainted(target, good.id, "pending", taint)
        old_token = Map.fetch!(:sys.get_state(GoalStore).active_tokens, target)
        {noted, old_token}
      end)

    bad_payload =
      good
      |> goal_payload()
      |> Map.put(:id, "mismatched_id_#{System.unique_integer([:positive])}")

    assert {:ok, %Record{}} =
             MemoryStore.compare_and_swap_tainted(
               "goals",
               "#{target}:#{bad_id}",
               :not_found,
               bad_payload,
               taint: taint
             )

    assert {:error, :invalid_provenance} = GoalStore.delete_agent_content(target)
    assert {:error, inv_reason} = GoalStore.delete_agent_content(target)
    assert inv_reason in @delete_errors

    state = :sys.get_state(GoalStore)
    refute MapSet.member?(state.pending_convergence, target)
    refute Map.has_key?(state.active_tokens, target)

    send(Process.whereis(GoalStore), {:converge_goal_agent, target, 4, old_token})
    _ = :sys.get_state(GoalStore)

    # Sidecars retained byte-for-byte from before the note (put failed while unregistered).
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:goal, target)
    assert {:ok, ^taint, :verified} = Provenance.resolve(:goal, target, good.id, payload)

    # Durable authority holds the post-note Goal, not the pre-mutation value.
    # get_goal may re-project and refresh the live label to the noted payload.
    assert {:ok, ^noted} = GoalStore.get_goal(target, good.id)
    assert {:ok, ^survivor_goal} = GoalStore.get_goal(survivor, survivor_goal.id)
  end

  test "owner process down returns closed mutation/read errors", %{target: target} do
    taint = taint(:trusted, :internal, "goal_owner_down")
    goal = Goal.new("owner down", id: "goal_od_#{System.unique_integer([:positive])}")
    assert {:ok, ^goal} = GoalStore.add_goal_tainted(target, goal, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:goal, target)

    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, GoalStore)
    assert Process.whereis(GoalStore) == nil

    assert {:error, del_reason} = GoalStore.delete_agent_content(target)
    assert del_reason in @delete_errors

    assert {:error, abs_reason} = GoalStore.agent_content_absent?(target)
    assert abs_reason in @absence_errors

    ensure_goal_store!()
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:goal, target)
  end

  test "public cleanup when durable store is stopped returns closed errors", %{target: target} do
    taint = taint(:trusted, :internal, "goal_store_stopped")
    goal = Goal.new("store stopped", id: "goal_ss_#{System.unique_integer([:positive])}")
    assert {:ok, ^goal} = GoalStore.add_goal_tainted(target, goal, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:goal, target)

    # Deterministic ExUnit stop (not Process.exit/:kill which can race permanent restart).
    assert :ok = stop_supervised(BufferedStore)
    refute MemoryStore.available?()

    assert {:error, del_reason} = GoalStore.delete_agent_content(target)
    assert del_reason in @delete_errors

    assert {:error, abs_reason} = GoalStore.agent_content_absent?(target)
    assert abs_reason in @absence_errors

    ensure_durable_store!()
    assert MemoryStore.available?()
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:goal, target)
  end

  test "cleanup public errors are always closed atoms" do
    assert {:error, del_reason} = GoalStore.delete_agent_content("")
    assert del_reason in @delete_errors

    assert {:error, abs_reason} = GoalStore.agent_content_absent?("has:colon")
    assert abs_reason in @absence_errors
  end

  test "compatibility clear_goals still purges provenance", %{target: target} do
    taint = taint(:trusted, :internal, "clear_compat")
    goal = Goal.new("compat clear", id: "goal_clear_#{System.unique_integer([:positive])}")
    assert {:ok, ^goal} = GoalStore.add_goal_tainted(target, goal, taint)
    payload = goal_payload(goal)

    assert {:ok, ^taint, :verified} = Provenance.resolve(:goal, target, goal.id, payload)
    assert :ok = GoalStore.clear_goals(target)
    assert [] = GoalStore.get_all_goals(target)

    assert {:ok, ids} = Provenance.list_item_ids(:goal, target)
    refute goal.id in ids
  end

  # Induce a name-resolution projection failure while retaining exact ETS sidecars.
  # Never terminate Provenance here — that destroys its owned table.
  defp with_provenance_unregistered(fun) when is_function(fun, 0) do
    pid = Process.whereis(Provenance)
    assert is_pid(pid)
    assert Process.unregister(Provenance)

    try do
      fun.()
    after
      restore_provenance_registration!(pid)
    end
  end

  defp restore_provenance_registration!(pid) when is_pid(pid) do
    case Process.whereis(Provenance) do
      ^pid ->
        :ok

      nil ->
        unless Process.alive?(pid) do
          flunk("captured Provenance pid died while unregistered: #{inspect(pid)}")
        end

        Process.register(pid, Provenance)

      other ->
        flunk(
          "Provenance name owned by unexpected process #{inspect(other)}; " <>
            "expected captured pid #{inspect(pid)}"
        )
    end

    assert Process.whereis(Provenance) == pid
  end

  defp ensure_provenance! do
    case Process.whereis(Provenance) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, Provenance) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          other -> flunk("failed to restart Provenance: #{inspect(other)}")
        end
    end
  end

  defp ensure_durable_store! do
    case Process.whereis(@store_name) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        assert is_pid(
                 start_supervised!(
                   {BufferedStore, name: @store_name, backend: nil, write_mode: :sync}
                 )
               )

        :ok
    end

    assert MemoryStore.available?()
  end

  defp ensure_goal_store! do
    owner =
      case Process.whereis(GoalStore) do
        pid when is_pid(pid) ->
          pid

        nil ->
          case Supervisor.restart_child(Arbor.Memory.Supervisor, GoalStore) do
            {:ok, pid} when is_pid(pid) ->
              pid

            {:error, {:already_started, pid}} when is_pid(pid) ->
              pid

            other ->
              flunk("failed to restart GoalStore: #{inspect(other)}")
          end
      end

    assert Process.alive?(owner)
    # Never create @goals_ets from the test process — that steals ownership and
    # can hide a broken GoalStore init. The supervised owner must own the table.
    tid = :ets.whereis(@goals_ets)
    assert tid != :undefined
    assert :ets.info(tid, :owner) == owner
    :ok
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(fun, 0), do: fun.() || flunk("condition not met")

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
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
