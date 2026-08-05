defmodule Arbor.Memory.WorkingMemoryProvenanceTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}

  alias Arbor.Memory.{
    MemoryStore,
    Provenance,
    WorkingMemory,
    WorkingMemoryStore
  }

  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @store_name :arbor_memory_durable
  @working_memory_ets :arbor_working_memory
  @timestamp ~U[2026-08-04 12:00:00Z]

  setup do
    start_supervised!({BufferedStore, name: @store_name, backend: nil, write_mode: :sync})

    agent_id = "agent_wm_provenance_#{System.unique_integer([:positive])}"
    :ok = WorkingMemoryStore.delete_working_memory(agent_id)

    on_exit(fn ->
      WorkingMemoryStore.delete_working_memory(agent_id)
      Provenance.delete_agent(agent_id)
    end)

    %{agent_id: agent_id}
  end

  test "security regression: raw save durably owns aggregate and per-item provenance", %{
    agent_id: agent_id
  } do
    thought = thought("raw-wrapper-thought", "raw compatibility content")
    wm = %{new_working_memory(agent_id) | recent_thoughts: [thought]}

    assert :ok = WorkingMemoryStore.save_working_memory(agent_id, wm)
    assert {:ok, wrapper} = wait_for_durable_data(agent_id)
    assert wrapper["version"] == 1
    assert wrapper["payload"] == WorkingMemory.serialize(wm)

    assert %{
             "aggregate" => %{"envelope" => aggregate_envelope},
             "recent_thoughts" => %{
               "raw-wrapper-thought" => %{"envelope" => thought_envelope}
             }
           } = wrapper["provenance"]

    assert aggregate_envelope["version"] == 1
    assert thought_envelope["version"] == 1
  end

  test "preserves mixed per-item labels and canonical aggregate sanitizations", %{
    agent_id: agent_id
  } do
    baseline = taint(:trusted, "baseline", sensitivity: :public, sanitizations: 0b111)

    thought_label =
      taint(:untrusted, "thought", sensitivity: :confidential, sanitizations: 0b011)

    goal_label =
      taint(:derived, "goal", sensitivity: :internal, sanitizations: 0b101)

    skill_label =
      taint(:trusted, "skill", sensitivity: :restricted, sanitizations: 0b001)

    wm = new_working_memory(agent_id)
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, baseline)

    wm = %{wm | recent_thoughts: [thought("thought-one", "mixed thought")]}
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, thought_label)

    wm = %{wm | active_goals: [goal("goal-one", "mixed goal")]}
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, goal_label)

    wm = %{wm | active_skills: [skill("skill-one", "mixed skill")]}
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, skill_label)

    assert {:ok, read} = WorkingMemoryStore.get_working_memory_tainted(agent_id)
    assert read.provenance_status == :verified
    assert item(read, :recent_thoughts, "thought-one").value.taint == thought_label
    assert item(read, :active_goals, "goal-one").value.taint == goal_label
    assert item(read, :active_skills, "skill-one").value.taint == skill_label

    assert {:ok, expected_aggregate} =
             Taint.join_many([baseline, thought_label, goal_label, skill_label])

    assert read.value.taint == expected_aggregate
    assert read.value.taint.sanitizations == 0b001

    assert %WorkingMemory{} = WorkingMemoryStore.get_working_memory(agent_id)
    assert {:ok, %Record{data: wrapper}} = durable_record(agent_id)
    assert wrapper["version"] == 1
    assert wrapper["payload"] == WorkingMemory.serialize(wm)
    refute Map.has_key?(wrapper["payload"], "provenance")

    Enum.each(
      wrapper["payload"]["recent_thoughts"] ++
        wrapper["payload"]["active_goals"] ++ wrapper["payload"]["active_skills"],
      fn payload ->
        refute Map.has_key?(payload, "taint")
        refute Map.has_key?(payload, "provenance")
      end
    )
  end

  test "base and aggregate domains cannot collide with caller thought IDs", %{
    agent_id: agent_id
  } do
    label = taint(:untrusted, "collision", sensitivity: :confidential)

    wm = %{
      new_working_memory(agent_id)
      | recent_thoughts: [
          thought("__working_memory_base_v1__", "base collision"),
          thought("__working_memory_aggregate_v1__", "aggregate collision")
        ]
    }

    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, label)
    assert {:ok, read} = WorkingMemoryStore.get_working_memory_tainted(agent_id)
    assert read.provenance_status == :verified
    assert read.value.taint == label

    for id <- ["__working_memory_base_v1__", "__working_memory_aggregate_v1__"] do
      entry = item(read, :recent_thoughts, id)
      assert entry.provenance_status == :verified
      assert entry.value.taint == label
    end

    payload = WorkingMemory.serialize(wm)
    base_payload = Map.drop(payload, ["recent_thoughts", "active_goals", "active_skills"])

    assert {:ok, ^label, :verified} =
             Provenance.resolve(:working_memory_base, agent_id, "base", base_payload)

    assert {:ok, ^label, :verified} =
             Provenance.resolve(:working_memory_aggregate, agent_id, "aggregate", payload)
  end

  test "security regression: deleting the sole hostile item cannot lower aggregate taint", %{
    agent_id: agent_id
  } do
    trusted = taint(:trusted, "trusted", sensitivity: :public, sanitizations: 0b111)
    hostile = taint(:hostile, "hostile", sensitivity: :restricted, sanitizations: 0b011)
    wm = new_working_memory(agent_id)

    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, trusted)

    hostile_thought = thought("hostile-thought", "hostile content")
    with_hostile = %{wm | recent_thoughts: [hostile_thought]}

    assert :ok =
             WorkingMemoryStore.save_working_memory_tainted(agent_id, with_hostile, hostile)

    assert {:ok, before_delete} = WorkingMemoryStore.get_working_memory_tainted(agent_id)
    assert before_delete.value.taint.level == :hostile

    without_hostile = %{with_hostile | recent_thoughts: []}

    assert :ok =
             WorkingMemoryStore.save_working_memory_tainted(agent_id, without_hostile, trusted)

    assert {:ok, after_delete} = WorkingMemoryStore.get_working_memory_tainted(agent_id)
    assert after_delete.items.recent_thoughts == []
    assert after_delete.value.taint.level == :hostile
    assert after_delete.value.taint.sensitivity == :restricted
    assert after_delete.value.taint.sanitizations == 0b011

    assert_missing(
      Provenance.resolve(
        :working_memory_thought,
        agent_id,
        hostile_thought.id,
        serialize_item(with_hostile, :recent_thoughts, hostile_thought.id)
      )
    )

    clear_live_state(agent_id)
    assert {:ok, reloaded} = WorkingMemoryStore.load_working_memory_tainted(agent_id)
    assert reloaded.value.taint.level == :hostile
    assert reloaded.items.recent_thoughts == []
  end

  test "trim retains survivor labels, removes stale sidecars, and keeps aggregate history", %{
    agent_id: agent_id
  } do
    baseline = taint(:trusted, "baseline", sensitivity: :public)
    hostile = taint(:hostile, "one", sensitivity: :restricted)
    trusted = taint(:trusted, "trusted", sensitivity: :public)
    derived = taint(:derived, "derived", sensitivity: :internal)
    wm = new_working_memory(agent_id)

    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, baseline)

    one = thought("one", "one")
    wm = %{wm | recent_thoughts: [one]}
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, hostile)

    two = thought("two", "two")
    wm = %{wm | recent_thoughts: [two | wm.recent_thoughts]}
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, trusted)

    three = thought("three", "three")
    wm = %{wm | recent_thoughts: [three | wm.recent_thoughts]}
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, derived)

    old_payload = serialize_item(wm, :recent_thoughts, one.id)
    four = thought("four", "four")
    trimmed = %{wm | recent_thoughts: Enum.take([four | wm.recent_thoughts], 3)}
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, trimmed, trusted)

    assert {:ok, read} = WorkingMemoryStore.get_working_memory_tainted(agent_id)
    assert Enum.map(read.items.recent_thoughts, & &1.id) == ["four", "three", "two"]
    assert item(read, :recent_thoughts, "four").value.taint == trusted
    assert item(read, :recent_thoughts, "three").value.taint == derived
    assert item(read, :recent_thoughts, "two").value.taint == trusted
    assert read.value.taint.level == :hostile
    assert_missing(Provenance.resolve(:working_memory_thought, agent_id, one.id, old_payload))
  end

  test "raw mutation preserves identity, rebinds payload, and becomes conservative", %{
    agent_id: agent_id
  } do
    trusted = taint(:trusted, "trusted", sensitivity: :public, sanitizations: 0b111)
    original = thought("stable-thought", "original")
    wm = %{new_working_memory(agent_id) | recent_thoughts: [original]}

    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, trusted)
    old_payload = serialize_item(wm, :recent_thoughts, original.id)

    mutated_thought = %{original | content: "mutated"}
    mutated = %{wm | recent_thoughts: [mutated_thought]}
    assert :ok = WorkingMemoryStore.save_working_memory(agent_id, mutated)

    assert {:ok, read} = WorkingMemoryStore.get_working_memory_tainted(agent_id)
    entry = item(read, :recent_thoughts, original.id)
    assert entry.id == original.id
    assert entry.provenance_status == :legacy_unlabeled
    assert entry.value.taint.level == :untrusted
    assert entry.value.taint.sensitivity == :restricted

    new_payload = serialize_item(mutated, :recent_thoughts, original.id)

    assert {:ok, rebound_taint, :verified} =
             Provenance.resolve(:working_memory_thought, agent_id, original.id, new_payload)

    assert rebound_taint == entry.value.taint

    assert_invalid(
      Provenance.resolve(:working_memory_thought, agent_id, original.id, old_payload)
    )

    cleared = %{mutated | recent_thoughts: []}
    assert :ok = WorkingMemoryStore.save_working_memory(agent_id, cleared)

    assert_missing(
      Provenance.resolve(:working_memory_thought, agent_id, original.id, new_payload)
    )

    assert {:ok, after_clear} = WorkingMemoryStore.get_working_memory_tainted(agent_id)
    assert after_clear.value.taint.level == :untrusted
    assert after_clear.provenance_status == :legacy_unlabeled
  end

  test "invalid supplied labels cause no ETS, sidecar, or durable partial write", %{
    agent_id: agent_id
  } do
    valid = taint(:derived, "valid", sensitivity: :internal)
    original = thought("existing", "original")
    wm = %{new_working_memory(agent_id) | recent_thoughts: [original]}
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, valid)

    original_payload = serialize_item(wm, :recent_thoughts, original.id)
    assert {:ok, before_record} = durable_record(agent_id)
    assert [{^agent_id, before_ets}] = :ets.lookup(@working_memory_ets, agent_id)

    added = thought("new", "secret-invalid-write")
    mutated = %{wm | recent_thoughts: [added | wm.recent_thoughts]}
    malformed = %Taint{level: :not_a_level}

    error = WorkingMemoryStore.save_working_memory_tainted(agent_id, mutated, malformed)
    assert {:error, {:working_memory_store, :invalid_provenance}} = error
    refute inspect(error) =~ "secret-invalid-write"

    assert [{^agent_id, ^before_ets}] = :ets.lookup(@working_memory_ets, agent_id)
    assert {:ok, ^before_record} = durable_record(agent_id)

    assert {:ok, ^valid, :verified} =
             Provenance.resolve(:working_memory_thought, agent_id, original.id, original_payload)

    assert_missing(
      Provenance.resolve(
        :working_memory_thought,
        agent_id,
        added.id,
        serialize_item(mutated, :recent_thoughts, added.id)
      )
    )
  end

  test "durable reload rehydrates exact aggregate and item labels after sidecar restart", %{
    agent_id: agent_id
  } do
    baseline = taint(:trusted, "baseline", sensitivity: :public, sanitizations: 0b111)
    thought_label = taint(:untrusted, "thought", sensitivity: :confidential, sanitizations: 0b011)
    goal_label = taint(:derived, "goal", sensitivity: :internal, sanitizations: 0b101)
    wm = new_working_memory(agent_id)
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, baseline)

    wm = %{wm | recent_thoughts: [thought("reload-thought", "reload")]}
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, thought_label)

    wm = %{wm | active_goals: [goal("reload-goal", "reload goal")]}
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, goal_label)

    assert {:ok, expected_aggregate} = Taint.join_many([baseline, thought_label, goal_label])

    restart_provenance()
    assert {:ok, conservative} = WorkingMemoryStore.get_working_memory_tainted(agent_id)
    assert conservative.provenance_status == :legacy_unlabeled
    assert conservative.value.taint.level == :untrusted

    :ets.delete(@working_memory_ets, agent_id)
    assert {:ok, restored} = WorkingMemoryStore.load_working_memory_tainted(agent_id)
    assert restored.provenance_status == :verified
    assert restored.value.taint == expected_aggregate
    assert item(restored, :recent_thoughts, "reload-thought").value.taint == thought_label
    assert item(restored, :active_goals, "reload-goal").value.taint == goal_label
    assert restored.value.value |> WorkingMemory.serialize() == WorkingMemory.serialize(wm)
  end

  test "legacy raw records migrate once with stable IDs and conservative statuses", %{
    agent_id: agent_id
  } do
    legacy = %{
      "agent_id" => agent_id,
      "recent_thoughts" => ["legacy thought"],
      "active_goals" => [%{"description" => "legacy goal"}],
      "active_skills" => [%{"name" => "legacy skill", "body" => "legacy body"}],
      "version" => 3
    }

    assert :ok = MemoryStore.persist("working_memory", agent_id, legacy)
    assert {:ok, first} = WorkingMemoryStore.load_working_memory_tainted(agent_id)
    assert first.provenance_status == :legacy_unlabeled
    assert first.value.value.started_at == nil
    assert Enum.all?(all_items(first), &(&1.provenance_status == :legacy_unlabeled))

    first_ids = item_ids(first)
    assert {:ok, %Record{data: wrapper}} = durable_record(agent_id)
    assert wrapper["version"] == 1
    assert wrapper["payload"]["started_at"] == nil

    clear_live_state(agent_id)
    assert {:ok, second} = WorkingMemoryStore.load_working_memory_tainted(agent_id)
    assert item_ids(second) == first_ids
    assert second.provenance_status == :legacy_unlabeled
    assert Enum.all?(all_items(second), &(&1.provenance_status == :legacy_unlabeled))
  end

  test "versionless, unknown, malformed, and nested-mismatched wrappers restore hostile", %{
    agent_id: root_agent_id
  } do
    corruptors = [
      {"versionless", fn wrapper, _id -> Map.delete(wrapper, "version") end},
      {"unknown", fn wrapper, _id -> Map.put(wrapper, "version", 99) end},
      {"nested_versionless",
       fn wrapper, id ->
         update_in(
           wrapper,
           ["provenance", "recent_thoughts", id, "envelope"],
           &Map.delete(&1, "version")
         )
       end},
      {"nested_unknown",
       fn wrapper, id ->
         put_in(wrapper, ["provenance", "recent_thoughts", id, "envelope", "version"], 99)
       end},
      {"nested_malformed",
       fn wrapper, id ->
         put_in(wrapper, ["provenance", "recent_thoughts", id, "envelope"], %{
           "version" => 1
         })
       end},
      {"nested_mismatch",
       fn wrapper, _id ->
         put_in(wrapper, ["payload", "recent_thoughts", Access.at(0), "content"], "changed")
       end}
    ]

    Enum.each(corruptors, fn {suffix, corruptor} ->
      agent_id = "#{root_agent_id}_#{suffix}"
      on_exit(fn -> WorkingMemoryStore.delete_working_memory(agent_id) end)
      label = taint(:trusted, "seed", sensitivity: :public)
      thought_id = "thought-#{suffix}"
      wm = %{new_working_memory(agent_id) | recent_thoughts: [thought(thought_id, "bound")]}

      assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, label)
      assert {:ok, %Record{data: wrapper}} = durable_record(agent_id)
      corrupt = corruptor.(wrapper, thought_id)
      assert :ok = MemoryStore.persist("working_memory", agent_id, corrupt, taint: label)

      clear_live_state(agent_id)
      assert {:ok, restored} = WorkingMemoryStore.load_working_memory_tainted(agent_id)
      assert restored.provenance_status == :invalid_durable_provenance
      assert restored.value.taint == TaintEnvelope.invalid_fallback()

      assert Enum.all?(all_items(restored), fn item ->
               item.provenance_status == :invalid_durable_provenance and
                 item.value.taint == TaintEnvelope.invalid_fallback()
             end)
    end)
  end

  test "outer payload mismatch cannot partially restore permissive provenance", %{
    agent_id: agent_id
  } do
    label = taint(:trusted, "outer", sensitivity: :public)
    thought = thought("outer-thought", "bound")
    wm = %{new_working_memory(agent_id) | recent_thoughts: [thought]}
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, label)
    assert {:ok, record} = durable_record(agent_id)

    tampered_data =
      put_in(record.data, ["payload", "recent_thoughts", Access.at(0), "content"], "tampered")

    assert :ok =
             BufferedStore.put(
               "working_memory:#{agent_id}",
               %{record | data: tampered_data},
               name: @store_name
             )

    assert :ok = Provenance.delete_agent(agent_id)
    assert {:ok, live_restored} = WorkingMemoryStore.load_working_memory_tainted(agent_id)
    assert live_restored.provenance_status == :invalid_durable_provenance
    assert live_restored.value.taint == TaintEnvelope.invalid_fallback()

    clear_live_state(agent_id)
    assert {:ok, restored} = WorkingMemoryStore.load_working_memory_tainted(agent_id)
    assert restored.provenance_status == :invalid_durable_provenance
    assert restored.value.taint == TaintEnvelope.invalid_fallback()
    assert Enum.all?(all_items(restored), &(&1.provenance_status == :invalid_durable_provenance))
  end

  test "delete cleans only working-memory sidecars", %{agent_id: agent_id} do
    label = taint(:derived, "delete", sensitivity: :internal)
    thought = thought("delete-thought", "delete me")
    wm = %{new_working_memory(agent_id) | recent_thoughts: [thought]}
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, label)

    unrelated_payload = %{"description" => "unrelated"}
    assert :ok = Provenance.put(:goal, agent_id, "unrelated-goal", unrelated_payload, label)

    payload = WorkingMemory.serialize(wm)
    base_payload = Map.drop(payload, ["recent_thoughts", "active_goals", "active_skills"])
    thought_payload = serialize_item(wm, :recent_thoughts, thought.id)

    assert :ok = WorkingMemoryStore.delete_working_memory(agent_id)
    assert WorkingMemoryStore.get_working_memory(agent_id) == nil
    assert {:error, :not_found} = durable_record(agent_id)

    assert_missing(
      Provenance.resolve(:working_memory_thought, agent_id, thought.id, thought_payload)
    )

    assert_missing(Provenance.resolve(:working_memory_base, agent_id, "base", base_payload))
    assert_missing(Provenance.resolve(:working_memory_aggregate, agent_id, "aggregate", payload))

    assert {:ok, ^label, :verified} =
             Provenance.resolve(:goal, agent_id, "unrelated-goal", unrelated_payload)

    assert :ok = Provenance.delete(:goal, agent_id, "unrelated-goal")
  end

  test "collection limits reject before any write and redact content", %{agent_id: agent_id} do
    wm = %{
      new_working_memory(agent_id)
      | recent_thoughts:
          Enum.map(1..65, fn index ->
            thought("bounded-#{index}", "secret-over-limit-#{index}")
          end)
    }

    error =
      WorkingMemoryStore.save_working_memory_tainted(
        agent_id,
        wm,
        taint(:untrusted, "bounded", sensitivity: :restricted)
      )

    assert {:error, {:working_memory_store, :collection_limit_exceeded}} = error
    refute inspect(error) =~ "secret-over-limit"
    assert WorkingMemoryStore.get_working_memory(agent_id) == nil
    assert {:error, :not_found} = durable_record(agent_id)

    first = hd(wm.recent_thoughts)

    assert_missing(
      Provenance.resolve(
        :working_memory_thought,
        agent_id,
        first.id,
        serialize_item(wm, :recent_thoughts, first.id)
      )
    )
  end

  test "durable unavailability is not treated as a fresh taint-aware record", %{
    agent_id: agent_id
  } do
    stop_supervised!(BufferedStore)
    assert Process.whereis(@store_name) == nil

    assert {:error, {:working_memory_store, :durable_unavailable}} =
             WorkingMemoryStore.load_working_memory_tainted(agent_id)

    assert WorkingMemoryStore.get_working_memory(agent_id) == nil
  end

  defp new_working_memory(agent_id) do
    WorkingMemory.new(agent_id, rebuild_from_signals: false)
  end

  defp thought(id, content) do
    %{
      id: id,
      content: content,
      timestamp: @timestamp,
      cached_tokens: 1,
      referenced_date: nil
    }
  end

  defp goal(id, description) do
    %{
      id: id,
      description: description,
      type: :task,
      priority: :normal,
      progress: 0,
      added_at: @timestamp
    }
  end

  defp skill(id, name) do
    %{
      id: id,
      name: name,
      description: "description",
      body: "body",
      activated_at: @timestamp
    }
  end

  defp taint(level, source, opts) do
    {:ok, taint} =
      Taint.new(%{
        level: level,
        sensitivity: Keyword.get(opts, :sensitivity, :internal),
        sanitizations: Keyword.get(opts, :sanitizations, 0),
        confidence: Keyword.get(opts, :confidence, :verified),
        source: source,
        chain: []
      })

    taint
  end

  defp item(read, field, id) do
    Enum.find(Map.fetch!(read.items, field), &(&1.id == id)) || flunk("missing item #{id}")
  end

  defp all_items(read) do
    read.items.recent_thoughts ++ read.items.active_goals ++ read.items.active_skills
  end

  defp item_ids(read) do
    %{
      thoughts: Enum.map(read.items.recent_thoughts, & &1.id),
      goals: Enum.map(read.items.active_goals, & &1.id),
      skills: Enum.map(read.items.active_skills, & &1.id)
    }
  end

  defp serialize_item(wm, field, id) do
    durable_key = Atom.to_string(field)

    wm
    |> WorkingMemory.serialize()
    |> Map.fetch!(durable_key)
    |> Enum.find(&(&1["id"] == id))
  end

  defp durable_record(agent_id) do
    BufferedStore.get("working_memory:#{agent_id}", name: @store_name)
  end

  defp wait_for_durable_data(agent_id, attempts \\ 100)

  defp wait_for_durable_data(_agent_id, 0), do: {:error, :not_found}

  defp wait_for_durable_data(agent_id, attempts) do
    case MemoryStore.load("working_memory", agent_id) do
      {:ok, data} ->
        {:ok, data}

      {:error, _reason} ->
        Process.sleep(10)
        wait_for_durable_data(agent_id, attempts - 1)
    end
  end

  defp clear_live_state(agent_id) do
    :ets.delete(@working_memory_ets, agent_id)
    assert :ok = Provenance.delete_agent(agent_id)
  end

  defp restart_provenance do
    old_pid = Process.whereis(Provenance)
    monitor = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :killed}
    wait_for_provenance(old_pid)
  end

  defp wait_for_provenance(old_pid, attempts \\ 100)
  defp wait_for_provenance(_old_pid, 0), do: flunk("provenance sidecar did not restart")

  defp wait_for_provenance(old_pid, attempts) do
    case Process.whereis(Provenance) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        Process.sleep(10)
        wait_for_provenance(old_pid, attempts - 1)
    end
  end

  defp assert_missing(result) do
    assert {:ok, taint, :legacy_unlabeled} = result
    assert taint == TaintEnvelope.missing_fallback()
  end

  defp assert_invalid(result) do
    assert {:ok, taint, :invalid_durable_provenance} = result
    assert taint == TaintEnvelope.invalid_fallback()
  end
end
