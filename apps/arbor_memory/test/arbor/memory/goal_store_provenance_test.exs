defmodule Arbor.Memory.GoalStoreProvenanceTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Memory.Goal
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{Taint, TaintedValue, TaintEnvelope}
  alias Arbor.Memory.{DistributedSync, GoalStore, MemoryStore, Provenance}
  alias Arbor.Persistence.BufferedStore
  alias Arbor.Signals.Taint, as: TaintCodec

  @moduletag :fast
  @store_name :arbor_memory_durable
  @goals_ets :arbor_memory_goals

  setup do
    start_supervised!({BufferedStore, name: @store_name, backend: nil, write_mode: :sync})

    agent_id = "agent_goal_provenance_#{System.unique_integer([:positive])}"
    :ok = GoalStore.clear_goals(agent_id)

    on_exit(fn ->
      if Process.whereis(GoalStore) == nil do
        Supervisor.restart_child(Arbor.Memory.Supervisor, GoalStore)
      end

      GoalStore.clear_goals(agent_id)
    end)

    %{agent_id: agent_id}
  end

  test "taint-aware add binds live and durable state to the serialized goal", %{
    agent_id: agent_id
  } do
    goal = Goal.new("Keep exact provenance", id: goal_id("valid-add"))
    taint = taint(:untrusted, :confidential, "voice")

    assert {:ok, ^goal} = GoalStore.add_goal_tainted(agent_id, goal, taint)
    assert_goal_taint(agent_id, goal, taint, :verified)

    assert {:ok, [{active_value, :verified}]} = GoalStore.get_active_goals_tainted(agent_id)
    assert active_value.value == goal
    assert active_value.taint == taint

    assert {:ok, [{all_value, :verified}]} = GoalStore.get_all_goals_tainted(agent_id)
    assert all_value == active_value

    payload = goal_payload(goal)

    assert eventually(fn ->
             case MemoryStore.load_tainted_with_status("goals", durable_key(agent_id, goal)) do
               {:ok, %TaintedValue{value: ^payload, taint: ^taint}, :verified} -> true
               _ -> false
             end
           end)
  end

  test "invalid supplied label produces no ETS, sidecar, or durable partial state", %{
    agent_id: agent_id
  } do
    goal = Goal.new("must not partially write", id: goal_id("invalid-label"))
    invalid = %Taint{level: :caller_selected_invalid}
    payload = goal_payload(goal)

    result = GoalStore.add_goal_tainted(agent_id, goal, invalid)

    assert {:error, :invalid_provenance} = result
    refute inspect(result) =~ goal.description
    assert {:error, :not_found} = GoalStore.get_goal(agent_id, goal.id)
    assert_missing(Provenance.resolve(:goal, agent_id, goal.id, payload))

    Process.sleep(20)

    assert {:error, :not_found} =
             BufferedStore.get("goals:#{durable_key(agent_id, goal)}", name: @store_name)
  end

  test "caller mutation of a live goal payload is hostile", %{agent_id: agent_id} do
    goal = Goal.new("original payload", id: goal_id("live-mutation"))
    taint = taint(:trusted, :internal, "operator")

    assert {:ok, ^goal} = GoalStore.add_goal_tainted(agent_id, goal, taint)

    mutated = %{goal | description: "mutated outside GoalStore"}
    true = :ets.insert(@goals_ets, {{agent_id, goal.id}, mutated})

    assert {:ok, %TaintedValue{value: ^mutated, taint: hostile}, :invalid_durable_provenance} =
             GoalStore.get_goal_tainted(agent_id, goal.id)

    assert hostile == TaintEnvelope.invalid_fallback()
  end

  test "security regression: exact live mutation is detected and rebound conservatively", %{
    agent_id: agent_id
  } do
    goal = Goal.new("original exact payload", id: goal_id("exact-live-mutation"))
    original_taint = taint(:trusted, :internal, "original_live")

    assert {:ok, ^goal} = GoalStore.add_goal(agent_id, goal)
    assert :ok = Provenance.put(:goal, agent_id, goal.id, goal_payload(goal), original_taint)

    caller_mutated = %{goal | description: "caller changed the live payload"}
    true = :ets.insert(@goals_ets, {{agent_id, goal.id}, caller_mutated})

    assert {:ok, updated} = GoalStore.add_note(agent_id, goal.id, "detected")
    assert updated.description == caller_mutated.description

    assert {:ok, rebound, :verified} =
             Provenance.resolve(:goal, agent_id, goal.id, goal_payload(updated))

    assert rebound == TaintEnvelope.invalid_fallback()
    updated_payload = goal_payload(updated)

    assert eventually(fn ->
             match?(
               {:ok, %TaintedValue{value: ^updated_payload, taint: ^rebound}, :verified},
               MemoryStore.load_tainted_with_status("goals", durable_key(agent_id, goal))
             )
           end)
  end

  test "every goal mutation preserves and rebinds the joined label", %{agent_id: agent_id} do
    taint = taint(:hostile, :restricted, "hostile_input")

    mutations = [
      {"progress",
       fn agent, id ->
         GoalStore.update_goal_progress_tainted(agent, id, 0.4, taint)
       end},
      {"achieve", fn agent, id -> GoalStore.achieve_goal_tainted(agent, id, taint) end},
      {"abandon",
       fn agent, id ->
         GoalStore.abandon_goal_tainted(agent, id, "stopped", taint)
       end},
      {"fail", fn agent, id -> GoalStore.fail_goal_tainted(agent, id, "failed", taint) end},
      {"note", fn agent, id -> GoalStore.add_note_tainted(agent, id, "note", taint) end},
      {"block",
       fn agent, id ->
         GoalStore.block_goal_tainted(agent, id, ["dependency"], taint)
       end},
      {"metadata",
       fn agent, id ->
         GoalStore.update_goal_metadata_tainted(agent, id, %{source: "test"}, taint)
       end}
    ]

    for {name, mutate} <- mutations do
      goal = Goal.new("mutation #{name}", id: goal_id(name))
      assert {:ok, ^goal} = GoalStore.add_goal_tainted(agent_id, goal, taint)
      assert {:ok, updated} = mutate.(agent_id, goal.id)
      assert_goal_taint(agent_id, updated, taint, :verified)

      payload = goal_payload(updated)

      assert eventually(fn ->
               case MemoryStore.load_tainted_with_status(
                      "goals",
                      durable_key(agent_id, updated)
                    ) do
                 {:ok, %TaintedValue{value: ^payload, taint: ^taint}, :verified} -> true
                 _ -> false
               end
             end)
    end
  end

  test "security regression: mutation joins prior provenance monotonically before rebinding", %{
    agent_id: agent_id
  } do
    goal = Goal.new("security regression", id: goal_id("security-regression"))
    prior_taint = taint(:hostile, :public, "prior_hostile", :verified)

    assert {:ok, ^goal} = GoalStore.add_goal(agent_id, goal)
    assert :ok = Provenance.put(:goal, agent_id, goal.id, goal_payload(goal), prior_taint)
    assert {:ok, updated} = GoalStore.update_goal_progress(agent_id, goal.id, 0.5)

    assert {:ok, rebound, :verified} =
             Provenance.resolve(:goal, agent_id, goal.id, goal_payload(updated))

    assert rebound.level == :hostile
    assert rebound.sensitivity == :restricted
    assert rebound.confidence == :unverified

    assert eventually(fn ->
             case MemoryStore.load_tainted_with_status("goals", durable_key(agent_id, goal)) do
               {:ok, %TaintedValue{value: value, taint: durable_taint}, :verified} ->
                 value == goal_payload(updated) and durable_taint.level == :hostile

               _ ->
                 false
             end
           end)
  end

  test "security regression: durable missing and mismatched labels reload conservatively", %{
    agent_id: agent_id
  } do
    missing_goal = Goal.new("missing durable label", id: goal_id("regression-missing"))
    original_mismatch = Goal.new("bound durable payload", id: goal_id("regression-mismatch"))
    mutated_mismatch = %{original_mismatch | description: "mismatched durable payload"}
    durable_taint = taint(:derived, :confidential, "durable_regression")

    put_raw_goal(agent_id, missing_goal, goal_payload(missing_goal), %{})

    {:ok, mismatched_envelope} =
      TaintCodec.bind_durable_provenance(goal_payload(original_mismatch), durable_taint)

    put_raw_goal(
      agent_id,
      original_mismatch,
      goal_payload(mutated_mismatch),
      %{"taint" => mismatched_envelope}
    )

    assert :ok = GoalStore.reload_for_agent(agent_id)
    assert {:ok, ^missing_goal} = GoalStore.get_goal(agent_id, missing_goal.id)
    assert {:ok, ^mutated_mismatch} = GoalStore.get_goal(agent_id, mutated_mismatch.id)

    assert {:ok, rebound_missing, :verified} =
             Provenance.resolve(:goal, agent_id, missing_goal.id, goal_payload(missing_goal))

    assert rebound_missing == TaintEnvelope.missing_fallback()

    assert {:ok, rebound_mismatch, :verified} =
             Provenance.resolve(
               :goal,
               agent_id,
               mutated_mismatch.id,
               goal_payload(mutated_mismatch)
             )

    assert rebound_mismatch == TaintEnvelope.invalid_fallback()
  end

  test "security regression: envelope-valid malformed durable goals are quarantined", %{
    agent_id: agent_id
  } do
    stale = Goal.new("stale valid live goal", id: goal_id("malformed-stale"))
    taint = taint(:untrusted, :confidential, "malformed_durable")
    stale_payload = goal_payload(stale)

    true = :ets.insert(@goals_ets, {{agent_id, stale.id}, stale})
    assert :ok = Provenance.put(:goal, agent_id, stale.id, stale_payload, taint)

    malformed_payloads = [
      Map.put(stale_payload, :type, "unknown_goal_type"),
      malformed_payload(stale_payload, "status", :status, "unknown_goal_status"),
      malformed_payload(stale_payload, "priority-range", :priority, 101),
      malformed_payload(stale_payload, "priority-type", :priority, 50.5),
      malformed_payload(stale_payload, "progress-range", :progress, 1.1),
      malformed_payload(stale_payload, "progress-type", :progress, 0),
      malformed_payload(stale_payload, "parent", :parent_id, 42),
      malformed_payload(stale_payload, "notes-shape", :notes, [42]),
      malformed_payload(
        stale_payload,
        "notes-bound",
        :notes,
        Enum.map(1..129, &"note #{&1}")
      ),
      malformed_payload(stale_payload, "metadata", :metadata, []),
      malformed_payload(stale_payload, "datetime", :deadline, "tomorrow"),
      malformed_payload(stale_payload, "criteria", :success_criteria, 42),
      malformed_payload(stale_payload, "assigned", :assigned_by, "unknown_assignee_value"),
      malformed_payload(stale_payload, "created-at", :created_at, nil)
    ]

    for payload <- malformed_payloads do
      goal_id = payload.id

      assert :ok = MemoryStore.persist("goals", "#{agent_id}:#{goal_id}", payload, taint: taint)

      assert {:ok, %TaintedValue{value: ^payload, taint: ^taint}, :verified} =
               MemoryStore.load_tainted_with_status("goals", "#{agent_id}:#{goal_id}")
    end

    assert :ok = GoalStore.reload_for_agent(agent_id)

    for payload <- malformed_payloads do
      assert {:error, :not_found} = GoalStore.get_goal(agent_id, payload.id)
    end

    assert_missing(Provenance.resolve(:goal, agent_id, stale.id, stale_payload))

    improper =
      stale_payload
      |> Map.put(:id, goal_id("improper-notes"))
      |> Map.put(:notes, ["note" | :invalid_tail])

    assert :ok = GoalStore.import_goals(agent_id, [improper])
    assert {:error, :not_found} = GoalStore.get_goal(agent_id, improper.id)
  end

  test "agent reload reconstructs valid, missing, and mismatched durable labels", %{
    agent_id: agent_id
  } do
    valid_goal = Goal.new("valid durable", id: goal_id("reload-valid"))
    missing_goal = Goal.new("missing durable", id: goal_id("reload-missing"))
    original_invalid = Goal.new("bound durable", id: goal_id("reload-invalid"))
    mutated_invalid = %{original_invalid | description: "mutated durable"}
    valid_taint = taint(:derived, :confidential, "durable")
    valid_payload = stringify_keys(goal_payload(valid_goal))
    legacy_payload = Map.take(goal_payload(missing_goal), [:id, :description, :created_at])

    assert :ok =
             MemoryStore.persist(
               "goals",
               durable_key(agent_id, valid_goal),
               valid_payload,
               taint: valid_taint
             )

    put_raw_goal(agent_id, missing_goal, legacy_payload, %{})

    {:ok, invalid_envelope} =
      TaintCodec.bind_durable_provenance(goal_payload(original_invalid), valid_taint)

    put_raw_goal(
      agent_id,
      original_invalid,
      goal_payload(mutated_invalid),
      %{"taint" => invalid_envelope}
    )

    assert :ok = GoalStore.reload_for_agent(agent_id)

    assert_goal_taint(agent_id, valid_goal, valid_taint, :verified)

    assert {:ok, %TaintedValue{value: ^missing_goal, taint: missing}, :legacy_unlabeled} =
             GoalStore.get_goal_tainted(agent_id, missing_goal.id)

    assert missing == TaintEnvelope.missing_fallback()

    assert {:ok, %TaintedValue{value: ^mutated_invalid, taint: hostile},
            :invalid_durable_provenance} =
             GoalStore.get_goal_tainted(agent_id, original_invalid.id)

    assert hostile == TaintEnvelope.invalid_fallback()
  end

  test "startup reload uses verified tainted reads", %{agent_id: agent_id} do
    goal = Goal.new("startup durable", id: goal_id("startup"))
    taint = taint(:untrusted, :restricted, "restart")

    assert :ok =
             MemoryStore.persist("goals", durable_key(agent_id, goal), goal_payload(goal),
               taint: taint
             )

    assert :ok = Provenance.delete(:goal, agent_id, goal.id)
    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, GoalStore)
    assert {:ok, _pid} = Supervisor.restart_child(Arbor.Memory.Supervisor, GoalStore)

    assert_goal_taint(agent_id, goal, taint, :verified)
  end

  test "security regression: distributed goal signal performs a verified targeted reload", %{
    agent_id: agent_id
  } do
    start_supervised!({DistributedSync, name: DistributedSync})

    goal_id = goal_id("distributed")
    stale = Goal.new("stale live", id: goal_id)
    updated = %{stale | description: "durable update", progress: 0.8}
    stale_taint = taint(:trusted, :internal, "stale")
    updated_taint = taint(:untrusted, :confidential, "remote")

    true = :ets.insert(@goals_ets, {{agent_id, goal_id}, stale})
    assert :ok = Provenance.put(:goal, agent_id, goal_id, goal_payload(stale), stale_taint)

    assert :ok =
             MemoryStore.persist("goals", durable_key(agent_id, updated), goal_payload(updated),
               taint: updated_taint
             )

    send(DistributedSync, {
      :signal_received,
      %{
        type: :goal_progress,
        data: %{agent_id: agent_id, goal_id: goal_id, origin_node: :remote@node}
      }
    })

    assert eventually(fn ->
             with {:ok, ^updated} <- GoalStore.get_goal(agent_id, goal_id),
                  {:ok, ^updated_taint, :verified} <-
                    Provenance.resolve(:goal, agent_id, goal_id, goal_payload(updated)) do
               true
             else
               _ -> false
             end
           end)
  end

  test "delete and clear remove only goal provenance", %{agent_id: agent_id} do
    first = Goal.new("delete one", id: goal_id("delete"))
    second = Goal.new("clear one", id: goal_id("clear"))
    taint = taint(:untrusted, :restricted, "cleanup")
    other_payload = %{"content" => "other domain"}

    assert {:ok, ^first} = GoalStore.add_goal_tainted(agent_id, first, taint)

    assert eventually(fn ->
             match?(
               {:ok, %TaintedValue{}, :verified},
               MemoryStore.load_tainted_with_status("goals", durable_key(agent_id, first))
             )
           end)

    assert :ok = GoalStore.delete_goal(agent_id, first.id)
    assert {:error, :not_found} = GoalStore.get_goal(agent_id, first.id)
    assert_missing(Provenance.resolve(:goal, agent_id, first.id, goal_payload(first)))

    assert {:error, :not_found} =
             MemoryStore.load_tainted_with_status("goals", durable_key(agent_id, first))

    assert {:ok, ^second} = GoalStore.add_goal_tainted(agent_id, second, taint)
    assert :ok = Provenance.put(:intent, agent_id, "intent-1", other_payload, taint)
    assert :ok = GoalStore.clear_goals(agent_id)

    assert {:error, :not_found} = GoalStore.get_goal(agent_id, second.id)
    assert_missing(Provenance.resolve(:goal, agent_id, second.id, goal_payload(second)))

    assert {:ok, ^taint, :verified} =
             Provenance.resolve(:intent, agent_id, "intent-1", other_payload)

    assert :ok = Provenance.delete(:intent, agent_id, "intent-1")
  end

  test "raw import establishes exact conservative provenance", %{agent_id: agent_id} do
    goal = Goal.new("imported goal", id: goal_id("import"))

    assert :ok = GoalStore.import_goals(agent_id, [goal_payload(goal)])

    assert {:ok, %TaintedValue{value: ^goal, taint: taint}, :legacy_unlabeled} =
             GoalStore.get_goal_tainted(agent_id, goal.id)

    assert taint == TaintEnvelope.missing_fallback()
  end

  defp put_raw_goal(agent_id, goal, payload, metadata) do
    key = "goals:#{durable_key(agent_id, goal)}"
    record = Record.new(key, payload, id: "memory:#{key}", metadata: metadata)
    assert :ok = BufferedStore.put(key, record, name: @store_name)
  end

  defp assert_goal_taint(agent_id, goal, taint, status) do
    assert {:ok, %TaintedValue{value: ^goal, taint: ^taint}, ^status} =
             GoalStore.get_goal_tainted(agent_id, goal.id)
  end

  defp assert_missing(result) do
    assert {:ok, taint, :legacy_unlabeled} = result
    assert taint == TaintEnvelope.missing_fallback()
  end

  defp taint(level, sensitivity, source, confidence \\ :unverified) do
    {:ok, taint} =
      Taint.new(%{
        level: level,
        sensitivity: sensitivity,
        sanitizations: 0,
        confidence: confidence,
        source: source,
        chain: []
      })

    taint
  end

  defp durable_key(agent_id, goal), do: "#{agent_id}:#{goal.id}"

  defp goal_id(suffix) do
    "goal_c3b_#{suffix}_#{System.unique_integer([:positive])}"
  end

  defp malformed_payload(base, suffix, field, value) do
    base
    |> Map.put(:id, goal_id("malformed-#{suffix}"))
    |> Map.put(field, value)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp goal_payload(goal) do
    goal
    |> Map.from_struct()
    |> Map.update!(:created_at, &datetime_to_string/1)
    |> Map.update!(:achieved_at, &datetime_to_string/1)
    |> Map.update!(:deadline, &datetime_to_string/1)
    |> Map.update!(:referenced_date, &datetime_to_string/1)
  end

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
