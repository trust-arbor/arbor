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

  defmodule SwitchableNodeRestartBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Persistence.QueryableStore.ETS

    @impl true
    def put(key, value, opts), do: available_call(opts, fn -> ETS.put(key, value, opts) end)

    @impl true
    def get(key, opts), do: available_call(opts, fn -> ETS.get(key, opts) end)

    @impl true
    def delete(key, opts), do: available_call(opts, fn -> ETS.delete(key, opts) end)

    @impl true
    def list(opts), do: available_call(opts, fn -> ETS.list(opts) end)

    @impl true
    def query(filter, opts), do: available_call(opts, fn -> ETS.query(filter, opts) end)

    @impl true
    def compare_and_swap(key, expected, replacement, opts) do
      available_call(opts, fn -> ETS.compare_and_swap(key, expected, replacement, opts) end)
    end

    @impl true
    def compare_and_delete(key, expected, opts) do
      available_call(opts, fn -> ETS.compare_and_delete(key, expected, opts) end)
    end

    @impl true
    def durability_class(_opts), do: :node_restart

    defp available_call(opts, fun) do
      if Agent.get(Keyword.fetch!(opts, :control), & &1),
        do: fun.(),
        else: {:error, :forced_failure}
    end
  end

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
    assert wrapper["version"] == 2
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

  test "security regression: portable snapshot preserves exact hostile item provenance", %{
    agent_id: agent_id
  } do
    trusted = taint(:trusted, "snapshot-base", sensitivity: :public)
    hostile = taint(:hostile, "snapshot-hostile", sensitivity: :restricted)
    hostile_thought = thought("snapshot-hostile-thought", "portable hostile content")

    wm = new_working_memory(agent_id)
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, trusted)

    wm = %{wm | recent_thoughts: [hostile_thought]}
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, hostile)

    assert {:ok, exported} = Arbor.Memory.export_working_memory_provenance_snapshot(agent_id)

    assert %{
             "snapshot_kind" => "arbor_working_memory_provenance",
             "snapshot_version" => 1,
             "working_memory" => wrapper,
             "outer_envelope" => outer_envelope
           } = exported

    assert wrapper["version"] == 2
    assert {:ok, verified_outer} = TaintEnvelope.verify(outer_envelope, wrapper)
    assert verified_outer.taint.level == :hostile

    assert :ok = WorkingMemoryStore.delete_working_memory(agent_id)

    assert {:error, {:working_memory_store, :not_found}} =
             WorkingMemoryStore.get_working_memory_tainted(agent_id)

    assert :ok = Arbor.Memory.import_working_memory_provenance_snapshot(agent_id, exported)
    assert {:ok, restored} = WorkingMemoryStore.get_working_memory_tainted(agent_id)

    assert restored.value.value.recent_thoughts == [hostile_thought]
    assert restored.value.taint.level == :hostile

    assert item(restored, :recent_thoughts, hostile_thought.id).value.taint == hostile
  end

  test "security regression: malformed portable snapshot has zero write effects", %{
    agent_id: agent_id
  } do
    trusted = taint(:trusted, "snapshot-atomic", sensitivity: :public)
    wm = new_working_memory(agent_id)

    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, trusted)
    assert {:ok, exported} = Arbor.Memory.export_working_memory_provenance_snapshot(agent_id)
    assert {:ok, %Record{} = before_record} = durable_record(agent_id)

    malformed = put_in(exported, ["outer_envelope", "payload_sha256"], String.duplicate("0", 64))

    assert {:error, {:working_memory_store, :invalid_provenance_snapshot}} =
             Arbor.Memory.import_working_memory_provenance_snapshot(agent_id, malformed)

    assert {:ok, ^before_record} = durable_record(agent_id)
    assert {:ok, read} = WorkingMemoryStore.get_working_memory_tainted(agent_id)
    assert read.value.value == wm
    assert read.value.taint == trusted
  end

  test "public snapshot validation is agent-bound and has zero effects", %{agent_id: agent_id} do
    label = taint(:hostile, "snapshot-validator", sensitivity: :restricted)
    wm = %{new_working_memory(agent_id) | recent_thoughts: [thought("validator", "bound")]}

    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, label)
    assert {:ok, exported} = Arbor.Memory.export_working_memory_provenance_snapshot(agent_id)
    assert {:ok, %Record{} = before_record} = durable_record(agent_id)

    before_projection = :ets.lookup(@working_memory_ets, agent_id)
    before_sidecars = sidecar_inventory(agent_id)

    assert :ok =
             Arbor.Memory.validate_working_memory_provenance_snapshot(agent_id, exported)

    assert {:error, {:working_memory_store, :invalid_provenance_snapshot}} =
             Arbor.Memory.validate_working_memory_provenance_snapshot(
               "#{agent_id}_other",
               exported
             )

    assert {:error, {:working_memory_store, :invalid_provenance_snapshot}} =
             Arbor.Memory.validate_working_memory_provenance_snapshot(
               agent_id,
               %{"snapshot_kind" => "arbor_working_memory_provenance"}
             )

    corrupt = put_in(exported, ["outer_envelope", "payload_sha256"], String.duplicate("0", 64))

    assert {:error, {:working_memory_store, :invalid_provenance_snapshot}} =
             Arbor.Memory.validate_working_memory_provenance_snapshot(agent_id, corrupt)

    assert {:ok, ^before_record} = durable_record(agent_id)
    assert :ets.lookup(@working_memory_ets, agent_id) == before_projection
    assert sidecar_inventory(agent_id) == before_sidecars
  end

  test "all reserved portable snapshot keys force strict snapshot classification" do
    for key <- [
          "snapshot_kind",
          "snapshot_version",
          "working_memory",
          "outer_envelope",
          :snapshot_kind,
          :snapshot_version,
          :working_memory,
          :outer_envelope
        ] do
      assert WorkingMemoryStore.working_memory_provenance_snapshot?(%{key => nil})
    end

    refute WorkingMemoryStore.working_memory_provenance_snapshot?(%{"agent_id" => "legacy"})
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
    assert wrapper["version"] == 2
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

  test "concerns and curiosity retain exact per-item labels with public scalar values", %{
    agent_id: agent_id
  } do
    baseline = taint(:trusted, "scalar-base", sensitivity: :public, sanitizations: 0b111)

    concern_label =
      taint(:untrusted, "scalar-concern", sensitivity: :confidential, sanitizations: 0b011)

    curiosity_label =
      taint(:derived, "scalar-curiosity", sensitivity: :internal, sanitizations: 0b101)

    wm = new_working_memory(agent_id)
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, baseline)

    wm = WorkingMemory.add_concern(wm, "scalar concern")
    concern_id = hd(wm.concern_ids)
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, concern_label)

    wm = WorkingMemory.add_curiosity(wm, "scalar curiosity")
    curiosity_id = hd(wm.curiosity_ids)
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, curiosity_label)

    assert {:ok, read} = WorkingMemoryStore.get_working_memory_tainted(agent_id)
    assert item(read, :concerns, concern_id).value.value == "scalar concern"
    assert item(read, :concerns, concern_id).value.taint == concern_label
    assert item(read, :curiosity, curiosity_id).value.value == "scalar curiosity"
    assert item(read, :curiosity, curiosity_id).value.taint == curiosity_label

    assert {:ok, expected} = Taint.join_many([baseline, concern_label, curiosity_label])
    assert read.value.taint == expected
    assert read.value.taint.sanitizations == 0b001

    assert {:ok, ^concern_label, :verified} =
             Provenance.resolve(
               :working_memory_concern,
               agent_id,
               concern_id,
               serialize_item(wm, :concerns, concern_id)
             )

    assert {:ok, ^curiosity_label, :verified} =
             Provenance.resolve(
               :working_memory_curiosity,
               agent_id,
               curiosity_id,
               serialize_item(wm, :curiosity, curiosity_id)
             )
  end

  test "security regression: scalar envelopes cannot move between equal-value identities", %{
    agent_id: agent_id
  } do
    trusted = taint(:trusted, "first-scalar", sensitivity: :public)
    hostile = taint(:hostile, "second-scalar", sensitivity: :restricted)

    first = WorkingMemory.add_concern(new_working_memory(agent_id), "same text")
    first_id = hd(first.concern_ids)
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, first, trusted)

    second_id = "concern_duplicate_identity"

    duplicates = %{
      first
      | concerns: ["same text", "same text"],
        concern_ids: [second_id, first_id]
    }

    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, duplicates, hostile)
    assert {:ok, read} = WorkingMemoryStore.get_working_memory_tainted(agent_id)
    assert item(read, :concerns, first_id).value.taint == trusted
    assert item(read, :concerns, second_id).value.taint == hostile
    assert {:ok, %Record{data: wrapper}} = durable_record(agent_id)

    first_entry = wrapper["provenance"]["concerns"][first_id]
    second_entry = wrapper["provenance"]["concerns"][second_id]

    swapped =
      wrapper
      |> put_in(["provenance", "concerns", first_id], second_entry)
      |> put_in(["provenance", "concerns", second_id], first_entry)

    assert :ok = replace_durable_data(agent_id, swapped, read.value.taint)
    clear_live_state(agent_id)

    assert {:ok, rejected} = WorkingMemoryStore.load_working_memory_tainted(agent_id)
    assert rejected.provenance_status == :invalid_durable_provenance
    assert rejected.value.taint == TaintEnvelope.invalid_fallback()

    assert Enum.all?(rejected.items.concerns, fn entry ->
             entry.provenance_status == :invalid_durable_provenance
           end)
  end

  test "removing and re-adding scalar text creates a new provenance identity", %{
    agent_id: agent_id
  } do
    hostile = taint(:hostile, "removed-scalar", sensitivity: :restricted)
    trusted = taint(:trusted, "readded-scalar", sensitivity: :public)
    first = WorkingMemory.add_concern(new_working_memory(agent_id), "reused text")
    first_id = hd(first.concern_ids)
    first_payload = serialize_item(first, :concerns, first_id)

    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, first, hostile)

    removed = WorkingMemory.resolve_concern(first, "reused text")
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, removed, trusted)

    readded = WorkingMemory.add_concern(removed, "reused text")
    second_id = hd(readded.concern_ids)
    refute second_id == first_id
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, readded, trusted)

    assert {:ok, read} = WorkingMemoryStore.get_working_memory_tainted(agent_id)
    assert item(read, :concerns, second_id).value.taint == trusted
    assert_missing(Provenance.resolve(:working_memory_concern, agent_id, first_id, first_payload))

    assert {:ok, ^trusted, :verified} =
             Provenance.resolve(
               :working_memory_concern,
               agent_id,
               second_id,
               serialize_item(readded, :concerns, second_id)
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

    base_payload =
      Map.drop(payload, [
        "recent_thoughts",
        "active_goals",
        "active_skills",
        "concerns",
        "concern_ids",
        "curiosity",
        "curiosity_ids"
      ])

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

  @tag timeout: 60_000
  test "security regression: concurrent hostile and trusted saves cannot lose aggregate taint", %{
    agent_id: agent_id
  } do
    trusted = taint(:trusted, "concurrent-trusted", sensitivity: :public)
    hostile = taint(:hostile, "concurrent-hostile", sensitivity: :restricted)

    for iteration <- 1..50 do
      assert :ok = WorkingMemoryStore.delete_working_memory(agent_id)
      original = thought("concurrent-thought", "baseline-#{iteration}")
      baseline = %{new_working_memory(agent_id) | recent_thoughts: [original]}
      assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, baseline, trusted)

      hostile_candidate = %{
        baseline
        | recent_thoughts: [%{original | content: "hostile-#{iteration}"}]
      }

      trusted_candidate = %{
        baseline
        | recent_thoughts: [%{original | content: "trusted-#{iteration}"}]
      }

      results =
        run_concurrently([
          fn ->
            WorkingMemoryStore.save_working_memory_tainted(
              agent_id,
              hostile_candidate,
              hostile
            )
          end,
          fn ->
            WorkingMemoryStore.save_working_memory_tainted(
              agent_id,
              trusted_candidate,
              trusted
            )
          end
        ])

      assert results == [:ok, :ok]
      assert {:ok, final} = WorkingMemoryStore.get_working_memory_tainted(agent_id)
      assert final.value.taint.level == :hostile
      assert item(final, :recent_thoughts, original.id).value.taint.level == :hostile
    end
  end

  @tag timeout: 60_000
  test "update and delete contention leaves one acknowledged durable projection", %{
    agent_id: agent_id
  } do
    baseline_label = taint(:derived, "delete-race-base", sensitivity: :internal)
    update_label = taint(:hostile, "delete-race-update", sensitivity: :restricted)

    for iteration <- 1..25 do
      assert :ok = WorkingMemoryStore.delete_working_memory(agent_id)
      original = thought("delete-race-thought", "baseline-#{iteration}")
      baseline = %{new_working_memory(agent_id) | recent_thoughts: [original]}

      assert :ok =
               WorkingMemoryStore.save_working_memory_tainted(
                 agent_id,
                 baseline,
                 baseline_label
               )

      updated = %{
        baseline
        | recent_thoughts: [%{original | content: "updated-#{iteration}"}]
      }

      assert [:ok, :ok] =
               run_concurrently([
                 fn ->
                   WorkingMemoryStore.save_working_memory_tainted(
                     agent_id,
                     updated,
                     update_label
                   )
                 end,
                 fn -> WorkingMemoryStore.delete_working_memory(agent_id) end
               ])

      case WorkingMemoryStore.get_working_memory_tainted(agent_id) do
        {:ok, read} ->
          assert read.value.value.recent_thoughts == updated.recent_thoughts
          assert WorkingMemoryStore.get_working_memory(agent_id) == read.value.value
          assert {:ok, %Record{data: wrapper}} = durable_record(agent_id)
          assert wrapper["payload"] == WorkingMemory.serialize(updated)

        {:error, {:working_memory_store, :not_found}} ->
          assert WorkingMemoryStore.get_working_memory(agent_id) == nil
          assert {:error, :not_found} = durable_record(agent_id)

          for domain <- working_memory_domains() do
            assert {:ok, []} = Provenance.list_item_ids(domain, agent_id)
          end
      end
    end
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
    :ets.delete(@working_memory_ets, agent_id)
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
    assert {:ok, rehydrated} = WorkingMemoryStore.get_working_memory_tainted(agent_id)
    assert rehydrated.provenance_status == :verified
    assert rehydrated.value.taint == expected_aggregate

    :ets.delete(@working_memory_ets, agent_id)
    assert {:ok, restored} = WorkingMemoryStore.load_working_memory_tainted(agent_id)
    assert restored.provenance_status == :verified
    assert restored.value.taint == expected_aggregate
    assert item(restored, :recent_thoughts, "reload-thought").value.taint == thought_label
    assert item(restored, :active_goals, "reload-goal").value.taint == goal_label
    assert restored.value.value |> WorkingMemory.serialize() == WorkingMemory.serialize(wm)
  end

  test "security regression: post-commit sidecar failure evicts stale raw projection", %{
    agent_id: agent_id
  } do
    trusted = taint(:trusted, "projection-old", sensitivity: :public)
    hostile = taint(:hostile, "projection-new", sensitivity: :restricted)
    original = thought("projection-thought", "old projected content")
    baseline = %{new_working_memory(agent_id) | recent_thoughts: [original]}

    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, baseline, trusted)
    assert {:ok, %Record{revision: baseline_revision}} = durable_record(agent_id)
    assert WorkingMemoryStore.get_working_memory(agent_id) == baseline

    changed = %{
      baseline
      | recent_thoughts: [%{original | content: "new durable content"}]
    }

    provenance_pid = Process.whereis(Provenance)
    assert is_pid(provenance_pid)
    assert Process.unregister(Provenance)

    try do
      assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, changed, hostile)

      assert {:ok, %Record{data: committed_wrapper, revision: committed_revision}} =
               durable_record(agent_id)

      assert committed_revision == baseline_revision + 1
      assert committed_wrapper["payload"] == WorkingMemory.serialize(changed)
      assert :ets.lookup(@working_memory_ets, agent_id) == []

      assert WorkingMemoryStore.get_working_memory(agent_id) == changed
      assert :ets.lookup(@working_memory_ets, agent_id) == []

      assert {:ok, authoritative} = WorkingMemoryStore.get_working_memory_tainted(agent_id)
      assert authoritative.value.value == changed
      assert authoritative.value.taint.level == :hostile

      assert :ets.lookup(@working_memory_ets, agent_id) == []
    after
      if Process.alive?(provenance_pid) and Process.whereis(Provenance) == nil do
        Process.register(provenance_pid, Provenance)
      end
    end

    assert {:ok, repaired} = WorkingMemoryStore.load_working_memory_tainted(agent_id)
    assert repaired.value.value == changed
    assert repaired.value.taint.level == :hostile

    assert item(repaired, :recent_thoughts, original.id).value.value.content ==
             "new durable content"

    assert WorkingMemoryStore.get_working_memory(agent_id) == changed
  end

  test "security regression: taint-aware reads reject caller ETS row and item omission", %{
    agent_id: agent_id
  } do
    hostile = taint(:hostile, "authoritative-inventory", sensitivity: :restricted)
    retained = thought("retained-hostile", "must remain in heartbeat context")
    wm = %{new_working_memory(agent_id) | recent_thoughts: [retained]}

    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, hostile)

    :ets.delete(@working_memory_ets, agent_id)
    assert WorkingMemoryStore.get_working_memory(agent_id) == wm
    assert [{^agent_id, ^wm}] = :ets.lookup(@working_memory_ets, agent_id)

    forged = %{wm | recent_thoughts: []}
    true = :ets.insert(@working_memory_ets, {agent_id, forged})
    assert WorkingMemoryStore.get_working_memory(agent_id) == wm
    assert [{^agent_id, ^wm}] = :ets.lookup(@working_memory_ets, agent_id)

    :ets.delete(@working_memory_ets, agent_id)
    assert {:ok, restored_row} = WorkingMemoryStore.get_working_memory_tainted(agent_id)
    assert item(restored_row, :recent_thoughts, retained.id).value.taint == hostile

    true = :ets.insert(@working_memory_ets, {agent_id, forged})
    assert :ok = Provenance.delete_domain_agent(:working_memory_thought, agent_id)

    assert {:ok, restored_item} = WorkingMemoryStore.get_working_memory_tainted(agent_id)
    assert [entry] = restored_item.items.recent_thoughts
    assert entry.id == retained.id
    assert entry.value.value == retained
    assert entry.value.taint == hostile
    assert restored_item.value.taint.level == :hostile
    assert [{^agent_id, ^wm}] = :ets.lookup(@working_memory_ets, agent_id)
  end

  test "legacy raw records migrate once with stable IDs and conservative statuses", %{
    agent_id: agent_id
  } do
    legacy = %{
      "agent_id" => agent_id,
      "recent_thoughts" => ["legacy thought"],
      "active_goals" => [%{"description" => "legacy goal"}],
      "active_skills" => [%{"name" => "legacy skill", "body" => "legacy body"}],
      "concerns" => ["legacy concern"],
      "curiosity" => ["legacy curiosity"],
      "version" => 3
    }

    assert :ok = MemoryStore.persist("working_memory", agent_id, legacy)
    assert {:ok, first} = WorkingMemoryStore.load_working_memory_tainted(agent_id)
    assert first.provenance_status == :legacy_unlabeled
    assert first.value.value.started_at == nil
    assert Enum.all?(all_items(first), &(&1.provenance_status == :legacy_unlabeled))

    first_ids = item_ids(first)
    assert {:ok, %Record{data: wrapper}} = durable_record(agent_id)
    assert wrapper["version"] == 2
    assert wrapper["payload"]["started_at"] == nil

    clear_live_state(agent_id)
    assert {:ok, second} = WorkingMemoryStore.load_working_memory_tainted(agent_id)
    assert item_ids(second) == first_ids
    assert second.provenance_status == :legacy_unlabeled
    assert Enum.all?(all_items(second), &(&1.provenance_status == :legacy_unlabeled))
  end

  test "version one wrappers migrate scalar identities and preserve verified inner labels", %{
    agent_id: agent_id
  } do
    label = taint(:derived, "legacy-wrapper", sensitivity: :internal)
    legacy_thought = thought("legacy-wrapper-thought", "legacy wrapper thought")

    wm =
      %{new_working_memory(agent_id) | recent_thoughts: [legacy_thought]}
      |> WorkingMemory.add_concern("legacy wrapper concern")

    legacy_payload =
      wm
      |> WorkingMemory.serialize()
      |> Map.drop(["concern_ids", "curiosity_ids"])

    legacy_base_payload =
      Map.drop(legacy_payload, ["recent_thoughts", "active_goals", "active_skills"])

    wrapper = %{
      "version" => 1,
      "payload" => legacy_payload,
      "provenance" => %{
        "base" => durable_entry(legacy_base_payload, label),
        "aggregate" => durable_entry(legacy_payload, label),
        "recent_thoughts" => %{
          legacy_thought.id =>
            durable_entry(
              serialize_item(wm, :recent_thoughts, legacy_thought.id),
              label
            )
        },
        "active_goals" => %{},
        "active_skills" => %{}
      }
    }

    assert :ok = MemoryStore.persist("working_memory", agent_id, wrapper, taint: label)
    assert {:ok, migrated} = WorkingMemoryStore.load_working_memory_tainted(agent_id)
    assert migrated.provenance_status == :verified
    assert migrated.value.taint == label
    assert item(migrated, :recent_thoughts, legacy_thought.id).value.taint == label
    assert [%{value: %{value: "legacy wrapper concern"}} = concern] = migrated.items.concerns
    assert concern.value.taint == label

    concern_id = concern.id
    assert {:ok, %Record{data: current_wrapper}} = durable_record(agent_id)
    assert current_wrapper["version"] == 2
    assert current_wrapper["payload"]["concern_ids"] == [concern_id]
    assert Map.has_key?(current_wrapper["provenance"]["concerns"], concern_id)

    clear_live_state(agent_id)
    assert {:ok, reloaded} = WorkingMemoryStore.load_working_memory_tainted(agent_id)
    assert Enum.map(reloaded.items.concerns, & &1.id) == [concern_id]
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
      assert :ok = replace_durable_data(agent_id, corrupt, label)

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

  test "missing outer metadata preserves hostile inner envelopes conservatively", %{
    agent_id: agent_id
  } do
    trusted = taint(:trusted, "inner-base", sensitivity: :public, sanitizations: 0b111)
    hostile = taint(:hostile, "inner-hostile", sensitivity: :restricted, sanitizations: 0b011)
    wm = new_working_memory(agent_id)
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, trusted)

    hostile_thought = thought("inner-hostile-thought", "hostile inner payload")
    wm = %{wm | recent_thoughts: [hostile_thought]}
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, hostile)
    assert {:ok, %Record{data: wrapper}} = durable_record(agent_id)

    assert :ok = replace_durable_data(agent_id, wrapper, :missing_outer)
    clear_live_state(agent_id)

    assert {:ok, restored} = WorkingMemoryStore.load_working_memory_tainted(agent_id)
    assert restored.provenance_status == :legacy_unlabeled
    assert restored.value.taint.level == :hostile
    assert restored.value.taint.sensitivity == :restricted

    restored_thought = item(restored, :recent_thoughts, hostile_thought.id)
    assert restored_thought.provenance_status == :legacy_unlabeled
    assert restored_thought.value.taint.level == :hostile
    assert restored_thought.value.taint.sensitivity == :restricted
    assert restored_thought.value.taint.sanitizations == 0

    assert {:ok, %Record{metadata: %{"taint" => _outer}}} = durable_record(agent_id)
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

    base_payload =
      Map.drop(payload, [
        "recent_thoughts",
        "active_goals",
        "active_skills",
        "concerns",
        "concern_ids",
        "curiosity",
        "curiosity_ids"
      ])

    thought_payload = serialize_item(wm, :recent_thoughts, thought.id)

    :ets.delete(@working_memory_ets, agent_id)
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

  test "security regression: durable delete evicts raw projection when sidecar cleanup fails", %{
    agent_id: agent_id
  } do
    label = taint(:hostile, "delete-projection", sensitivity: :restricted)
    wm = %{new_working_memory(agent_id) | concerns: ["must be deleted"]}

    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, wm, label)

    assert %WorkingMemory{concerns: ["must be deleted"]} =
             WorkingMemoryStore.get_working_memory(agent_id)

    provenance_pid = Process.whereis(Provenance)
    assert is_pid(provenance_pid)
    assert Process.unregister(Provenance)

    failing_owner = spawn(fn -> failing_provenance_owner() end)
    failing_monitor = Process.monitor(failing_owner)
    assert Process.register(failing_owner, Provenance)

    try do
      assert :ok = WorkingMemoryStore.delete_working_memory(agent_id)

      assert WorkingMemoryStore.get_working_memory(agent_id) == nil

      assert {:error, :not_found} =
               MemoryStore.load_tainted_authoritative_with_status("working_memory", agent_id)
    after
      if Process.whereis(Provenance) == failing_owner do
        Process.unregister(Provenance)
      end

      Process.exit(failing_owner, :kill)
      assert_receive {:DOWN, ^failing_monitor, :process, ^failing_owner, _reason}, 1_000

      if Process.alive?(provenance_pid) and Process.whereis(Provenance) == nil do
        Process.register(provenance_pid, Provenance)
      end
    end

    assert {:error, {:working_memory_store, :not_found}} =
             WorkingMemoryStore.get_working_memory_tainted(agent_id)

    for domain <- working_memory_domains() do
      assert {:ok, []} = Provenance.list_item_ids(domain, agent_id)
    end
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
    candidate = %{
      new_working_memory(agent_id)
      | recent_thoughts: [thought("unavailable-thought", "must not install")]
    }

    stop_supervised!(BufferedStore)
    assert Process.whereis(@store_name) == nil

    assert {:error, {:working_memory_store, :durable_unavailable}} =
             WorkingMemoryStore.load_working_memory_tainted(agent_id)

    assert {:error, {:working_memory_store, :durable_unavailable}} =
             WorkingMemoryStore.save_working_memory(agent_id, candidate)

    transient = WorkingMemoryStore.load_working_memory(agent_id, rebuild_from_signals: false)
    assert transient.agent_id == agent_id
    assert WorkingMemoryStore.get_working_memory(agent_id) == nil

    assert_missing(
      Provenance.resolve(
        :working_memory_thought,
        agent_id,
        "unavailable-thought",
        serialize_item(candidate, :recent_thoughts, "unavailable-thought")
      )
    )

    assert_missing(
      Provenance.resolve(
        :working_memory_aggregate,
        agent_id,
        "aggregate",
        WorkingMemory.serialize(transient)
      )
    )
  end

  test "security regression: insufficient configured durability cannot mutate raw projection", %{
    agent_id: agent_id
  } do
    stop_supervised!(BufferedStore)
    backend_name = unique_name(:wm_insufficient_backend)
    start_supervised!({Arbor.Persistence.QueryableStore.ETS, name: backend_name})

    start_supervised!(
      {BufferedStore,
       name: @store_name, backend: Arbor.Persistence.QueryableStore.ETS, collection: backend_name}
    )

    candidate = %{
      new_working_memory(agent_id)
      | recent_thoughts: [thought("insufficient-thought", "must not install")]
    }

    assert {:error, {:working_memory_store, :insufficient_durability}} =
             WorkingMemoryStore.save_working_memory(agent_id, candidate)

    transient = WorkingMemoryStore.load_working_memory(agent_id, rebuild_from_signals: false)
    assert transient.agent_id == agent_id
    assert WorkingMemoryStore.get_working_memory(agent_id) == nil

    assert {:error, :not_found} =
             Arbor.Persistence.QueryableStore.ETS.get(
               "working_memory:#{agent_id}",
               name: backend_name
             )

    assert_missing(
      Provenance.resolve(
        :working_memory_thought,
        agent_id,
        "insufficient-thought",
        serialize_item(candidate, :recent_thoughts, "insufficient-thought")
      )
    )
  end

  test "security regression: backend failure cannot acknowledge or project a hostile save", %{
    agent_id: agent_id
  } do
    stop_supervised!(BufferedStore)
    backend_name = unique_name(:wm_restart_backend)
    control = unique_name(:wm_restart_control)

    start_supervised!({Arbor.Persistence.QueryableStore.ETS, name: backend_name})

    start_supervised!(%{
      id: control,
      start: {Agent, :start_link, [fn -> true end, [name: control]]}
    })

    store_spec =
      {BufferedStore,
       name: @store_name,
       backend: SwitchableNodeRestartBackend,
       backend_opts: [control: control],
       collection: backend_name,
       write_mode: :async,
       ack_mode: :cache}

    start_supervised!(store_spec)

    trusted = taint(:trusted, "durable-trusted", sensitivity: :public)
    hostile = taint(:hostile, "failed-hostile", sensitivity: :restricted)
    original = thought("restart-thought", "trusted durable content")
    baseline = %{new_working_memory(agent_id) | recent_thoughts: [original]}

    assert :ok = WorkingMemoryStore.save_working_memory_tainted(agent_id, baseline, trusted)
    assert [{^agent_id, before_ets}] = :ets.lookup(@working_memory_ets, agent_id)

    Agent.update(control, fn _ -> false end)
    changed = %{baseline | recent_thoughts: [%{original | content: "hostile update"}]}

    assert {:error, {:working_memory_store, :durable_unavailable}} =
             WorkingMemoryStore.save_working_memory_tainted(agent_id, changed, hostile)

    assert [{^agent_id, ^before_ets}] = :ets.lookup(@working_memory_ets, agent_id)

    assert {:ok, ^trusted, :verified} =
             Provenance.resolve(
               :working_memory_thought,
               agent_id,
               original.id,
               serialize_item(baseline, :recent_thoughts, original.id)
             )

    assert_invalid(
      Provenance.resolve(
        :working_memory_thought,
        agent_id,
        original.id,
        serialize_item(changed, :recent_thoughts, original.id)
      )
    )

    assert {:ok, %Record{data: retained_wrapper}} =
             Arbor.Persistence.QueryableStore.ETS.get(
               "working_memory:#{agent_id}",
               name: backend_name
             )

    assert retained_wrapper["payload"] == WorkingMemory.serialize(baseline)

    stop_supervised!(BufferedStore)
    restart_provenance()
    Agent.update(control, fn _ -> true end)
    start_supervised!(store_spec)
    :ets.delete(@working_memory_ets, agent_id)

    assert {:ok, restored} = WorkingMemoryStore.load_working_memory_tainted(agent_id)
    assert restored.value.taint == trusted
    assert restored.value.value.recent_thoughts == [original]
    assert item(restored, :recent_thoughts, original.id).value.taint == trusted
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
    read.items.recent_thoughts ++
      read.items.active_goals ++
      read.items.active_skills ++ read.items.concerns ++ read.items.curiosity
  end

  defp item_ids(read) do
    %{
      thoughts: Enum.map(read.items.recent_thoughts, & &1.id),
      goals: Enum.map(read.items.active_goals, & &1.id),
      skills: Enum.map(read.items.active_skills, & &1.id),
      concerns: Enum.map(read.items.concerns, & &1.id),
      curiosity: Enum.map(read.items.curiosity, & &1.id)
    }
  end

  defp serialize_item(wm, field, id) do
    serialized = WorkingMemory.serialize(wm)

    case field do
      :concerns -> serialize_scalar_item(serialized, "concerns", "concern_ids", id)
      :curiosity -> serialize_scalar_item(serialized, "curiosity", "curiosity_ids", id)
      _ -> Enum.find(serialized[Atom.to_string(field)], &(&1["id"] == id))
    end
  end

  defp serialize_scalar_item(serialized, value_key, id_key, id) do
    index = Enum.find_index(serialized[id_key], &(&1 == id))
    %{"id" => id, "value" => Enum.at(serialized[value_key], index)}
  end

  defp durable_entry(payload, taint) do
    assert {:ok, envelope} = TaintEnvelope.new(payload, taint)
    assert {:ok, persisted} = TaintEnvelope.to_map(envelope)
    %{"envelope" => persisted, "status" => "verified"}
  end

  defp durable_record(agent_id) do
    BufferedStore.get("working_memory:#{agent_id}", name: @store_name)
  end

  defp replace_durable_data(agent_id, data, outer_taint) do
    assert {:ok, _value, _status, %Record{} = current, :namespaced} =
             MemoryStore.load_tainted_authoritative_with_status("working_memory", agent_id)

    opts =
      case outer_taint do
        :missing_outer ->
          []

        %Taint{} = taint ->
          [taint: taint]
      end

    assert {:ok, %Record{}} =
             MemoryStore.compare_and_swap_tainted(
               "working_memory",
               agent_id,
               current,
               data,
               opts
             )

    :ok
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

  defp run_concurrently(functions) do
    parent = self()

    tasks =
      Enum.map(functions, fn function ->
        Task.async(fn ->
          send(parent, {:concurrent_ready, self()})

          receive do
            :concurrent_go -> function.()
          end
        end)
      end)

    pids =
      Enum.map(tasks, fn _task ->
        assert_receive {:concurrent_ready, pid}, 2_000
        pid
      end)

    Enum.each(pids, &send(&1, :concurrent_go))
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  defp failing_provenance_owner do
    receive do
      {:"$gen_call", from, _request} ->
        GenServer.reply(from, {:error, :forced_sidecar_failure})
        failing_provenance_owner()
    end
  end

  defp working_memory_domains do
    [
      :working_memory_base,
      :working_memory_aggregate,
      :working_memory_thought,
      :working_memory_goal,
      :working_memory_skill,
      :working_memory_concern,
      :working_memory_curiosity
    ]
  end

  defp sidecar_inventory(agent_id) do
    Map.new(working_memory_domains(), fn domain ->
      assert {:ok, ids} = Provenance.list_item_ids(domain, agent_id)
      {domain, ids}
    end)
  end

  defp unique_name(prefix) do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
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
