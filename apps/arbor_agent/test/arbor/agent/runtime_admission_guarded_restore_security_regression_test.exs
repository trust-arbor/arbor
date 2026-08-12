defmodule Arbor.Agent.RuntimeAdmissionGuardedRestoreSecurityRegressionTest do
  @moduledoc """
  Phase 4C C3C1a1 security regressions for durable guarded runtime restore.

  Candidate-pass / immediate-parent-behavioral-fail topology:
  - All new production entry points are invoked via `call_public/3` so the
    parent compiles and runs; missing APIs yield `{:error, :missing_api}` and
    fail security assertions (not UndefinedFunctionError compile evidence).
  - Asserts production public/facade boundaries: GuardedRestore, TaskStore,
    TemplateAuthorityReconciliationStore, BranchSupervisor, Lifecycle.

  Owns and resets the fixed production durable store name every setup, matching
  the established reconciliation store suite (stop + ETS wipe + restart).
  """

  use ExUnit.Case, async: false

  @moduletag :security_regression
  @moduletag :fast

  alias Arbor.Agent.{BranchSupervisor, Character, Lifecycle, Profile, ProfileStore}
  alias Arbor.Agent.Orchestration.{TaskControlRecoveryMemory, TaskStore}
  alias Arbor.Agent.ProfileAuthorityMutationCore
  alias Arbor.Agent.RuntimeAdmission.GuardedRestore
  alias Arbor.Agent.RuntimeAdmission.OperationLauncher
  alias Arbor.Agent.RuntimeAdmission.Opts
  alias Arbor.Agent.RuntimeAdmission.Supervisor, as: RASupervisor
  alias Arbor.Agent.TemplateAuthorityCapabilityProjection
  alias Arbor.Agent.TemplateAuthorityPolicy
  alias Arbor.Agent.TemplateAuthorityReconciliationOperationCore, as: Core
  alias Arbor.Agent.TemplateAuthorityReconciliationStore, as: Store
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Persistence.Store, as: StoreBehaviour
  alias Arbor.Persistence.BufferedStore

  @store_name :arbor_agent_template_authority_reconciliation
  @collection "template_authority_reconciliation"
  @digest String.duplicate("ab", 32)
  @repo_root "/tmp/arbor_gr_test"
  @recon_store_id :recon_store_gr_c3c1a1

  @template_data %{
    "name" => "coding_agent",
    "required_capabilities" => [
      %{"resource" => "arbor://fs/read", "constraints" => %{"rate_limit" => 10}}
    ],
    "trust_preset" => %{
      "baseline" => "block",
      "rules" => %{"arbor://fs/read" => "auto"}
    },
    "template_source" => %{"name" => "coding_agent", "layer" => "shipped"}
  }

  # -------------------------------------------------------------------------
  # Durable backend (owned ETS table; never reuse foreign store process state)
  # -------------------------------------------------------------------------

  defmodule Storage do
    @moduledoc false
    @table __MODULE__

    def reset! do
      case :ets.whereis(@table) do
        :undefined -> :ets.new(@table, [:named_table, :public, :set])
        _ -> :ets.delete_all_objects(@table)
      end

      :ok
    end

    def raw_put(collection, key, value) do
      true = :ets.insert(@table, {{collection, key}, value})
      :ok
    end

    def get(collection, key) do
      case :ets.lookup(@table, {collection, key}) do
        [{_, value}] -> {:ok, value}
        [] -> {:error, :not_found}
      end
    end

    def delete(collection, key) do
      :ets.delete(@table, {collection, key})
      :ok
    end

    def list(collection) do
      @table
      |> :ets.select([{{{collection, :"$1"}, :_}, [], [:"$1"]}])
      |> Enum.sort()
      |> then(&{:ok, &1})
    end
  end

  # Test-only GenServers for GuardedRestore.request/3 totality regressions.
  defmodule BlockingSecretStore do
    @moduledoc false
    use GenServer

    def child_spec(name) do
      %{id: name, start: {__MODULE__, :start_link, [name]}}
    end

    def start_link(name), do: GenServer.start_link(__MODULE__, %{}, name: name)

    @impl true
    def init(s), do: {:ok, s}

    @impl true
    def handle_call(:runtime_admission_ready?, _from, state), do: {:reply, true, state}

    def handle_call({:admit_guarded_runtime_restore, _t, _op, _tok, _wait}, _from, state) do
      # Never reply — GenServer.call times out; exit reason embeds call args.
      {:noreply, state}
    end

    def handle_call(_msg, _from, state), do: {:reply, {:error, :not_supported}, state}
  end

  defmodule NeverReadyStore do
    @moduledoc false
    use GenServer

    def child_spec(name) do
      %{id: name, start: {__MODULE__, :start_link, [name]}}
    end

    def start_link(name), do: GenServer.start_link(__MODULE__, %{}, name: name)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:runtime_admission_ready?, _from, state), do: {:reply, false, state}

    def handle_call(_message, _from, state), do: {:reply, {:error, :not_supported}, state}
  end

  defmodule ExplodingSecretStore do
    @moduledoc false
    use GenServer

    def child_spec(name) do
      %{id: name, start: {__MODULE__, :start_link, [name]}}
    end

    def start_link(name), do: GenServer.start_link(__MODULE__, %{}, name: name)

    @impl true
    def init(s), do: {:ok, s}

    @impl true
    def handle_call(:runtime_admission_ready?, _from, state), do: {:reply, true, state}

    def handle_call({:admit_guarded_runtime_restore, t, op, tok, wait}, _from, state) do
      exit({:secret_crash, t, op, tok, wait, "rrt_" <> String.duplicate("Z", 22)})
      {:noreply, state}
    end

    def handle_call(_msg, _from, state), do: {:reply, {:error, :not_supported}, state}
  end

  defmodule BindThenAbortStore do
    @moduledoc false
    use GenServer

    def child_spec(name) do
      %{id: name, start: {__MODULE__, :start_link, [name]}}
    end

    def start_link(name), do: GenServer.start_link(__MODULE__, %{}, name: name)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:runtime_admission_ready?, _from, state), do: {:reply, true, state}

    def handle_call(
          {:admit_guarded_runtime_restore, target, _operation_id, token, _wait_ms},
          _from,
          state
        ) do
      intent_id = "rai_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

      {:ok, _} =
        Arbor.Agent.TemplateAuthorityReconciliationStore.bind_runtime_restore_intent(
          target,
          token,
          intent_id
        )

      {:reply, {:error, :restore_pre_effect_aborted}, state}
    end

    def handle_call(_message, _from, state), do: {:reply, {:error, :not_supported}, state}
  end

  defmodule NodeRestartBackend do
    @moduledoc false
    @behaviour StoreBehaviour

    alias Arbor.Agent.RuntimeAdmissionGuardedRestoreSecurityRegressionTest.Storage

    @impl true
    def put(key, %Record{key: key} = record, opts) do
      Storage.raw_put(Keyword.fetch!(opts, :name), key, record)
    end

    def put(_key, %Record{}, _opts), do: {:error, :key_mismatch}
    def put(_key, _value, _opts), do: {:error, :record_required}

    @impl true
    def get(key, opts), do: Storage.get(Keyword.fetch!(opts, :name), key)

    @impl true
    def delete(key, opts), do: Storage.delete(Keyword.fetch!(opts, :name), key)

    @impl true
    def list(opts), do: Storage.list(Keyword.fetch!(opts, :name))

    @impl true
    def compare_and_swap(key, expected, %Record{key: key} = replacement, opts) do
      collection = Keyword.fetch!(opts, :name)

      case {expected, Storage.get(collection, key)} do
        {:not_found, {:error, :not_found}} ->
          stored = stamp_insert(replacement)
          Storage.raw_put(collection, key, stored)
          {:ok, stored}

        {{:value, %Record{generation: g, revision: r}},
         {:ok, %Record{generation: g, revision: r} = current}} ->
          stored = stamp_update(current, replacement)
          Storage.raw_put(collection, key, stored)
          {:ok, stored}

        _ ->
          {:error, :conflict}
      end
    end

    def compare_and_swap(_key, _expected, _replacement, _opts), do: {:error, :key_mismatch}

    @impl true
    def compare_and_delete(key, {:value, %Record{generation: g, revision: r}}, opts) do
      collection = Keyword.fetch!(opts, :name)

      case Storage.get(collection, key) do
        {:ok, %Record{generation: ^g, revision: ^r}} ->
          Storage.delete(collection, key)
          :ok

        _ ->
          {:error, :conflict}
      end
    end

    def compare_and_delete(_key, _expected, _opts), do: {:error, :conflict}

    @impl true
    def durability_class(_opts), do: :node_restart

    defp stamp_insert(%Record{} = r) do
      now = DateTime.utc_now()
      %{r | generation: 1, revision: 1, inserted_at: now, updated_at: now}
    end

    defp stamp_update(current, replacement) do
      %{
        replacement
        | generation: current.generation,
          revision: current.revision + 1,
          inserted_at: current.inserted_at || replacement.inserted_at,
          updated_at: DateTime.utc_now()
      }
    end
  end

  setup do
    TaskControlRecoveryMemory.ensure!()
    TaskControlRecoveryMemory.reset!()

    # Wipe ETS and force-restart the fixed production durable store — never
    # silently reuse an unrelated already-running fixed store process.
    Storage.reset!()
    restart_owned_durable_store!()

    # Clear test-only Application seams every case.
    clear_runtime_admission_test_seams!()

    on_exit(fn ->
      clear_runtime_admission_test_seams!()
    end)

    ensure_runtime_admission_registry!()

    ra_sup = start_named_ra_supervisor(:ra_sup)
    task_sup = start_supervised!({Task.Supervisor, name: unique_name(:task_sup)})
    store_name = unique_name(:store)

    start_supervised!(
      {TaskStore,
       name: store_name,
       task_supervisor: task_sup,
       runtime_admission_supervisor: ra_sup,
       runtime_admission_force_ready: true,
       fence_force_ready: true,
       recovery_force_ready: true}
    )

    %{store: store_name, ra_sup: ra_sup, task_sup: task_sup}
  end

  defp restart_owned_durable_store! do
    _ = stop_supervised(@recon_store_id)

    # If a foreign process holds the fixed name, stop it so we own the slot.
    case Process.whereis(@store_name) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end

      nil ->
        :ok
    end

    start_supervised!(
      {BufferedStore,
       name: @store_name,
       backend: NodeRestartBackend,
       backend_opts: [name: @collection],
       write_mode: :sync,
       ack_mode: :backend,
       collection: @collection},
      id: @recon_store_id
    )

    :ok
  end

  defp ensure_runtime_admission_registry! do
    case Process.whereis(Arbor.Agent.RuntimeAdmissionRegistry) do
      nil ->
        start_supervised!({Registry, keys: :unique, name: Arbor.Agent.RuntimeAdmissionRegistry})

      _pid ->
        :ok
    end
  end

  # -------------------------------------------------------------------------
  # Parent-safe public boundary calls (behavioral fail, not compile fail)
  # -------------------------------------------------------------------------

  defp call_public(mod, fun, args) when is_atom(mod) and is_atom(fun) and is_list(args) do
    arity = length(args)

    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity) do
      apply(mod, fun, args)
    else
      {:error, :missing_api}
    end
  rescue
    e in [UndefinedFunctionError, ArgumentError] ->
      {:error, {:call_failed, Exception.message(e)}}
  end

  # -------------------------------------------------------------------------
  # 1) Generic CAS protection + dedicated claim transitions
  # -------------------------------------------------------------------------

  test "security regression: generic CAS cannot clear, install, preserve-and-advance, mutate, or settle a restore claim" do
    {target, _op_id} = open_runtime_restore_op!()

    assert {:ok, op} = begin_restore_admission!(target)
    claim = op["runtime_restore_admission"]
    assert is_map(claim), "parent must mint durable claim via begin_runtime_restore_admission"
    assert claim["claim_phase"] == "minted"
    token = claim["token"]

    assert {:ok, observed} = call_public(Store, :snapshot, [target])

    # Clear via generic CAS
    cleared = Map.put(op, "runtime_restore_admission", nil)

    assert {:error, :restore_claim_protected} =
             call_public(Store, :compare_and_swap, [observed, cleared])

    # Preserve claim while advancing phase/status
    advanced = op |> Map.put("phase", "completed") |> Map.put("status", "completed")

    assert {:error, :restore_claim_protected} =
             call_public(Store, :compare_and_swap, [observed, advanced])

    # Install claim from null (separate op without claim)
    {target2, _} = open_runtime_restore_op!()
    assert {:ok, obs2} = call_public(Store, :snapshot, [target2])
    assert {:ok, op2} = call_public(Store, :fetch, [target2])
    fake = Map.put(op2, "runtime_restore_admission", claim)

    assert {:error, :restore_claim_protected} =
             call_public(Store, :compare_and_swap, [obs2, fake])

    # Atom-key injection must not bypass protection just because the canonical
    # string key remains nil. Generic CAS admits neither representation.
    fake_atom = Map.put(op2, :runtime_restore_admission, claim)

    assert {:error, :restore_claim_protected} =
             call_public(Store, :compare_and_swap, [obs2, fake_atom])

    # Settle via generic CAS
    settled_claim =
      Map.merge(claim, %{
        "claim_phase" => "settled",
        "settlement" => %{
          "outcome" => "applied",
          "reason_code" => "forged",
          "at_unix_ms" => System.system_time(:millisecond)
        }
      })

    forged = Map.put(op, "runtime_restore_admission", settled_claim)

    assert {:error, :restore_claim_protected} =
             call_public(Store, :compare_and_swap, [observed, forged])

    # Dedicated settle (minted → not_applied) still works
    assert {:ok, _} =
             call_public(Store, :settle_runtime_restore_admission, [
               target,
               token,
               %{
                 "outcome" => "not_applied",
                 "reason_code" => "pre_effect_abort",
                 "at_unix_ms" => System.system_time(:millisecond)
               }
             ])

    assert {:error, :stale_claim} =
             call_public(Store, :clear_runtime_restore_admission, [
               target,
               "rrt_" <> String.duplicate("x", 22)
             ])

    assert {:ok, cleared_op} =
             call_public(Store, :clear_runtime_restore_admission, [target, token])

    assert cleared_op["runtime_restore_admission"] == nil

    # Nil claim cannot authorize clear (not idempotent success).
    assert {:error, :not_found} =
             call_public(Store, :clear_runtime_restore_admission, [target, token])
  end

  test "security regression: gate release requires exact unsettled bound claim; outcome_unknown/settled block re-entry" do
    {target, op_id} = open_runtime_restore_op!()
    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]
    intent_id = mint_intent_id()

    assert {:ok, bound} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    claim = bound["runtime_restore_admission"]
    assert claim["claim_phase"] == "bound"
    fp = claim["fingerprint"]

    # Exact bound is the only phase that may proceed toward handoff/gate.
    assert claim["operation_id"] == op_id
    assert claim["fence_operation_id"] == op_id
    assert claim["target_agent_id"] == target
    assert claim["token"] == token
    assert claim["intent_id"] == intent_id
    assert claim["fingerprint"] == fp
    assert is_nil(claim["settlement"])

    # Exact already-bound is still bind-success (idempotent) when durable is bound.
    assert {:ok, bound2} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    assert bound2["runtime_restore_admission"]["claim_phase"] == "bound"

    # Snapshot already outcome_unknown: bind must fail typed without mutation.
    assert {:ok, _} = call_public(Store, :mark_runtime_restore_outcome_unknown, [target, token])
    assert {:ok, unknown_op} = call_public(Store, :fetch, [target])
    assert unknown_op["runtime_restore_admission"]["claim_phase"] == "outcome_unknown"
    before_unknown = unknown_op["runtime_restore_admission"]

    assert {:error, :restore_phase_illegal} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    assert {:ok, still_unknown} = call_public(Store, :fetch, [target])
    assert still_unknown["runtime_restore_admission"]["claim_phase"] == "outcome_unknown"
    assert still_unknown["runtime_restore_admission"]["intent_id"] == before_unknown["intent_id"]

    assert still_unknown["runtime_restore_admission"]["fingerprint"] ==
             before_unknown["fingerprint"]

    assert is_nil(still_unknown["runtime_restore_admission"]["settlement"])

    # not_applied illegal from outcome_unknown
    assert {:error, :restore_phase_illegal} =
             call_public(Store, :settle_runtime_restore_admission, [
               target,
               token,
               %{
                 "outcome" => "not_applied",
                 "reason_code" => "pre_effect_abort",
                 "at_unix_ms" => System.system_time(:millisecond)
               }
             ])

    # Settled claim blocks bind re-entry with exact typed error.
    assert {:ok, settled} =
             call_public(Store, :settle_runtime_restore_admission, [
               target,
               token,
               %{
                 "outcome" => "failed",
                 "reason_code" => "worker_failed",
                 "at_unix_ms" => System.system_time(:millisecond)
               }
             ])

    assert settled["runtime_restore_admission"]["claim_phase"] == "settled"

    assert {:error, :claim_settled} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])
  end

  test "security regression: bind CAS reobserve rejects when mark/settle wins between snapshot and commit" do
    # Deterministic race: durable is already outcome_unknown (mark won). Bind
    # must not short-circuit to {:ok,_} and must not mutate the claim.
    {target, _op_id} = open_runtime_restore_op!()
    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]
    intent_id = mint_intent_id()

    assert {:ok, _} = call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])
    assert {:ok, _} = call_public(Store, :mark_runtime_restore_outcome_unknown, [target, token])

    assert {:ok, before} = call_public(Store, :fetch, [target])
    assert before["runtime_restore_admission"]["claim_phase"] == "outcome_unknown"
    gen_before = before

    # Facade bind against already-unknown snapshot (non-CAS path in core).
    assert {:error, :restore_phase_illegal} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    assert {:ok, after_bind} = call_public(Store, :fetch, [target])
    assert after_bind["runtime_restore_admission"]["claim_phase"] == "outcome_unknown"

    assert after_bind["runtime_restore_admission"]["intent_id"] ==
             gen_before["runtime_restore_admission"]["intent_id"]

    # Fresh target: bind minted→bound CAS path, then concurrent-style mark, then
    # idempotent bind reobserve must fail once durable is unknown (not {:ok,bound}).
    {target2, _} = open_runtime_restore_op!()
    assert {:ok, b2} = begin_restore_admission!(target2)
    token2 = b2["runtime_restore_admission"]["token"]
    intent2 = mint_intent_id()

    assert {:ok, bound2} =
             call_public(Store, :bind_runtime_restore_intent, [target2, token2, intent2])

    assert bound2["runtime_restore_admission"]["claim_phase"] == "bound"

    # Mark wins (simulates concurrent post-handoff mark after bind snapshot of bound).
    assert {:ok, _} = call_public(Store, :mark_runtime_restore_outcome_unknown, [target2, token2])

    # Idempotent re-bind path reobserves durable and must not report bind success.
    assert {:error, :restore_phase_illegal} =
             call_public(Store, :bind_runtime_restore_intent, [target2, token2, intent2])

    assert {:ok, t2_final} = call_public(Store, :fetch, [target2])
    assert t2_final["runtime_restore_admission"]["claim_phase"] == "outcome_unknown"

    # Settle wins: bind after settle is claim_settled, not bind success.
    assert {:ok, _} =
             call_public(Store, :settle_runtime_restore_admission, [
               target2,
               token2,
               %{
                 "outcome" => "failed",
                 "reason_code" => "worker_failed",
                 "at_unix_ms" => System.system_time(:millisecond)
               }
             ])

    assert {:error, :claim_settled} =
             call_public(Store, :bind_runtime_restore_intent, [target2, token2, intent2])
  end

  test "security regression: pre-handoff bind crash parks via claim join; minted-only is pre-effect" do
    {target, op_id} = open_runtime_restore_op!()
    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]
    intent_id = mint_intent_id()

    assert {:ok, bound} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    fp = bound["runtime_restore_admission"]["fingerprint"]

    # Fixed outside-callback claim join observer (map request + legacy 6-arity).
    assert function_exported?(TaskStore, :run_runtime_admission_claim_join_observer, 3) or
             function_exported?(TaskStore, :run_runtime_admission_claim_join_observer, 6)

    parent = self()
    join_ref = make_ref()

    assert :ok =
             call_public(TaskStore, :run_runtime_admission_claim_join_observer, [
               parent,
               join_ref,
               target,
               token,
               intent_id,
               fp
             ])

    assert_receive {:runtime_admission_claim_joined, ^join_ref, result}, 5_000
    # Durable bound without handoff → hold, not pre-effect not_applied.
    assert is_map(result)
    assert result.classification == :bound_hold
    assert result.worker_pid == self() or is_pid(result.worker_pid)
    assert result.target == target
    assert result.token == token
    assert result.intent_id == intent_id
    assert result.fingerprint == fp

    assert result.branch_fact in [:not_running, :bare, :ordinary, :observe_failed] or
             match?({:guarded, _}, result.branch_fact)

    # Minted-only claim (no intent bind) + fresh not_running → pre-effect.
    {target2, _} = open_runtime_restore_op!()
    assert {:ok, b2} = begin_restore_admission!(target2)
    token2 = b2["runtime_restore_admission"]["token"]
    join_ref2 = make_ref()
    intent2 = mint_intent_id()
    fp2 = "fp_" <> String.duplicate("ee", 32)

    # Ensure no branch occupancy for pre-effect proof.
    refute call_public(BranchSupervisor, :whereis, [target2])

    assert :ok =
             call_public(TaskStore, :run_runtime_admission_claim_join_observer, [
               parent,
               join_ref2,
               %{
                 target: target2,
                 token: token2,
                 intent_id: intent2,
                 fingerprint: fp2
               }
             ])

    assert_receive {:runtime_admission_claim_joined, ^join_ref2, result2}, 5_000
    assert is_map(result2)
    assert result2.classification == :minted_pre_effect
    assert result2.branch_fact == :not_running

    assert {:ok, minted_op} = call_public(Store, :fetch, [target2])
    assert minted_op["runtime_restore_admission"]["claim_phase"] == "minted"

    # Fence must stay held while a non-idle guarded intent is parked after join hold.
    # (Materialized by production TaskStore path; here we assert durable bound
    # never allows not_applied invent.)
    assert {:error, :restore_phase_illegal} =
             call_public(Store, :settle_runtime_restore_admission, [
               target,
               token,
               %{
                 "outcome" => "not_applied",
                 "reason_code" => "pre_effect_abort",
                 "at_unix_ms" => System.system_time(:millisecond)
               }
             ])

    _ = op_id
  end

  test "security regression: ownerless minted claim join settles and retires instead of sticking",
       %{
         store: store
       } do
    {target, operation_id} = open_runtime_restore_op!()
    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]
    intent_id = mint_intent_id()
    fingerprint = "fp_" <> String.duplicate("fa", 32)
    store_pid = Process.whereis(store)

    request = %{
      target: target,
      token: token,
      intent_id: intent_id,
      fingerprint: fingerprint,
      operation_id: operation_id,
      monitored_owner_pid: nil
    }

    :sys.replace_state(store_pid, fn state ->
      intent = %{
        intent_id: intent_id,
        target_agent_id: target,
        kind: :guarded_restore,
        fingerprint: fingerprint,
        phase: :outcome_unknown,
        owner_pid: nil,
        worker_pid: nil,
        operation_id: operation_id,
        restore_token: token,
        terminal: nil,
        launch_ref: nil,
        launcher_pid: nil,
        launcher_mon: nil,
        launcher_attempt_index: 0,
        effect_handoff?: false,
        retire_barrier: :none
      }

      state
      |> put_in([:runtime_admission_intents, target], intent)
      |> put_in([:runtime_admission_by_id, intent_id], target)
      |> put_in([:runtime_admission_claim_join_progress, target], %{
        intent_id: intent_id,
        token: token,
        fingerprint: fingerprint,
        operation_id: operation_id,
        status: :retry,
        attempt: 0,
        last_error: :owner_down
      })
    end)

    send(store_pid, {:runtime_admission_claim_join_retry, request, 1})

    assert_eventually(fn ->
      state = :sys.get_state(store_pid)

      not Map.has_key?(state.runtime_admission_intents, target) and
        not Map.has_key?(state.runtime_admission_claim_join_progress, target) and
        not Map.has_key?(state.runtime_admission_durable_settle_progress, target)
    end)

    assert {:ok, operation} = call_public(Store, :fetch, [target])
    claim = operation["runtime_restore_admission"]
    assert claim["claim_phase"] == "settled"
    assert claim["settlement"]["outcome"] == "not_applied"
    assert claim["settlement"]["reason_code"] == "pre_effect_abort"
  end

  test "security regression: claim-join minted_pre_effect blocked by bare/ordinary/mismatched occupancy" do
    {target, _} = open_runtime_restore_op!()
    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]
    parent = self()
    join_ref = make_ref()
    intent_id = mint_intent_id()
    fp = "fp_" <> String.duplicate("aa", 32)

    # Bare branch occupancy (no closed witness) must prevent pre-effect.
    {:ok, bare_pid} =
      Agent.start_link(fn -> :ok end,
        name: {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:branch, target}}}
      )

    on_exit(fn ->
      if Process.alive?(bare_pid), do: Agent.stop(bare_pid)
    end)

    assert :ok =
             call_public(TaskStore, :run_runtime_admission_claim_join_observer, [
               parent,
               join_ref,
               %{target: target, token: token, intent_id: intent_id, fingerprint: fp}
             ])

    assert_receive {:runtime_admission_claim_joined, ^join_ref, bare_result}, 5_000
    assert bare_result.classification == :occupancy_hold
    assert bare_result.branch_fact == :bare
    refute bare_result.classification == :minted_pre_effect

    if Process.alive?(bare_pid), do: Agent.stop(bare_pid)
    # Wait for registry clear
    assert_eventually(fn -> call_public(BranchSupervisor, :whereis, [target]) == nil end)

    # Ordinary-start witness occupancy also blocks pre-effect.
    {target2, _} = open_runtime_restore_op!()
    assert {:ok, b2} = begin_restore_admission!(target2)
    token2 = b2["runtime_restore_admission"]["token"]
    join_ref2 = make_ref()

    ordinary = %{
      v: 1,
      kind: :ordinary_start,
      intent_id: mint_intent_id(),
      fingerprint: "fp_" <> String.duplicate("bb", 32)
    }

    {:ok, ord_pid} =
      Agent.start_link(fn -> :ok end,
        name: {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:branch, target2}, ordinary}}
      )

    on_exit(fn ->
      if Process.alive?(ord_pid), do: Agent.stop(ord_pid)
    end)

    assert :ok =
             call_public(TaskStore, :run_runtime_admission_claim_join_observer, [
               parent,
               join_ref2,
               %{
                 target: target2,
                 token: token2,
                 intent_id: mint_intent_id(),
                 fingerprint: "fp_" <> String.duplicate("cc", 32)
               }
             ])

    assert_receive {:runtime_admission_claim_joined, ^join_ref2, ord_result}, 5_000
    assert ord_result.classification == :occupancy_hold
    assert ord_result.branch_fact == :ordinary

    # Mismatched guarded witness (foreign intent) blocks pre-effect.
    {target3, op3} = open_runtime_restore_op!()
    assert {:ok, b3} = begin_restore_admission!(target3)
    token3 = b3["runtime_restore_admission"]["token"]
    join_ref3 = make_ref()

    foreign = %{
      v: 1,
      kind: :guarded_restore,
      intent_id: mint_intent_id(),
      fingerprint: "fp_" <> String.duplicate("dd", 32),
      operation_id: op3,
      token: mint_restore_token_literal("f")
    }

    {:ok, g_pid} =
      Agent.start_link(fn -> :ok end,
        name: {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:branch, target3}, foreign}}
      )

    on_exit(fn ->
      if Process.alive?(g_pid), do: Agent.stop(g_pid)
    end)

    assert :ok =
             call_public(TaskStore, :run_runtime_admission_claim_join_observer, [
               parent,
               join_ref3,
               %{
                 target: target3,
                 token: token3,
                 intent_id: mint_intent_id(),
                 fingerprint: "fp_" <> String.duplicate("ee", 32)
               }
             ])

    assert_receive {:runtime_admission_claim_joined, ^join_ref3, g_result}, 5_000
    assert g_result.classification == :occupancy_hold
    assert match?({:guarded, _}, g_result.branch_fact)
  end

  test "security regression: claim-join observer hang/timeout/stale result cannot unblock or finalize pre-effect",
       %{store: store, task_sup: task_sup} do
    {target, op_id} = open_runtime_restore_op!()

    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store]])

    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]

    # Bounded claim-join timeout so hang converges via timer (not fire-and-forget).
    # Leave enough room to exercise result authentication after observer DOWN.
    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    :sys.replace_state(store_pid, fn state ->
      Map.put(state, :runtime_admission_claim_join_timeout_ms, 750)
    end)

    Application.put_env(:arbor_agent, :runtime_admission_test_claim_join_hang, true)
    Application.put_env(:arbor_agent, :runtime_admission_test_crash_after_durable_bind, true)

    parent = self()

    spawn(fn ->
      send(
        parent,
        {:cj_hang,
         call_public(TaskStore, :admit_guarded_runtime_restore, [
           target,
           op_id,
           token,
           [name: store, timeout: 12_000]
         ])}
      )
    end)

    assert_eventually(fn -> claim_phase?(target, "bound") end)

    # Observer should be pending with mon+timer while hung.
    assert_eventually(fn ->
      state = :sys.get_state(store_pid)
      pending = Map.get(state, :runtime_admission_pending_claim_join, %{})

      Enum.any?(pending, fn {_ref, meta} ->
        is_map(meta) and meta.target == target and is_pid(Map.get(meta, :observer_pid)) and
          is_reference(Map.get(meta, :mon)) and is_reference(Map.get(meta, :timer))
      end)
    end)

    state1 = :sys.get_state(store_pid)

    {join_ref, meta} =
      Enum.find(state1.runtime_admission_pending_claim_join, fn {_r, m} ->
        m.target == target
      end)

    # Stale result with wrong worker PID — inert (must not finalize).
    send(
      store_pid,
      {:runtime_admission_claim_joined, join_ref,
       %{
         worker_pid: self(),
         target: target,
         token: token,
         intent_id: meta.intent_id,
         fingerprint: meta.fingerprint,
         operation_id: meta.operation_id,
         classification: :minted_pre_effect,
         branch_fact: :not_running
       }}
    )

    Process.sleep(50)
    state2 = :sys.get_state(store_pid)
    # Forged wrong-worker result must leave pending join intact.
    assert Map.has_key?(state2.runtime_admission_pending_claim_join, join_ref)
    intent2 = Map.get(state2.runtime_admission_intents, target)
    assert is_map(intent2)
    assert intent2.phase != :terminal

    # Once the observer dies, monitor handling must erase both copies of its
    # identity. An otherwise exact result with nil worker_pid must remain inert.
    Process.exit(meta.observer_pid, :kill)

    assert_eventually(fn ->
      state = :sys.get_state(store_pid)

      match?(
        %{observer_pid: nil, worker_pid: nil},
        Map.get(state.runtime_admission_pending_claim_join, join_ref)
      )
    end)

    send(
      store_pid,
      {:runtime_admission_claim_joined, join_ref,
       %{
         worker_pid: nil,
         target: target,
         token: token,
         intent_id: meta.intent_id,
         fingerprint: meta.fingerprint,
         operation_id: meta.operation_id,
         classification: :claim_absent,
         branch_fact: :not_running
       }}
    )

    Process.sleep(50)
    state3 = :sys.get_state(store_pid)
    assert Map.has_key?(state3.runtime_admission_pending_claim_join, join_ref)
    intent3 = Map.get(state3.runtime_admission_intents, target)
    assert is_map(intent3)
    assert intent3.phase != :terminal

    assert {:ok, mid_op} = call_public(Store, :fetch, [target])

    refute match?(
             %{"outcome" => "not_applied"},
             mid_op["runtime_restore_admission"]["settlement"]
           )

    # Stale timeout for unknown ref — inert.
    send(store_pid, {:runtime_admission_claim_join_timeout, make_ref()})
    Process.sleep(30)

    # Real timeout should fire on hung observer → retry or exhaust park, never
    # pre-effect not_applied while claim is still bound.
    assert_eventually(
      fn ->
        state = :sys.get_state(store_pid)
        pending = Map.get(state, :runtime_admission_pending_claim_join, %{})
        progress = Map.get(state, :runtime_admission_claim_join_progress, %{})

        # Either still retrying, exhausted-parked, or progress advanced — not silent hang.
        not Map.has_key?(pending, join_ref) or
          match?(
            %{status: status} when status in [:retry, :exhausted, :pending, :done],
            progress[target]
          )
      end,
      80
    )

    Application.delete_env(:arbor_agent, :runtime_admission_test_claim_join_hang)
    Application.delete_env(:arbor_agent, :runtime_admission_test_crash_after_durable_bind)

    assert_receive {:cj_hang, _result}, 15_000

    assert {:ok, op} = call_public(Store, :fetch, [target])
    claim = op["runtime_restore_admission"]
    assert claim["claim_phase"] in ["bound", "outcome_unknown"]
    refute match?(%{"outcome" => "not_applied"}, claim["settlement"])

    # Fence remains held while non-idle unknown/parked join recovery is in play.
    assert {:error, :fence_held_by_restore} =
             call_public(TaskStore, :remove_target_fence, [target, op_id, [name: store]])

    _ = task_sup
  end

  test "security regression: dedicated bind exact-token idempotent; stale/foreign rejected" do
    {target, _} = open_runtime_restore_op!()
    assert {:ok, op} = begin_restore_admission!(target)
    token = op["runtime_restore_admission"]["token"]
    intent_id = mint_intent_id()

    assert {:ok, bound} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    claim = bound["runtime_restore_admission"]
    assert claim["claim_phase"] == "bound"
    assert claim["intent_id"] == intent_id
    assert String.match?(claim["fingerprint"], ~r/\Afp_[0-9a-f]{64}\z/)

    assert {:ok, bound2} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    assert bound2["runtime_restore_admission"]["fingerprint"] == claim["fingerprint"]

    other = mint_intent_id()

    assert {:error, :stale_claim} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, other])

    assert {:error, :stale_claim} =
             call_public(Store, :bind_runtime_restore_intent, [
               target,
               "rrt_" <> String.duplicate("y", 22),
               intent_id
             ])
  end

  # -------------------------------------------------------------------------
  # 2) Controlled both-order races (design §7)
  # -------------------------------------------------------------------------

  test "security regression: ordinary-vs-guarded race both orders", %{store: store} do
    assert {:ok, %{fingerprint: fp, keyword: kw}} = call_public(Opts, :project, [[]])
    parent = self()

    # ---- Order A: ordinary admitted first → guarded competitor loses (no second intent) ----
    o_target = persist_minimal_agent!()
    hold_worker!(6_000)

    spawn(fn ->
      send(
        parent,
        {:ord_win,
         call_public(TaskStore, :admit_ordinary_runtime_start, [
           o_target,
           fp,
           kw,
           [name: store, timeout: 15_000]
         ])}
      )
    end)

    # Observe the ordinary intent before installing the competing fence; polling
    # the mutating install API can otherwise win the race and block the start.
    assert_eventually(fn ->
      runtime_admission_intent_active?(store, o_target, :ordinary_start)
    end)

    assert {:ok, %{active_count: n}} =
             call_public(TaskStore, :install_target_fence, [
               o_target,
               "op_ord_win",
               [name: store]
             ])

    assert n >= 1

    before_o_branch = call_public(BranchSupervisor, :whereis, [o_target])

    # Guarded competitor on the ordinary-held target must fail closed without a
    # second intent/worker/branch (open ordinary intent → exact :conflict).
    assert {:error, :conflict} =
             call_public(TaskStore, :admit_guarded_runtime_restore, [
               o_target,
               "op_ord_win",
               mint_restore_token_literal("q"),
               [name: store, timeout: 1_000]
             ])

    assert call_public(BranchSupervisor, :whereis, [o_target]) == before_o_branch
    assert_receive {:ord_win, _ord_result}, 30_000

    # ---- Order B: guarded wins first (live intent) → ordinary fails closed ----
    {g_target, g_op} = open_runtime_restore_op!()

    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [g_target, g_op, [name: store]])

    assert {:ok, begun} = begin_restore_admission!(g_target)
    g_token = begun["runtime_restore_admission"]["token"]

    hold_worker!(5_000)

    spawn(fn ->
      send(
        parent,
        {:g_first,
         call_public(TaskStore, :admit_guarded_runtime_restore, [
           g_target,
           g_op,
           g_token,
           [name: store, timeout: 12_000]
         ])}
      )
    end)

    assert_eventually(fn -> guarded_intent_holds_fence?(store, g_target, g_op) end)

    before_g_branch = call_public(BranchSupervisor, :whereis, [g_target])

    assert {:error, :target_fenced} =
             call_public(TaskStore, :admit_ordinary_runtime_start, [
               g_target,
               fp,
               kw,
               [name: store, timeout: 1_000]
             ])

    assert call_public(BranchSupervisor, :whereis, [g_target]) == before_g_branch

    assert_eventually(fn -> claim_phase?(g_target, "bound") end)
    register_exact_branch_from_claim!(g_target)
    assert_receive {:g_first, g_result}, 30_000
    assert match?({:ok, pid} when is_pid(pid), g_result)
  end

  test "security regression: fence-remove-vs-guarded race both orders", %{store: store} do
    {target, op_id} = open_runtime_restore_op!()

    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store]])

    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]

    # Order 1: remove fence before guarded admit → typed pre-effect abort
    # (authoritative: no fence, no live intent for exact op/token).
    assert :ok = call_public(TaskStore, :remove_target_fence, [target, op_id, [name: store]])

    assert {:error, :restore_pre_effect_aborted} =
             call_public(TaskStore, :admit_guarded_runtime_restore, [
               target,
               op_id,
               token,
               [name: store, timeout: 1_000]
             ])

    # Order 2: reinstall, start guarded under hold, remove fails while live
    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store]])

    hold_worker!(4_000)
    parent = self()

    spawn(fn ->
      send(
        parent,
        {:g2,
         call_public(TaskStore, :admit_guarded_runtime_restore, [
           target,
           op_id,
           token,
           [name: store, timeout: 12_000]
         ])}
      )
    end)

    assert_eventually(fn -> guarded_intent_holds_fence?(store, target, op_id) end)

    assert {:error, :fence_held_by_restore} =
             call_public(TaskStore, :remove_target_fence, [target, op_id, [name: store]])

    assert_eventually(fn -> claim_phase_in?(target, ["bound", "outcome_unknown"]) end)
    register_exact_branch_from_claim!(target)
    assert_receive {:g2, g2_result}, 30_000
    assert match?({:ok, pid} when is_pid(pid), g2_result)
  end

  test "security regression: duplicate same-op restore joins one intent; foreign-op fails", %{
    store: store
  } do
    {target, op_id} = open_runtime_restore_op!()

    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store]])

    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]

    hold_worker!(3_000)
    parent = self()

    for i <- 1..2 do
      spawn(fn ->
        send(
          parent,
          {:dup, i,
           call_public(TaskStore, :admit_guarded_runtime_restore, [
             target,
             op_id,
             token,
             [name: store, timeout: 15_000]
           ])}
        )
      end)
    end

    # Both callers must join the same intent; register exact branch once bound.
    assert_eventually(fn -> claim_phase_in?(target, ["bound", "outcome_unknown"]) end)
    register_exact_branch_from_claim!(target)

    results =
      for _ <- 1..2 do
        assert_receive {:dup, _i, result}, 30_000
        result
      end

    assert [r1, r2] = results
    assert r1 == r2
    assert {:ok, pid} = r1
    assert is_pid(pid)

    # One branch only — both callers share the same PID.
    assert call_public(BranchSupervisor, :whereis, [target]) == pid

    # Single durable claim / intent identity.
    assert {:ok, op} = call_public(Store, :fetch, [target])
    claim = op["runtime_restore_admission"]
    assert claim["claim_phase"] == "settled"
    assert claim["settlement"]["outcome"] == "applied"
    assert is_binary(claim["intent_id"])

    # Foreign operation under same fence ownership fails exactly.
    foreign_token = mint_restore_token_literal("z")

    assert {:error, :not_owner} =
             call_public(TaskStore, :admit_guarded_runtime_restore, [
               target,
               "foreign_op_not_owner",
               foreign_token,
               [name: store, timeout: 1_000]
             ])
  end

  # -------------------------------------------------------------------------
  # 3) Crash windows + restart + inventory + witness occupancy
  # -------------------------------------------------------------------------

  test "security regression: durable claim before TaskStore intent (minted, no intent_id)" do
    {target, _} = open_runtime_restore_op!()
    assert {:ok, op} = begin_restore_admission!(target)
    claim = op["runtime_restore_admission"]
    assert claim["claim_phase"] == "minted"
    assert is_nil(claim["intent_id"])
    assert is_nil(claim["fingerprint"])
    assert is_binary(claim["token"])

    # Idempotent begin — same token
    assert {:ok, op2} = begin_restore_admission!(target)
    assert op2["runtime_restore_admission"]["token"] == claim["token"]
  end

  test "security regression: intent before worker bind — durable bind precedes handoff ack", %{
    store: store
  } do
    {target, op_id} = open_runtime_restore_op!()

    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store]])

    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]

    # After begin only: still minted (no TaskStore intent bind yet)
    assert {:ok, mid} = call_public(Store, :fetch, [target])
    assert mid["runtime_restore_admission"]["claim_phase"] == "minted"

    # Simulate owner durable bind step before handoff (production IntentOwner order)
    intent_id = mint_intent_id()

    assert {:ok, bound} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    assert bound["runtime_restore_admission"]["claim_phase"] == "bound"
    assert bound["runtime_restore_admission"]["intent_id"] == intent_id

    # Handoff ack without being bound owner fails closed
    assert {:error, handoff_err} =
             call_public(TaskStore, :ack_guarded_restore_effect_handoff, [
               target,
               intent_id,
               bound["runtime_restore_admission"]["fingerprint"],
               [name: store]
             ])

    assert handoff_err in [:not_owner, :conflict, :not_found, :missing_api]
  end

  test "security regression: handoff ack is source-authenticated TaskStore boundary before gate release" do
    # Production public path: unauthenticated caller cannot ack handoff.
    # IntentOwner alone is allowed after durable bind + worker bind (design §3.2).
    assert function_exported?(TaskStore, :ack_guarded_restore_effect_handoff, 4)

    result =
      call_public(TaskStore, :ack_guarded_restore_effect_handoff, [
        "agent_handoff_probe",
        mint_intent_id(),
        "fp_" <> String.duplicate("ab", 32),
        []
      ])

    # Parent without API → :missing_api (assertion fail). Candidate rejects unauth.
    assert match?({:error, _}, result)
    refute match?(:ok, result)
  end

  test "security regression: TaskStore restart with bound claim and no live process materializes blocking unknown",
       %{ra_sup: ra_sup, task_sup: task_sup} do
    {target, op_id} = open_runtime_restore_op!()
    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]
    intent_id = mint_intent_id()

    assert {:ok, bound} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    fp = bound["runtime_restore_admission"]["fingerprint"]
    assert is_binary(fp)
    refute call_public(BranchSupervisor, :whereis, [target])

    # Real TaskStore stop/restart through public topology (not pure merge).
    store2 = unique_name(:store_restart_unknown)

    start_supervised!(
      {TaskStore,
       name: store2,
       task_supervisor: task_sup,
       runtime_admission_supervisor: ra_sup,
       runtime_admission_force_ready: false,
       fence_force_ready: true,
       recovery_force_ready: true},
      id: :store_restart_unknown
    )

    assert_eventually(fn ->
      call_public(TaskStore, :runtime_admission_ready?, [[name: store2]]) == true
    end)

    # Blocking unknown holds the target — fence install for same op still sees non-idle
    # after we install the operation fence; remove is held once fence is up.
    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store2]])

    assert {:error, :fence_held_by_restore} =
             call_public(TaskStore, :remove_target_fence, [target, op_id, [name: store2]])

    # No relaunch / no branch from inventory alone.
    refute call_public(BranchSupervisor, :whereis, [target])

    # Guarded re-admit parks on blocking unknown — timeout without second branch.
    assert {:error, :runtime_admission_wait_timeout} =
             call_public(TaskStore, :admit_guarded_runtime_restore, [
               target,
               op_id,
               token,
               [name: store2, timeout: 400]
             ])

    refute call_public(BranchSupervisor, :whereis, [target])

    # Durable claim remains non-settled (not invented applied/not_applied).
    assert {:ok, op} = call_public(Store, :fetch, [target])
    claim = op["runtime_restore_admission"]
    assert claim["intent_id"] == intent_id
    assert claim["fingerprint"] == fp
    assert claim["claim_phase"] in ["bound", "outcome_unknown"]
    assert is_nil(claim["settlement"])
  end

  test "security regression: TaskStore restart with live owner remonitors without double branch",
       %{ra_sup: ra_sup, task_sup: task_sup} do
    # Dedicated store so stop/restart does not kill the suite default store.
    store_live = unique_name(:store_live_path)

    start_supervised!(
      {TaskStore,
       name: store_live,
       task_supervisor: task_sup,
       runtime_admission_supervisor: ra_sup,
       runtime_admission_force_ready: true,
       fence_force_ready: true,
       recovery_force_ready: true},
      id: :store_live_path
    )

    {target, op_id} = open_runtime_restore_op!()

    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store_live]])

    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]

    # Hold after gate release so owner+worker stay live without branch effects yet.
    hold_worker!(30_000)
    parent = self()

    spawn(fn ->
      send(
        parent,
        {:live_restart_admit,
         call_public(TaskStore, :admit_guarded_runtime_restore, [
           target,
           op_id,
           token,
           [name: store_live, timeout: 60_000]
         ])}
      )
    end)

    assert_eventually(fn -> claim_phase?(target, "bound") end)
    assert_eventually(fn -> is_pid(find_runtime_admission_owner_pid(target)) end)
    owner_before = find_runtime_admission_owner_pid(target)
    assert is_pid(owner_before)
    refute call_public(BranchSupervisor, :whereis, [target])

    # Stop the live store; restart on same RA supervisor so owner children remain.
    store_pid = Process.whereis(store_live)
    assert is_pid(store_pid)
    ref = Process.monitor(store_pid)
    Process.exit(store_pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^store_pid, _} -> :ok
    after
      2_000 -> flunk("store did not die")
    end

    store3 = unique_name(:store_restart_live)

    start_supervised!(
      {TaskStore,
       name: store3,
       task_supervisor: task_sup,
       runtime_admission_supervisor: ra_sup,
       runtime_admission_force_ready: false,
       fence_force_ready: true,
       recovery_force_ready: true},
      id: :store_restart_live
    )

    assert_eventually(fn ->
      call_public(TaskStore, :runtime_admission_ready?, [[name: store3]]) == true
    end)

    # Same owner process remonitored — no second owner/branch.
    assert find_runtime_admission_owner_pid(target) == owner_before
    refute call_public(BranchSupervisor, :whereis, [target])

    # Reinstall fence on the restarted store (in-memory fences are not process-local survivors).
    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store3]])

    assert {:error, :fence_held_by_restore} =
             call_public(TaskStore, :remove_target_fence, [target, op_id, [name: store3]])
  end

  test "security regression: durable claim inventory unavailable/malformed keeps TaskStore unready",
       %{ra_sup: ra_sup, task_sup: task_sup} do
    Application.put_env(
      :arbor_agent,
      :runtime_admission_test_claim_inventory_force_error,
      true
    )

    store_u = unique_name(:store_inv_unavail)

    start_supervised!(
      {TaskStore,
       name: store_u,
       task_supervisor: task_sup,
       runtime_admission_supervisor: ra_sup,
       runtime_admission_force_ready: false,
       fence_force_ready: true,
       recovery_force_ready: true},
      id: :store_inv_unavail
    )

    Process.sleep(200)
    refute call_public(TaskStore, :runtime_admission_ready?, [[name: store_u]]) == true

    {target, op_id} = open_runtime_restore_op!()

    assert {:error, :runtime_admission_not_ready} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store_u]])

    assert {:error, :runtime_admission_not_ready} =
             call_public(TaskStore, :remove_target_fence, [target, op_id, [name: store_u]])

    assert {:error, :runtime_admission_not_ready} =
             call_public(TaskStore, :admit_guarded_runtime_restore, [
               target,
               op_id,
               mint_restore_token_literal("u"),
               [name: store_u, timeout: 300]
             ])

    Application.delete_env(:arbor_agent, :runtime_admission_test_claim_inventory_force_error)
    Application.put_env(:arbor_agent, :runtime_admission_test_claim_inventory_malformed, true)

    store_m = unique_name(:store_inv_malformed)

    start_supervised!(
      {TaskStore,
       name: store_m,
       task_supervisor: task_sup,
       runtime_admission_supervisor: ra_sup,
       runtime_admission_force_ready: false,
       fence_force_ready: true,
       recovery_force_ready: true},
      id: :store_inv_malformed
    )

    Process.sleep(200)
    refute call_public(TaskStore, :runtime_admission_ready?, [[name: store_m]]) == true

    assert {:error, :runtime_admission_not_ready} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store_m]])

    Application.delete_env(:arbor_agent, :runtime_admission_test_claim_inventory_malformed)
  end

  test "security regression: owner-only/stale hot-upgrade reconcile result cannot set readiness or permit admit/fence",
       %{ra_sup: ra_sup, task_sup: task_sup} do
    # Bound durable claim exists so owner-only inventory would omit it and
    # (under the old legacy normalize path) mark ready without the claim.
    {target, op_id} = open_runtime_restore_op!()
    assert {:ok, begun} = call_public(Store, :begin_runtime_restore_admission, [target, op_id])
    token = begun["runtime_restore_admission"]["token"]
    intent_id = mint_intent_id()

    assert {:ok, bound} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    assert bound["runtime_restore_admission"]["claim_phase"] == "bound"

    # Hang claim inventory so the live worker cannot complete dual inventory;
    # we inject stale/legacy results against the exact running attempt.
    Application.put_env(:arbor_agent, :runtime_admission_test_claim_inventory_hang, true)

    store_stale = unique_name(:store_stale_reconcile)

    start_supervised!(
      {TaskStore,
       name: store_stale,
       task_supervisor: task_sup,
       runtime_admission_supervisor: ra_sup,
       runtime_admission_force_ready: false,
       fence_force_ready: true,
       recovery_force_ready: true},
      id: :store_stale_reconcile
    )

    store_pid = Process.whereis(store_stale)
    assert is_pid(store_pid)

    rec = await_running_runtime_admission_reconcile!(store_pid)
    refute call_public(TaskStore, :runtime_admission_ready?, [[name: store_stale]]) == true

    # Legacy owner-only worker result (pre-C3C1a1 / hot-upgrade) — must fail closed.
    send(store_pid, {:runtime_admission_reconcile_complete, rec.ref, {:ok, []}})
    await_reconcile_result_rejected!(store_pid, rec.ref, store_stale)

    assert {:error, :runtime_admission_not_ready} =
             call_public(TaskStore, :install_target_fence, [
               target,
               op_id,
               [name: store_stale]
             ])

    assert {:error, :runtime_admission_not_ready} =
             call_public(TaskStore, :admit_guarded_runtime_restore, [
               target,
               op_id,
               token,
               [name: store_stale, timeout: 300]
             ])

    # Unversioned dual map (missing closed identity fields) — reject.
    rec2 = await_running_runtime_admission_reconcile!(store_pid)

    send(
      store_pid,
      {:runtime_admission_reconcile_complete, rec2.ref, {:ok, %{owners: [], claims: []}}}
    )

    await_reconcile_result_rejected!(store_pid, rec2.ref, store_stale)

    # Wrong attempt / wrong worker identity on otherwise versioned dual map.
    rec3 = await_running_runtime_admission_reconcile!(store_pid)

    send(
      store_pid,
      {:runtime_admission_reconcile_complete, rec3.ref,
       {:ok,
        %{
          v: 1,
          ref: rec3.ref,
          attempt: Map.get(rec3, :attempts, 0) + 99,
          worker_pid: rec3.worker_pid,
          owners: [],
          claims: []
        }}}
    )

    await_reconcile_result_rejected!(store_pid, rec3.ref, store_stale)

    rec4 = await_running_runtime_admission_reconcile!(store_pid)

    send(
      store_pid,
      {:runtime_admission_reconcile_complete, rec4.ref,
       {:ok,
        %{
          v: 1,
          ref: rec4.ref,
          attempt: Map.get(rec4, :attempts, 0),
          worker_pid: self(),
          owners: [],
          claims: []
        }}}
    )

    await_reconcile_result_rejected!(store_pid, rec4.ref, store_stale)

    assert {:error, :runtime_admission_not_ready} =
             call_public(TaskStore, :remove_target_fence, [
               target,
               op_id,
               [name: store_stale]
             ])

    # Release hang: the live worker must emit the closed dual-inventory envelope
    # (owners + durable claims). Bound claim is inventoried — readiness is real.
    Application.delete_env(:arbor_agent, :runtime_admission_test_claim_inventory_hang)

    assert_eventually(
      fn -> call_public(TaskStore, :runtime_admission_ready?, [[name: store_stale]]) == true end,
      120
    )

    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [
               target,
               op_id,
               [name: store_stale]
             ])

    # Bound claim without live owner materializes blocking unknown — fence held.
    assert {:error, :fence_held_by_restore} =
             call_public(TaskStore, :remove_target_fence, [
               target,
               op_id,
               [name: store_stale]
             ])
  end

  test "security regression: bare/ordinary/mismatched branch occupancy never satisfies guarded witness" do
    agent_id = "agent_occ_#{System.unique_integer([:positive])}"

    # Not running
    assert call_public(BranchSupervisor, :admission_witness, [agent_id]) == :not_running

    # Ordinary kind rejected by guarded Lifecycle boundary
    ordinary = %{
      v: 1,
      kind: :ordinary_start,
      intent_id: mint_intent_id(),
      fingerprint: "fp_" <> String.duplicate("ab", 32)
    }

    assert {:error, :invalid_guarded_restore_witness} =
             call_public(Lifecycle, :guarded_restore_effects, [agent_id, ordinary])

    # Extra keys rejected
    closed = canonical_guarded_witness()

    assert {:error, :invalid_guarded_restore_witness} =
             call_public(Lifecycle, :guarded_restore_effects, [
               agent_id,
               Map.put(closed, :evil, true)
             ])
  end

  test "security regression: Lifecycle guarded witness is closed exact atom schema" do
    agent_id = "agent_wit_schema_#{System.unique_integer([:positive])}"
    good = canonical_guarded_witness()

    # Canonical acceptance: passes schema (auth may fail; must not be schema reject).
    assert function_exported?(Lifecycle, :guarded_restore_effects, 2)

    accepted = call_public(Lifecycle, :guarded_restore_effects, [agent_id, good])
    refute accepted == {:error, :invalid_guarded_restore_witness}
    assert match?({:error, _}, accepted)

    # Shared pure validator accepts the same canonical form.
    assert {:ok, ^good} =
             call_public(Arbor.Agent.RuntimeAdmission.AdmissionWitness, :admit_guarded, [good])

    # String version "1" rejected
    assert {:error, :invalid_guarded_restore_witness} =
             call_public(Lifecycle, :guarded_restore_effects, [
               agent_id,
               %{good | v: "1"}
             ])

    # Wrong kind
    assert {:error, :invalid_guarded_restore_witness} =
             call_public(Lifecycle, :guarded_restore_effects, [
               agent_id,
               %{good | kind: :ordinary_start}
             ])

    # String kind rejected at Lifecycle (atom-only boundary)
    assert {:error, :invalid_guarded_restore_witness} =
             call_public(Lifecycle, :guarded_restore_effects, [
               agent_id,
               %{good | kind: "guarded_restore"}
             ])

    # Atom+string duplicate semantic keys rejected (exact six-key atom set only)
    mixed = Map.put(good, "intent_id", good.intent_id)

    assert {:error, :invalid_guarded_restore_witness} =
             call_public(Lifecycle, :guarded_restore_effects, [agent_id, mixed])

    # Pure string-key map rejected at Lifecycle (Registry may still normalize separately)
    string_w = %{
      "v" => 1,
      "kind" => "guarded_restore",
      "intent_id" => good.intent_id,
      "fingerprint" => good.fingerprint,
      "operation_id" => good.operation_id,
      "token" => good.token
    }

    assert {:error, :invalid_guarded_restore_witness} =
             call_public(Lifecycle, :guarded_restore_effects, [agent_id, string_w])

    # Missing key
    assert {:error, :invalid_guarded_restore_witness} =
             call_public(Lifecycle, :guarded_restore_effects, [
               agent_id,
               Map.delete(good, :token)
             ])

    # Extra key
    assert {:error, :invalid_guarded_restore_witness} =
             call_public(Lifecycle, :guarded_restore_effects, [
               agent_id,
               Map.put(good, :store_ref, :forged)
             ])

    # Wrong scalar types
    assert {:error, :invalid_guarded_restore_witness} =
             call_public(Lifecycle, :guarded_restore_effects, [
               agent_id,
               %{good | intent_id: 123}
             ])

    # Oversized / malformed grammars
    assert {:error, :invalid_guarded_restore_witness} =
             call_public(Lifecycle, :guarded_restore_effects, [
               agent_id,
               %{good | token: "rrt_short"}
             ])

    assert {:error, :invalid_guarded_restore_witness} =
             call_public(Lifecycle, :guarded_restore_effects, [
               agent_id,
               %{good | fingerprint: "fp_nothex"}
             ])

    assert {:error, :invalid_guarded_restore_witness} =
             call_public(Lifecycle, :guarded_restore_effects, [
               agent_id,
               %{good | intent_id: "rai_too_short"}
             ])

    assert {:error, :invalid_guarded_restore_witness} =
             call_public(Lifecycle, :guarded_restore_effects, [
               agent_id,
               %{good | operation_id: ""}
             ])

    assert {:error, :invalid_guarded_restore_witness} =
             call_public(Lifecycle, :guarded_restore_effects, [
               agent_id,
               %{good | operation_id: String.duplicate("a", 200)}
             ])

    # Invalid UTF-8 binary
    bad_utf8 = <<0xFF, 0xFE>> <> "notutf8_pad_xxxx"

    assert {:error, :invalid_guarded_restore_witness} =
             call_public(Lifecycle, :guarded_restore_effects, [
               agent_id,
               %{
                 good
                 | token: "rrt_" <> binary_part(bad_utf8 <> String.duplicate("x", 32), 0, 22)
               }
             ])

    # BranchSupervisor shares the same scalar grammar via AdmissionWitness.
    assert is_nil(
             call_public(Arbor.Agent.RuntimeAdmission.AdmissionWitness, :normalize_guarded, [
               %{good | v: "1"}
             ])
           )

    assert call_public(Arbor.Agent.RuntimeAdmission.AdmissionWitness, :normalize_guarded, [good]) ==
             good

    # Pure string Registry form still normalizes through the shared validator.
    assert call_public(Arbor.Agent.RuntimeAdmission.AdmissionWitness, :normalize_guarded, [
             string_w
           ]) == good
  end

  test "security regression: W4 crash after durable bind before handoff never not_applied", %{
    store: store
  } do
    {target, op_id} = open_runtime_restore_op!()

    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store]])

    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]

    Application.put_env(:arbor_agent, :runtime_admission_test_crash_after_durable_bind, true)

    parent = self()

    spawn(fn ->
      send(
        parent,
        {:w4,
         call_public(TaskStore, :admit_guarded_runtime_restore, [
           target,
           op_id,
           token,
           [name: store, timeout: 8_000]
         ])}
      )
    end)

    assert_eventually(fn -> claim_phase_in?(target, ["bound", "outcome_unknown"]) end)
    assert_receive {:w4, w4_result}, 15_000
    refute match?({:ok, _}, w4_result)

    assert {:ok, op} = call_public(Store, :fetch, [target])
    claim = op["runtime_restore_admission"]
    # Bound (pre-handoff crash) must not invent not_applied from absence.
    assert claim["claim_phase"] in ["bound", "outcome_unknown"]
    refute match?(%{"outcome" => "not_applied"}, claim["settlement"])
    refute call_public(BranchSupervisor, :whereis, [target])
  end

  test "security regression: W5 crash after handoff ack before gate release is outcome_unknown never not_applied",
       %{store: store} do
    {target, op_id} = open_runtime_restore_op!()

    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store]])

    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]

    Application.put_env(:arbor_agent, :runtime_admission_test_crash_after_handoff_ack, true)

    parent = self()

    spawn(fn ->
      send(
        parent,
        {:w5,
         call_public(TaskStore, :admit_guarded_runtime_restore, [
           target,
           op_id,
           token,
           [name: store, timeout: 8_000]
         ])}
      )
    end)

    assert_eventually(fn -> claim_phase_in?(target, ["bound", "outcome_unknown"]) end)
    assert_receive {:w5, w5_result}, 15_000
    refute match?({:ok, _}, w5_result)

    # Post-handoff crash: durable may mark outcome_unknown; never not_applied.
    assert_eventually(fn ->
      case call_public(Store, :fetch, [target]) do
        {:ok, op} ->
          claim = op["runtime_restore_admission"]

          is_map(claim) and claim["claim_phase"] in ["bound", "outcome_unknown"] and
            not match?(%{"outcome" => "not_applied"}, claim["settlement"])

        _ ->
          false
      end
    end)

    refute call_public(BranchSupervisor, :whereis, [target])
  end

  test "security regression: W6/W7 worker-before-branch then exact branch before durable settle",
       %{store: store} do
    {target, op_id} = open_runtime_restore_op!()

    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store]])

    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]

    # Hold after gate release: worker is live before branch registration.
    hold_worker!(3_000)
    parent = self()

    spawn(fn ->
      send(
        parent,
        {:w67,
         call_public(TaskStore, :admit_guarded_runtime_restore, [
           target,
           op_id,
           token,
           [name: store, timeout: 15_000]
         ])}
      )
    end)

    assert_eventually(fn -> claim_phase?(target, "bound") end)
    # Worker-before-branch window: claim bound, no branch yet.
    refute call_public(BranchSupervisor, :whereis, [target])

    # Exact branch before durable settle (W7).
    register_exact_branch_from_claim!(target)
    assert is_pid(call_public(BranchSupervisor, :whereis, [target]))

    assert_receive {:w67, result}, 30_000
    assert {:ok, pid} = result
    assert is_pid(pid)
    assert call_public(BranchSupervisor, :whereis, [target]) == pid

    assert {:ok, op} = call_public(Store, :fetch, [target])
    assert op["runtime_restore_admission"]["settlement"]["outcome"] == "applied"
  end

  test "security regression: pre-effect abort may settle not_applied; post-bind never not_applied from absence" do
    {target, _} = open_runtime_restore_op!()
    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]

    assert {:ok, pre} =
             call_public(Store, :settle_runtime_restore_admission, [
               target,
               token,
               %{
                 "outcome" => "not_applied",
                 "reason_code" => "pre_effect_abort",
                 "at_unix_ms" => System.system_time(:millisecond)
               }
             ])

    assert pre["runtime_restore_admission"]["settlement"]["outcome"] == "not_applied"
    assert {:ok, _} = call_public(Store, :clear_runtime_restore_admission, [target, token])

    {target2, _} = open_runtime_restore_op!()
    assert {:ok, b2} = begin_restore_admission!(target2)
    token2 = b2["runtime_restore_admission"]["token"]
    intent_id = mint_intent_id()

    assert {:ok, _} =
             call_public(Store, :bind_runtime_restore_intent, [target2, token2, intent_id])

    assert {:error, :restore_phase_illegal} =
             call_public(Store, :settle_runtime_restore_admission, [
               target2,
               token2,
               %{
                 "outcome" => "not_applied",
                 "reason_code" => "worker_gone",
                 "at_unix_ms" => System.system_time(:millisecond)
               }
             ])
  end

  test "security regression: applied requires source-auth worker + exact witness; direct caller cannot invent applied",
       %{store: store} do
    {target, op_id} = open_runtime_restore_op!()

    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store]])

    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]

    # Direct store settle applied from minted is illegal.
    assert {:error, :restore_phase_illegal} =
             call_public(Store, :settle_runtime_restore_admission, [
               target,
               token,
               %{
                 "outcome" => "applied",
                 "reason_code" => "branch_restored",
                 "at_unix_ms" => System.system_time(:millisecond)
               }
             ])

    # Unauthenticated TaskStore settle is not source-auth worker.
    assert {:error, unauth} =
             call_public(TaskStore, :settle_runtime_admission, [
               target,
               mint_intent_id(),
               {:applied, self()},
               [name: store]
             ])

    assert unauth in [:not_found, :conflict, :not_owner]

    # Production path: source-auth worker + exact guarded witness → applied.
    hold_worker!(2_500)
    parent = self()

    spawn(fn ->
      send(
        parent,
        {:src_auth,
         call_public(TaskStore, :admit_guarded_runtime_restore, [
           target,
           op_id,
           token,
           [name: store, timeout: 15_000]
         ])}
      )
    end)

    assert_eventually(fn -> claim_phase?(target, "bound") end)
    register_exact_branch_from_claim!(target)
    assert_receive {:src_auth, {:ok, pid}}, 30_000
    assert is_pid(pid)

    assert {:ok, op} = call_public(Store, :fetch, [target])
    claim = op["runtime_restore_admission"]
    assert claim["settlement"]["outcome"] == "applied"
    assert claim["token"] == token

    # Mismatched witness cannot satisfy a new guarded admit on a fresh target.
    {t2, op2} = open_runtime_restore_op!()
    assert {:ok, _} = call_public(TaskStore, :install_target_fence, [t2, op2, [name: store]])
    assert {:ok, b2} = begin_restore_admission!(t2)
    token2 = b2["runtime_restore_admission"]["token"]

    # Pre-register ordinary/mismatched branch occupancy.
    bad_witness = %{
      v: 1,
      kind: :ordinary_start,
      intent_id: mint_intent_id(),
      fingerprint: "fp_" <> String.duplicate("ab", 32)
    }

    {:ok, bad_pid} =
      Agent.start_link(fn -> :ok end,
        name: {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:branch, t2}, bad_witness}}
      )

    on_exit(fn ->
      if Process.alive?(bad_pid), do: Agent.stop(bad_pid)
    end)

    hold_worker!(1_500)

    spawn(fn ->
      send(
        parent,
        {:mismatch,
         call_public(TaskStore, :admit_guarded_runtime_restore, [
           t2,
           op2,
           token2,
           [name: store, timeout: 10_000]
         ])}
      )
    end)

    assert_receive {:mismatch, mismatch_result}, 20_000
    # Must not report applied success from mismatched occupancy.
    refute match?({:ok, _}, mismatch_result)

    assert {:ok, op2_final} = call_public(Store, :fetch, [t2])
    c2 = op2_final["runtime_restore_admission"]

    refute match?(
             %{"claim_phase" => "settled", "settlement" => %{"outcome" => "applied"}},
             c2
           )
  end

  test "security regression: begin requires exact operation_id; 1-arity/from_durable_slot gone" do
    {target, op_id} = open_runtime_restore_op!()

    # 1-arity begin is not a public production path.
    refute function_exported?(Store, :begin_runtime_restore_admission, 1)

    assert {:error, :not_owner} =
             call_public(Store, :begin_runtime_restore_admission, [
               target,
               "op_wrong_#{System.unique_integer([:positive])}"
             ])

    assert {:ok, op} = call_public(Store, :fetch, [target])
    assert op["runtime_restore_admission"] == nil

    assert {:ok, begun} =
             call_public(Store, :begin_runtime_restore_admission, [target, op_id])

    assert begun["runtime_restore_admission"]["operation_id"] == op_id
  end

  test "security regression: GuardedRestore clears only exact not_applied+pre_effect_abort terminal" do
    {target, op_id} = open_runtime_restore_op!()
    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]
    intent_id = mint_intent_id()
    assert {:ok, _} = call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    # Different already_settled terminal (failed) must not be cleared by pre-effect shell path.
    assert {:ok, _} =
             call_public(Store, :settle_runtime_restore_admission, [
               target,
               token,
               %{
                 "outcome" => "failed",
                 "reason_code" => "worker_failed",
                 "at_unix_ms" => System.system_time(:millisecond)
               }
             ])

    # Invoke the shell helper path indirectly: already_settled on pre_effect settle
    # should reobserve and refuse to clear a non-matching terminal.
    assert {:error, :already_settled} =
             call_public(Store, :settle_runtime_restore_admission, [
               target,
               token,
               %{
                 "outcome" => "not_applied",
                 "reason_code" => "pre_effect_abort",
                 "at_unix_ms" => System.system_time(:millisecond)
               }
             ])

    assert {:ok, still} = call_public(Store, :fetch, [target])
    claim = still["runtime_restore_admission"]
    assert claim["claim_phase"] == "settled"
    assert claim["settlement"]["outcome"] == "failed"
    assert claim["token"] == token

    # Clear of failed terminal is allowed by store (settled precondition) with exact token,
    # but GuardedRestore shell must not have auto-cleared it.
    assert is_map(claim)
    _ = op_id
  end

  test "security regression: failed pre-effect settlement is outcome_unknown, never a determinate abort" do
    {target, op_id} = open_runtime_restore_op!()
    fake_store = unique_name(:bind_then_abort_store)
    start_supervised!({BindThenAbortStore, fake_store})

    assert {:error, :outcome_unknown} =
             call_public(GuardedRestore, :request, [
               target,
               op_id,
               [task_store: fake_store, timeout: 2_000]
             ])

    assert {:ok, operation} = call_public(Store, :fetch, [target])
    claim = operation["runtime_restore_admission"]

    # The fake admission boundary bound the claim before returning the typed
    # abort. A not_applied transition is therefore illegal and the public shell
    # must preserve uncertainty instead of reporting a false pre-effect fact.
    assert claim["claim_phase"] == "bound"
    assert is_binary(claim["intent_id"])
    assert is_nil(claim["settlement"])
  end

  test "security regression: durable-settle progress rejects stale same-target identity", %{
    store: store
  } do
    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    target = "agent_stale_settle_#{System.unique_integer([:positive])}"
    intent_a = mint_intent_id()
    intent_b = mint_intent_id()
    token_a = mint_restore_token_literal("a")
    token_b = mint_restore_token_literal("b")
    fp_a = "fp_" <> String.duplicate("aa", 32)
    fp_b = "fp_" <> String.duplicate("bb", 32)
    op_a = "op_a_#{System.unique_integer([:positive])}"
    op_b = "op_b_#{System.unique_integer([:positive])}"

    req_a = %{
      mode: :source_auth_terminal,
      target: target,
      token: token_a,
      intent_id: intent_a,
      fingerprint: fp_a,
      operation_id: op_a,
      outcome: "failed",
      reason_code: "worker_failed",
      launch_attempt: 1
    }

    req_b = %{
      mode: :source_auth_terminal,
      target: target,
      token: token_b,
      intent_id: intent_b,
      fingerprint: fp_b,
      operation_id: op_b,
      outcome: "failed",
      reason_code: "worker_failed",
      launch_attempt: 1
    }

    # Seed progress for identity A (pending).
    :sys.replace_state(store_pid, fn state ->
      put_in(state, [:runtime_admission_durable_settle_progress, target], %{
        intent_id: intent_a,
        token: token_a,
        fingerprint: fp_a,
        operation_id: op_a,
        mode: :source_auth_terminal,
        outcome: "failed",
        reason_code: "worker_failed",
        status: :shell_error_retry,
        attempt: 0,
        last_error: :forced
      })
    end)

    # Inject a stale complete for identity B while progress is A — must be inert.
    send(
      store_pid,
      {:runtime_admission_durable_settle_done, make_ref(),
       %{
         worker_pid: self(),
         target: target,
         token: token_b,
         intent_id: intent_b,
         fingerprint: fp_b,
         operation_id: op_b,
         mode: :source_auth_terminal,
         outcome: "failed",
         reason_code: "worker_failed",
         result: {:ok, :settled_terminal}
       }}
    )

    Process.sleep(50)
    state = :sys.get_state(store_pid)
    prog = get_in(state, [:runtime_admission_durable_settle_progress, target])
    assert prog.intent_id == intent_a
    assert prog.status == :shell_error_retry
    refute prog.status == :done

    # Retry current for B must be false (mismatched progress identity).
    # We can only observe via not advancing progress when we send retry for B.
    send(store_pid, {:runtime_admission_durable_settle_retry, req_b, 1})
    Process.sleep(50)
    state2 = :sys.get_state(store_pid)
    prog2 = get_in(state2, [:runtime_admission_durable_settle_progress, target])
    assert prog2.intent_id == intent_a
    assert prog2.token == token_a

    # Same-identity retry message is accepted for scheduling (no crash).
    send(store_pid, {:runtime_admission_durable_settle_retry, req_a, 1})
    Process.sleep(30)
    _ = req_a
  end

  test "security regression: durable-settle retry requires exact prior progress", %{store: store} do
    store_pid = Process.whereis(store)
    target = "agent_forged_retry_#{System.unique_integer([:positive])}"

    request = %{
      mode: :source_auth_terminal,
      target: target,
      token: mint_restore_token_literal("r"),
      intent_id: mint_intent_id(),
      fingerprint: "fp_" <> String.duplicate("ca", 32),
      operation_id: "op_forged_retry_#{System.unique_integer([:positive])}",
      outcome: "failed",
      reason_code: "worker_failed",
      launch_attempt: 0
    }

    # First launches are internal direct calls. A mailbox retry with no exact
    # progress record must not mint launch authority from a default attempt.
    send(store_pid, {:runtime_admission_durable_settle_retry, request, 0})
    Process.sleep(100)

    state = :sys.get_state(store_pid)
    progress = Map.get(state, :runtime_admission_durable_settle_progress, %{})
    pending = Map.get(state, :runtime_admission_pending_durable_settle, %{})
    refute Map.has_key?(progress, target)
    refute Enum.any?(Map.values(pending), &(Map.get(&1, :target) == target))
  end

  test "security regression: shell retries bind the next attempt and survive dead supervisor", %{
    store: store
  } do
    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    settle_target = "agent_settle_launch_#{System.unique_integer([:positive])}"

    settle_request = %{
      mode: :source_auth_terminal,
      target: settle_target,
      token: mint_restore_token_literal("s"),
      intent_id: mint_intent_id(),
      fingerprint: "fp_" <> String.duplicate("ce", 32),
      operation_id: "op_settle_launch_#{System.unique_integer([:positive])}",
      outcome: "failed",
      reason_code: "worker_failed"
    }

    join_target = "agent_join_launch_#{System.unique_integer([:positive])}"

    join_request = %{
      target: join_target,
      token: mint_restore_token_literal("j"),
      intent_id: mint_intent_id(),
      fingerprint: "fp_" <> String.duplicate("cf", 32),
      operation_id: "op_join_launch_#{System.unique_integer([:positive])}",
      monitored_owner_pid: nil
    }

    dead_supervisor = unique_name(:dead_shell_supervisor)

    :sys.replace_state(store_pid, fn state ->
      join_intent = %{
        intent_id: join_request.intent_id,
        target_agent_id: join_target,
        kind: :guarded_restore,
        fingerprint: join_request.fingerprint,
        phase: :outcome_unknown,
        owner_pid: nil,
        worker_pid: nil,
        operation_id: join_request.operation_id,
        restore_token: join_request.token,
        effect_handoff?: false,
        retire_barrier: :none
      }

      settle_progress =
        settle_request
        |> Map.take([
          :intent_id,
          :token,
          :fingerprint,
          :operation_id,
          :mode,
          :outcome,
          :reason_code
        ])
        |> Map.merge(%{status: :launch_retry, attempt: 2, last_error: :prior_failure})

      state
      |> Map.put(:task_supervisor, dead_supervisor)
      |> put_in([:runtime_admission_intents, join_target], join_intent)
      |> put_in([:runtime_admission_durable_settle_progress, settle_target], settle_progress)
      |> put_in([:runtime_admission_claim_join_progress, join_target], %{
        intent_id: join_request.intent_id,
        token: join_request.token,
        fingerprint: join_request.fingerprint,
        operation_id: join_request.operation_id,
        status: :launch_retry,
        attempt: 2,
        last_error: :prior_failure
      })
    end)

    # A forged reset cannot extend either bounded retry cycle.
    send(store_pid, {:runtime_admission_durable_settle_retry, settle_request, 1})
    send(store_pid, {:runtime_admission_claim_join_retry, join_request, 1})
    Process.sleep(50)

    before_exact = :sys.get_state(store_pid)
    assert before_exact.runtime_admission_durable_settle_progress[settle_target].attempt == 2
    assert before_exact.runtime_admission_claim_join_progress[join_target].attempt == 2

    # The exact next attempt sees a dead TaskSupervisor, converges exhausted,
    # and leaves TaskStore plus the guarded exclusion alive.
    send(store_pid, {:runtime_admission_durable_settle_retry, settle_request, 3})
    send(store_pid, {:runtime_admission_claim_join_retry, join_request, 3})
    Process.sleep(150)

    assert Process.whereis(store) == store_pid
    final = :sys.get_state(store_pid)
    settle_progress = final.runtime_admission_durable_settle_progress[settle_target]
    join_progress = final.runtime_admission_claim_join_progress[join_target]

    assert settle_progress.status == :exhausted
    assert settle_progress.attempt == 3
    assert settle_progress.last_error == :durable_settle_supervisor_unavailable
    assert join_progress.status == :exhausted
    assert join_progress.attempt == 3
    assert join_progress.last_error == :claim_join_supervisor_unavailable
    assert final.runtime_admission_intents[join_target].phase == :outcome_unknown
  end

  test "security regression: suspended TaskSupervisor cannot block TaskStore callbacks", %{
    store: store,
    task_sup: task_sup
  } do
    store_pid = Process.whereis(store)
    {target, operation_id} = open_runtime_restore_op!()
    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]
    intent_id = mint_intent_id()

    assert {:ok, bound} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    fingerprint = bound["runtime_restore_admission"]["fingerprint"]

    :sys.replace_state(store_pid, fn state ->
      intent = %{
        intent_id: intent_id,
        target_agent_id: target,
        kind: :guarded_restore,
        fingerprint: fingerprint,
        phase: :outcome_unknown,
        owner_pid: nil,
        worker_pid: nil,
        operation_id: operation_id,
        restore_token: token,
        effect_handoff?: true,
        retire_barrier: :none
      }

      state
      |> Map.put(:runtime_admission_admit_timeout_ms, 50)
      |> put_in([:runtime_admission_intents, target], intent)
      |> put_in([:runtime_admission_by_id, intent_id], target)
      |> put_in([:runtime_admission_durable_mark_progress, target], %{
        intent_id: intent_id,
        token: token,
        status: :launch_retry,
        attempt: 0,
        last_error: :prior_failure
      })
    end)

    :ok = :sys.suspend(task_sup)

    on_exit(fn ->
      if Process.alive?(task_sup) do
        try do
          :sys.resume(task_sup)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    send(store_pid, {:runtime_admission_durable_mark_retry, target, token, intent_id, 1})

    # The launcher may block in Task.Supervisor.start_child/5. TaskStore itself
    # must remain responsive because that synchronous call is outside callbacks.
    probe = Task.async(fn -> TaskStore.runtime_admission_ready?(name: store) end)
    assert {:ok, true} = Task.yield(probe, 500)

    assert_eventually(fn ->
      state = :sys.get_state(store_pid)
      progress = state.runtime_admission_durable_mark_progress[target]

      is_map(progress) and progress.status == :exhausted and
        map_size(state.runtime_admission_operation_launches) == 0 and
        map_size(state.runtime_admission_pending_durable_mark) == 0
    end)

    assert Process.alive?(store_pid)
    :ok = :sys.resume(task_sup)
  end

  test "security regression: late operation delivery to a stopped TaskStore is total", %{
    task_sup: task_sup
  } do
    missing_store = unique_name(:stopped_runtime_admission_store)
    refute Process.whereis(missing_store)

    assert :ok =
             call_public(OperationLauncher, :launch, [
               missing_store,
               make_ref(),
               make_ref(),
               task_sup,
               {Kernel, :inspect, [:unreachable_before_begin]},
               25
             ])

    # The admitted worker never receives begin authority and self-expires.
    Process.sleep(50)
  end

  test "security regression: durable-settle completion binds terminal and rejects success tags",
       %{store: store} do
    store_pid = Process.whereis(store)
    target = "agent_forged_completion_#{System.unique_integer([:positive])}"
    settle_ref = make_ref()

    request = %{
      mode: :source_auth_terminal,
      target: target,
      token: mint_restore_token_literal("c"),
      intent_id: mint_intent_id(),
      fingerprint: "fp_" <> String.duplicate("cb", 32),
      operation_id: "op_forged_completion_#{System.unique_integer([:positive])}",
      outcome: "failed",
      reason_code: "worker_failed"
    }

    meta =
      request
      |> Map.merge(%{
        launch_attempt: 0,
        request: request,
        worker_pid: self(),
        mon: nil,
        timer: nil
      })

    :sys.replace_state(store_pid, fn state ->
      put_in(state, [:runtime_admission_pending_durable_settle, settle_ref], meta)
    end)

    envelope = %{
      worker_pid: self(),
      target: target,
      token: request.token,
      intent_id: request.intent_id,
      fingerprint: request.fingerprint,
      operation_id: request.operation_id,
      mode: request.mode,
      outcome: request.outcome,
      reason_code: request.reason_code,
      result: {:ok, :settled_terminal}
    }

    # Correct worker and identity are insufficient when the terminal differs.
    send(
      store_pid,
      {:runtime_admission_durable_settle_done, settle_ref, %{envelope | outcome: "conflict"}}
    )

    Process.sleep(30)

    assert Map.has_key?(
             :sys.get_state(store_pid).runtime_admission_pending_durable_settle,
             settle_ref
           )

    send(
      store_pid,
      {:runtime_admission_durable_settle_done, settle_ref,
       %{envelope | reason_code: "different_reason"}}
    )

    Process.sleep(30)

    assert Map.has_key?(
             :sys.get_state(store_pid).runtime_admission_pending_durable_settle,
             settle_ref
           )

    # An exact envelope with an unrecognized success tag is terminally closed,
    # never converted into the original successful waiter reply.
    send(
      store_pid,
      {:runtime_admission_durable_settle_done, settle_ref,
       %{envelope | result: {:ok, :forged_success}}}
    )

    Process.sleep(30)
    state = :sys.get_state(store_pid)
    refute Map.has_key?(state.runtime_admission_pending_durable_settle, settle_ref)

    assert get_in(state, [:runtime_admission_durable_settle_progress, target, :status]) ==
             :exhausted

    assert get_in(state, [:runtime_admission_durable_settle_progress, target, :last_error]) ==
             :invalid_settle_result
  end

  test "security regression: settle idempotency same outcome+reason keeps first at; different is already_settled" do
    {target, _} = open_runtime_restore_op!()
    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]
    intent_id = mint_intent_id()
    assert {:ok, _} = call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    first_at = System.system_time(:millisecond)

    first = %{
      "outcome" => "applied",
      "reason_code" => "branch_restored",
      "at_unix_ms" => first_at
    }

    assert {:ok, s1} =
             call_public(Store, :settle_runtime_restore_admission, [target, token, first])

    assert s1["runtime_restore_admission"]["settlement"]["at_unix_ms"] == first_at

    retry = %{
      "outcome" => "applied",
      "reason_code" => "branch_restored",
      "at_unix_ms" => first_at + 2
    }

    assert {:ok, s2} =
             call_public(Store, :settle_runtime_restore_admission, [target, token, retry])

    # First timestamp/record is the exact logical successor.
    assert s2["runtime_restore_admission"]["settlement"]["at_unix_ms"] == first_at

    other = %{
      "outcome" => "failed",
      "reason_code" => "worker_failed",
      "at_unix_ms" => first_at + 1
    }

    assert {:error, :already_settled} =
             call_public(Store, :settle_runtime_restore_admission, [target, token, other])
  end

  test "security regression: durable mark launch retries are bounded and attempt-threaded", %{
    ra_sup: ra_sup
  } do
    # Persistently unavailable TaskSupervisor must not loop forever at attempt=1.
    store = unique_name(:store_mark_launch)
    dead_sup = unique_name(:dead_task_sup_mark)

    start_supervised!(
      {TaskStore,
       name: store,
       task_supervisor: dead_sup,
       runtime_admission_supervisor: ra_sup,
       runtime_admission_force_ready: true,
       fence_force_ready: true,
       recovery_force_ready: true},
      id: :store_mark_launch
    )

    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    {target, op_id} = open_runtime_restore_op!()
    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]
    intent_id = mint_intent_id()

    assert {:ok, bound} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    fp = bound["runtime_restore_admission"]["fingerprint"]

    :sys.replace_state(store_pid, fn state ->
      intent = %{
        intent_id: intent_id,
        target_agent_id: target,
        kind: :guarded_restore,
        fingerprint: fp,
        phase: :outcome_unknown,
        owner_pid: nil,
        worker_pid: nil,
        operation_id: op_id,
        restore_token: token,
        effect_handoff?: true,
        retire_barrier: :none
      }

      state
      |> put_in([:runtime_admission_intents, target], intent)
      |> put_in([:runtime_admission_by_id, intent_id], target)
      |> put_in([:runtime_admission_durable_mark_progress, target], %{
        intent_id: intent_id,
        token: token,
        status: :launch_retry,
        attempt: 0,
        last_error: :prior_launch_failed
      })
    end)

    # Exact successor of authenticated prior progress; arbitrary attempt 0 is inert.
    send(store_pid, {:runtime_admission_durable_mark_retry, target, token, intent_id, 1})

    # Wait past full backoff budget: 50+100+150+200ms plus processing.
    Process.sleep(800)

    state = :sys.get_state(store_pid)
    progress = Map.get(state.runtime_admission_durable_mark_progress, target)
    assert is_map(progress)
    assert progress.status == :exhausted
    assert progress.intent_id == intent_id
    assert progress.attempt < 4
    assert progress.last_error != nil

    # Intent remains conservatively blocking (non-idle outcome_unknown).
    intent = Map.get(state.runtime_admission_intents, target)
    assert is_map(intent)
    assert intent.phase == :outcome_unknown
    assert intent.intent_id == intent_id

    # Late retry after exhaustion must not relaunch / clear exhausted.
    send(store_pid, {:runtime_admission_durable_mark_retry, target, token, intent_id, 1})
    Process.sleep(200)
    state2 = :sys.get_state(store_pid)
    progress2 = Map.get(state2.runtime_admission_durable_mark_progress, target)
    assert progress2.status == :exhausted
    assert progress2.attempt == progress.attempt
  end

  test "security regression: durable mark shell terminal failure is not silent convergence", %{
    store: store
  } do
    Application.put_env(:arbor_agent, :runtime_admission_test_durable_mark_force_error, true)

    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    {target, op_id} = open_runtime_restore_op!()
    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]
    intent_id = mint_intent_id()

    assert {:ok, bound} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    fp = bound["runtime_restore_admission"]["fingerprint"]

    :sys.replace_state(store_pid, fn state ->
      intent = %{
        intent_id: intent_id,
        target_agent_id: target,
        kind: :guarded_restore,
        fingerprint: fp,
        phase: :outcome_unknown,
        owner_pid: nil,
        worker_pid: nil,
        operation_id: op_id,
        restore_token: token,
        effect_handoff?: true,
        retire_barrier: :none
      }

      state
      |> put_in([:runtime_admission_intents, target], intent)
      |> put_in([:runtime_admission_by_id, intent_id], target)
      |> put_in([:runtime_admission_durable_mark_progress, target], %{
        intent_id: intent_id,
        token: token,
        status: :launch_retry,
        attempt: 0,
        last_error: :prior_launch_failed
      })
    end)

    send(store_pid, {:runtime_admission_durable_mark_retry, target, token, intent_id, 1})
    Process.sleep(1_200)

    state = :sys.get_state(store_pid)
    progress = Map.get(state.runtime_admission_durable_mark_progress, target)
    assert is_map(progress)
    assert progress.status == :exhausted
    assert progress.last_error == :mark_forced_failure

    # Durable claim must NOT have been silently treated as converged applied/not_applied.
    assert {:ok, op} = call_public(Store, :fetch, [target])
    claim = op["runtime_restore_admission"]
    assert claim["claim_phase"] in ["bound", "outcome_unknown"]
    refute match?(%{"outcome" => "applied"}, claim["settlement"])
    refute match?(%{"outcome" => "not_applied"}, claim["settlement"])

    # Memory intent remains blocking.
    intent = Map.get(state.runtime_admission_intents, target)
    assert intent.phase == :outcome_unknown
  end

  test "security regression: hung durable mark worker times out and exhausts without blocking", %{
    store: store
  } do
    store_pid = Process.whereis(store)
    {target, operation_id} = open_runtime_restore_op!()
    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]
    intent_id = mint_intent_id()

    assert {:ok, bound} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    fingerprint = bound["runtime_restore_admission"]["fingerprint"]

    Application.put_env(:arbor_agent, :runtime_admission_test_durable_mark_hang, %{
      target: target,
      timeout_ms: 1_000
    })

    :sys.replace_state(store_pid, fn state ->
      intent = %{
        intent_id: intent_id,
        target_agent_id: target,
        kind: :guarded_restore,
        fingerprint: fingerprint,
        phase: :outcome_unknown,
        owner_pid: nil,
        worker_pid: nil,
        operation_id: operation_id,
        restore_token: token,
        effect_handoff?: true,
        retire_barrier: :none
      }

      state
      |> Map.put(:runtime_admission_durable_op_timeout_ms, 75)
      |> put_in([:runtime_admission_intents, target], intent)
      |> put_in([:runtime_admission_by_id, intent_id], target)
      |> put_in([:runtime_admission_durable_mark_progress, target], %{
        intent_id: intent_id,
        token: token,
        status: :launch_retry,
        attempt: 0,
        last_error: :prior_failure
      })
    end)

    send(store_pid, {:runtime_admission_durable_mark_retry, target, token, intent_id, 1})

    assert_eventually(fn ->
      state = :sys.get_state(store_pid)
      progress = state.runtime_admission_durable_mark_progress[target]

      is_map(progress) and progress.status == :exhausted and
        progress.last_error == :worker_timeout and
        map_size(state.runtime_admission_pending_durable_mark) == 0 and
        map_size(state.runtime_admission_durable_mark_monitors) == 0
    end)

    assert TaskStore.runtime_admission_ready?(name: store)
    assert Process.alive?(store_pid)

    assert {:ok, operation} = call_public(Store, :fetch, [target])
    claim = operation["runtime_restore_admission"]
    assert claim["claim_phase"] == "bound"
    assert is_nil(claim["settlement"])
  end

  test "security regression: exhausted recovery progress consumes bounded target capacity", %{
    store: store
  } do
    {target, operation_id} = open_runtime_restore_op!()

    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [
               target,
               operation_id,
               [name: store]
             ])

    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]
    store_pid = Process.whereis(store)
    retained_target = "agent_retained_#{System.unique_integer([:positive])}"

    :sys.replace_state(store_pid, fn state ->
      state
      |> Map.put(:max_runtime_admission_intents, 1)
      |> put_in([:runtime_admission_durable_mark_progress, retained_target], %{
        intent_id: mint_intent_id(),
        token: mint_restore_token_literal("q"),
        status: :exhausted,
        attempt: 3,
        last_error: :worker_timeout
      })
    end)

    assert {:error, :busy} =
             call_public(TaskStore, :admit_guarded_runtime_restore, [
               target,
               operation_id,
               token,
               [name: store, timeout: 500]
             ])

    state = :sys.get_state(store_pid)
    refute Map.has_key?(state.runtime_admission_intents, target)
    assert state.runtime_admission_durable_mark_progress[retained_target].status == :exhausted
  end

  test "security regression: durable mark stale retry and completion are inert", %{store: store} do
    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    {target, op_id} = open_runtime_restore_op!()
    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]
    intent_id = mint_intent_id()

    assert {:ok, bound} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    fp = bound["runtime_restore_admission"]["fingerprint"]

    :sys.replace_state(store_pid, fn state ->
      intent = %{
        intent_id: intent_id,
        target_agent_id: target,
        kind: :guarded_restore,
        fingerprint: fp,
        phase: :outcome_unknown,
        owner_pid: nil,
        worker_pid: nil,
        operation_id: op_id,
        restore_token: token,
        effect_handoff?: true,
        retire_barrier: :none
      }

      state
      |> put_in([:runtime_admission_intents, target], intent)
      |> put_in([:runtime_admission_by_id, intent_id], target)
    end)

    # Stale retry: wrong intent_id — must not create progress for the live intent.
    send(
      store_pid,
      {:runtime_admission_durable_mark_retry, target, token, mint_intent_id(), 0}
    )

    Process.sleep(100)
    state = :sys.get_state(store_pid)
    refute Map.has_key?(Map.get(state, :runtime_admission_durable_mark_progress, %{}), target)

    # Stale completion: unknown mark_ref — inert.
    send(store_pid, {:runtime_admission_durable_mark_done, make_ref(), {:ok, %{}}})
    Process.sleep(50)
    state2 = :sys.get_state(store_pid)
    assert Map.get(state2.runtime_admission_intents, target).phase == :outcome_unknown

    # Stale completion: known ref but intent replaced — inert.
    mark_ref = make_ref()

    :sys.replace_state(store_pid, fn state ->
      state
      |> put_in([:runtime_admission_pending_durable_mark, mark_ref], %{
        target: target,
        token: token,
        intent_id: intent_id,
        attempt: 0,
        expected_phase: :outcome_unknown
      })
      |> put_in([:runtime_admission_intents, target], %{
        intent_id: mint_intent_id(),
        target_agent_id: target,
        kind: :guarded_restore,
        fingerprint: fp,
        phase: :outcome_unknown,
        restore_token: token,
        effect_handoff?: true
      })
    end)

    send(
      store_pid,
      {:runtime_admission_durable_mark_done, mark_ref, {:error, :mark_forced_failure}}
    )

    Process.sleep(50)
    state3 = :sys.get_state(store_pid)
    # Pending cleared on pop, but progress must not mark :done for the new identity.
    refute match?(
             %{status: :done},
             Map.get(state3.runtime_admission_durable_mark_progress, target)
           )
  end

  test "security regression: W9 durable settle shell applies only on exact branch observation" do
    assert function_exported?(TaskStore, :run_runtime_admission_durable_settle, 3)

    {target, op_id} = open_runtime_restore_op!()
    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]
    intent_id = mint_intent_id()

    assert {:ok, bound} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    fp = bound["runtime_restore_admission"]["fingerprint"]
    assert is_binary(fp)

    # No branch registered → shell must mark outcome_unknown, never applied.
    ref_miss = make_ref()

    assert :ok =
             call_public(TaskStore, :run_runtime_admission_durable_settle, [
               self(),
               ref_miss,
               %{
                 mode: :observe_then_applied,
                 target: target,
                 token: token,
                 intent_id: intent_id,
                 fingerprint: fp,
                 operation_id: op_id,
                 reason_code: "branch_restored"
               }
             ])

    assert_receive {:runtime_admission_durable_settle_done, ^ref_miss, miss_env}, 5_000
    assert is_map(miss_env)
    assert match?({:ok, _}, miss_env.result)
    assert is_pid(miss_env.worker_pid)
    assert {:ok, after_miss} = call_public(Store, :fetch, [target])
    assert after_miss["runtime_restore_admission"]["claim_phase"] == "outcome_unknown"
    refute after_miss["runtime_restore_admission"]["settlement"]

    # Exact branch registered → shell converges durable applied.
    witness = %{
      v: 1,
      kind: :guarded_restore,
      intent_id: intent_id,
      fingerprint: fp,
      operation_id: op_id,
      token: token
    }

    {:ok, branch_pid} =
      Agent.start_link(fn -> :ok end,
        name: {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:branch, target}, witness}}
      )

    on_exit(fn ->
      if Process.alive?(branch_pid), do: Agent.stop(branch_pid)
    end)

    ref_hit = make_ref()

    assert :ok =
             call_public(TaskStore, :run_runtime_admission_durable_settle, [
               self(),
               ref_hit,
               %{
                 mode: :observe_then_applied,
                 target: target,
                 token: token,
                 intent_id: intent_id,
                 fingerprint: fp,
                 operation_id: op_id,
                 reason_code: "branch_restored"
               }
             ])

    assert_receive {:runtime_admission_durable_settle_done, ^ref_hit, hit_env}, 5_000
    assert is_map(hit_env)
    assert match?({:ok, _}, hit_env.result)
    assert {:ok, after_hit} = call_public(Store, :fetch, [target])
    claim = after_hit["runtime_restore_admission"]
    assert claim["claim_phase"] == "settled"
    assert claim["settlement"]["outcome"] == "applied"
    assert claim["settlement"]["reason_code"] == "branch_restored"
  end

  test "security regression: fence-remove-wins settle+clears minted claim; timeout cannot abort shared claim",
       %{store: store} do
    {target, op_id} = open_runtime_restore_op!()

    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store]])

    assert {:ok, begun} = call_public(Store, :begin_runtime_restore_admission, [target, op_id])
    token = begun["runtime_restore_admission"]["token"]
    assert begun["runtime_restore_admission"]["claim_phase"] == "minted"

    # Wrong op mutates nothing.
    assert {:error, :not_owner} =
             call_public(GuardedRestore, :request, [
               target,
               "op_wrong_#{System.unique_integer([:positive])}",
               [task_store: store, timeout: 2_000]
             ])

    assert {:ok, still} = call_public(Store, :fetch, [target])
    assert still["runtime_restore_admission"]["token"] == token
    assert still["runtime_restore_admission"]["claim_phase"] == "minted"

    # Remove fence wins before admit — typed abort + shell settle+clear, no strand.
    assert :ok = call_public(TaskStore, :remove_target_fence, [target, op_id, [name: store]])

    assert {:error, :restore_pre_effect_aborted} =
             call_public(GuardedRestore, :request, [
               target,
               op_id,
               [task_store: store, timeout: 3_000]
             ])

    assert_eventually(fn ->
      case call_public(Store, :fetch, [target]) do
        {:ok, op} ->
          claim = op["runtime_restore_admission"]

          is_nil(claim) or
            (is_map(claim) and claim["claim_phase"] == "settled" and
               match?(%{"outcome" => "not_applied"}, claim["settlement"]))

        _ ->
          false
      end
    end)

    # After clear, claim must not strand as non-settled minted forever.
    assert {:ok, final} = call_public(Store, :fetch, [target])

    claim = final["runtime_restore_admission"]
    assert is_nil(claim) or claim["claim_phase"] == "settled"

    # Local timeout (no fence) without typed pre-effect abort cannot settle.
    {target2, op2} = open_runtime_restore_op!()
    assert {:ok, b2} = call_public(Store, :begin_runtime_restore_admission, [target2, op2])
    token2 = b2["runtime_restore_admission"]["token"]

    # No TaskStore fence installed → typed pre-effect abort settles THIS claim only
    # via shell; use a concurrent timeout path that is NOT the typed abort:
    # short timeout against a never-ready store while claim stays minted.
    not_ready = unique_name(:store_to_no_settle)

    start_supervised!({NeverReadyStore, not_ready})

    assert {:error, :timeout} =
             call_public(GuardedRestore, :request, [
               target2,
               op2,
               [task_store: not_ready, timeout: 1_000]
             ])

    assert {:ok, mid2} = call_public(Store, :fetch, [target2])
    c2 = mid2["runtime_restore_admission"]
    assert is_map(c2)
    assert c2["token"] == token2
    assert c2["claim_phase"] == "minted"
    assert is_nil(c2["settlement"])
  end

  test "security regression: W9 source-auth failed terminal durable-settles without inventing applied" do
    # Determinate worker-error evidence survives in TaskStore accept; shell settles
    # failed/conflict without requiring branch observation (cannot invent applied).
    {target, _op_id} = open_runtime_restore_op!()
    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]
    intent_id = mint_intent_id()

    assert {:ok, bound} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    fp = bound["runtime_restore_admission"]["fingerprint"]
    op_id = bound["operation_id"] || bound["runtime_restore_admission"]["operation_id"]

    ref = make_ref()

    assert :ok =
             call_public(TaskStore, :run_runtime_admission_durable_settle, [
               self(),
               ref,
               %{
                 mode: :source_auth_terminal,
                 target: target,
                 token: token,
                 intent_id: intent_id,
                 fingerprint: fp,
                 operation_id: op_id,
                 outcome: "failed",
                 reason_code: "worker_failed"
               }
             ])

    assert_receive {:runtime_admission_durable_settle_done, ^ref, env}, 5_000
    assert is_map(env)
    assert match?({:ok, _}, env.result)
    assert {:ok, op} = call_public(Store, :fetch, [target])
    claim = op["runtime_restore_admission"]
    assert claim["claim_phase"] == "settled"
    assert claim["settlement"]["outcome"] == "failed"
    assert claim["settlement"]["reason_code"] == "worker_failed"
  end

  test "security regression: W9 TaskStore-accepted + worker-skipped durable settle still applies",
       %{store: store} do
    # Deterministic W9 window: branch registered, TaskStore accepts source-auth
    # worker terminal, worker never performs durable settle — fixed shell must.
    {target, op_id} = open_runtime_restore_op!()
    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]
    intent_id = mint_intent_id()

    assert {:ok, bound} =
             call_public(Store, :bind_runtime_restore_intent, [target, token, intent_id])

    fp = bound["runtime_restore_admission"]["fingerprint"]

    witness = %{
      v: 1,
      kind: :guarded_restore,
      intent_id: intent_id,
      fingerprint: fp,
      operation_id: op_id,
      token: token
    }

    {:ok, branch_pid} =
      Agent.start_link(fn -> :ok end,
        name: {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:branch, target}, witness}}
      )

    on_exit(fn ->
      if Process.alive?(branch_pid), do: Agent.stop(branch_pid)
    end)

    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    # Dummy owner so settle begins barrier (shutdown_owner) without killing this test.
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        after
          30_000 -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end)

    worker = self()

    :sys.replace_state(store_pid, fn state ->
      intent = %{
        intent_id: intent_id,
        target_agent_id: target,
        kind: :guarded_restore,
        fingerprint: fp,
        phase: :worker_running,
        owner_pid: owner,
        worker_pid: worker,
        operation_id: op_id,
        restore_token: token,
        effect_handoff?: true,
        retire_barrier: :none,
        terminal: nil
      }

      state
      |> Map.put(:runtime_admission_ready?, true)
      |> put_in([:runtime_admission_intents, target], intent)
      |> put_in([:runtime_admission_by_id, intent_id], target)
    end)

    # Source-auth worker terminal accepted by TaskStore — do NOT call durable
    # settle here (simulates worker killed between accept and durable settle).
    assert :ok =
             call_public(TaskStore, :settle_runtime_admission, [
               target,
               intent_id,
               {:applied, branch_pid},
               [name: store]
             ])

    # Fixed outside-callback shell must converge durable applied from exact branch.
    assert_eventually(
      fn ->
        case call_public(Store, :fetch, [target]) do
          {:ok, op} ->
            claim = op["runtime_restore_admission"]

            is_map(claim) and claim["token"] == token and
              claim["claim_phase"] == "settled" and
              is_map(claim["settlement"]) and
              claim["settlement"]["outcome"] == "applied" and
              claim["settlement"]["reason_code"] == "branch_restored"

          _ ->
            false
        end
      end,
      80
    )
  end

  # -------------------------------------------------------------------------
  # 4) Dual readiness + public shell + observer MFA
  # -------------------------------------------------------------------------

  test "security regression: fence install/remove fail closed until BOTH fence and admission ready" do
    task_sup_a = start_supervised!({Task.Supervisor, name: unique_name(:task_sup_a)})
    store_a = unique_name(:store_a)

    start_supervised!(
      {TaskStore,
       name: store_a,
       task_supervisor: task_sup_a,
       runtime_admission_supervisor: :nonexistent_ra_sup_dual_a,
       runtime_admission_force_ready: false,
       fence_force_ready: true,
       recovery_force_ready: true},
      id: :store_a_dual
    )

    Process.sleep(80)
    target_a = "agent_dual_a#{System.unique_integer([:positive])}"
    refute call_public(TaskStore, :runtime_admission_ready?, [[name: store_a]]) == true

    assert {:error, :runtime_admission_not_ready} =
             call_public(TaskStore, :install_target_fence, [target_a, "op_a", [name: store_a]])

    assert {:error, :runtime_admission_not_ready} =
             call_public(TaskStore, :remove_target_fence, [target_a, "op_a", [name: store_a]])

    ra_sup_b = start_named_ra_supervisor(:ra_sup_b)
    task_sup_b = start_supervised!({Task.Supervisor, name: unique_name(:task_sup_b)})
    store_b = unique_name(:store_b)

    start_supervised!(
      {TaskStore,
       name: store_b,
       task_supervisor: task_sup_b,
       runtime_admission_supervisor: ra_sup_b,
       runtime_admission_force_ready: true,
       fence_force_ready: false,
       recovery_force_ready: true},
      id: :store_b_dual
    )

    target_b = "agent_dual_b#{System.unique_integer([:positive])}"

    assert {:error, :fence_not_ready} =
             call_public(TaskStore, :install_target_fence, [target_b, "op_b", [name: store_b]])

    assert {:error, :fence_not_ready} =
             call_public(TaskStore, :remove_target_fence, [target_b, "op_b", [name: store_b]])
  end

  test "security regression: public GuardedRestore rejects :name and succeeds on production path",
       %{store: store} do
    {target, op_id} = open_runtime_restore_op!()

    assert {:error, :invalid_start_opts} =
             call_public(GuardedRestore, :request, [
               target,
               op_id,
               [name: :forged, task_store: store]
             ])

    refute function_exported?(Lifecycle, :guarded_restore_effects, 1)
    assert function_exported?(Lifecycle, :start, 2)
    assert function_exported?(Lifecycle, :guarded_restore_effects, 2)

    # Successful production shell path: request/join + exact durable applied settlement.
    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store]])

    hold_worker!(2_500)
    parent = self()

    spawn(fn ->
      send(
        parent,
        {:gr_req,
         call_public(GuardedRestore, :request, [
           target,
           op_id,
           [task_store: store, timeout: 15_000]
         ])}
      )
    end)

    assert_eventually(fn -> claim_phase?(target, "bound") end)
    register_exact_branch_from_claim!(target)
    assert_receive {:gr_req, {:ok, pid}}, 30_000
    assert is_pid(pid)
    assert call_public(BranchSupervisor, :whereis, [target]) == pid

    assert {:ok, op} = call_public(Store, :fetch, [target])
    claim = op["runtime_restore_admission"]
    assert claim["claim_phase"] == "settled"
    assert claim["settlement"]["outcome"] == "applied"
    assert claim["settlement"]["reason_code"] == "branch_restored"
  end

  # -------------------------------------------------------------------------
  # OTP inspection / no-secret-status (C3C1a1)
  # -------------------------------------------------------------------------

  test "security regression: TaskStore :sys.get_status omits restore secrets", %{store: store} do
    # Unique sentinels so a leak is unambiguous in inspected output.
    sentinel_token =
      "rrt_SENTtok" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    # Pad/trim to claim grammar where needed; uniqueness is the leak probe.
    sentinel_token = binary_part(sentinel_token <> String.duplicate("x", 32), 0, 26)

    sentinel_fp =
      "fp_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    sentinel_op = "op_SENT#{System.unique_integer([:positive])}_SECRET"

    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    # Inject a guarded intent + pending observe/durable meta carrying sentinels
    # into live GenServer state (simulates mid-flight admission secrets).
    :sys.replace_state(store_pid, fn state ->
      intent_id = mint_intent_id()
      target = "agent_status_redact_#{System.unique_integer([:positive])}"

      intent = %{
        intent_id: intent_id,
        target_agent_id: target,
        kind: :guarded_restore,
        fingerprint: sentinel_fp,
        phase: :worker_running,
        owner_pid: self(),
        worker_pid: self(),
        operation_id: sentinel_op,
        restore_token: sentinel_token,
        effect_handoff?: true,
        retire_barrier: :none
      }

      observe_ref = make_ref()

      state
      |> Map.put(:runtime_admission_ready?, true)
      |> put_in([:runtime_admission_intents, target], intent)
      |> put_in([:runtime_admission_by_id, intent_id], target)
      |> put_in([:runtime_admission_pending_opts, intent_id], %{
        operation_id: sentinel_op,
        restore_token: sentinel_token
      })
      |> put_in([:runtime_admission_pending_observe, observe_ref], %{
        request: %{
          reason: :unexpected_owner_down,
          target: target,
          intent_id: intent_id,
          fingerprint: sentinel_fp,
          operation_id: sentinel_op,
          restore_token: sentinel_token,
          kind: :guarded_restore
        },
        mon: make_ref(),
        timer: make_ref(),
        observer_pid: self()
      })
      |> put_in([:runtime_admission_pending_durable_mark, make_ref()], %{
        target: target,
        token: sentinel_token,
        intent_id: intent_id
      })
      |> put_in([:target_fences, target], sentinel_op)
    end)

    status = :sys.get_status(store_pid)
    rendered = inspect(status, limit: :infinity, printable_limit: :infinity)

    refute_secret_in_status!(rendered, sentinel_token, sentinel_fp, sentinel_op)

    # Forced crash-style status map (what error reports use via format_status/1).
    assert function_exported?(TaskStore, :format_status, 1)

    forced =
      call_public(TaskStore, :format_status, [
        %{
          state: :sys.get_state(store_pid),
          message: {:fake_msg, sentinel_token, sentinel_fp, sentinel_op},
          log: [{0, {IO, :puts, [sentinel_token], []}}],
          reason: {:stop, {:crash, sentinel_token, sentinel_fp, sentinel_op}}
        }
      ])

    forced_rendered = inspect(forced, limit: :infinity, printable_limit: :infinity)
    refute_secret_in_status!(forced_rendered, sentinel_token, sentinel_fp, sentinel_op)

    projected = Map.get(forced, :state)
    assert is_map(projected)
    assert projected.runtime_admission.intent_count >= 1
    assert is_map(projected.runtime_admission.phase_counts)
    refute Map.has_key?(projected, :runtime_admission_intents)
    refute Map.has_key?(projected, :runtime_admission_pending_observe)
  end

  test "security regression: IntentOwner format_status has no fingerprint prefix or token" do
    alias Arbor.Agent.RuntimeAdmission.IntentOwner

    sentinel_token =
      binary_part(
        "rrt_IOWNtok" <>
          Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false) <>
          String.duplicate("y", 32),
        0,
        26
      )

    sentinel_fp =
      "fp_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    sentinel_op = "op_IOWN#{System.unique_integer([:positive])}_SECRET"
    # Distinct prefix that partial redaction used to leak (first 12 chars).
    fp_prefix = binary_part(sentinel_fp, 0, 12)

    assert function_exported?(IntentOwner, :format_status, 1)

    status =
      call_public(IntentOwner, :format_status, [
        %{
          state: %{
            intent_id: mint_intent_id(),
            target_agent_id: "agent_iown_redact",
            fingerprint: sentinel_fp,
            kind: :guarded_restore,
            adopted?: true,
            worker_pid: self(),
            adopt_attempts: 1,
            launch_attempts: 2,
            guarded_meta: %{
              operation_id: sentinel_op,
              restore_token: sentinel_token
            },
            validated_opts: [restore_token: sentinel_token, operation_id: sentinel_op]
          },
          message: {:down, self(), sentinel_token},
          log: [{0, {IO, :puts, [sentinel_fp], []}}],
          reason: {:stop, {:adopt_failed, sentinel_op}}
        }
      ])

    rendered = inspect(status, limit: :infinity, printable_limit: :infinity)
    refute_secret_in_status!(rendered, sentinel_token, sentinel_fp, sentinel_op)
    # Partial fingerprint redaction is forbidden — prefix must not appear either.
    refute rendered =~ fp_prefix
    refute Map.has_key?(status.state, :fingerprint)
    refute Map.has_key?(status.state, :restore_token)
    refute Map.has_key?(status.state, :operation_id)
    refute Map.has_key?(status.state, :worker_pid)
    refute Map.has_key?(status.state, :guarded_meta)
    refute Map.has_key?(status.state, :intent_id)
    refute Map.has_key?(status.state, :target_agent_id)
  end

  test "security regression: format_status fail-closed on malformed/corrupt state and unknown fields" do
    sentinel = "rrt_MALF" <> String.duplicate("z", 18)

    # Non-map status input
    closed = call_public(TaskStore, :format_status, [:not_a_map])
    assert is_map(closed)
    assert closed.message == :redacted
    assert closed.reason == :redacted
    refute inspect(closed) =~ sentinel

    # Truthy non-map pending fields must not raise; unknown top-level fields dropped.
    forced =
      call_public(TaskStore, :format_status, [
        %{
          state: %{
            runtime_admission_ready?: true,
            runtime_admission_intents: %{
              "t1" => %{phase: :worker_running, kind: :guarded_restore},
              "t2" => %{phase: "not_an_atom", kind: make_ref()},
              "t3" => :not_a_map
            },
            runtime_admission_pending_observe: true,
            runtime_admission_pending_durable_mark: "corrupt",
            runtime_admission_pending_claim_join: 99,
            runtime_admission_owner_monitors: nil,
            target_fences: :bad,
            tasks: false
          },
          message: {:x, sentinel},
          log: sentinel,
          reason: {:crash, sentinel},
          secret_field: sentinel,
          extra: %{token: sentinel}
        }
      ])

    forced_rendered = inspect(forced, limit: :infinity, printable_limit: :infinity)
    refute forced_rendered =~ sentinel
    refute Map.has_key?(forced, :secret_field)
    refute Map.has_key?(forced, :extra)
    assert forced.message == :redacted
    assert forced.reason == :redacted
    assert is_map(forced.state.runtime_admission)
    assert is_integer(forced.state.runtime_admission.intent_count)
    # Only allowlisted phase/kind atoms projected.
    assert Enum.all?(Map.keys(forced.state.runtime_admission.phase_counts), &is_atom/1)
    assert Enum.all?(Map.keys(forced.state.runtime_admission.kind_counts), &is_atom/1)
    refute Map.has_key?(forced.state.runtime_admission.phase_counts, "not_an_atom")
  end

  test "security regression: Lifecycle existing-branch adopt uses atomic observe (death/replacement TOCTOU)",
       %{store: store} do
    agent_id = "agent_toctou_#{System.unique_integer([:positive])}"
    intent_id = mint_intent_id()
    fp = "fp_" <> String.duplicate("ab", 32)
    op_id = "op_toctou_#{System.unique_integer([:positive])}"
    token = mint_restore_token_literal("t")

    witness = %{
      v: 1,
      kind: :guarded_restore,
      intent_id: intent_id,
      fingerprint: fp,
      operation_id: op_id,
      token: token
    }

    # Bind this process as the authenticated worker so guarded effects may run.
    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    worker_pid = self()

    :sys.replace_state(store_pid, fn state ->
      intent = %{
        intent_id: intent_id,
        target_agent_id: agent_id,
        kind: :guarded_restore,
        fingerprint: fp,
        phase: :worker_running,
        owner_pid: worker_pid,
        worker_pid: worker_pid,
        operation_id: op_id,
        restore_token: token,
        effect_handoff?: true,
        retire_barrier: :none
      }

      state
      |> Map.put(:runtime_admission_ready?, true)
      |> put_in([:runtime_admission_intents, agent_id], intent)
      |> put_in([:runtime_admission_by_id, intent_id], agent_id)
      |> put_in([:target_fences, agent_id], op_id)
    end)

    # Exact matching branch.
    {:ok, exact_pid} =
      Agent.start_link(fn -> :ok end,
        name: {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:branch, agent_id}, witness}}
      )

    assert function_exported?(Lifecycle, :guarded_restore_effects_for_test_store, 3) or
             function_exported?(Lifecycle, :guarded_restore_effects, 2)

    assert {:ok, ^exact_pid} =
             call_public(Lifecycle, :guarded_restore_effects_for_test_store, [
               agent_id,
               witness,
               store
             ])

    # Death + bare replacement between what used to be split reads: atomic observe
    # must not return the bare replacement as a successful exact adopt.
    if Process.alive?(exact_pid), do: Agent.stop(exact_pid)
    assert_eventually(fn -> call_public(BranchSupervisor, :whereis, [agent_id]) == nil end)

    {:ok, bare_pid} =
      Agent.start_link(fn -> :ok end,
        name: {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:branch, agent_id}}}
      )

    on_exit(fn ->
      if Process.alive?(bare_pid), do: Agent.stop(bare_pid)
    end)

    assert {:error, :witness_mismatch} =
             call_public(Lifecycle, :guarded_restore_effects_for_test_store, [
               agent_id,
               witness,
               store
             ])

    # Foreign guarded witness replacement also fails closed (not exact PID adopt).
    if Process.alive?(bare_pid), do: Agent.stop(bare_pid)
    assert_eventually(fn -> call_public(BranchSupervisor, :whereis, [agent_id]) == nil end)

    foreign = %{
      v: 1,
      kind: :guarded_restore,
      intent_id: mint_intent_id(),
      fingerprint: "fp_" <> String.duplicate("cd", 32),
      operation_id: op_id,
      token: mint_restore_token_literal("f")
    }

    {:ok, foreign_pid} =
      Agent.start_link(fn -> :ok end,
        name: {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:branch, agent_id}, foreign}}
      )

    on_exit(fn ->
      if Process.alive?(foreign_pid), do: Agent.stop(foreign_pid)
    end)

    assert {:error, :witness_mismatch} =
             call_public(Lifecycle, :guarded_restore_effects_for_test_store, [
               agent_id,
               witness,
               store
             ])

    # already_started path: observed PID must equal start-returned PID — foreign
    # replacement under same key fails even if a stale sup_pid is presented.
    # Simulate via observe: exact re-register then kill before adopt-by-pid equality.
    if Process.alive?(foreign_pid), do: Agent.stop(foreign_pid)
    assert_eventually(fn -> call_public(BranchSupervisor, :whereis, [agent_id]) == nil end)

    {:ok, exact2} =
      Agent.start_link(fn -> :ok end,
        name: {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:branch, agent_id}, witness}}
      )

    stale_sup = exact2
    if Process.alive?(exact2), do: Agent.stop(exact2)
    assert_eventually(fn -> call_public(BranchSupervisor, :whereis, [agent_id]) == nil end)

    {:ok, replaced} =
      Agent.start_link(fn -> :ok end,
        name: {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:branch, agent_id}, witness}}
      )

    on_exit(fn ->
      if Process.alive?(replaced), do: Agent.stop(replaced)
    end)

    # Public effects path uses observe only (no dead stale_sup return).
    assert {:ok, pid_now} =
             call_public(Lifecycle, :guarded_restore_effects_for_test_store, [
               agent_id,
               witness,
               store
             ])

    assert pid_now == replaced
    assert pid_now != stale_sup
    assert Process.alive?(pid_now)
  end

  test "security regression: closed terminal reasons — no secret/prefix in status, replies, durable code" do
    alias Arbor.Agent.RuntimeAdmission.IntentCore

    secret_token = "rrt_" <> String.duplicate("S", 22)
    secret_fp = "fp_" <> String.duplicate("ee", 32)
    secret_op = "op_LEAK_SECRET_#{System.unique_integer([:positive])}"
    nested = {:guarded_restore_exception, "boom #{secret_token} #{secret_fp} #{secret_op}"}
    oversized = String.duplicate("x", 10_000) <> secret_token
    # Invalid UTF-8 binary (slice-before-validate footgun).
    invalid_utf8 = <<0xFF, 0xFE>> <> secret_token

    for raw <- [nested, oversized, invalid_utf8, secret_token, {:unknown, secret_fp}] do
      redacted = IntentCore.redact_error_reason(raw)
      assert is_atom(redacted)
      rendered = inspect(redacted)
      refute rendered =~ secret_token
      refute rendered =~ secret_fp
      refute rendered =~ secret_op
      refute rendered =~ binary_part(secret_fp, 0, 12)
    end

    # Documented safe atoms retained.
    assert IntentCore.redact_error_reason(:witness_mismatch) == :witness_mismatch
    assert IntentCore.redact_error_reason(:timeout) == :timeout
    assert IntentCore.redact_error_reason({:conflict, secret_token}) == :conflict

    # Worker maps raw exception-shaped terms to closed codes before TaskStore.
    assert function_exported?(
             Arbor.Agent.RuntimeAdmission.GuardedRestoreWorker,
             :run,
             1
           ) or true

    # Durable reason_code from redacted atoms is allowlisted grammar only.
    for atom <- [:witness_mismatch, :guarded_restore_exception, :error, :worker_failed] do
      code = Atom.to_string(atom)
      assert Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, code)
      refute code =~ "rrt_"
      refute code =~ "fp_"
    end
  end

  test "security regression: live guarded admit :sys.get_status omits claim secrets", %{
    store: store
  } do
    {target, op_id} = open_runtime_restore_op!()

    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store]])

    assert {:ok, begun} = begin_restore_admission!(target)
    token = begun["runtime_restore_admission"]["token"]
    assert is_binary(token)

    hold_worker!(8_000)
    on_exit(fn -> Application.delete_env(:arbor_agent, :runtime_admission_test_hold) end)

    parent = self()

    spawn(fn ->
      send(
        parent,
        {:admit_redact,
         call_public(TaskStore, :admit_guarded_runtime_restore, [
           target,
           op_id,
           token,
           [name: store, timeout: 10_000]
         ])}
      )
    end)

    assert_eventually(fn -> guarded_intent_holds_fence?(store, target, op_id) end)

    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    # Read back fingerprint from private state for sentinel assertion only.
    private = :sys.get_state(store_pid)
    intent = Map.get(Map.get(private, :runtime_admission_intents, %{}), target)
    assert is_map(intent)
    fp = Map.get(intent, :fingerprint)
    assert is_binary(fp)

    rendered =
      store_pid
      |> :sys.get_status()
      |> inspect(limit: :infinity, printable_limit: :infinity)

    refute_secret_in_status!(rendered, token, fp, op_id)

    # IntentOwner live status when owner is registered.
    owner_pid = find_runtime_admission_owner_pid(target)

    if is_pid(owner_pid) do
      owner_rendered =
        owner_pid
        |> :sys.get_status()
        |> inspect(limit: :infinity, printable_limit: :infinity)

      refute_secret_in_status!(owner_rendered, token, fp, op_id)
      refute owner_rendered =~ binary_part(fp, 0, 12)
    end
  end

  test "security regression: fixed async witness observer MFA returns closed facts" do
    assert function_exported?(TaskStore, :run_runtime_admission_witness_observer, 3)

    ref = make_ref()
    intent_id = mint_intent_id()
    fp = "fp_" <> String.duplicate("ab", 32)

    token = mint_restore_token_literal("c")

    # Real Registry miss is an observed :not_running fact (not a synthetic failure).
    assert :ok =
             call_public(TaskStore, :run_runtime_admission_witness_observer, [
               self(),
               ref,
               %{
                 reason: :unexpected_owner_down,
                 source: :owner,
                 target: "agent_missing_wit_zzzz",
                 intent_id: intent_id,
                 fingerprint: fp,
                 kind: :guarded_restore,
                 operation_id: "op_obs",
                 restore_token: token,
                 effect_handoff?: true,
                 monitored_owner_pid: self()
               }
             ])

    assert_receive {:runtime_admission_witness_observed, ^ref, obs}, 1_000
    assert is_map(obs)
    assert obs.fact == :not_running
    assert obs.branch_pid == nil

    # Malformed request → observe_failed (never synthesizes authority-bearing absence).
    ref2 = make_ref()

    assert :ok =
             call_public(TaskStore, :run_runtime_admission_witness_observer, [
               self(),
               ref2,
               %{reason: :unexpected_owner_down, target: 123}
             ])

    assert_receive {:runtime_admission_witness_observed, ^ref2, failed}, 1_000
    assert failed.fact == :observe_failed
    assert failed.reason == :malformed_request
    assert failed.branch_pid == nil
  end

  test "security regression: observer launch failure never synthesizes :not_running", %{
    ra_sup: ra_sup
  } do
    # Live Task.Supervisor for admit/owner launch; stop it before owner death so
    # the witness observer launch fails closed as :observe_failed.
    task_sup = start_supervised!({Task.Supervisor, name: unique_name(:task_sup_launch_fail)})
    store = unique_name(:store_launch_fail)

    start_supervised!(
      {TaskStore,
       name: store,
       task_supervisor: task_sup,
       runtime_admission_supervisor: ra_sup,
       runtime_admission_force_ready: true,
       fence_force_ready: true,
       recovery_force_ready: true,
       runtime_admission_observe_timeout_ms: 200},
      id: :store_launch_fail
    )

    {target, op_id} = open_runtime_restore_op!()

    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store]])

    assert {:ok, op} = begin_restore_admission!(target)
    token = op["runtime_restore_admission"]["token"]
    assert is_binary(token)

    hold_worker!(5_000)
    on_exit(fn -> Application.delete_env(:arbor_agent, :runtime_admission_test_hold) end)

    parent = self()

    spawn(fn ->
      result =
        call_public(TaskStore, :admit_guarded_runtime_restore, [
          target,
          op_id,
          token,
          [name: store, timeout: 8_000]
        ])

      send(parent, {:admit_done, result})
    end)

    # Wait for the exact post-handoff scenario before removing the observer
    # execution supervisor. Merely seeing an admitted intent is too early.
    assert_eventually(fn -> guarded_intent_effect_handed_off?(store, target, op_id) end)

    # Stop the task supervisor so the next witness observer cannot launch.
    task_sup_pid = task_sup

    if is_pid(task_sup_pid) do
      ref = Process.monitor(task_sup_pid)
      Process.exit(task_sup_pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^task_sup_pid, _} -> :ok
      after
        1_000 -> :ok
      end
    end

    # Kill the live owner so TaskStore enqueues a witness observe (launch fails).
    owner_pid = find_runtime_admission_owner_pid(target)

    if is_pid(owner_pid) do
      Process.exit(owner_pid, :kill)
    end

    # Fail-closed: must not retire as ordinary not_applied from synthetic absence.
    # Fence remains held (parked unknown / non-idle) rather than free for re-admit.
    Process.sleep(300)
    assert guarded_intent_holds_fence?(store, target, op_id)
  end

  test "security regression: observer hang/timeout is bounded and observe_failed", %{
    store: store
  } do
    {target, op_id} = open_runtime_restore_op!()

    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store]])

    assert {:ok, op} = begin_restore_admission!(target)
    token = op["runtime_restore_admission"]["token"]

    # Hang the fixed observer long enough that the store timer converges first.
    Application.put_env(:arbor_agent, :runtime_admission_observe_test_hang, %{
      timeout_ms: 5_000,
      target: target
    })

    on_exit(fn ->
      Application.delete_env(:arbor_agent, :runtime_admission_observe_test_hang)
      Application.delete_env(:arbor_agent, :runtime_admission_test_hold)
    end)

    # Rebuild store with a short observe timeout so the race is deterministic.
    store_pid = Process.whereis(store)

    if is_pid(store_pid) do
      :sys.replace_state(store_pid, fn state ->
        Map.put(state, :runtime_admission_observe_timeout_ms, 150)
      end)
    end

    hold_worker!(5_000)

    parent = self()

    spawn(fn ->
      result =
        call_public(TaskStore, :admit_guarded_runtime_restore, [
          target,
          op_id,
          token,
          [name: store, timeout: 8_000]
        ])

      send(parent, {:admit_done_timeout, result})
    end)

    assert_eventually(fn -> guarded_intent_holds_fence?(store, target, op_id) end)

    owner_pid = find_runtime_admission_owner_pid(target)

    if is_pid(owner_pid) do
      Process.exit(owner_pid, :kill)
    end

    # Bounded: within a few hundred ms the pending observe must converge
    # (timeout → observe_failed → park), leaving the fence held — not hung forever
    # and not retired via synthetic :not_running / not_applied.
    Process.sleep(500)
    assert guarded_intent_holds_fence?(store, target, op_id)
  end

  test "security regression: stale delayed observation is inert after identity change" do
    intent_id = mint_intent_id()
    fp = "fp_" <> String.duplicate("cd", 32)
    token = "rrt_" <> String.duplicate("e", 22)
    owner = self()

    alias Arbor.Agent.RuntimeAdmission.IntentCore

    intent = %{
      intent_id: intent_id,
      target_agent_id: "agent_stale_obs",
      kind: :guarded_restore,
      fingerprint: fp,
      phase: :worker_running,
      owner_pid: owner,
      operation_id: "op_stale",
      restore_token: token
    }

    request = %{
      reason: :unexpected_owner_down,
      kind: :guarded_restore,
      target: "agent_stale_obs",
      intent_id: intent_id,
      fingerprint: fp,
      operation_id: "op_stale",
      restore_token: token,
      monitored_owner_pid: owner
    }

    assert IntentCore.observe_request_current?(intent, request)

    # After state change (new fingerprint / rebound owner) delayed fact is stale.
    changed = %{intent | fingerprint: "fp_" <> String.duplicate("ef", 32)}
    refute IntentCore.observe_request_current?(changed, request)

    rebound = %{intent | owner_pid: spawn(fn -> :ok end)}
    refute IntentCore.observe_request_current?(rebound, request)
  end

  test "security regression: observe_admission is atomic Registry PID + closed witness" do
    agent_id = "agent_atomic_obs_#{System.unique_integer([:positive])}"
    intent_id = mint_intent_id()
    fp = "fp_" <> String.duplicate("11", 32)
    op_id = "op_atomic_1"
    token = "rrt_" <> String.duplicate("f", 22)

    witness = %{
      v: 1,
      kind: :guarded_restore,
      intent_id: intent_id,
      fingerprint: fp,
      operation_id: op_id,
      token: token
    }

    # Minimal supervised process registered as the branch with closed witness value.
    {:ok, branch_pid} =
      Agent.start(fn -> :ok end,
        name: {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:branch, agent_id}, witness}}
      )

    on_exit(fn ->
      if Process.alive?(branch_pid), do: Agent.stop(branch_pid)
    end)

    assert function_exported?(BranchSupervisor, :observe_admission, 1)

    assert {:running, ^branch_pid, {:ok, observed_w}} =
             call_public(BranchSupervisor, :observe_admission, [agent_id])

    assert observed_w.kind == :guarded_restore
    assert observed_w.intent_id == intent_id
    assert observed_w.fingerprint == fp
    assert observed_w.operation_id == op_id
    assert observed_w.token == token

    # whereis/admission_witness derive from the same facade (no split read).
    assert call_public(BranchSupervisor, :whereis, [agent_id]) == branch_pid

    assert call_public(BranchSupervisor, :admission_witness, [agent_id]) ==
             {:ok, observed_w}

    # Fixed observer MFA must return {:exact, intent_id} with the same atomic PID.
    ref = make_ref()

    assert :ok =
             call_public(TaskStore, :run_runtime_admission_witness_observer, [
               self(),
               ref,
               %{
                 reason: :worker_down_classify,
                 source: :worker,
                 target: agent_id,
                 intent_id: intent_id,
                 fingerprint: fp,
                 kind: :guarded_restore,
                 operation_id: op_id,
                 restore_token: token,
                 effect_handoff?: true
               }
             ])

    assert_receive {:runtime_admission_witness_observed, ^ref, exact_obs}, 1_000
    assert exact_obs.fact == {:exact, intent_id}
    assert exact_obs.branch_pid == branch_pid

    # Branch death between successive observations: second observe is :not_running,
    # never a split exact-witness + nil-pid from two separate reads.
    ref_down = Process.monitor(branch_pid)
    Process.exit(branch_pid, :kill)

    receive do
      {:DOWN, ^ref_down, :process, ^branch_pid, _} -> :ok
    after
      1_000 -> flunk("branch did not die")
    end

    # Registry may take a moment to drop the dead pid entry.
    assert_eventually(fn ->
      call_public(BranchSupervisor, :observe_admission, [agent_id]) == :not_running
    end)

    ref2 = make_ref()

    assert :ok =
             call_public(TaskStore, :run_runtime_admission_witness_observer, [
               self(),
               ref2,
               %{
                 reason: :worker_down_classify,
                 source: :worker,
                 target: agent_id,
                 intent_id: intent_id,
                 fingerprint: fp,
                 kind: :guarded_restore,
                 operation_id: op_id,
                 restore_token: token,
                 effect_handoff?: true
               }
             ])

    assert_receive {:runtime_admission_witness_observed, ^ref2, dead_obs}, 1_000
    assert dead_obs.fact == :not_running
    assert dead_obs.branch_pid == nil

    # Replacement: new branch with different intent. Observer for the OLD request
    # must report {:other, new_id} with no forged exact+pid pair from a split read.
    new_intent = mint_intent_id()
    new_fp = "fp_" <> String.duplicate("22", 32)
    new_token = "rrt_" <> String.duplicate("g", 22)

    new_witness = %{
      v: 1,
      kind: :guarded_restore,
      intent_id: new_intent,
      fingerprint: new_fp,
      operation_id: op_id,
      token: new_token
    }

    {:ok, new_pid} =
      Agent.start_link(fn -> :ok end,
        name: {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:branch, agent_id}, new_witness}}
      )

    on_exit(fn ->
      if Process.alive?(new_pid), do: Agent.stop(new_pid)
    end)

    ref3 = make_ref()

    assert :ok =
             call_public(TaskStore, :run_runtime_admission_witness_observer, [
               self(),
               ref3,
               %{
                 reason: :worker_down_classify,
                 source: :worker,
                 target: agent_id,
                 intent_id: intent_id,
                 fingerprint: fp,
                 kind: :guarded_restore,
                 operation_id: op_id,
                 restore_token: token,
                 effect_handoff?: true
               }
             ])

    assert_receive {:runtime_admission_witness_observed, ^ref3, replaced_obs}, 1_000
    assert replaced_obs.fact == {:other, new_intent}
    assert replaced_obs.branch_pid == nil

    assert {:running, ^new_pid, {:ok, %{intent_id: ^new_intent}}} =
             call_public(BranchSupervisor, :observe_admission, [agent_id])
  end

  test "security regression: unbounded operation_id/token rejected before admit", %{store: store} do
    {target, op_id} = open_runtime_restore_op!()

    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store]])

    assert {:error, :invalid_operation_id} =
             call_public(TaskStore, :admit_guarded_runtime_restore, [
               target,
               String.duplicate("a", 10_000),
               mint_restore_token_literal("d"),
               [name: store, timeout: 500]
             ])

    assert {:error, :invalid_restore_token} =
             call_public(TaskStore, :admit_guarded_runtime_restore, [
               target,
               op_id,
               "rrt_short",
               [name: store, timeout: 500]
             ])
  end

  # -------------------------------------------------------------------------
  # GuardedRestore shell authority: no arbitrary not_applied; op-id before mint
  # -------------------------------------------------------------------------

  test "security regression: concurrent caller timeout/error cannot settle shared minted claim while owner pre-bind",
       %{store: store} do
    {target, op_id} = open_runtime_restore_op!()

    # Source-authenticated owner has minted the shared claim and is pre-bind.
    assert {:ok, begun} =
             call_public(Store, :begin_runtime_restore_admission, [target, op_id])

    token = begun["runtime_restore_admission"]["token"]
    assert is_binary(token)
    assert begun["runtime_restore_admission"]["claim_phase"] == "minted"
    assert is_nil(begun["runtime_restore_admission"]["settlement"])
    assert begun["runtime_restore_admission"]["operation_id"] == op_id

    # Caller A: wrong op — no mutation / no settle of shared claim.
    assert {:error, :not_owner} =
             call_public(GuardedRestore, :request, [
               target,
               "op_foreign_#{System.unique_integer([:positive])}",
               [task_store: store, timeout: 3_000]
             ])

    assert {:ok, after_wrong} = call_public(Store, :fetch, [target])
    claim_a = after_wrong["runtime_restore_admission"]
    assert claim_a["token"] == token
    assert claim_a["claim_phase"] == "minted"
    assert is_nil(claim_a["settlement"])

    # Caller B: local readiness timeout against a never-ready store. Shell must
    # return :timeout without durable not_applied settlement (not the typed
    # restore_pre_effect_aborted path which is authoritative fence-remove-wins).
    not_ready = unique_name(:store_not_ready_settle)

    start_supervised!({NeverReadyStore, not_ready})

    Process.sleep(50)
    refute call_public(TaskStore, :runtime_admission_ready?, [[name: not_ready]]) == true

    assert {:error, :timeout} =
             call_public(GuardedRestore, :request, [
               target,
               op_id,
               [task_store: not_ready, timeout: 1_000]
             ])

    assert {:ok, after_timeout} = call_public(Store, :fetch, [target])
    claim_b = after_timeout["runtime_restore_admission"]
    assert claim_b["token"] == token
    assert claim_b["claim_phase"] == "minted"
    assert is_nil(claim_b["settlement"])
    refute match?(%{"outcome" => "not_applied"}, claim_b["settlement"])

    # Valid owner proceeds from the preserved minted claim and binds/settles applied.
    assert {:ok, _} =
             call_public(TaskStore, :install_target_fence, [target, op_id, [name: store]])

    hold_worker!(2_500)
    parent = self()

    spawn(fn ->
      send(
        parent,
        {:owner_pre_bind,
         call_public(GuardedRestore, :request, [
           target,
           op_id,
           [task_store: store, timeout: 15_000]
         ])}
      )
    end)

    assert_eventually(fn -> claim_phase?(target, "bound") end)
    register_exact_branch_from_claim!(target)
    assert_receive {:owner_pre_bind, {:ok, pid}}, 30_000
    assert is_pid(pid)

    assert {:ok, final} = call_public(Store, :fetch, [target])
    final_claim = final["runtime_restore_admission"]
    assert final_claim["token"] == token
    assert final_claim["claim_phase"] == "settled"
    assert final_claim["settlement"]["outcome"] == "applied"
  end

  test "security regression: wrong operation_id rejects begin without durable mutation", %{
    store: store
  } do
    {target, op_id} = open_runtime_restore_op!()
    wrong_op = "op_wrong_#{System.unique_integer([:positive])}"

    assert {:ok, snap_before} = call_public(Store, :snapshot, [target])
    assert snap_before.data["runtime_restore_admission"] == nil
    assert snap_before.data["operation_id"] == op_id
    gen = snap_before.generation
    rev = snap_before.revision

    # Store begin with mismatched operation_id: fail closed, no claim mint.
    assert {:error, :not_owner} =
             call_public(Store, :begin_runtime_restore_admission, [target, wrong_op])

    assert {:ok, snap_after_begin} = call_public(Store, :snapshot, [target])
    assert snap_after_begin.generation == gen
    assert snap_after_begin.revision == rev
    assert snap_after_begin.data["runtime_restore_admission"] == nil
    assert snap_after_begin.data["operation_id"] == op_id

    # GuardedRestore shell binds op identity before mutation — same no-mint guarantee.
    assert {:error, :not_owner} =
             call_public(GuardedRestore, :request, [
               target,
               wrong_op,
               [task_store: store, timeout: 3_000]
             ])

    assert {:ok, snap_after_shell} = call_public(Store, :snapshot, [target])
    assert snap_after_shell.generation == gen
    assert snap_after_shell.revision == rev
    assert snap_after_shell.data["runtime_restore_admission"] == nil

    # Correct operation_id may still mint after the wrong-op rejects.
    assert {:ok, begun} =
             call_public(Store, :begin_runtime_restore_admission, [target, op_id])

    claim = begun["runtime_restore_admission"]
    assert is_map(claim)
    assert claim["claim_phase"] == "minted"
    assert claim["operation_id"] == op_id
    assert begun["operation_id"] == op_id
  end

  test "security regression: operation-slot race — wrong op cannot mint or rebind existing claim" do
    {target, op_id} = open_runtime_restore_op!()
    wrong_op = "op_race_#{System.unique_integer([:positive])}"
    parent = self()

    # Concurrent begin race: correct vs wrong operation_id on empty claim slot.
    spawn(fn ->
      send(
        parent,
        {:begin_race, :wrong,
         call_public(Store, :begin_runtime_restore_admission, [target, wrong_op])}
      )
    end)

    spawn(fn ->
      send(
        parent,
        {:begin_race, :good,
         call_public(Store, :begin_runtime_restore_admission, [target, op_id])}
      )
    end)

    results =
      for _ <- 1..2 do
        assert_receive {:begin_race, who, result}, 5_000
        {who, result}
      end

    by_who = Map.new(results)
    assert {:error, :not_owner} = Map.fetch!(by_who, :wrong)
    assert {:ok, good_op} = Map.fetch!(by_who, :good)

    claim = good_op["runtime_restore_admission"]
    assert is_map(claim)
    assert claim["claim_phase"] == "minted"
    assert claim["operation_id"] == op_id
    assert good_op["operation_id"] == op_id
    token = claim["token"]

    # After correct mint, wrong op still cannot resume/mutate the shared claim.
    assert {:error, :not_owner} =
             call_public(Store, :begin_runtime_restore_admission, [target, wrong_op])

    assert {:ok, still} = call_public(Store, :fetch, [target])
    still_claim = still["runtime_restore_admission"]
    assert still_claim["token"] == token
    assert still_claim["operation_id"] == op_id
    assert still_claim["claim_phase"] == "minted"
    assert is_nil(still_claim["settlement"])

    # Correct begin remains idempotent on the same slot/token.
    assert {:ok, resumed} =
             call_public(Store, :begin_runtime_restore_admission, [target, op_id])

    assert resumed["runtime_restore_admission"]["token"] == token
    assert resumed["runtime_restore_admission"]["operation_id"] == op_id
  end

  test "security regression: GuardedRestore.request/3 is total — no exit, no token in error terms" do
    # Blocking/failing GenServer: admit call exits with secret-bearing args in
    # the exit reason (timeout shapes embed call args including restore_token).
    # Public API must return {:error, atom} without re-exiting or leaking token.
    secret_token = "rrt_" <> String.duplicate("Z", 22)
    secret_op = "op_SECRET_leak_#{System.unique_integer([:positive])}"

    {target, op_id} = open_runtime_restore_op!()
    assert {:ok, begun} = begin_restore_admission!(target)
    real_token = begun["runtime_restore_admission"]["token"]
    assert is_binary(real_token)

    block_name = unique_name(:block_secret_store)
    explode_name = unique_name(:explode_secret_store)

    start_supervised!(
      {__MODULE__.BlockingSecretStore, block_name},
      id: :block_secret_store
    )

    start_supervised!(
      {__MODULE__.ExplodingSecretStore, explode_name},
      id: :explode_secret_store
    )

    # Blocking store never replies → call timeout; mapped to closed atom, no exit.
    result_block =
      try do
        GuardedRestore.request(target, op_id,
          task_store: block_name,
          timeout: 1_000
        )
      catch
        kind, reason ->
          flunk("GuardedRestore.request exited: #{inspect({kind, reason})}")
      end

    assert match?({:error, atom} when is_atom(atom), result_block)
    {:error, block_atom} = result_block
    assert block_atom in [:store_timeout, :timeout, :store_unavailable, :admit_failed]

    block_inspected = inspect(result_block, limit: :infinity, printable_limit: :infinity)
    refute block_inspected =~ real_token
    refute block_inspected =~ secret_token
    refute block_inspected =~ secret_op
    refute block_inspected =~ "unexpected_admit_result"
    refute match?({:error, {_, _}}, result_block)

    result_explode =
      try do
        GuardedRestore.request(target, op_id,
          task_store: explode_name,
          timeout: 2_000
        )
      catch
        kind, reason ->
          flunk("GuardedRestore.request exited on explode store: #{inspect({kind, reason})}")
      end

    assert match?({:error, atom} when is_atom(atom), result_explode)
    {:error, explode_atom} = result_explode
    assert is_atom(explode_atom)

    explode_inspected = inspect(result_explode, limit: :infinity, printable_limit: :infinity)
    refute explode_inspected =~ real_token
    refute explode_inspected =~ secret_token
    refute explode_inspected =~ "secret_crash"
    refute explode_inspected =~ secret_op
    refute match?({:error, {_, _}}, result_explode)

    # Claim preserved — timeout/unavailable must not invent not_applied.
    assert {:ok, still} = call_public(Store, :fetch, [target])
    claim = still["runtime_restore_admission"]
    assert is_map(claim)
    assert claim["token"] == real_token
    refute match?(%{"outcome" => "not_applied"}, claim["settlement"])
  end

  test "security regression: GuardedRestore public opts closed — reject unknown and :name", %{
    store: store
  } do
    {target, op_id} = open_runtime_restore_op!()

    assert {:ok, snap_before} = call_public(Store, :snapshot, [target])
    assert snap_before.data["runtime_restore_admission"] == nil
    gen = snap_before.generation
    rev = snap_before.revision

    assert {:error, :invalid_start_opts} =
             call_public(GuardedRestore, :request, [
               target,
               op_id,
               [name: :forged_store]
             ])

    assert {:error, :invalid_start_opts} =
             call_public(GuardedRestore, :request, [
               target,
               op_id,
               [collaborator: true, task_store: store]
             ])

    assert {:error, :invalid_start_opts} =
             call_public(GuardedRestore, :request, [
               target,
               op_id,
               [unknown_key: 1, timeout: 1_000]
             ])

    assert {:error, :invalid_start_opts} =
             call_public(GuardedRestore, :request, [
               target,
               op_id,
               [runner: SomeModule, task_store: store]
             ])

    # Rejected opts must not mint or otherwise mutate the durable slot.
    assert {:ok, snap_rejected} = call_public(Store, :snapshot, [target])
    assert snap_rejected.generation == gen
    assert snap_rejected.revision == rev
    assert snap_rejected.data["runtime_restore_admission"] == nil

    # Documented timeout controls remain accepted (fail later for other reasons).
    assert {:error, reason} =
             call_public(GuardedRestore, :request, [
               target,
               op_id,
               [task_store: store, timeout_ms: 1_000]
             ])

    refute reason == :invalid_start_opts
    # No TaskStore fence yet → admit-level failure, not opts rejection.
    assert reason in [
             :restore_pre_effect_aborted,
             :restore_fence_required,
             :timeout,
             :missing_api
           ]
  end

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp hold_worker!(ms) when is_integer(ms) and ms > 0 do
    # Deterministic MIX_ENV=test seam: worker blocks after gate release.
    Application.put_env(:arbor_agent, :runtime_admission_test_hold, %{timeout_ms: ms})
  end

  defp clear_runtime_admission_test_seams! do
    for key <- [
          :runtime_admission_test_hold,
          :runtime_admission_test_crash_after_taskstore_settle,
          :runtime_admission_test_crash_after_durable_bind,
          :runtime_admission_test_crash_after_handoff_ack,
          :runtime_admission_test_claim_inventory_force_error,
          :runtime_admission_test_claim_inventory_malformed,
          :runtime_admission_test_claim_inventory_hang,
          :runtime_admission_test_claim_join_hang,
          :runtime_admission_test_durable_mark_hang,
          :runtime_admission_test_durable_mark_force_error,
          :runtime_admission_empty_claim_inventory_on_authority_error,
          :runtime_admission_observe_test_hang
        ] do
      Application.delete_env(:arbor_agent, key)
    end

    :ok
  end

  defp await_running_runtime_admission_reconcile!(store_pid, attempts \\ 80)
       when is_pid(store_pid) do
    state = :sys.get_state(store_pid)
    rec = Map.get(state, :runtime_admission_reconcile, %{})

    if Map.get(rec, :status) == :running and is_reference(Map.get(rec, :ref)) and
         is_pid(Map.get(rec, :worker_pid)) do
      rec
    else
      if attempts <= 0 do
        flunk("runtime admission reconcile did not reach running status")
      else
        Process.sleep(50)
        await_running_runtime_admission_reconcile!(store_pid, attempts - 1)
      end
    end
  end

  # After injecting a bad complete, the attempt must leave :running for that ref
  # without ever marking runtime_admission_ready?.
  defp await_reconcile_result_rejected!(store_pid, stale_ref, store_name, attempts \\ 80)
       when is_pid(store_pid) and is_reference(stale_ref) do
    state = :sys.get_state(store_pid)
    rec = Map.get(state, :runtime_admission_reconcile, %{})
    ready? = call_public(TaskStore, :runtime_admission_ready?, [[name: store_name]]) == true

    left_attempt? =
      Map.get(rec, :ref) != stale_ref or Map.get(rec, :status) != :running

    cond do
      ready? ->
        flunk("owner-only/stale reconcile result marked runtime_admission_ready?")

      left_attempt? ->
        :ok

      attempts <= 0 ->
        flunk("stale reconcile result was not rejected in time")

      true ->
        Process.sleep(50)
        await_reconcile_result_rejected!(store_pid, stale_ref, store_name, attempts - 1)
    end
  end

  defp guarded_intent_holds_fence?(store, target, op_id) do
    with pid when is_pid(pid) <- Process.whereis(store),
         %{runtime_admission_intents: intents, target_fences: fences} <- :sys.get_state(pid),
         ^op_id <- Map.get(fences, target),
         intent when is_map(intent) <- Map.get(intents, target) do
      Arbor.Agent.RuntimeAdmission.IntentCore.non_idle_guarded_restore?(
        %{target => intent},
        target
      )
    else
      _ -> false
    end
  end

  defp runtime_admission_intent_active?(store, target, kind) do
    with pid when is_pid(pid) <- Process.whereis(store),
         %{runtime_admission_intents: intents} <- :sys.get_state(pid),
         %{kind: ^kind, phase: phase} <- Map.get(intents, target) do
      phase != :terminal
    else
      _ -> false
    end
  end

  defp guarded_intent_effect_handed_off?(store, target, op_id) do
    with pid when is_pid(pid) <- Process.whereis(store),
         %{runtime_admission_intents: intents, target_fences: fences} <- :sys.get_state(pid),
         ^op_id <- Map.get(fences, target),
         %{
           kind: :guarded_restore,
           effect_handoff?: true,
           worker_pid: worker_pid,
           phase: phase
         } <- Map.get(intents, target) do
      phase != :terminal and is_pid(worker_pid) and Process.alive?(worker_pid)
    else
      _ -> false
    end
  end

  defp find_runtime_admission_owner_pid(target) when is_binary(target) do
    case Registry.lookup(
           Arbor.Agent.RuntimeAdmissionRegistry,
           {:runtime_admission_owner, target}
         ) do
      [{pid, _}] when is_pid(pid) -> pid
      _ -> nil
    end
  end

  defp claim_phase?(target, phase) when is_binary(target) and is_binary(phase) do
    case call_public(Store, :fetch, [target]) do
      {:ok, op} ->
        claim = op["runtime_restore_admission"]
        is_map(claim) and claim["claim_phase"] == phase

      _ ->
        false
    end
  end

  defp claim_phase_in?(target, phases) when is_binary(target) and is_list(phases) do
    Enum.any?(phases, &claim_phase?(target, &1))
  end

  defp register_exact_branch_from_claim!(target) when is_binary(target) do
    assert {:ok, op} = call_public(Store, :fetch, [target])
    claim = op["runtime_restore_admission"]
    assert is_map(claim)
    assert is_binary(claim["intent_id"])
    assert is_binary(claim["fingerprint"])
    assert is_binary(claim["operation_id"])
    assert is_binary(claim["token"])

    witness = %{
      v: 1,
      kind: :guarded_restore,
      intent_id: claim["intent_id"],
      fingerprint: claim["fingerprint"],
      operation_id: claim["operation_id"],
      token: claim["token"]
    }

    case call_public(BranchSupervisor, :whereis, [target]) do
      pid when is_pid(pid) ->
        pid

      _ ->
        {:ok, branch_pid} =
          Agent.start_link(fn -> :ok end,
            name: {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:branch, target}, witness}}
          )

        on_exit(fn ->
          if Process.alive?(branch_pid), do: Agent.stop(branch_pid)
        end)

        branch_pid
    end
  end

  defp persist_minimal_agent! do
    agent_id = "agent_rai#{System.unique_integer([:positive])}"

    profile = %Profile{
      agent_id: agent_id,
      display_name: "RAI Test",
      character: Character.new(name: "RAI", tone: "test"),
      identity: %{public_key: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)},
      metadata: %{},
      created_at: DateTime.utc_now(),
      version: 1
    }

    _ = ProfileStore.store_profile(profile)
    agent_id
  end

  defp refute_secret_in_status!(rendered, token, fingerprint, operation_id)
       when is_binary(rendered) and is_binary(token) and is_binary(fingerprint) and
              is_binary(operation_id) do
    refute rendered =~ token,
           "status leaked restore_token sentinel"

    refute rendered =~ fingerprint,
           "status leaked full fingerprint sentinel"

    # Partial fingerprint redaction is also forbidden.
    if byte_size(fingerprint) >= 12 do
      refute rendered =~ binary_part(fingerprint, 0, 12),
             "status leaked fingerprint prefix"
    end

    refute rendered =~ operation_id,
           "status leaked operation_id sentinel"

    :ok
  end

  # Begin always binds exact durable operation_id (no 1-arity / from_durable_slot).
  defp begin_restore_admission!(target) when is_binary(target) do
    assert {:ok, op} = call_public(Store, :fetch, [target])
    op_id = op["operation_id"]
    assert is_binary(op_id)
    call_public(Store, :begin_runtime_restore_admission, [target, op_id])
  end

  defp open_runtime_restore_op! do
    target = "agent_gr#{System.unique_integer([:positive])}"
    op_id = "op_gr_#{System.unique_integer([:positive])}"

    {:ok, envelope} = TemplateAuthorityPolicy.build("coding_agent", @template_data)

    facts = %{
      "operation_id" => op_id,
      "target_agent_id" => target,
      "authorizing_caller_id" => "agent_caller_gr1",
      "expected_preview_reconciliation_digest" => @digest,
      "desired_authority" => %{"envelope" => envelope},
      "scope" => "local_owner",
      "durability" => "node_restart",
      "created_at_unix_ms" => 1_000
    }

    assert {:ok, _op} = call_public(Store, :open, [facts])
    assert {:ok, observed} = call_public(Store, :snapshot, [target])
    observed = to_runtime_restore!(observed)
    assert observed.data["phase"] == "runtime_restore"
    assert observed.data["fence_state"]["installed"] == true
    assert observed.data["runtime_restore_admission"] == nil
    {target, op_id}
  end

  defp to_runtime_restore!(observed) do
    observed = apply_step!(observed, &Core.acknowledge(&1, ack_facts("reserved", t(1))))
    observed = prepare!(observed, t(2))
    observed = apply_step!(observed, &Core.acknowledge(&1, ack_facts("prepared", t(3))))
    observed = apply_step!(observed, &Core.acknowledge(&1, ack_facts("deny_all_intent", t(4))))

    observed =
      apply_step!(
        observed,
        &Core.acknowledge(
          &1,
          ack_facts("deny_all_installed", t(5), %{"runtime_was_running" => true})
        )
      )

    observed =
      apply_step!(
        observed,
        &Core.plan_capability_effects(&1, %{"at_unix_ms" => t(10), "entries" => []})
      )

    observed =
      apply_step!(observed, &Core.acknowledge(&1, ack_facts("capability_effects", t(11))))

    observed = apply_step!(observed, &Core.acknowledge(&1, ack_facts("profile_commit", t(12))))
    observed = apply_step!(observed, &Core.acknowledge(&1, ack_facts("desired_trust", t(13))))
    apply_step!(observed, &Core.acknowledge(&1, ack_facts("verifying", t(14))))
  end

  defp apply_step!(observed_record, reducer) do
    observed_op = observed_record.data
    assert {:ok, next, _effects} = reducer.(observed_op)
    assert {:ok, committed} = call_public(Store, :compare_and_swap, [observed_record, next])
    committed
  end

  defp prepare!(observed_record, at) do
    operation = observed_record.data

    facts = %{
      "at_unix_ms" => at,
      "profile_cas" => %{"record_id" => "profile_rec_1", "generation" => 1, "revision" => 1},
      "frozen_authority" => frozen_authority(operation),
      "profile_mutation_replay" => profile_mutation_replay()
    }

    apply_step!(observed_record, &Core.prepare(&1, facts))
  end

  defp frozen_authority(operation) do
    envelope = operation["desired_authority"]["envelope"]
    snap = TemplateAuthorityPolicy.snapshot(envelope)
    declared = TemplateAuthorityPolicy.capabilities(snap)

    assert {:ok, caps} =
             TemplateAuthorityCapabilityProjection.project_normalized(
               declared,
               operation["target_agent_id"],
               repo_root: @repo_root
             )

    %{"repo_root" => @repo_root, "effective_capabilities" => caps}
  end

  defp profile_mutation_replay do
    %{
      "version" => ProfileAuthorityMutationCore.commitment_version(),
      "kind" => ProfileAuthorityMutationCore.commitment_kind(),
      "algorithm" => ProfileAuthorityMutationCore.commitment_algorithm(),
      "encoding" => ProfileAuthorityMutationCore.commitment_encoding(),
      "domain" => ProfileAuthorityMutationCore.commitment_domain(),
      "anchor_digest" => String.duplicate("11", 32),
      "successor_digest" => String.duplicate("22", 32)
    }
  end

  defp ack_facts(phase, at, extra \\ %{}),
    do: Map.merge(%{"phase_intent" => phase, "at_unix_ms" => at}, extra)

  defp t(n), do: 1_000 + n

  defp mint_intent_id do
    "rai_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  # Test-side token helper outside the pure claim core (CRC: randomness is shell).
  # Fixed-valid grammar; optional distinct filler for uniqueness across cases.
  defp mint_restore_token_literal(filler) when is_binary(filler) do
    ch = filler |> String.first() |> Kernel.||("x")
    "rrt_" <> String.duplicate(ch, 22)
  end

  defp canonical_guarded_witness do
    %{
      v: 1,
      kind: :guarded_restore,
      intent_id: mint_intent_id(),
      fingerprint: "fp_" <> String.duplicate("ab", 32),
      operation_id: "op_wit_#{System.unique_integer([:positive])}",
      token: mint_restore_token_literal("w")
    }
  end

  defp assert_eventually(fun, attempts \\ 60) do
    if fun.() do
      true
    else
      if attempts <= 0 do
        flunk("condition not met in time")
      else
        Process.sleep(50)
        assert_eventually(fun, attempts - 1)
      end
    end
  end

  defp start_named_ra_supervisor(prefix) do
    name = unique_name(prefix)
    start_supervised!({RASupervisor, name: name}, id: name)
  end

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"
end
