defmodule Arbor.Orchestrator.RunLifecycleEffectEnvelopeTest.ControllableStore do
  @moduledoc false
  use GenServer

  def durability_class(_opts), do: :process_lifetime

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def put(key, value, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:put, key, value})
  end

  def get(key, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:get, key})
  end

  def list(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, :list)
  end

  def delete(key, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:delete, key})
  end

  def set_fail(name, fail?), do: GenServer.call(name, {:set_fail, fail?})

  @impl true
  def init(_opts), do: {:ok, %{data: %{}, fail?: false}}

  @impl true
  def handle_call({:set_fail, fail?}, _from, state), do: {:reply, :ok, %{state | fail?: fail?}}

  def handle_call({:put, _key, _value}, _from, %{fail?: true} = state) do
    {:reply, {:error, :injected_write_failure}, state}
  end

  def handle_call({:put, key, value}, _from, state) do
    {:reply, :ok, %{state | data: Map.put(state.data, key, value)}}
  end

  def handle_call({:get, key}, _from, state) do
    case Map.fetch(state.data, key) do
      {:ok, v} -> {:reply, {:ok, v}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, %{fail?: true} = state) do
    {:reply, {:error, :injected_list_failure}, state}
  end

  def handle_call(:list, _from, state), do: {:reply, {:ok, Map.keys(state.data)}, state}

  def handle_call({:delete, _key}, _from, %{fail?: true} = state) do
    {:reply, {:error, :injected_delete_failure}, state}
  end

  def handle_call({:delete, key}, _from, state) do
    {:reply, :ok, %{state | data: Map.delete(state.data, key)}}
  end
end

