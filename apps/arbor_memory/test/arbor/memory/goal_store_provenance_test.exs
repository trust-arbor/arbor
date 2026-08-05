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
  @backend_state :goal_store_provenance_authoritative_backend

  defmodule AuthoritativeBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Contracts.Persistence.Record

    def put(key, value, opts) do
      update_state(opts, fn state ->
        stored = advance_put(Map.get(state.records, key), value)
        {:ok, put_in(state, [:records, key], stored)}
      end)
    end

    def get(key, opts) do
      update_state(opts, fn state ->
        if state.available? do
          {state, value} = apply_read_action(state, key)
          reply = if is_nil(value), do: {:error, :not_found}, else: {:ok, value}
          {reply, state}
        else
          {{:error, :forced_unavailable}, state}
        end
      end)
    end

    def delete(key, opts) do
      update_state(opts, fn state ->
        if state.available? do
          {:ok, %{state | records: Map.delete(state.records, key)}}
        else
          {{:error, :forced_unavailable}, state}
        end
      end)
    end

    def list(opts) do
      update_state(opts, fn state ->
        if state.available? do
          {{:ok, Map.keys(state.records)}, state}
        else
          {{:error, :forced_unavailable}, state}
        end
      end)
    end

    def query(_filter, opts) do
      update_state(opts, fn state ->
        if state.available? do
          records = state.records |> Map.values() |> Enum.sort_by(& &1.key)
          {{:ok, records}, state}
        else
          {{:error, :forced_unavailable}, state}
        end
      end)
    end

    def compare_and_swap(key, expected, replacement, opts) do
      update_state(opts, fn state ->
        if state.available? do
          case apply_cas(Map.get(state.records, key), expected, replacement) do
            {:ok, stored} ->
              {{:ok, stored}, put_in(state, [:records, key], stored)}

            {:error, _reason} = error ->
              {error, state}
          end
        else
          {{:error, :forced_unavailable}, state}
        end
      end)
    end

    def compare_and_delete(key, expected, opts) do
      update_state(opts, fn state ->
        current = Map.get(state.records, key)

        cond do
          not state.available? ->
            {{:error, :forced_unavailable}, state}

          is_integer(state.compare_delete_fail_after) and
              state.compare_delete_successes >= state.compare_delete_fail_after ->
            {{:error, :forced_compare_delete_failure}, state}

          record_matches?(current, expected) ->
            next = %{
              state
              | records: Map.delete(state.records, key),
                compare_delete_successes: state.compare_delete_successes + 1
            }

            {:ok, next}

          true ->
            {{:error, :conflict}, state}
        end
      end)
    end

    def durability_class(_opts), do: :node_restart

    def arm_read_update(name, key, reads_to_skip, fun)
        when is_integer(reads_to_skip) and reads_to_skip >= 0 and is_function(fun, 1) do
      Agent.update(name, fn state ->
        put_in(state, [:read_actions, key], {reads_to_skip, fun})
      end)
    end

    def update_now(name, key, fun) when is_function(fun, 1) do
      Agent.update(name, fn state ->
        %{state | records: Map.update!(state.records, key, fun)}
      end)
    end

    def set_available(name, available?) when is_boolean(available?) do
      Agent.update(name, &%{&1 | available?: available?})
    end

    def fail_compare_delete_after(name, successful_deletes)
        when is_integer(successful_deletes) and successful_deletes >= 0 do
      Agent.update(name, fn state ->
        %{state | compare_delete_fail_after: successful_deletes, compare_delete_successes: 0}
      end)
    end

    def allow_compare_deletes(name) do
      Agent.update(name, fn state ->
        %{state | compare_delete_fail_after: nil, compare_delete_successes: 0}
      end)
    end

    defp update_state(opts, fun) do
      opts
      |> Keyword.fetch!(:name)
      |> Agent.get_and_update(fun)
    end

    defp apply_read_action(state, key) do
      case Map.get(state.read_actions, key) do
        {0, fun} ->
          updated = Map.update!(state.records, key, fun)

          {%{state | records: updated, read_actions: Map.delete(state.read_actions, key)},
           updated[key]}

        {remaining, fun} when remaining > 0 ->
          {%{state | read_actions: Map.put(state.read_actions, key, {remaining - 1, fun})},
           Map.get(state.records, key)}

        nil ->
          {state, Map.get(state.records, key)}
      end
    end

    defp apply_cas(nil, :not_found, %Record{} = replacement) do
      {:ok, %{replacement | generation: 1, revision: 1}}
    end

    defp apply_cas(%Record{} = current, {:value, %Record{} = expected}, %Record{} = replacement) do
      if record_matches?(current, expected) do
        {:ok,
         %{
           replacement
           | id: current.id,
             generation: current.generation,
             revision: current.revision + 1,
             inserted_at: current.inserted_at
         }}
      else
        {:error, :conflict}
      end
    end

    defp apply_cas(_current, _expected, _replacement), do: {:error, :conflict}

    defp advance_put(nil, %Record{} = replacement),
      do: %{replacement | generation: 1, revision: 1}

    defp advance_put(%Record{} = current, %Record{} = replacement) do
      %{
        replacement
        | id: current.id,
          generation: current.generation,
          revision: current.revision + 1,
          inserted_at: current.inserted_at
      }
    end

    defp advance_put(_current, value), do: value

    defp record_matches?(%Record{} = current, %Record{} = expected) do
      current.key == expected.key and current.generation == expected.generation and
        current.revision == expected.revision
    end

    defp record_matches?(current, expected), do: current == expected
  end

  setup do
    start_supervised!({BufferedStore, name: @store_name, backend: nil, write_mode: :sync})

    agent_id = "agent_goal_provenance_#{System.unique_integer([:positive])}"
    :ok = GoalStore.clear_goals(agent_id)

    on_exit(fn ->
      if Process.whereis(Provenance) == nil do
        Supervisor.restart_child(Arbor.Memory.Supervisor, Provenance)
      end

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

  test "security regression: ambiguous goal identifiers are rejected without effects" do
    suffix = System.unique_integer([:positive])
    left_agent = "agent_collision_#{suffix}:branch"
    right_agent = "agent_collision_#{suffix}"
    left_goal = Goal.new("left collision", id: "goal")
    right_goal = Goal.new("right collision", id: "branch:goal")
    taint = taint(:hostile, :restricted, "ambiguous_identifier")
    physical_key = "#{left_agent}:#{left_goal.id}"

    assert physical_key == "#{right_agent}:#{right_goal.id}"

    assert {:error, :invalid_provenance} =
             GoalStore.add_goal_tainted(left_agent, left_goal, taint)

    assert {:error, :invalid_provenance} =
             GoalStore.add_goal_tainted(right_agent, right_goal, taint)

    assert {:error, :invalid_provenance} =
             GoalStore.import_goals(right_agent, [goal_payload(right_goal)])

    assert [] = :ets.lookup(@goals_ets, {left_agent, left_goal.id})
    assert [] = :ets.lookup(@goals_ets, {right_agent, right_goal.id})

    assert_missing(Provenance.resolve(:goal, left_agent, left_goal.id, goal_payload(left_goal)))

    assert_missing(
      Provenance.resolve(:goal, right_agent, right_goal.id, goal_payload(right_goal))
    )

    assert {:error, :not_found} =
             BufferedStore.get("goals:#{physical_key}", name: @store_name)

    assert {:error, :not_found} = BufferedStore.get(physical_key, name: @store_name)
  end

  test "tainted read discards caller mutation of a live goal payload", %{agent_id: agent_id} do
    goal = Goal.new("original payload", id: goal_id("live-mutation"))
    taint = taint(:trusted, :internal, "operator")

    assert {:ok, ^goal} = GoalStore.add_goal_tainted(agent_id, goal, taint)

    mutated = %{goal | description: "mutated outside GoalStore"}
    true = :ets.insert(@goals_ets, {{agent_id, goal.id}, mutated})

    assert {:ok, %TaintedValue{value: ^goal, taint: ^taint}, :verified} =
             GoalStore.get_goal_tainted(agent_id, goal.id)

    assert {:ok, ^goal} = GoalStore.get_goal(agent_id, goal.id)
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
    assert updated.description == goal.description
    refute updated.description == caller_mutated.description

    assert {:ok, rebound, :verified} =
             Provenance.resolve(:goal, agent_id, goal.id, goal_payload(updated))

    assert rebound == TaintEnvelope.missing_fallback()
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

    assert {:ok, ^goal} = GoalStore.add_goal_tainted(agent_id, goal, prior_taint)
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

  test "security regression: Provenance-down commit leaves no unlabeled live projection", %{
    agent_id: agent_id
  } do
    original = Goal.new("live before projection failure", id: goal_id("projection-failure"))
    goal = %{original | description: "committed before projection"}
    taint = taint(:hostile, :restricted, "projection_failure")
    payload = goal_payload(goal)

    assert {:ok, ^original} = GoalStore.add_goal_tainted(agent_id, original, taint)
    stop_provenance()

    assert {:error, :projection_failed} = GoalStore.add_goal_tainted(agent_id, goal, taint)
    assert {:error, :not_found} = GoalStore.get_goal(agent_id, goal.id)

    assert {:ok, %TaintedValue{value: ^payload, taint: ^taint}, :verified} =
             MemoryStore.load_tainted_with_status("goals", durable_key(agent_id, goal))

    restart_provenance()

    assert :ok = GoalStore.reload_goal_from_durable(agent_id, goal.id)
    assert_goal_taint(agent_id, goal, taint, :verified)
  end

  test "raw add and import return bounded projection errors without losing fallback labels", %{
    agent_id: agent_id
  } do
    added = Goal.new("raw add while sidecar is down", id: goal_id("raw-projection"))
    imported = Goal.new("raw import while sidecar is down", id: goal_id("import-projection"))
    fallback = TaintEnvelope.missing_fallback()

    stop_provenance()

    assert {:error, :projection_failed} = GoalStore.add_goal(agent_id, added)

    assert {:error, :projection_failed} =
             GoalStore.import_goals(agent_id, [goal_payload(imported)])

    assert {:error, :not_found} = GoalStore.get_goal(agent_id, added.id)
    assert {:error, :not_found} = GoalStore.get_goal(agent_id, imported.id)

    for goal <- [added, imported] do
      payload = goal_payload(goal)

      assert {:ok, %TaintedValue{value: ^payload, taint: ^fallback}, :verified} =
               MemoryStore.load_tainted_with_status("goals", durable_key(agent_id, goal))
    end

    restart_provenance()
    assert :ok = GoalStore.reload_for_agent(agent_id)

    for goal <- [added, imported] do
      assert {:ok, %TaintedValue{value: ^goal, taint: ^fallback}, :legacy_unlabeled} =
               GoalStore.get_goal_tainted(agent_id, goal.id)
    end
  end

  test "security regression: Provenance restart recovers exact hostile durable label", %{
    agent_id: agent_id
  } do
    goal = Goal.new("recover exact label", id: goal_id("sidecar-recovery"))
    taint = taint(:hostile, :confidential, "durable_hostile")

    assert {:ok, ^goal} = GoalStore.add_goal_tainted(agent_id, goal, taint)
    stop_provenance()
    restart_provenance()

    assert_goal_taint(agent_id, goal, taint, :verified)

    assert {:ok, ^taint, :verified} =
             Provenance.resolve(:goal, agent_id, goal.id, goal_payload(goal))
  end

  test "security regression: raw import overwrite joins existing provenance", %{
    agent_id: agent_id
  } do
    goal = Goal.new("before import", id: goal_id("import-overwrite"))
    prior = taint(:hostile, :confidential, "prior_import", :verified)
    imported = %{goal | description: "after import", metadata: %{imported: true}}

    assert {:ok, ^goal} = GoalStore.add_goal_tainted(agent_id, goal, prior)
    assert :ok = GoalStore.import_goals(agent_id, [goal_payload(imported)])

    assert {:ok, %TaintedValue{value: ^imported, taint: joined}, :verified} =
             GoalStore.get_goal_tainted(agent_id, goal.id)

    assert joined.level == :hostile
    assert joined.sensitivity == :restricted
    assert joined.confidence == :unverified

    imported_payload = goal_payload(imported)

    assert {:ok, %TaintedValue{value: ^imported_payload, taint: ^joined}, :verified} =
             MemoryStore.load_tainted_with_status("goals", durable_key(agent_id, goal))
  end

  test "concurrent weaker and stronger mutations serialize and join monotonically", %{
    agent_id: agent_id
  } do
    goal = Goal.new("serialized mutation", id: goal_id("concurrent-mutation"))
    base = taint(:trusted, :public, "base", :verified)
    weaker = taint(:derived, :internal, "weaker", :verified)
    stronger = taint(:hostile, :restricted, "stronger")

    assert {:ok, ^goal} = GoalStore.add_goal_tainted(agent_id, goal, base)

    tasks = [
      concurrent_mutation(agent_id, goal.id, %{weaker: true}, weaker),
      concurrent_mutation(agent_id, goal.id, %{stronger: true}, stronger)
    ]

    Enum.each(tasks, fn {task, _ready_ref} -> send(task.pid, :commit) end)
    assert Enum.all?(tasks, fn {task, _ref} -> match?({:ok, %Goal{}}, Task.await(task)) end)

    assert {:ok, %TaintedValue{value: final, taint: joined}, :verified} =
             GoalStore.get_goal_tainted(agent_id, goal.id)

    assert final.metadata.weaker
    assert final.metadata.stronger
    assert joined.level == :hostile
    assert joined.sensitivity == :restricted
    assert joined.confidence == :unverified
  end

  test "security regression: deleting one hostile ETS item cannot hide it from tainted read", %{
    agent_id: agent_id
  } do
    goal = Goal.new("cannot hide one", id: goal_id("inventory-item"))
    taint = taint(:hostile, :restricted, "inventory_item")

    assert {:ok, ^goal} = GoalStore.add_goal_tainted(agent_id, goal, taint)
    true = :ets.delete(@goals_ets, {agent_id, goal.id})
    assert {:error, :not_found} = GoalStore.get_goal(agent_id, goal.id)
    assert_goal_taint(agent_id, goal, taint, :verified)
  end

  test "security regression: deleting the agent ETS slice cannot lower tainted inventory", %{
    agent_id: agent_id
  } do
    taint = taint(:hostile, :restricted, "inventory_agent")
    first = Goal.new("cannot hide first", id: goal_id("inventory-all-first"))
    second = Goal.new("cannot hide second", id: goal_id("inventory-all-second"))

    assert {:ok, ^first} = GoalStore.add_goal_tainted(agent_id, first, taint)
    assert {:ok, ^second} = GoalStore.add_goal_tainted(agent_id, second, taint)

    match_spec = [{{{agent_id, :_}, :_}, [], [true]}]
    assert 2 = :ets.select_delete(@goals_ets, match_spec)
    assert [] = GoalStore.get_all_goals(agent_id)

    assert {:ok, tainted_goals} = GoalStore.get_all_goals_tainted(agent_id)

    assert Enum.sort(Enum.map(tainted_goals, fn {value, _status} -> value.value.id end)) ==
             Enum.sort([first.id, second.id])

    assert Enum.all?(tainted_goals, fn {value, status} ->
             value.taint == taint and status == :verified
           end)
  end

  test "security regression: tainted reconciliation ignores attacker-sized projection cardinality",
       %{agent_id: agent_id} do
    goal = Goal.new("bounded authoritative goal", id: goal_id("bounded-projection"))
    taint = taint(:hostile, :restricted, "bounded_projection")

    assert {:ok, ^goal} = GoalStore.add_goal_tainted(agent_id, goal, taint)

    attacker_rows =
      Enum.map(1..2_000, fn index ->
        {{agent_id, "caller_projection_#{index}"}, %{malformed: index}}
      end)

    attacker_keys = Enum.map(attacker_rows, &elem(&1, 0))
    on_exit(fn -> Enum.each(attacker_keys, &:ets.delete(@goals_ets, &1)) end)
    true = :ets.insert(@goals_ets, attacker_rows)

    assert {:ok, [{%TaintedValue{value: ^goal, taint: ^taint}, :verified}]} =
             GoalStore.get_all_goals_tainted(agent_id)

    assert :ok = GoalStore.reload_for_agent(agent_id)
    assert Process.alive?(Process.whereis(GoalStore))

    assert [hd(attacker_rows)] == :ets.lookup(@goals_ets, hd(attacker_keys))
    assert [List.last(attacker_rows)] == :ets.lookup(@goals_ets, List.last(attacker_keys))

    Enum.each(attacker_keys, &:ets.delete(@goals_ets, &1))
  end

  test "security regression: clear is total without scanning malformed projection rows", %{
    agent_id: agent_id
  } do
    goal = Goal.new("clear bounded goal", id: goal_id("bounded-clear"))
    taint = taint(:untrusted, :restricted, "bounded_clear")
    marker = System.unique_integer([:positive])

    assert {:ok, ^goal} = GoalStore.add_goal_tainted(agent_id, goal, taint)

    attacker_rows = [
      {{agent_id, "caller_malformed_#{marker}"}, :not_a_goal},
      {{agent_id, {:wrong_shape, marker}}, %{not: "a goal"}},
      {{:wrong_key_shape, agent_id, marker}, Goal.new("unrelated malformed row")}
    ]

    attacker_keys = Enum.map(attacker_rows, &elem(&1, 0))
    on_exit(fn -> Enum.each(attacker_keys, &:ets.delete(@goals_ets, &1)) end)
    true = :ets.insert(@goals_ets, attacker_rows)

    assert {:error, :not_found} =
             GoalStore.get_goal(agent_id, "caller_malformed_#{marker}")

    assert {:ok, [{%TaintedValue{value: ^goal}, :verified}]} =
             GoalStore.get_all_goals_tainted(agent_id)

    assert :ok = GoalStore.clear_goals(agent_id)
    assert {:ok, []} = GoalStore.get_all_goals_tainted(agent_id)
    assert [] = GoalStore.get_all_goals(agent_id)

    assert Enum.all?(attacker_rows, fn {key, value} ->
             :ets.lookup(@goals_ets, key) == [{key, value}]
           end)

    assert_missing(Provenance.resolve(:goal, agent_id, goal.id, goal_payload(goal)))

    Enum.each(attacker_keys, &:ets.delete(@goals_ets, &1))
  end

  test "delete and clear remove namespaced and legacy rows after GoalStore restart", %{
    agent_id: agent_id
  } do
    taint = taint(:untrusted, :restricted, "restart_cleanup")
    deleted = Goal.new("delete after restart", id: goal_id("restart-delete"))
    cleared = Goal.new("clear after restart", id: goal_id("restart-clear"))
    intent_payload = %{"intent" => "preserve"}

    assert {:ok, ^deleted} = GoalStore.add_goal_tainted(agent_id, deleted, taint)
    assert {:ok, ^cleared} = GoalStore.add_goal_tainted(agent_id, cleared, taint)
    put_legacy_goal(agent_id, deleted, goal_payload(deleted), taint)
    put_legacy_goal(agent_id, cleared, goal_payload(cleared), taint)
    assert :ok = Provenance.put(:intent, agent_id, "intent-restart", intent_payload, taint)

    restart_goal_store()

    assert :ok = GoalStore.delete_goal(agent_id, deleted.id)
    assert_goal_rows_deleted(agent_id, deleted)

    assert :ok = GoalStore.clear_goals(agent_id)
    assert_goal_rows_deleted(agent_id, cleared)

    assert_missing(Provenance.resolve(:goal, agent_id, deleted.id, goal_payload(deleted)))
    assert_missing(Provenance.resolve(:goal, agent_id, cleared.id, goal_payload(cleared)))

    assert {:ok, ^taint, :verified} =
             Provenance.resolve(:intent, agent_id, "intent-restart", intent_payload)

    assert :ok = Provenance.delete(:intent, agent_id, "intent-restart")
  end

  test "security regression: partial clear converges every acknowledged deletion", %{
    agent_id: agent_id
  } do
    backend = use_authoritative_backend!()
    suffix = System.unique_integer([:positive])
    taint = taint(:hostile, :restricted, "partial_clear")

    deleted = Goal.new("committed partial deletion", id: "goal_partial_clear_#{suffix}_a")
    second = Goal.new("first surviving goal", id: "goal_partial_clear_#{suffix}_b")
    third = Goal.new("second surviving goal", id: "goal_partial_clear_#{suffix}_c")

    assert {:ok, ^deleted} = GoalStore.add_goal_tainted(agent_id, deleted, taint)
    assert {:ok, ^second} = GoalStore.add_goal_tainted(agent_id, second, taint)
    assert {:ok, ^third} = GoalStore.add_goal_tainted(agent_id, third, taint)

    AuthoritativeBackend.fail_compare_delete_after(backend, 1)

    assert {:error, :store_unavailable} = GoalStore.clear_goals(agent_id)

    assert {:error, :not_found} = GoalStore.get_goal(agent_id, deleted.id)
    assert {:error, :not_found} = GoalStore.get_goal_tainted(agent_id, deleted.id)
    assert_missing(Provenance.resolve(:goal, agent_id, deleted.id, goal_payload(deleted)))

    assert {:error, :not_found} =
             MemoryStore.load_tainted_authoritative_with_status(
               "goals",
               durable_key(agent_id, deleted)
             )

    assert Enum.sort(Enum.map(GoalStore.get_all_goals(agent_id), & &1.id)) ==
             Enum.sort([second.id, third.id])

    assert {:ok, surviving} = GoalStore.get_all_goals_tainted(agent_id)

    assert Enum.sort(Enum.map(surviving, fn {value, _status} -> value.value.id end)) ==
             Enum.sort([second.id, third.id])

    assert Enum.all?(surviving, fn {value, status} ->
             value.taint == taint and status == :verified
           end)

    AuthoritativeBackend.allow_compare_deletes(backend)
    assert :ok = GoalStore.clear_goals(agent_id)
    assert {:ok, []} = GoalStore.get_all_goals_tainted(agent_id)
  end

  test "security regression: tainted single read replaces a stale valid live pair", %{
    agent_id: agent_id
  } do
    goal = Goal.new("stale live pair", id: goal_id("stale-live-pair"))
    updated = %{goal | description: "authoritative replacement", progress: 0.7}
    taint = taint(:untrusted, :confidential, "authoritative_single_read")
    logical_key = durable_key(agent_id, goal)

    assert {:ok, ^goal} = GoalStore.add_goal_tainted(agent_id, goal, taint)

    assert {:ok, %TaintedValue{}, :verified, %Record{} = expected, :namespaced} =
             MemoryStore.load_tainted_authoritative_with_status("goals", logical_key)

    assert {:ok, %Record{}} =
             MemoryStore.compare_and_swap_tainted(
               "goals",
               logical_key,
               expected,
               goal_payload(updated),
               taint: taint
             )

    assert {:ok, ^goal} = GoalStore.get_goal(agent_id, goal.id)
    assert_goal_taint(agent_id, updated, taint, :verified)
  end

  test "security regression: deleting projection rows cannot bypass the authoritative goal cap",
       %{
         agent_id: agent_id
       } do
    original_limit = Application.get_env(:arbor_memory, :goal_limit_per_agent)
    Application.put_env(:arbor_memory, :goal_limit_per_agent, 1)

    on_exit(fn ->
      if is_nil(original_limit) do
        Application.delete_env(:arbor_memory, :goal_limit_per_agent)
      else
        Application.put_env(:arbor_memory, :goal_limit_per_agent, original_limit)
      end
    end)

    first = Goal.new("authoritative cap member", id: goal_id("cap-first"))
    second = Goal.new("must remain over cap", id: goal_id("cap-second"))

    assert {:ok, ^first} = GoalStore.add_goal(agent_id, first)
    true = :ets.delete(@goals_ets, {agent_id, first.id})

    assert {:error, :goal_limit_reached} = GoalStore.add_goal(agent_id, second)
    assert {:error, :not_found} = GoalStore.get_goal(agent_id, second.id)
  end

  test "raw add and import fail explicitly when the shared store owner is absent", %{
    agent_id: agent_id
  } do
    added = Goal.new("ownerless raw add", id: goal_id("ownerless-add"))
    imported = Goal.new("ownerless raw import", id: goal_id("ownerless-import"))

    assert :ok = stop_supervised!(BufferedStore)
    assert Process.whereis(@store_name) == nil

    assert {:error, :store_unavailable} = GoalStore.add_goal(agent_id, added)

    assert {:error, :store_unavailable} =
             GoalStore.import_goals(agent_id, [goal_payload(imported)])

    assert {:error, :not_found} = GoalStore.get_goal(agent_id, added.id)
    assert {:error, :not_found} = GoalStore.get_goal(agent_id, imported.id)

    start_ephemeral_store!()
  end

  test "security regression: concurrent remote progress and local metadata mutations do not lose fields",
       %{agent_id: agent_id} do
    backend = use_authoritative_backend!()
    goal = Goal.new("cross-owner mutation", id: goal_id("cross-owner-mutation"))
    initial = taint(:trusted, :public, "initial", :verified)
    local = taint(:derived, :internal, "local", :verified)
    remote = taint(:hostile, :restricted, "remote")
    remote_goal = %{goal | progress: 0.6}
    physical_key = "goals:#{durable_key(agent_id, goal)}"

    assert {:ok, ^goal} = GoalStore.add_goal_tainted(agent_id, goal, initial)

    AuthoritativeBackend.arm_read_update(
      backend,
      physical_key,
      1,
      backend_goal_update(remote_goal, remote)
    )

    assert {:ok, updated} =
             GoalStore.update_goal_metadata_tainted(
               agent_id,
               goal.id,
               %{local_update: true},
               local
             )

    assert updated.progress == 0.6
    assert updated.metadata.local_update

    assert {:ok, %TaintedValue{value: ^updated, taint: joined}, :verified} =
             GoalStore.get_goal_tainted(agent_id, goal.id)

    assert joined.level == :hostile
    assert joined.sensitivity == :restricted
  end

  test "configured backend outage fails before replacing live or authoritative goal state", %{
    agent_id: agent_id
  } do
    backend = use_authoritative_backend!()
    original = Goal.new("durable before outage", id: goal_id("backend-outage"))
    replacement = %{original | description: "weaker replacement"}
    strong = taint(:hostile, :restricted, "before_outage")

    assert {:ok, ^original} = GoalStore.add_goal_tainted(agent_id, original, strong)
    AuthoritativeBackend.set_available(backend, false)

    assert {:error, :store_unavailable} = GoalStore.add_goal(agent_id, replacement)
    assert {:ok, ^original} = GoalStore.get_goal(agent_id, original.id)

    AuthoritativeBackend.set_available(backend, true)
    assert_goal_taint(agent_id, original, strong, :verified)
  end

  test "distributed targeted reload reads backend authority instead of stale named-store cache",
       %{
         agent_id: agent_id
       } do
    backend = use_authoritative_backend!()
    start_supervised!({DistributedSync, name: DistributedSync})

    stale = Goal.new("stale separate cache", id: goal_id("separate-cache"))
    updated = %{stale | description: "backend authoritative", progress: 0.9}
    stale_taint = taint(:trusted, :internal, "stale_cache", :verified)
    updated_taint = taint(:hostile, :restricted, "remote_backend")
    physical_key = "goals:#{durable_key(agent_id, stale)}"

    assert {:ok, ^stale} = GoalStore.add_goal_tainted(agent_id, stale, stale_taint)

    AuthoritativeBackend.update_now(
      backend,
      physical_key,
      backend_goal_update(updated, updated_taint)
    )

    assert {:ok, %Record{data: stale_payload}} =
             BufferedStore.get(physical_key, name: @store_name)

    assert stale_payload == goal_payload(stale)

    send(DistributedSync, {
      :signal_received,
      %{
        type: :goal_progress,
        data: %{agent_id: agent_id, goal_id: stale.id, origin_node: :remote@node}
      }
    })

    assert eventually(fn ->
             with {:ok, ^updated} <- GoalStore.get_goal(agent_id, stale.id),
                  {:ok, ^updated_taint, :verified} <-
                    Provenance.resolve(:goal, agent_id, stale.id, goal_payload(updated)) do
               true
             else
               _ -> false
             end
           end)
  end

  test "distributed delete and clear signals remove stale live goals and sidecars", %{
    agent_id: agent_id
  } do
    start_supervised!({DistributedSync, name: DistributedSync})
    taint = taint(:untrusted, :restricted, "remote_delete")
    deleted = Goal.new("remote delete", id: goal_id("distributed-delete"))
    cleared = Goal.new("remote clear", id: goal_id("distributed-clear"))

    assert {:ok, ^deleted} = GoalStore.add_goal_tainted(agent_id, deleted, taint)
    assert {:ok, ^cleared} = GoalStore.add_goal_tainted(agent_id, cleared, taint)

    assert :ok =
             MemoryStore.delete_tainted_authoritative(
               "goals",
               durable_key(agent_id, deleted)
             )

    send(DistributedSync, {
      :signal_received,
      %{
        type: :goal_deleted,
        data: %{agent_id: agent_id, goal_id: deleted.id, origin_node: :remote@node}
      }
    })

    assert eventually(fn -> GoalStore.get_goal(agent_id, deleted.id) == {:error, :not_found} end)
    assert_missing(Provenance.resolve(:goal, agent_id, deleted.id, goal_payload(deleted)))

    assert :ok =
             MemoryStore.delete_tainted_authoritative(
               "goals",
               durable_key(agent_id, cleared)
             )

    send(DistributedSync, {
      :signal_received,
      %{
        type: :goals_cleared,
        data: %{agent_id: agent_id, origin_node: :remote@node}
      }
    })

    assert eventually(fn -> GoalStore.get_all_goals(agent_id) == [] end)
    assert_missing(Provenance.resolve(:goal, agent_id, cleared.id, goal_payload(cleared)))
  end

  defp start_ephemeral_store! do
    start_supervised!({BufferedStore, name: @store_name, backend: nil, write_mode: :sync})
  end

  defp use_authoritative_backend! do
    assert :ok = stop_supervised!(BufferedStore)

    start_supervised!(%{
      id: @backend_state,
      start:
        {Agent, :start_link,
         [
           fn ->
             %{
               records: %{},
               read_actions: %{},
               available?: true,
               compare_delete_fail_after: nil,
               compare_delete_successes: 0
             }
           end,
           [name: @backend_state]
         ]}
    })

    start_supervised!(
      {BufferedStore,
       name: @store_name,
       backend: AuthoritativeBackend,
       collection: @backend_state,
       write_mode: :async,
       ack_mode: :cache}
    )

    @backend_state
  end

  defp backend_goal_update(goal, taint) do
    payload = goal_payload(goal)
    {:ok, envelope} = TaintCodec.bind_durable_provenance(payload, taint)

    fn %Record{} = current ->
      current
      |> Record.update(payload, metadata: %{"taint" => envelope})
      |> Map.update!(:revision, &(&1 + 1))
    end
  end

  defp concurrent_mutation(agent_id, goal_id, metadata, taint) do
    parent = self()
    ready_ref = make_ref()

    task =
      Task.async(fn ->
        send(parent, {:mutation_ready, ready_ref})

        receive do
          :commit ->
            GoalStore.update_goal_metadata_tainted(agent_id, goal_id, metadata, taint)
        end
      end)

    assert_receive {:mutation_ready, ^ready_ref}, 1_000
    {task, ready_ref}
  end

  defp stop_provenance do
    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, Provenance)
    assert Process.whereis(Provenance) == nil
  end

  defp restart_provenance do
    assert {:ok, _pid} = Supervisor.restart_child(Arbor.Memory.Supervisor, Provenance)
  end

  defp restart_goal_store do
    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, GoalStore)
    assert {:ok, _pid} = Supervisor.restart_child(Arbor.Memory.Supervisor, GoalStore)
  end

  defp put_legacy_goal(agent_id, goal, payload, taint) do
    logical_key = durable_key(agent_id, goal)
    {:ok, envelope} = TaintCodec.bind_durable_provenance(payload, taint)

    record =
      Record.new(logical_key, payload,
        id: "goals:#{logical_key}",
        metadata: %{"taint" => envelope}
      )

    assert :ok = BufferedStore.put(logical_key, record, name: @store_name)
  end

  defp assert_goal_rows_deleted(agent_id, goal) do
    logical_key = durable_key(agent_id, goal)

    assert {:error, :not_found} =
             BufferedStore.get("goals:#{logical_key}", name: @store_name)

    assert {:error, :not_found} = BufferedStore.get(logical_key, name: @store_name)
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
