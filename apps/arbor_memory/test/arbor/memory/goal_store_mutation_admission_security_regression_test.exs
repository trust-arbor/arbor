defmodule Arbor.Memory.GoalStoreMutationAdmissionSecurityRegressionTest do
  @moduledoc """
  Public-API security regression for GoalStore mutation admission.

  Uses only APIs present on the immediate parent so parent failure is
  behavioral (missing admission gate), not a compile or setup failure.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Memory.Goal
  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.GoalStore
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.Provenance
  alias Arbor.Memory.Test.MutationAdmissionFakeBackend, as: Fake
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B1A"
  @moduletag security_regression: true

  @store_name :arbor_memory_durable
  @goals_ets :arbor_memory_goals
  @admission_registry Arbor.Memory.MutationAdmission.Registry
  @guardian_supervisor Arbor.Memory.MutationAdmission.GuardianSupervisor
  @fake_name :goal_sec_ma_fake

  setup do
    ensure_durable_store!()
    ensure_goal_store!()
    ensure_provenance!()
    ensure_default_admission!()
    :ok
  end

  test "post-drain goal mutation is rejected with no durable, ETS, or Provenance row" do
    agent_id = unique_agent("mut")
    goal = Goal.new("post-drain mutation", id: unique_goal("mut"))

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    assert {:error, :store_unavailable} = GoalStore.add_goal(agent_id, goal)

    assert {:error, :not_found} =
             MemoryStore.load_tainted_authoritative_with_status(
               "goals",
               "#{agent_id}:#{goal.id}"
             )

    assert [] = :ets.lookup(@goals_ets, {agent_id, goal.id})
    assert {:ok, ids} = Provenance.list_item_ids(:goal, agent_id)
    refute goal.id in ids
  end

  test "post-drain authoritative read cannot rehydrate stripped projections" do
    agent_id = unique_agent("read")
    taint = taint(:trusted, :internal, "goal_sec_read")
    goal = Goal.new("seed before drain", id: unique_goal("read"))

    assert {:ok, ^goal} = GoalStore.add_goal_tainted(agent_id, goal, taint)
    payload = goal_payload(goal)

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    assert true == :ets.delete(@goals_ets, {agent_id, goal.id})
    assert :ok = Provenance.delete(:goal, agent_id, goal.id)

    assert {:error, :store_unavailable} = GoalStore.get_goal_tainted(agent_id, goal.id)
    assert [] = :ets.lookup(@goals_ets, {agent_id, goal.id})
    assert {:error, :not_found} = Provenance.resolve(:goal, agent_id, goal.id, payload)

    assert {:ok, _value, _status, _record, _location} =
             MemoryStore.load_tainted_authoritative_with_status(
               "goals",
               "#{agent_id}:#{goal.id}"
             )
  end

  test "a retained deferred root does not admit a later public request after drain starts" do
    agent_id = unique_agent("reuse")
    taint = taint(:trusted, :internal, "goal_sec_reuse")
    goal = Goal.new("arm deferred", id: unique_goal("reuse"))
    assert {:ok, ^goal} = GoalStore.add_goal_tainted(agent_id, goal, taint)

    with_provenance_unregistered(fn ->
      assert {:ok, _noted} = GoalStore.add_note_tainted(agent_id, goal.id, "arm", taint)
    end)

    drain_task = Task.async(fn -> MutationAdmission.drain(agent_id, timeout_ms: 5_000) end)

    assert eventually(fn ->
             match?({:ok, %{gate: :draining}}, MutationAdmission.status(agent_id))
           end)

    later = Goal.new("unrelated later write", id: unique_goal("later"))
    assert {:error, :store_unavailable} = GoalStore.add_goal(agent_id, later)

    assert {:error, :not_found} =
             MemoryStore.load_tainted_authoritative_with_status(
               "goals",
               "#{agent_id}:#{later.id}"
             )

    assert [] = :ets.lookup(@goals_ets, {agent_id, later.id})
    assert {:ok, ids} = Provenance.list_item_ids(:goal, agent_id)
    refute later.id in ids

    assert :ok = GoalStore.delete_agent_content(agent_id)
    assert {:ok, _fence} = Task.await(drain_task, 5_000)
  end

  test "legacy queued convergence without a retained root cannot project after drain" do
    agent_id = unique_agent("legacy")
    taint = taint(:trusted, :internal, "goal_sec_legacy")
    goal = Goal.new("legacy converge", id: unique_goal("legacy"))
    assert {:ok, ^goal} = GoalStore.add_goal_tainted(agent_id, goal, taint)
    payload = goal_payload(goal)

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    assert true == :ets.delete(@goals_ets, {agent_id, goal.id})
    assert :ok = Provenance.delete(:goal, agent_id, goal.id)

    pid = Process.whereis(GoalStore)
    token = 1

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

    assert [] = :ets.lookup(@goals_ets, {agent_id, goal.id})
    assert {:error, :not_found} = Provenance.resolve(:goal, agent_id, goal.id, payload)

    assert {:ok, _value, _status, _record, _location} =
             MemoryStore.load_tainted_authoritative_with_status(
               "goals",
               "#{agent_id}:#{goal.id}"
             )
  end

  defp unique_agent(label), do: "goal_sec_#{label}_#{System.unique_integer([:positive])}"
  defp unique_goal(label), do: "goal_sec_#{label}_#{System.unique_integer([:positive])}"

  defp ensure_default_admission! do
    case MutationAdmission.readiness() do
      {:ok, %{durability: :node_restart}} ->
        :ok

      _ ->
        start_parent_admission_stack!()
    end
  end

  defp start_parent_admission_stack! do
    unless Process.whereis(@fake_name) do
      {:ok, _} = Fake.start_link(agent_name: @fake_name)
    end

    unless Process.whereis(@admission_registry) do
      start_supervised!({Registry, keys: :unique, name: @admission_registry})
    end

    unless Process.whereis(@guardian_supervisor) do
      start_supervised!({@guardian_supervisor, []})
    end

    unless Process.whereis(MutationAdmission) do
      start_supervised!(
        {MutationAdmission,
         [
           target: %{
             namespace: :memory_mutation_admission,
             backend: Fake,
             opts: [agent_name: @fake_name]
           }
         ]}
      )
    end

    assert {:ok, %{durability: :node_restart}} = MutationAdmission.readiness()
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