defmodule Arbor.Orchestrator.RunLifecycleEffectEnvelopeTest do
  @moduledoc """
  L3A: pure effect-envelope bounds/schema, durable roundtrip, journal owner
  APIs (prepare/record/settle), preservation, compaction, and reload fail-closed.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.RunJournal
  alias Arbor.Orchestrator.RunLifecycle.Adapter
  alias Arbor.Orchestrator.RunLifecycle.EffectEnvelope
  alias Arbor.Orchestrator.RunLifecycle.Record
  alias Arbor.Orchestrator.RunState.Core, as: RunState
  alias Arbor.Persistence.Store.ETS, as: StoreETS
  alias Arbor.Contracts.Persistence.Record, as: PersistenceRecord
  alias Arbor.Orchestrator.RunLifecycleEffectEnvelopeTest.ControllableStore

  @hash_a String.duplicate("a", 64)
  @hash_b String.duplicate("b", 64)
  @hash_c String.duplicate("c", 64)
  @started_at "2026-07-15T12:00:00.000000Z"
  @completed_at "2026-07-15T12:00:01.000000Z"

  # ---------------------------------------------------------------------------
  # Pure envelope schema / bounds
  # ---------------------------------------------------------------------------

  describe "EffectEnvelope pure schema" do
    test "table-driven pending construction and rejection" do
      base = pending_attrs(generation: 1)

      cases = [
        {:ok, base},
        {:error, Map.put(base, "schema_version", 2), :invalid_schema_version},
        {:error, Map.put(base, "generation", 0), :invalid_generation},
        {:error, Map.put(base, "generation", EffectEnvelope.max_generation() + 1),
         :invalid_generation},
        {:error, Map.put(base, "input_hash", String.duplicate("A", 64)), :invalid_input_hash},
        {:error, Map.put(base, "input_hash", String.duplicate("a", 63)), :invalid_input_hash},
        {:error, Map.put(base, "idempotency_class", "maybe"), :invalid_idempotency_class},
        {:error, Map.put(base, "started_at", "not-a-date"), :invalid_started_at},
        {:error, Map.put(base, "run_id", ""), {:empty, :run_id}},
        {:error, Map.put(base, "handler", String.duplicate("h", 300)), {:oversized, :handler}},
        {:error, Map.put(base, "extra", "nope"), :unknown_keys},
        {:error, Map.merge(base, %{"run_id" => "x", run_id: "x"}), :atom_string_key_alias},
        {:error, Map.put(base, "completed_at", @completed_at), :unknown_keys}
      ]

      for entry <- cases do
        case entry do
          {:ok, attrs} ->
            assert {:ok, effect} = EffectEnvelope.new_pending(attrs)
            assert effect["status"] == "pending"
            assert effect["schema_version"] == 1
            assert effect["generation"] == 1
            assert is_map_key(effect, "completed_at") == false

          {:error, attrs, reason} ->
            assert {:error, ^reason} = EffectEnvelope.new_pending(attrs)
        end
      end
    end

    test "complete and settle preserve identity and reject wrong status" do
      assert {:ok, pending} = EffectEnvelope.new_pending(pending_attrs(generation: 2))

      assert {:ok, completed} =
               EffectEnvelope.complete(pending, %{
                 "completed_at" => @completed_at,
                 "outcome_status" => "success",
                 "result_digest" => @hash_b
               })

      assert completed["status"] == "completed"
      assert completed["generation"] == 2
      assert completed["input_hash"] == @hash_a
      assert completed["result_digest"] == @hash_b

      assert {:ok, settled} = EffectEnvelope.settle(completed)
      assert settled["status"] == "settled"
      assert settled["result_digest"] == @hash_b
      assert settled["outcome_status"] == "success"

      assert {:error, :status_mismatch} = EffectEnvelope.settle(pending)
      assert {:error, :status_mismatch} = EffectEnvelope.complete(completed, receipt_attrs())

      assert {:error, :invalid_outcome_status} =
               EffectEnvelope.complete(pending, Map.put(receipt_attrs(), "outcome_status", "ok"))
    end

    test "closed outcome statuses are accepted" do
      assert {:ok, pending} = EffectEnvelope.new_pending(pending_attrs(generation: 1))

      for outcome <- ["success", "partial_success", "retry", "fail", "skipped"] do
        assert {:ok, completed} =
                 EffectEnvelope.complete(
                   pending,
                   Map.put(receipt_attrs(), "outcome_status", outcome)
                 )

        assert completed["outcome_status"] == outcome
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Adapter durable roundtrip / public projection / compaction
  # ---------------------------------------------------------------------------

  describe "Adapter effect field preservation" do
    test "durable roundtrip and public projection retain effect evidence" do
      assert {:ok, pending} = EffectEnvelope.new_pending(pending_attrs(generation: 3))

      record = %Record{
        run_id: "run_effect_1",
        pipeline_id: "pipe_effect_1",
        status: :running,
        total_nodes: 2,
        completed_count: 1,
        completed_nodes: ["start"],
        started_at: DateTime.utc_now(),
        effect_generation: 3,
        current_effect: pending,
        graph_hash: "gh",
        logs_root: "/tmp/logs",
        execution_principal: "agent_abc"
      }

      assert {:ok, durable} = Adapter.to_durable_map(record)
      assert durable["effect_generation"] == 3
      assert durable["current_effect"]["status"] == "pending"
      assert durable["current_effect"]["generation"] == 3
      refute Map.has_key?(durable, "spawning_pid")

      rehydrated = Adapter.from_durable_map(durable)
      assert {:ok, validated} = Adapter.validate_and_normalize_record(rehydrated)
      assert validated.effect_generation == 3
      assert validated.current_effect["execution_id"] == pending["execution_id"]

      public = Adapter.to_public_map(validated)
      assert public.effect_generation == 3
      assert public.current_effect["status"] == "pending"
    end

    test "malformed current_effect is rejected by validation" do
      record = %Record{
        run_id: "bad_effect",
        pipeline_id: "bad_effect",
        status: :running,
        effect_generation: 1,
        current_effect: %{"status" => "pending", "generation" => 1}
      }

      assert {:error, {:invalid_current_effect, _}} =
               Adapter.validate_and_normalize_record(record)

      assert {:error, {:invalid_current_effect, :generation_mismatch}} =
               Adapter.validate_and_normalize_record(%Record{
                 run_id: "mismatch",
                 pipeline_id: "mismatch",
                 status: :running,
                 effect_generation: 2,
                 current_effect: elem(EffectEnvelope.new_pending(pending_attrs(generation: 1)), 1)
               })
    end

    test "minimal payload compaction retains effect evidence and fails closed if too large" do
      assert {:ok, pending} = EffectEnvelope.new_pending(pending_attrs(generation: 1))

      # Normal compact path keeps effect fields.
      record = %Record{
        run_id: "compact_ok",
        pipeline_id: "compact_ok",
        status: :running,
        total_nodes: 1,
        completed_count: 0,
        # Force compaction with large diagnostic fields.
        failure_reason: String.duplicate("x", 4000),
        node_durations: Map.new(for i <- 1..200, do: {"n#{i}", i}),
        completed_nodes: for(i <- 1..200, do: "node_#{i}"),
        effect_generation: 1,
        current_effect: pending,
        graph_hash: "hash",
        logs_root: "/tmp/l",
        execution_principal: "agent_x"
      }

      assert {:ok, durable} = Adapter.to_durable_map(record)
      assert durable["effect_generation"] == 1
      assert durable["current_effect"]["generation"] == 1
      assert durable["current_effect"]["input_hash"] == @hash_a

      # If identity + effect cannot fit the ceiling, fail closed (do not drop effect).
      huge_id = String.duplicate("r", 200)
      huge_path = String.duplicate("p", 900)

      assert {:ok, pending2} =
               EffectEnvelope.new_pending(
                 pending_attrs(generation: 1)
                 |> Map.put("run_id", huge_id)
                 |> Map.put("node_id", String.duplicate("n", 200))
                 |> Map.put("execution_id", String.duplicate("e", 200))
                 |> Map.put("handler", String.duplicate("h", 200))
               )

      oversized = %Record{
        run_id: huge_id,
        pipeline_id: huge_id,
        status: :running,
        graph_hash: String.duplicate("g", 100),
        dot_source_path: huge_path,
        logs_root: huge_path,
        execution_principal: String.duplicate("a", 200),
        owner_node: String.duplicate("o", 200),
        source_node: String.duplicate("s", 200),
        effect_generation: 1,
        current_effect: pending2,
        failure_reason: String.duplicate("f", 4000),
        node_durations: Map.new(for i <- 1..256, do: {String.duplicate("k#{i}", 20), i}),
        completed_nodes: for(i <- 1..256, do: String.duplicate("c#{i}", 20))
      }

      # May still fit within 8KiB after compact; if not, must be the effect-aware error.
      case Adapter.to_durable_map(oversized) do
        {:ok, durable2} ->
          assert durable2["current_effect"]["generation"] == 1
          assert durable2["effect_generation"] == 1

        {:error, {:durable_payload_exceeds_bound, :identity_or_effect_too_large}} ->
          :ok

        other ->
          flunk("unexpected durable result: #{inspect(other)}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Journal owner APIs
  # ---------------------------------------------------------------------------

  describe "RunJournal effect owner APIs" do
    setup do
      suffix = System.unique_integer([:positive, :monotonic])
      store_name = :"rj_effect_store_#{suffix}"
      journal_name = :"rj_effect_journal_#{suffix}"
      ets_table = :"rj_effect_hot_#{suffix}"
      run_id = "effect_run_#{suffix}"

      {:ok, _store} = start_supervised({StoreETS, name: store_name})

      {:ok, journal} =
        start_supervised(
          {RunJournal,
           name: journal_name,
           ets_table: ets_table,
           backend: StoreETS,
           store_name: store_name,
           start_store: false}
        )

      seed = %Record{
        run_id: run_id,
        pipeline_id: run_id,
        status: :running,
        total_nodes: 2,
        completed_count: 0,
        started_at: DateTime.utc_now(),
        owner_node: node(),
        source_node: node()
      }

      assert :ok = RunJournal.put(seed, server: journal_name)

      on_exit(fn ->
        try do
          GenServer.stop(journal, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok,
       journal_name: journal_name,
       store_name: store_name,
       ets_table: ets_table,
       run_id: run_id,
       journal: journal}
    end

    test "prepare → record → settle with exact idempotent retries", ctx do
      %{journal_name: j, run_id: run_id} = ctx
      attrs = prepare_attrs(run_id)

      assert {:ok, :prepared, effect1} = RunJournal.prepare_effect(run_id, attrs, server: j)
      assert effect1["status"] == "pending"
      assert effect1["generation"] == 1
      assert effect1["run_id"] == run_id

      # Exact retry — no write, same envelope
      assert {:ok, :already_prepared, effect1b} =
               RunJournal.prepare_effect(run_id, attrs, server: j)

      assert effect1b == effect1

      # Different pending attrs conflict
      bad_attrs = Map.put(attrs, "execution_id", "exec_other")

      assert {:error, {:effect_conflict, :pending}} =
               RunJournal.prepare_effect(run_id, bad_attrs, server: j)

      assert {:ok, still} = RunJournal.get_record(run_id, server: j)
      assert still.current_effect == effect1
      assert still.effect_generation == 1

      receipt = receipt_attrs()

      assert {:ok, :recorded, completed} =
               RunJournal.record_effect_receipt(run_id, 1, "exec_1", receipt, server: j)

      assert completed["status"] == "completed"
      assert completed["result_digest"] == @hash_b

      assert {:ok, :already_recorded, completed2} =
               RunJournal.record_effect_receipt(run_id, 1, "exec_1", receipt, server: j)

      assert completed2 == completed

      # Stale generation / different receipt conflicts without mutation
      assert {:error, {:effect_conflict, :completed}} =
               RunJournal.record_effect_receipt(
                 run_id,
                 1,
                 "exec_1",
                 Map.put(receipt, "result_digest", @hash_c),
                 server: j
               )

      assert {:error, {:effect_conflict, :completed}} =
               RunJournal.record_effect_receipt(run_id, 9, "exec_1", receipt, server: j)

      assert {:ok, still_completed} = RunJournal.get_record(run_id, server: j)
      assert still_completed.current_effect == completed

      assert {:ok, :settled, settled} = RunJournal.settle_effect(run_id, 1, "exec_1", server: j)
      assert settled["status"] == "settled"
      assert settled["result_digest"] == @hash_b

      assert {:ok, :already_settled, settled2} =
               RunJournal.settle_effect(run_id, 1, "exec_1", server: j)

      assert settled2 == settled

      # Later prepare replaces settled and increments generation
      attrs2 = Map.put(attrs, "execution_id", "exec_2")
      assert {:ok, :prepared, effect2} = RunJournal.prepare_effect(run_id, attrs2, server: j)
      assert effect2["generation"] == 2
      assert effect2["execution_id"] == "exec_2"

      assert {:ok, rec} = RunJournal.get_record(run_id, server: j)
      assert rec.effect_generation == 2
      assert rec.current_effect["status"] == "pending"
    end

    test "backend-first failure leaves hot effect state unchanged" do
      suffix = System.unique_integer([:positive, :monotonic])
      store_name = :"rj_eff_fail_store_#{suffix}"
      journal_name = :"rj_eff_fail_journal_#{suffix}"
      ets_table = :"rj_eff_fail_hot_#{suffix}"
      run_id = "eff_fail_#{suffix}"

      {:ok, _} = start_supervised({ControllableStore, name: store_name})

      {:ok, _} =
        start_supervised(
          {RunJournal,
           name: journal_name,
           ets_table: ets_table,
           backend: ControllableStore,
           store_name: store_name,
           start_store: false}
        )

      seed = %Record{
        run_id: run_id,
        pipeline_id: run_id,
        status: :running,
        total_nodes: 1,
        completed_count: 0,
        started_at: DateTime.utc_now(),
        source_node: node()
      }

      assert :ok = RunJournal.put(seed, server: journal_name)

      attrs = prepare_attrs(run_id)

      assert {:ok, :prepared, prepared} =
               RunJournal.prepare_effect(run_id, attrs, server: journal_name)

      :ok = ControllableStore.set_fail(store_name, true)

      receipt = receipt_attrs()

      assert {:error, {:durable_write_failed, :injected_write_failure}} =
               RunJournal.record_effect_receipt(
                 run_id,
                 1,
                 "exec_1",
                 receipt,
                 server: journal_name
               )

      assert {:ok, after_fail} = RunJournal.get_record(run_id, server: journal_name)
      assert after_fail.current_effect == prepared
      assert after_fail.current_effect["status"] == "pending"
      assert after_fail.effect_generation == 1
    end

    test "preservation across put_run_state and finalize", ctx do
      %{journal_name: j, run_id: run_id} = ctx
      attrs = prepare_attrs(run_id)

      assert {:ok, :prepared, effect} = RunJournal.prepare_effect(run_id, attrs, server: j)

      state = %RunState{
        run_id: run_id,
        pipeline_id: run_id,
        graph_id: "g1",
        status: :running,
        total_nodes: 4,
        completed_count: 2,
        current_node: "work",
        completed_nodes: ["start", "work"],
        node_durations: %{"start" => 1},
        started_at: DateTime.utc_now(),
        last_heartbeat: DateTime.utc_now(),
        owner_node: node()
      }

      assert :ok = RunJournal.put_run_state(state, %{logs_root: "/tmp/x"}, server: j)
      assert {:ok, mid} = RunJournal.get_record(run_id, server: j)
      assert mid.completed_count == 2
      assert mid.effect_generation == 1
      assert mid.current_effect == effect

      assert {:ok, :transitioned, final} =
               RunJournal.finalize(run_id, :completed, nil, 10, %{}, server: j)

      assert final.status == :completed
      assert final.effect_generation == 1
      assert final.current_effect == effect
    end

    test "durable restart rehydrates effect evidence", ctx do
      %{
        journal_name: journal_name,
        store_name: store_name,
        ets_table: ets_table,
        run_id: run_id
      } = ctx

      attrs = prepare_attrs(run_id)

      assert {:ok, :prepared, prepared} =
               RunJournal.prepare_effect(run_id, attrs, server: journal_name)

      assert {:ok, :recorded, completed} =
               RunJournal.record_effect_receipt(
                 run_id,
                 1,
                 "exec_1",
                 receipt_attrs(),
                 server: journal_name
               )

      :ok = stop_supervised(journal_name)
      assert :ets.info(ets_table) == :undefined

      {:ok, _} =
        start_supervised(
          {RunJournal,
           name: journal_name,
           ets_table: ets_table,
           backend: StoreETS,
           store_name: store_name,
           start_store: false}
        )

      assert {:ok, reloaded} = RunJournal.get_record(run_id, server: journal_name)
      assert reloaded.effect_generation == 1
      assert reloaded.current_effect["status"] == "completed"
      assert reloaded.current_effect["result_digest"] == completed["result_digest"]
      assert reloaded.current_effect["execution_id"] == prepared["execution_id"]
      # Boot-normalize may mark interrupted; effect evidence must survive.
      assert reloaded.status == :interrupted
    end

    test "generation ceiling fails closed", ctx do
      %{journal_name: j, run_id: run_id} = ctx
      max = EffectEnvelope.max_generation()

      assert {:ok, pending} =
               EffectEnvelope.new_pending(pending_attrs(generation: max, run_id: run_id))

      assert {:ok, completed} = EffectEnvelope.complete(pending, receipt_attrs())
      assert {:ok, settled} = EffectEnvelope.settle(completed)

      # Settled at max generation — next prepare would exceed JSON-safe ceiling.
      ceiling = %Record{
        run_id: run_id,
        pipeline_id: run_id,
        status: :running,
        total_nodes: 1,
        completed_count: 0,
        started_at: DateTime.utc_now(),
        effect_generation: max,
        current_effect: settled,
        source_node: node()
      }

      assert :ok = RunJournal.put(ceiling, server: j)

      assert {:error, {:effect_generation_ceiling, ^max}} =
               RunJournal.prepare_effect(run_id, prepare_attrs(run_id), server: j)

      assert {:ok, still} = RunJournal.get_record(run_id, server: j)
      assert still.effect_generation == max
      assert still.current_effect["status"] == "settled"
      assert still.current_effect["generation"] == max
    end

    test "malformed durable effect rejects journal startup", ctx do
      %{store_name: store_name, run_id: run_id} = ctx
      suffix = System.unique_integer([:positive, :monotonic])
      bad_journal = :"rj_bad_effect_#{suffix}"
      bad_table = :"rj_bad_effect_hot_#{suffix}"

      # Seed backend with identity + corrupt current_effect (missing required fields).
      corrupt = %{
        "run_id" => run_id <> "_corrupt",
        "pipeline_id" => run_id <> "_corrupt",
        "status" => "running",
        "total_nodes" => 0,
        "completed_count" => 0,
        "completed_nodes" => [],
        "current_node" => nil,
        "node_durations" => %{},
        "started_at" => nil,
        "finished_at" => nil,
        "duration_ms" => nil,
        "failure_reason" => nil,
        "owner_node" => nil,
        "source_node" => nil,
        "origin_trust_zone" => nil,
        "last_heartbeat" => nil,
        "last_ets_sync" => nil,
        "graph_hash" => nil,
        "dot_source_path" => nil,
        "logs_root" => nil,
        "execution_principal" => nil,
        "effect_generation" => 1,
        "current_effect" => %{
          "status" => "pending",
          "generation" => 1,
          "run_id" => run_id <> "_corrupt"
        }
      }

      persistence_record =
        PersistenceRecord.new(run_id <> "_corrupt", corrupt,
          metadata: %{"collection" => "pipeline_run_lifecycle"}
        )

      assert :ok =
               Arbor.Persistence.put(
                 store_name,
                 StoreETS,
                 run_id <> "_corrupt",
                 persistence_record,
                 []
               )

      result =
        start_supervised(
          {RunJournal,
           name: bad_journal,
           ets_table: bad_table,
           backend: StoreETS,
           store_name: store_name,
           start_store: false}
        )

      assert {:error, reason} = result
      reason_str = inspect(reason)

      assert reason_str =~ "durable_rehydrate_invalid_effect" or
               reason_str =~ "durable_rehydrate_failed" or
               reason_str =~ "invalid_current_effect"
    end

    test "missing run and malformed attrs fail closed", ctx do
      %{journal_name: j} = ctx

      assert {:error, :not_found} =
               RunJournal.prepare_effect("missing_run", prepare_attrs("missing_run"), server: j)

      %{run_id: run_id} = ctx

      assert {:error, {:invalid_effect_attrs, _}} =
               RunJournal.prepare_effect(
                 run_id,
                 Map.put(prepare_attrs(run_id), "input_hash", "nope"),
                 server: j
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp pending_attrs(opts) do
    generation = Keyword.get(opts, :generation, 1)
    run_id = Keyword.get(opts, :run_id, "run_1")

    %{
      "schema_version" => 1,
      "generation" => generation,
      "run_id" => run_id,
      "node_id" => "node_a",
      "execution_id" => "exec_1",
      "handler" => "Arbor.Orchestrator.Handlers.ExecHandler",
      "input_hash" => @hash_a,
      "idempotency_class" => "idempotent",
      "started_at" => @started_at
    }
  end

  defp prepare_attrs(run_id) do
    %{
      "node_id" => "node_a",
      "execution_id" => "exec_1",
      "handler" => "Arbor.Orchestrator.Handlers.ExecHandler",
      "input_hash" => @hash_a,
      "idempotency_class" => "idempotent",
      "started_at" => @started_at,
      "run_id" => run_id
    }
  end

  defp receipt_attrs do
    %{
      "completed_at" => @completed_at,
      "outcome_status" => "success",
      "result_digest" => @hash_b
    }
  end
end
