defmodule Arbor.Orchestrator.JobRegistryTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.JobRegistry
  alias Arbor.Orchestrator.JobRegistry.Entry

  @store_name :arbor_orchestrator_jobs

  setup do
    # Clear the store
    case Arbor.Persistence.BufferedStore.list(name: @store_name) do
      {:ok, keys} ->
        Enum.each(keys, fn key ->
          Arbor.Persistence.BufferedStore.delete(key, name: @store_name)
        end)

      _ ->
        :ok
    end

    :ok
  end

  # Helper to insert an entry directly into the BufferedStore
  defp insert_entry(run_id, attrs \\ %{}) do
    entry = %Entry{
      pipeline_id: Map.get(attrs, :pipeline_id, run_id),
      run_id: run_id,
      graph_id: Map.get(attrs, :graph_id, "test_pipeline"),
      graph_hash: Map.get(attrs, :graph_hash),
      dot_source_path: Map.get(attrs, :dot_source_path),
      logs_root: Map.get(attrs, :logs_root),
      started_at: Map.get(attrs, :started_at, DateTime.utc_now()),
      current_node: Map.get(attrs, :current_node),
      completed_count: Map.get(attrs, :completed_count, 0),
      total_nodes: Map.get(attrs, :total_nodes, 3),
      status: Map.get(attrs, :status, :running),
      node_durations: Map.get(attrs, :node_durations, %{}),
      finished_at: Map.get(attrs, :finished_at),
      duration_ms: Map.get(attrs, :duration_ms),
      failure_reason: Map.get(attrs, :failure_reason),
      source_node: Map.get(attrs, :source_node, node()),
      owner_node: Map.get(attrs, :owner_node, node()),
      origin_trust_zone: Map.get(attrs, :origin_trust_zone, 0),
      last_heartbeat: Map.get(attrs, :last_heartbeat, DateTime.utc_now()),
      spawning_pid: Map.get(attrs, :spawning_pid)
    }

    Arbor.Persistence.BufferedStore.put(run_id, entry, name: @store_name)
    entry
  end

  describe "query API" do
    test "list_active returns running entries" do
      insert_entry("run_active_1", %{status: :running})
      insert_entry("run_done_1", %{status: :completed})

      active = JobRegistry.list_active()
      assert length(active) == 1
      assert hd(active).run_id == "run_active_1"
    end

    test "list_recent returns completed/failed entries newest first" do
      insert_entry("run_old", %{
        status: :completed,
        finished_at: ~U[2026-01-01 00:00:00Z]
      })

      insert_entry("run_new", %{
        status: :completed,
        finished_at: ~U[2026-04-01 00:00:00Z]
      })

      recent = JobRegistry.list_recent(10)
      assert length(recent) == 2
      assert hd(recent).run_id == "run_new"
    end

    test "get returns entry by id" do
      insert_entry("run_get_1", %{graph_id: "specific_pipeline"})

      entry = JobRegistry.get("run_get_1")
      assert entry != nil
      assert entry.graph_id == "specific_pipeline"
      assert entry.status == :running
    end

    test "get returns nil for unknown id" do
      assert JobRegistry.get("nonexistent_pipeline_12345") == nil
    end

    test "list_interrupted returns interrupted entries" do
      insert_entry("run_int_1", %{status: :interrupted})
      insert_entry("run_run_1", %{status: :running})

      interrupted = JobRegistry.list_interrupted()
      assert length(interrupted) == 1
      assert hd(interrupted).run_id == "run_int_1"
    end
  end

  describe "recovery status management" do
    test "mark_interrupted changes status" do
      insert_entry("run_interrupt_1")

      assert JobRegistry.get("run_interrupt_1").status == :running

      JobRegistry.mark_interrupted("run_interrupt_1")

      entry = JobRegistry.get("run_interrupt_1")
      assert entry.status == :interrupted
      assert [entry] == JobRegistry.list_interrupted()
    end

    test "mark_abandoned changes status" do
      insert_entry("run_abandon_1")

      JobRegistry.mark_abandoned("run_abandon_1")

      entry = JobRegistry.get("run_abandon_1")
      assert entry.status == :abandoned
      assert entry.finished_at != nil
    end

    test "mark_recovering changes status" do
      insert_entry("run_recover_1")

      JobRegistry.mark_recovering("run_recover_1")

      entry = JobRegistry.get("run_recover_1")
      assert entry.status == :recovering
    end
  end

  describe "distributed pipeline fields" do
    test "touch_heartbeat updates the heartbeat timestamp" do
      insert_entry("run_hb_1", %{last_heartbeat: ~U[2026-01-01 00:00:00Z]})

      original = JobRegistry.get("run_hb_1").last_heartbeat

      JobRegistry.touch_heartbeat("run_hb_1")
      Process.sleep(10)

      updated = JobRegistry.get("run_hb_1").last_heartbeat
      assert DateTime.compare(updated, original) == :gt
    end

    test "list_stale_heartbeats finds pipelines with old heartbeats" do
      insert_entry("run_stale_1")

      # With a very small max_age, the heartbeat should be considered stale
      stale = JobRegistry.list_stale_heartbeats(0)
      assert length(stale) >= 1
      assert Enum.any?(stale, fn e -> e.run_id == "run_stale_1" end)

      # With a large max_age, nothing should be stale
      not_stale = JobRegistry.list_stale_heartbeats(999_999_999)
      assert not Enum.any?(not_stale, fn e -> e.run_id == "run_stale_1" end)
    end

    test "list_stale_heartbeats/2 accepts explicit now for deterministic staleness" do
      fixed_now = ~U[2026-05-21 12:00:00Z]

      # Entry with a heartbeat from well before fixed_now
      insert_entry("run_explicit_stale", %{
        last_heartbeat: ~U[2026-05-21 11:00:00Z],
        status: :running
      })

      # Using a cutoff of 30 minutes with our fixed_now → should be stale
      stale = JobRegistry.list_stale_heartbeats(30 * 60 * 1000, fixed_now)
      assert Enum.any?(stale, fn e -> e.run_id == "run_explicit_stale" end)

      # Using a very large cutoff with the same fixed_now → should not be stale
      not_stale = JobRegistry.list_stale_heartbeats(999_999_999, fixed_now)
      assert not Enum.any?(not_stale, fn e -> e.run_id == "run_explicit_stale" end)

      # Prove that changing `now` changes the result (determinism)
      future_now = ~U[2026-05-22 12:00:00Z]
      still_stale_in_future = JobRegistry.list_stale_heartbeats(30 * 60 * 1000, future_now)
      assert Enum.any?(still_stale_in_future, fn e -> e.run_id == "run_explicit_stale" end)
    end

    test "list_by_owner finds pipelines owned by a specific node" do
      insert_entry("run_owner_1", %{owner_node: node()})

      owned = JobRegistry.list_by_owner(node())
      assert length(owned) >= 1
      assert Enum.any?(owned, fn e -> e.run_id == "run_owner_1" end)

      # No pipelines owned by a fake node
      none = JobRegistry.list_by_owner(:fake@node)
      assert none == []
    end

    test "claim_for_recovery succeeds on interrupted pipeline" do
      insert_entry("run_claim_1")
      JobRegistry.mark_interrupted("run_claim_1")

      assert {:ok, claimed} = JobRegistry.claim_for_recovery("run_claim_1")
      assert claimed.status == :recovering
      assert claimed.owner_node == node()
    end

    test "claim_for_recovery fails on running pipeline" do
      insert_entry("run_claim_fail_1")

      assert {:error, {:invalid_status, :running}} =
               JobRegistry.claim_for_recovery("run_claim_fail_1")
    end

    test "claim_for_recovery fails on already-claimed pipeline" do
      insert_entry("run_double_1")
      JobRegistry.mark_interrupted("run_double_1")

      # First claim succeeds
      assert {:ok, _} = JobRegistry.claim_for_recovery("run_double_1", :other@node)

      # Second claim by a different node fails (status is now :recovering)
      assert {:error, {:invalid_status, :recovering}} =
               JobRegistry.claim_for_recovery("run_double_1", :third@node)
    end

    test "claim_for_recovery returns not_found for unknown pipeline" do
      assert {:error, :not_found} = JobRegistry.claim_for_recovery("nonexistent_run")
    end
  end

  describe "parse_node_name atom safety (H9 regression)" do
    test "security regression (H9): unknown owner_node strings do not create new atoms" do
      # H9: an attacker who can write to the persistence backend used to be able
      # to inject arbitrary owner_node strings, which the old rescue→String.to_atom
      # path would convert into new atoms, exhausting the BEAM atom table.
      # The fix routes through SafeAtom.to_existing/1 and falls back to nil.
      unique_unknown =
        "h9_node_#{:erlang.unique_integer([:positive])}@nope_#{:erlang.unique_integer([:positive])}"

      raw_map = %{
        "pipeline_id" => "h9_run_1",
        "run_id" => "h9_run_1",
        "graph_id" => "h9_graph",
        "status" => "interrupted",
        "owner_node" => unique_unknown,
        "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "last_heartbeat" => DateTime.to_iso8601(DateTime.utc_now()),
        "total_nodes" => 1,
        "completed_count" => 0,
        "node_durations" => %{},
        "origin_trust_zone" => 0
      }

      Arbor.Persistence.BufferedStore.put("h9_run_1", raw_map, name: @store_name)
      entry = JobRegistry.get("h9_run_1")

      assert %Entry{} = entry

      assert is_nil(entry.owner_node),
             "Unknown owner_node string must resolve to nil — H9 regression. " <>
               "Got: #{inspect(entry.owner_node)}"

      # The specific unknown string must NOT have been added to the atom table.
      # If String.to_existing_atom succeeds, the fix is bypassed and the bug
      # would let an attacker exhaust the atom table via persisted records.
      assert_raise ArgumentError, fn -> String.to_existing_atom(unique_unknown) end
    end
  end
end
