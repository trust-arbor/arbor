defmodule Arbor.Memory.GoalStoreOwnerAdmissionTest do
  @moduledoc """
  GoalStore owner-root acknowledgement and live-upgrade tests (VP-05D2C3I1B1A).
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Memory.Goal
  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.GoalStore
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.MutationAdmission.OwnerRoots
  alias Arbor.Memory.Provenance
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B1A"

  @store_name :arbor_memory_durable
  @goals_ets :arbor_memory_goals

  setup do
    ensure_durable_store!()
    ensure_goal_store!()
    ensure_provenance!()
    assert {:ok, %{durability: :node_restart}} = MutationAdmission.readiness()
    :ok
  end

  test "coalesced deferred roots block drain until successful convergence" do
    agent_id = unique_agent("coal")
    taint = taint(:trusted, :internal, "goal_owner_coal")
    first = Goal.new("first miss", id: unique_goal("coal1"))
    second = Goal.new("second miss", id: unique_goal("coal2"))

    drain_task =
      with_provenance_unregistered(fn ->
        assert {:ok, ^first} = GoalStore.add_goal_tainted(agent_id, first, taint)
        assert {:ok, ^second} = GoalStore.add_goal_tainted(agent_id, second, taint)
        assert OwnerRoots.held_count(owner_roots(), agent_id) == 2
        assert {:ok, %{active_roots: 2}} = MutationAdmission.status(agent_id)

        task = Task.async(fn -> MutationAdmission.drain(agent_id, timeout_ms: 5_000) end)

        assert eventually(fn ->
                 match?(
                   {:ok, %{gate: :draining, active_roots: 2}},
                   MutationAdmission.status(agent_id)
                 )
               end)

        task
      end)

    assert eventually(fn ->
             state = :sys.get_state(GoalStore)

             not MapSet.member?(state.pending_convergence, agent_id) and
               not MapSet.member?(state.scheduled_convergence, agent_id) and
               OwnerRoots.held_count(owner_roots(), agent_id) == 0
           end)

    assert {:ok, _fence} = Task.await(drain_task, 5_000)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  test "bounded exhaustion settles coalesced roots and leaves the pending marker" do
    agent_id = unique_agent("exh")
    taint = taint(:trusted, :internal, "goal_owner_exh")
    first = Goal.new("exhaust first", id: unique_goal("exh1"))
    second = Goal.new("exhaust second", id: unique_goal("exh2"))

    with_provenance_unregistered(fn ->
      assert {:ok, ^first} = GoalStore.add_goal_tainted(agent_id, first, taint)
      assert {:ok, ^second} = GoalStore.add_goal_tainted(agent_id, second, taint)

      assert eventually(fn ->
               state = :sys.get_state(GoalStore)

               MapSet.member?(state.pending_convergence, agent_id) and
                 not MapSet.member?(state.scheduled_convergence, agent_id) and
                 OwnerRoots.held_count(owner_roots(), agent_id) == 0
             end)
    end)

    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  test "immediate success and pre-effect failures leave zero active roots" do
    agent_id = unique_agent("imm")
    assert {:ok, _goal} = GoalStore.add_goal(agent_id, "immediate success")
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    assert {:error, :empty_description} = GoalStore.add_goal(agent_id, "")
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    assert {:error, :invalid_provenance} =
             GoalStore.add_goal_tainted(agent_id, Goal.new("bad"), :not_a_taint)

    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0

    assert {:error, :not_found} = GoalStore.update_goal_progress(agent_id, "missing-goal", 0.5)
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    original = Application.get_env(:arbor_memory, :goal_limit_per_agent)
    Application.put_env(:arbor_memory, :goal_limit_per_agent, 1)

    try do
      assert {:error, :goal_limit_reached} = GoalStore.add_goal(agent_id, "over the cap")
      assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
      assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
    after
      Application.put_env(:arbor_memory, :goal_limit_per_agent, original)
    end
  end

  test "content-only cleanup disarms convergence and settles roots" do
    agent_id = unique_agent("clean")
    taint = taint(:trusted, :internal, "goal_owner_clean")
    goal = Goal.new("cleanup target", id: unique_goal("clean"))
    assert {:ok, ^goal} = GoalStore.add_goal_tainted(agent_id, goal, taint)
    payload = goal_payload(goal)
    assert {:ok, ids_before} = Provenance.list_item_ids(:goal, agent_id)

    with_provenance_unregistered(fn ->
      assert {:ok, _noted} = GoalStore.add_note_tainted(agent_id, goal.id, "arm", taint)
    end)

    assert OwnerRoots.held_count(owner_roots(), agent_id) > 0

    assert :ok = GoalStore.delete_agent_content(agent_id)
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0

    state = :sys.get_state(GoalStore)
    refute MapSet.member?(state.pending_convergence, agent_id)
    refute MapSet.member?(state.scheduled_convergence, agent_id)
    refute Map.has_key?(state.active_tokens, agent_id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:goal, agent_id)
    assert {:ok, ^taint, :verified} = Provenance.resolve(:goal, agent_id, goal.id, payload)
  end

  test "restart during drain skips the drained agent and hydrates a sibling" do
    agent_a = unique_agent("rst_a")
    agent_b = unique_agent("rst_b")
    taint = taint(:trusted, :internal, "goal_owner_rst")
    goal_a = Goal.new("drained agent", id: unique_goal("rst_a"))
    goal_b = Goal.new("open sibling", id: unique_goal("rst_b"))

    assert {:ok, ^goal_a} = GoalStore.add_goal_tainted(agent_a, goal_a, taint)
    assert {:ok, ^goal_b} = GoalStore.add_goal_tainted(agent_b, goal_b, taint)
    assert {:ok, _fence} = MutationAdmission.drain(agent_a)

    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, GoalStore)
    assert {:ok, _pid} = Supervisor.restart_child(Arbor.Memory.Supervisor, GoalStore)
    assert is_pid(Process.whereis(GoalStore))

    assert [] = :ets.lookup(@goals_ets, {agent_a, goal_a.id})
    assert [{_key, ^goal_b}] = :ets.lookup(@goals_ets, {agent_b, goal_b.id})

    assert {:ok, _value, _status, _record, _location} =
             MemoryStore.load_tainted_authoritative_with_status(
               "goals",
               "#{agent_a}:#{goal_a.id}"
             )
  end

  test "legacy state with an open gate acquires a fresh deferred root before repair" do
    agent_id = unique_agent("upgrade")
    taint = taint(:trusted, :internal, "goal_owner_upgrade")
    goal = Goal.new("legacy open repair", id: unique_goal("upgrade"))
    assert {:ok, ^goal} = GoalStore.add_goal_tainted(agent_id, goal, taint)
    payload = goal_payload(goal)

    assert true == :ets.delete(@goals_ets, {agent_id, goal.id})
    assert :ok = Provenance.delete(:goal, agent_id, goal.id)

    pid = Process.whereis(GoalStore)
    token = 7

    :sys.replace_state(pid, fn state ->
      pending = Map.get(state, :pending_convergence, MapSet.new())
      tokens = Map.get(state, :active_tokens, %{})

      state
      |> Map.delete(:owner_roots)
      |> Map.put(:pending_convergence, MapSet.put(pending, agent_id))
      |> Map.put(:active_tokens, Map.put(tokens, agent_id, token))
      |> Map.put(:owner_generation, max(Map.get(state, :owner_generation, 0), 1))
    end)

    send(pid, {:converge_goal_agent, agent_id, 4, token})
    _ = :sys.get_state(pid)

    assert eventually(fn ->
             match?([{{^agent_id, _}, ^goal}], :ets.lookup(@goals_ets, {agent_id, goal.id}))
           end)

    assert {:ok, ^taint, :verified} = Provenance.resolve(:goal, agent_id, goal.id, payload)
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  test "roots and drain on one agent do not block another" do
    agent_a = unique_agent("iso_a")
    agent_b = unique_agent("iso_b")
    taint = taint(:trusted, :internal, "goal_owner_iso")
    goal_a = Goal.new("isolated a", id: unique_goal("iso_a"))

    assert {:ok, ^goal_a} = GoalStore.add_goal_tainted(agent_a, goal_a, taint)
    assert {:ok, _fence} = MutationAdmission.drain(agent_a)

    assert {:ok, goal_b} = GoalStore.add_goal_tainted(agent_b, Goal.new("isolated b"), taint)
    assert {:ok, ^goal_b} = GoalStore.get_goal(agent_b, goal_b.id)
    assert {:error, :store_unavailable} = GoalStore.add_goal(agent_a, "blocked")
  end

  defp owner_roots do
    case :sys.get_state(GoalStore) do
      %{owner_roots: %OwnerRoots{} = roots} -> roots
      _ -> OwnerRoots.new()
    end
  end

  defp unique_agent(label), do: "goal_own_#{label}_#{System.unique_integer([:positive])}"
  defp unique_goal(label), do: "goal_own_#{label}_#{System.unique_integer([:positive])}"

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
    case Process.whereis(GoalStore) do
      pid when is_pid(pid) ->
        pid

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, GoalStore) do
          {:ok, pid} when is_pid(pid) -> pid
          {:error, {:already_started, pid}} when is_pid(pid) -> pid
          other -> flunk("failed to restart GoalStore: #{inspect(other)}")
        end
    end
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

  defp with_provenance_unregistered(fun) when is_function(fun, 0) do
    pid = Process.whereis(Provenance)
    assert is_pid(pid)
    assert Process.unregister(Provenance)

    try do
      fun.()
    after
      case Process.whereis(Provenance) do
        ^pid -> :ok
        nil -> Process.register(pid, Provenance)
        other -> flunk("Provenance name owned by #{inspect(other)}")
      end
    end
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
