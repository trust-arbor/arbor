defmodule Arbor.Orchestrator.EngineCanonicalKeyedReplaySecurityRegressionTest do
  @moduledoc """
  G3C1 Engine resume regressions for verified idempotent_with_key replay.

  Proves original execution_id reuse, successor-generation prepare after
  settle, stale repeated-node markers, authority-context hash normalization,
  and handler/delegate drift with zero journal mutation.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Actions.TestFixtures.ReplayKeyedPinAction
  alias Arbor.Common.ActionRegistry
  alias Arbor.Contracts.Persistence.Record, as: PersistenceRecord
  alias Arbor.Orchestrator.CodingPlan.{ActionCatalog, ExecutionManifest}
  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Engine.{Checkpoint, Context, Outcome, RunAuthorization}
  alias Arbor.Orchestrator.Handlers.{ExecHandler, Registry}
  alias Arbor.Orchestrator.IR.Compiler
  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RunJournal
  alias Arbor.Orchestrator.RunLifecycle.Record

  @agent_id "agent_g3c1_keyed"
  @agent_context %{"session.agent_id" => @agent_id}

  defmodule KeyedNoDelegateHandler do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def idempotency, do: :idempotent_with_key

    @impl true
    def execute(node, _context, _graph, opts) do
      if pid = Application.get_env(:arbor_orchestrator, :g3c1_keyed_replay_test_pid) do
        send(pid, {:g3c1_keyed, opts[:execution_id]})
      end

      %Outcome{status: :success, context_updates: %{"probe.keyed" => node.id}}
    end
  end

  defmodule FailStore do
    @moduledoc false
    use GenServer

    def durability_class(_opts), do: :process_lifetime

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)

      GenServer.start_link(
        __MODULE__,
        %{
          fail_on: Keyword.fetch!(opts, :fail_on),
          fail_node: Keyword.get(opts, :fail_node, "task"),
          fired?: false,
          data: %{}
        },
        name: name
      )
    end

    def put(key, value, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value})
    def get(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
    def list(opts), do: GenServer.call(Keyword.fetch!(opts, :name), :list)
    def delete(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})
    def rearm(name, fail_on), do: GenServer.call(name, {:rearm, fail_on})

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:put, key, value}, _from, state) do
      if not state.fired? and matches?(state.fail_on, state.fail_node, value) do
        {:reply, {:error, {:oneshot_fail, state.fail_on}}, %{state | fired?: true}}
      else
        {:reply, :ok, %{state | data: Map.put(state.data, key, value)}}
      end
    end

    def handle_call({:get, key}, _from, state) do
      case Map.fetch(state.data, key) do
        {:ok, v} -> {:reply, {:ok, v}, state}
        :error -> {:reply, {:error, :not_found}, state}
      end
    end

    def handle_call(:list, _from, state), do: {:reply, {:ok, Map.keys(state.data)}, state}

    def handle_call({:delete, key}, _from, state) do
      {:reply, :ok, %{state | data: Map.delete(state.data, key)}}
    end

    def handle_call({:rearm, fail_on}, _from, state) do
      {:reply, :ok, %{state | fail_on: fail_on, fired?: false}}
    end

    defp matches?(fail_on, fail_node, value) do
      data = lifecycle_data(value)
      effect = data["current_effect"]

      case fail_on do
        :receipt ->
          is_map(effect) and effect["status"] == "completed" and effect["node_id"] == fail_node

        :second_receipt ->
          is_map(effect) and effect["status"] == "completed" and
            effect["node_id"] == fail_node and effect["generation"] > 1

        :successor_prepare ->
          is_map(effect) and effect["status"] == "pending" and effect["node_id"] == fail_node and
            is_integer(effect["generation"]) and effect["generation"] > 1

        _ ->
          false
      end
    end

    defp lifecycle_data(%PersistenceRecord{data: data}) when is_map(data), do: data
    defp lifecycle_data(%{data: data}) when is_map(data), do: data
    defp lifecycle_data(data) when is_map(data), do: data
    defp lifecycle_data(_), do: %{}
  end

  setup do
    ensure_action_registry_started!()
    snapshot = ActionRegistry.snapshot()
    install_fixture_bindings!(%{"test_g3c1_keyed_pin" => ReplayKeyedPinAction})
    :ok = Arbor.Orchestrator.TestCapabilities.grant_orchestrator_access(@agent_id)

    :ok =
      Arbor.Orchestrator.TestCapabilities.grant_capability(
        @agent_id,
        Arbor.Actions.canonical_uri_for(ReplayKeyedPinAction, %{})
      )

    previous_pid = Application.get_env(:arbor_orchestrator, :g3c1_keyed_replay_test_pid)
    previous_break = Application.get_env(:arbor_orchestrator, :g3c1_break_logs_root)
    Application.put_env(:arbor_orchestrator, :g3c1_keyed_replay_test_pid, self())
    Application.delete_env(:arbor_orchestrator, :g3c1_break_logs_root)

    on_exit(fn ->
      if Process.whereis(ActionRegistry), do: ActionRegistry.restore(snapshot)
      Arbor.Orchestrator.TestCapabilities.revoke_all(@agent_id)
      restore_env(:g3c1_keyed_replay_test_pid, previous_pid)
      restore_env(:g3c1_break_logs_root, previous_break)
    end)

    :ok
  end

  test "security regression: pending absent-marker resume reuses the original execution_id" do
    ctx = start_backed_journal("g3c1_pend", :receipt)
    jopts = [server: ctx.journal_name]
    identity = :crypto.strong_rand_bytes(32)
    logs_root = tmp_logs("g3c1_pend")
    graph = parse!(keyed_dot())

    assert {:error, {:effect_receipt_failed, _}} =
             Engine.run(graph,
               run_id: ctx.run_id,
               logs_root: logs_root,
               journal_opts: jopts,
               identity_private_key: identity,
               resumable: true,
               initial_values: @agent_context
             )

    assert_receive {:g3c1_keyed, exec_id}, 1_000
    rec = PipelineStatus.get_record(ctx.run_id, jopts)
    assert rec.current_effect["status"] == "pending"
    assert rec.current_effect["execution_id"] == exec_id
    started_at = rec.current_effect["started_at"]
    generation = rec.current_effect["generation"]

    FailStore.rearm(ctx.store_name, :never)
    reopen_as_recovering!(ctx.run_id, jopts, logs_root)

    assert {:ok, result} =
             Engine.run(graph,
               run_id: ctx.run_id,
               logs_root: logs_root,
               journal_opts: jopts,
               identity_private_key: identity,
               resume: true,
               recovery: true
             )

    assert_receive {:g3c1_keyed, ^exec_id}, 1_000
    refute_receive {:g3c1_keyed, _}, 150
    assert "task" in result.completed_nodes

    final = PipelineStatus.get_record(ctx.run_id, jopts)
    assert final.current_effect["execution_id"] == exec_id
    assert final.current_effect["started_at"] == started_at
    assert final.current_effect["generation"] == generation
    assert final.current_effect["status"] == "settled"
  end

  test "security regression: nil-binding keyed handlers replay pending visits" do
    saved = Registry.snapshot_custom_handlers()
    Registry.reset_custom_handlers()
    :ok = Registry.register("g3c1_keyed_probe", KeyedNoDelegateHandler)

    on_exit(fn -> Registry.restore_custom_handlers(saved) end)

    ctx = start_backed_journal("g3c1_nilbind", :receipt)
    jopts = [server: ctx.journal_name]
    identity = :crypto.strong_rand_bytes(32)
    logs_root = tmp_logs("g3c1_nilbind")
    graph = parse!(keyed_probe_dot())

    assert {:error, {:effect_receipt_failed, _}} =
             Engine.run(graph,
               run_id: ctx.run_id,
               logs_root: logs_root,
               journal_opts: jopts,
               identity_private_key: identity,
               resumable: true,
               initial_values: @agent_context
             )

    assert_receive {:g3c1_keyed, exec_id}, 1_000
    rec = PipelineStatus.get_record(ctx.run_id, jopts)
    assert rec.current_effect["status"] == "pending"
    assert rec.current_effect["idempotency_class"] == "idempotent_with_key"
    assert rec.current_effect["execution_id"] == exec_id

    FailStore.rearm(ctx.store_name, :never)
    reopen_as_recovering!(ctx.run_id, jopts, logs_root)

    assert {:ok, result} =
             Engine.run(graph,
               run_id: ctx.run_id,
               logs_root: logs_root,
               journal_opts: jopts,
               identity_private_key: identity,
               resume: true,
               recovery: true
             )

    assert_receive {:g3c1_keyed, ^exec_id}, 1_000
    refute_receive {:g3c1_keyed, _}, 150
    assert "task" in result.completed_nodes

    final = PipelineStatus.get_record(ctx.run_id, jopts)
    assert final.current_effect["execution_id"] == exec_id
    assert final.current_effect["status"] == "settled"
  end

  test "security regression: stale repeated-node marker replays the second execution_id" do
    ctx = start_backed_journal("g3c1_stale", :second_receipt)
    jopts = [server: ctx.journal_name]
    identity = :crypto.strong_rand_bytes(32)
    logs_root = tmp_logs("g3c1_stale")
    graph = parse!(loop_dot())

    assert {:error, {:effect_receipt_failed, _}} =
             run_loop_until_second_receipt_fails(graph, ctx, logs_root, identity, jopts)

    exec_ids = flush_keyed()
    assert length(exec_ids) == 2
    [first_id, second_id] = exec_ids
    refute first_id == second_id

    rec = PipelineStatus.get_record(ctx.run_id, jopts)
    assert rec.current_effect["status"] == "pending"
    assert rec.current_effect["execution_id"] == second_id
    assert "task" in (rec.completed_nodes || [])

    FailStore.rearm(ctx.store_name, :never)
    reopen_as_recovering!(ctx.run_id, jopts, logs_root)

    assert {:ok, _result} =
             Engine.run(graph,
               run_id: ctx.run_id,
               logs_root: logs_root,
               journal_opts: jopts,
               identity_private_key: identity,
               resume: true,
               recovery: true,
               initial_values: %{"done" => false, "true_value" => true}
             )

    assert_receive {:g3c1_keyed, ^second_id}, 1_000
    refute_receive {:g3c1_keyed, _}, 150

    final = PipelineStatus.get_record(ctx.run_id, jopts)
    assert final.current_effect["execution_id"] == second_id
    refute final.current_effect["execution_id"] == first_id
  end

  test "security regression: completed-unapplied settles then prepares a successor with the same execution_id" do
    ctx = start_isolated_journal("g3c1_unapp")
    jopts = [server: ctx.journal_name]
    identity = :crypto.strong_rand_bytes(32)
    logs_root = tmp_logs("g3c1_unapp")
    {:ok, breaker} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(breaker), do: Agent.stop(breaker) end)
    Application.put_env(:arbor_orchestrator, :g3c1_break_logs_root, {logs_root, breaker})

    graph = parse!(keyed_dot())

    assert {:error, {:effect_checkpoint_failed, _}} =
             Engine.run(graph,
               run_id: ctx.run_id,
               logs_root: logs_root,
               journal_opts: jopts,
               identity_private_key: identity,
               resumable: true,
               initial_values: @agent_context
             )

    assert_receive {:g3c1_keyed, exec_id}, 1_000
    rec = PipelineStatus.get_record(ctx.run_id, jopts)
    assert rec.current_effect["status"] == "completed"
    assert rec.current_effect["execution_id"] == exec_id
    old_generation = rec.current_effect["generation"]
    old_started = rec.current_effect["started_at"]

    _ = File.rm_rf(logs_root)
    :ok = File.mkdir_p(logs_root)
    seed_start_checkpoint!(logs_root, ctx.run_id, identity)
    reopen_as_recovering!(ctx.run_id, jopts, logs_root)

    assert {:ok, _result} =
             Engine.run(graph,
               run_id: ctx.run_id,
               logs_root: logs_root,
               journal_opts: jopts,
               identity_private_key: identity,
               resume: true,
               recovery: true
             )

    assert_receive {:g3c1_keyed, ^exec_id}, 1_000
    final = PipelineStatus.get_record(ctx.run_id, jopts)
    assert final.current_effect["execution_id"] == exec_id
    assert final.current_effect["generation"] > old_generation
    assert final.current_effect["started_at"] != old_started
    assert final.current_effect["status"] == "settled"
  end

  test "security regression: crash between settle and successor prepare keeps the original execution_id" do
    ctx = start_backed_journal("g3c1_succ", :receipt)
    jopts = [server: ctx.journal_name]
    identity = :crypto.strong_rand_bytes(32)
    logs_root = tmp_logs("g3c1_succ")
    {:ok, breaker} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(breaker), do: Agent.stop(breaker) end)
    Application.put_env(:arbor_orchestrator, :g3c1_break_logs_root, {logs_root, breaker})
    graph = parse!(keyed_dot())

    FailStore.rearm(ctx.store_name, :never)

    assert {:error, {:effect_checkpoint_failed, _}} =
             Engine.run(graph,
               run_id: ctx.run_id,
               logs_root: logs_root,
               journal_opts: jopts,
               identity_private_key: identity,
               resumable: true,
               initial_values: @agent_context
             )

    assert_receive {:g3c1_keyed, exec_id}, 1_000
    rec = PipelineStatus.get_record(ctx.run_id, jopts)
    assert rec.current_effect["status"] == "completed"
    old_generation = rec.current_effect["generation"]

    _ = File.rm_rf(logs_root)
    :ok = File.mkdir_p(logs_root)
    seed_start_checkpoint!(logs_root, ctx.run_id, identity)
    reopen_as_recovering!(ctx.run_id, jopts, logs_root)
    FailStore.rearm(ctx.store_name, :successor_prepare)

    assert {:error, {:effect_prepare_failed, _}} =
             Engine.run(graph,
               run_id: ctx.run_id,
               logs_root: logs_root,
               journal_opts: jopts,
               identity_private_key: identity,
               resume: true,
               recovery: true
             )

    mid = PipelineStatus.get_record(ctx.run_id, jopts)
    assert mid.current_effect["status"] == "settled"
    assert mid.current_effect["execution_id"] == exec_id
    assert mid.current_effect["generation"] == old_generation
    refute_receive {:g3c1_keyed, _}, 150

    FailStore.rearm(ctx.store_name, :never)
    reopen_as_recovering!(ctx.run_id, jopts, logs_root)

    assert {:ok, _result} =
             Engine.run(graph,
               run_id: ctx.run_id,
               logs_root: logs_root,
               journal_opts: jopts,
               identity_private_key: identity,
               resume: true,
               recovery: true
             )

    assert_receive {:g3c1_keyed, ^exec_id}, 1_000
    final = PipelineStatus.get_record(ctx.run_id, jopts)
    assert final.current_effect["execution_id"] == exec_id
    assert final.current_effect["generation"] > old_generation
    assert final.current_effect["status"] == "settled"
  end

  test "security regression: side-effecting pins stay fail-closed even with force_replay" do
    ctx = start_backed_journal("g3c1_side", :receipt)
    jopts = [server: ctx.journal_name]
    identity = :crypto.strong_rand_bytes(32)
    logs_root = tmp_logs("g3c1_side")
    graph = parse!(side_pin_dot())

    assert {:error, {:effect_receipt_failed, _}} =
             Engine.run(graph,
               run_id: ctx.run_id,
               logs_root: logs_root,
               journal_opts: jopts,
               identity_private_key: identity,
               resumable: true,
               initial_values: @agent_context
             )

    assert_receive {:g3c1_keyed, exec_id}, 1_000
    reopen_as_recovering!(ctx.run_id, jopts, logs_root)

    assert {:error, {:indeterminate_effect, "task", ^exec_id}} =
             Engine.run(graph,
               run_id: ctx.run_id,
               logs_root: logs_root,
               journal_opts: jopts,
               identity_private_key: identity,
               resume: true,
               recovery: true,
               force_replay: true
             )

    refute_receive {:g3c1_keyed, _}, 150
    rec = PipelineStatus.get_record(ctx.run_id, jopts)
    assert rec.current_effect["status"] == "pending"
    assert rec.current_effect["execution_id"] == exec_id
  end

  test "security regression: context cannot override a static keyed replay classification" do
    ctx = start_backed_journal("g3c1_shadow", :receipt)
    jopts = [server: ctx.journal_name]
    identity = :crypto.strong_rand_bytes(32)
    logs_root = tmp_logs("g3c1_shadow")
    graph = parse!(shadowed_pin_dot())

    assert {:error, {:effect_receipt_failed, _}} =
             Engine.run(graph,
               run_id: ctx.run_id,
               logs_root: logs_root,
               journal_opts: jopts,
               identity_private_key: identity,
               resumable: true,
               initial_values: Map.put(@agent_context, "pin", "default")
             )

    assert_receive {:g3c1_keyed, exec_id}, 1_000
    rec = PipelineStatus.get_record(ctx.run_id, jopts)
    assert rec.current_effect["idempotency_class"] == "side_effecting"
    assert rec.current_effect["execution_id"] == exec_id

    FailStore.rearm(ctx.store_name, :never)
    reopen_as_recovering!(ctx.run_id, jopts, logs_root)

    assert {:error, {:indeterminate_effect, "task", ^exec_id}} =
             Engine.run(graph,
               run_id: ctx.run_id,
               logs_root: logs_root,
               journal_opts: jopts,
               identity_private_key: identity,
               resumable: true,
               resume: true,
               recovery: true,
               force_replay: true,
               initial_values: %{"pin" => "default"}
             )

    refute_receive {:g3c1_keyed, _}, 150
  end

  test "security regression: canonical replay bypasses a matching cached success" do
    ctx = start_backed_journal("g3c1_cached", :receipt)
    jopts = [server: ctx.journal_name]
    identity = :crypto.strong_rand_bytes(32)
    logs_root = tmp_logs("g3c1_cached")
    graph = parse!(keyed_dot())

    assert {:error, {:effect_receipt_failed, _}} =
             Engine.run(graph,
               run_id: ctx.run_id,
               logs_root: logs_root,
               journal_opts: jopts,
               identity_private_key: identity,
               resumable: true,
               initial_values: @agent_context
             )

    assert_receive {:g3c1_keyed, exec_id}, 1_000
    rec = PipelineStatus.get_record(ctx.run_id, jopts)
    assert rec.current_effect["status"] == "pending"

    seed_matching_cached_task!(
      logs_root,
      ctx.run_id,
      identity,
      rec.current_effect["input_hash"]
    )

    FailStore.rearm(ctx.store_name, :never)
    reopen_as_recovering!(ctx.run_id, jopts, logs_root)

    assert {:ok, _result} =
             Engine.run(graph,
               run_id: ctx.run_id,
               logs_root: logs_root,
               journal_opts: jopts,
               identity_private_key: identity,
               resumable: true,
               resume: true,
               recovery: true
             )

    assert_receive {:g3c1_keyed, ^exec_id}, 1_000
    refute_receive {:g3c1_keyed, _}, 150

    final = PipelineStatus.get_record(ctx.run_id, jopts)
    assert final.current_effect["status"] == "settled"
    assert final.current_effect["execution_id"] == exec_id
  end

  test "security regression: enforce_context hash admits replay; unoverwritten context mismatch does not" do
    ctx = start_isolated_journal("g3c1_hash")
    jopts = [server: ctx.journal_name]
    identity = :crypto.strong_rand_bytes(32)
    logs_root = tmp_logs("g3c1_hash")
    {:ok, breaker} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(breaker), do: Agent.stop(breaker) end)
    Application.put_env(:arbor_orchestrator, :g3c1_break_logs_root, {logs_root, breaker})

    graph = parse!(keyed_context_dot())
    workdir_root = tmp_logs("g3c1_hash_wd")
    {:ok, workdir} = Arbor.Common.SafePath.resolve_real(workdir_root)

    {opts, projection, graph_hash} =
      authorized_opts(graph, ctx.run_id, logs_root, workdir, identity, jopts)

    assert {:error, {:effect_checkpoint_failed, _}} = Engine.run(graph, opts)

    assert_receive {:g3c1_keyed, exec_id}, 1_000
    rec = PipelineStatus.get_record(ctx.run_id, jopts)
    assert rec.current_effect["status"] == "completed"

    hmac = Engine.derive_checkpoint_hmac_secret(identity_private_key: identity)
    _ = File.rm_rf(logs_root)
    :ok = File.mkdir_p(logs_root)
    seed_start_checkpoint!(logs_root, ctx.run_id, identity, projection, graph_hash)

    poison_checkpoint_context!(logs_root, ctx.run_id, hmac, %{
      "workdir" => "/tmp/g3c1-poisoned-workdir",
      "session.agent_id" => "agent_forged"
    })

    reopen_as_recovering!(ctx.run_id, jopts, logs_root)

    assert {:ok, _result} =
             Engine.run(graph, Keyword.merge(opts, resume: true, recovery: true))

    assert_receive {:g3c1_keyed, ^exec_id}, 1_000

    ctx2 = start_isolated_journal("g3c1_hash_miss")
    jopts2 = [server: ctx2.journal_name]
    logs2 = tmp_logs("g3c1_hash_miss")
    {:ok, breaker2} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(breaker2), do: Agent.stop(breaker2) end)
    Application.put_env(:arbor_orchestrator, :g3c1_break_logs_root, {logs2, breaker2})

    {opts2, projection2, graph_hash2} =
      authorized_opts(graph, ctx2.run_id, logs2, workdir, identity, jopts2)

    assert {:error, {:effect_checkpoint_failed, _}} = Engine.run(graph, opts2)
    assert_receive {:g3c1_keyed, exec_id2}, 1_000
    rec2 = PipelineStatus.get_record(ctx2.run_id, jopts2)
    generation2 = rec2.current_effect["generation"]
    started2 = rec2.current_effect["started_at"]

    _ = File.rm_rf(logs2)
    :ok = File.mkdir_p(logs2)
    seed_start_checkpoint!(logs2, ctx2.run_id, identity, projection2, graph_hash2)
    poison_checkpoint_context!(logs2, ctx2.run_id, hmac, %{"payload" => "tampered"})
    reopen_as_recovering!(ctx2.run_id, jopts2, logs2)

    assert {:error, {:completed_effect_unapplied, "task", ^exec_id2}} =
             Engine.run(graph, Keyword.merge(opts2, resume: true, recovery: true))

    refute_receive {:g3c1_keyed, _}, 150
    after_rec = PipelineStatus.get_record(ctx2.run_id, jopts2)
    assert after_rec.current_effect["status"] == "completed"
    assert after_rec.current_effect["execution_id"] == exec_id2
    assert after_rec.current_effect["generation"] == generation2
    assert after_rec.current_effect["started_at"] == started2
  end

  test "security regression: handler drift refuses replay without journal mutation" do
    ctx = start_isolated_journal("g3c1_drift")
    jopts = [server: ctx.journal_name]
    identity = :crypto.strong_rand_bytes(32)
    logs_root = tmp_logs("g3c1_drift")
    {:ok, breaker} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(breaker), do: Agent.stop(breaker) end)
    Application.put_env(:arbor_orchestrator, :g3c1_break_logs_root, {logs_root, breaker})

    graph = parse!(keyed_dot())
    workdir_root = tmp_logs("g3c1_drift_wd")
    {:ok, workdir} = Arbor.Common.SafePath.resolve_real(workdir_root)

    {opts, projection, graph_hash} =
      authorized_opts(graph, ctx.run_id, logs_root, workdir, identity, jopts)

    {ExecHandler, original_beam, original_filename} = :code.get_object_code(ExecHandler)
    on_exit(fn -> restore_loaded_module!(ExecHandler, original_filename, original_beam) end)

    assert {:error, {:effect_checkpoint_failed, _}} = Engine.run(graph, opts)
    assert_receive {:g3c1_keyed, exec_id}, 1_000
    rec = PipelineStatus.get_record(ctx.run_id, jopts)
    assert rec.current_effect["status"] == "completed"
    generation = rec.current_effect["generation"]
    started_at = rec.current_effect["started_at"]

    _ = File.rm_rf(logs_root)
    :ok = File.mkdir_p(logs_root)
    seed_start_checkpoint!(logs_root, ctx.run_id, identity, projection, graph_hash)
    replace_exec_handler!()
    reopen_as_recovering!(ctx.run_id, jopts, logs_root)

    assert {:error, {:completed_effect_unapplied, "task", ^exec_id}} =
             Engine.run(graph, Keyword.merge(opts, resume: true, recovery: true))

    refute_receive {:g3c1_keyed, _}, 150
    after_rec = PipelineStatus.get_record(ctx.run_id, jopts)
    assert after_rec.current_effect["status"] == "completed"
    assert after_rec.current_effect["execution_id"] == exec_id
    assert after_rec.current_effect["generation"] == generation
    assert after_rec.current_effect["started_at"] == started_at
    assert after_rec.effect_generation == rec.effect_generation
  end

  defp run_loop_until_second_receipt_fails(graph, ctx, logs_root, identity, jopts) do
    Engine.run(graph,
      run_id: ctx.run_id,
      logs_root: logs_root,
      journal_opts: jopts,
      identity_private_key: identity,
      resumable: true,
      initial_values: Map.merge(@agent_context, %{"done" => false, "true_value" => true})
    )
  end

  defp keyed_probe_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="g3c1_keyed_probe"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end

  defp keyed_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="exec", target="action", action="test_g3c1_keyed_pin", param.pin="cross_app"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end

  defp keyed_context_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="exec", target="action", action="test_g3c1_keyed_pin", param.pin="cross_app", context_keys="payload"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end

  defp side_pin_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="exec", target="action", action="test_g3c1_keyed_pin", param.pin="default", on_resume="retry"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end

  defp shadowed_pin_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="exec", target="action", action="test_g3c1_keyed_pin", param.pin="cross_app", context_keys="pin"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end

  defp loop_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="exec", target="action", action="test_g3c1_keyed_pin", param.pin="cross_app", context_keys="done"]
      check [type="gate", shape=diamond, predicate="expression", expression="done"]
      mark [type="transform", transform="identity", source_key="true_value", output_key="done"]
      exit [shape=Msquare]
      start -> task -> check
      check -> exit [condition="context.done=true"]
      check -> mark [condition="context.done!=true"]
      mark -> task
    }
    """
  end

  defp parse!(dot) do
    assert {:ok, parsed} = Parser.parse(dot)
    assert {:ok, compiled} = Compiler.compile(parsed)
    compiled
  end

  defp authorized_opts(graph, run_id, logs_root, workdir, identity, jopts) do
    graph_hash = RunAuthorization.graph_hash(graph)
    {:ok, catalog} = ActionCatalog.snapshot(modules: [ReplayKeyedPinAction])
    {:ok, {manifest, digest}} = ExecutionManifest.build(graph, catalog, graph_hash)

    opts = [
      authorization: true,
      agent_id: @agent_id,
      authorizer: fn _principal, _handler_type -> :ok end,
      execution_manifest: manifest,
      execution_manifest_digest: digest,
      graph_hash: graph_hash,
      identity_private_key: identity,
      initial_values: %{"payload" => "original"},
      journal_opts: jopts,
      logs_root: logs_root,
      resumable: true,
      run_id: run_id,
      workdir: workdir
    ]

    {:ok, {authority, _prepared}} = RunAuthorization.prepare(graph, opts)
    {opts, RunAuthorization.projection(authority), graph_hash}
  end

  defp poison_checkpoint_context!(logs_root, run_id, hmac, overrides) do
    path = Path.join(logs_root, "checkpoint.json")

    assert {:ok, checkpoint} =
             Checkpoint.load(path, run_id: run_id, hmac_secret: hmac)

    values = Map.merge(checkpoint.context_values || %{}, overrides)
    context = Context.new(values, pipeline_started_at: checkpoint.pipeline_started_at)

    poisoned =
      Checkpoint.from_state(
        checkpoint.current_node,
        checkpoint.completed_nodes || [],
        checkpoint.node_retries || %{},
        context,
        checkpoint.node_outcomes || %{},
        run_id: run_id,
        pipeline_started_at: checkpoint.pipeline_started_at || DateTime.utc_now(),
        execution_digests: checkpoint.execution_digests || %{},
        content_hashes: checkpoint.content_hashes || %{},
        pending_intents: checkpoint.pending_intents || %{},
        run_authorization: checkpoint.run_authorization,
        graph_hash: checkpoint.graph_hash
      )

    assert {:ok, _} = Checkpoint.persist(poisoned, logs_root, hmac_secret: hmac)
  end

  defp seed_matching_cached_task!(logs_root, run_id, identity, input_hash) do
    hmac = Engine.derive_checkpoint_hmac_secret(identity_private_key: identity)
    assert is_binary(hmac)

    path = Path.join(logs_root, "checkpoint.json")
    assert {:ok, checkpoint} = Checkpoint.load(path, run_id: run_id, hmac_secret: hmac)

    context =
      Context.new(checkpoint.context_values || %{},
        pipeline_started_at: checkpoint.pipeline_started_at
      )

    cached =
      Checkpoint.from_state(
        checkpoint.current_node,
        checkpoint.completed_nodes || [],
        checkpoint.node_retries || %{},
        context,
        Map.put(checkpoint.node_outcomes || %{}, "task", %Outcome{status: :success}),
        run_id: run_id,
        pipeline_started_at: checkpoint.pipeline_started_at || DateTime.utc_now(),
        execution_digests: checkpoint.execution_digests || %{},
        content_hashes: Map.put(checkpoint.content_hashes || %{}, "task", input_hash),
        pending_intents: checkpoint.pending_intents || %{},
        run_authorization: checkpoint.run_authorization,
        graph_hash: checkpoint.graph_hash
      )

    assert {:ok, _} = Checkpoint.persist(cached, logs_root, hmac_secret: hmac)
  end

  defp seed_start_checkpoint!(
         logs_root,
         run_id,
         identity,
         run_authorization \\ nil,
         graph_hash \\ nil
       ) do
    context =
      Context.new(
        Map.merge(@agent_context, %{
          "graph.goal" => "",
          "graph.label" => "",
          "outcome" => "success",
          "payload" => "original"
        })
      )

    outcomes = %{"start" => %Outcome{status: :success}}
    hmac = Engine.derive_checkpoint_hmac_secret(identity_private_key: identity)
    assert is_binary(hmac)

    checkpoint =
      Checkpoint.from_state("start", ["start"], %{}, context, outcomes,
        run_id: run_id,
        pipeline_started_at: DateTime.utc_now(),
        execution_digests: %{},
        run_authorization: run_authorization,
        graph_hash: graph_hash
      )

    assert {:ok, _} = Checkpoint.persist(checkpoint, logs_root, hmac_secret: hmac)
  end

  defp reopen_as_recovering!(run_id, jopts, logs_root) do
    rec = PipelineStatus.get_record(run_id, jopts)
    assert %Record{} = rec

    reopened = %Record{
      rec
      | status: :interrupted,
        failure_reason: nil,
        finished_at: nil,
        duration_ms: nil,
        owner_node: nil,
        logs_root: logs_root || rec.logs_root
    }

    assert :ok = PipelineStatus.put(reopened, jopts)
    assert {:ok, _} = PipelineStatus.claim_for_recovery_record(run_id, node(), jopts)
  end

  defp start_isolated_journal(label) do
    suffix = System.unique_integer([:positive, :monotonic])
    journal_name = :"#{label}_journal_#{suffix}"
    ets_table = :"#{label}_hot_#{suffix}"
    run_id = "#{label}_run_#{suffix}"

    {:ok, journal} =
      start_supervised({RunJournal, name: journal_name, ets_table: ets_table})

    on_exit(fn ->
      try do
        _ = PipelineStatus.delete(run_id, server: journal_name)
      catch
        :exit, _ -> :ok
      end

      try do
        GenServer.stop(journal, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    %{journal_name: journal_name, run_id: run_id, journal: journal}
  end

  defp start_backed_journal(label, fail_on) do
    suffix = System.unique_integer([:positive, :monotonic])
    journal_name = :"#{label}_journal_#{suffix}"
    ets_table = :"#{label}_hot_#{suffix}"
    store_name = :"#{label}_store_#{suffix}"
    run_id = "#{label}_run_#{suffix}"

    {:ok, _store} =
      start_supervised({FailStore, name: store_name, fail_on: fail_on})

    {:ok, journal} =
      start_supervised(
        {RunJournal,
         name: journal_name,
         ets_table: ets_table,
         backend: FailStore,
         store_name: store_name,
         start_store: false}
      )

    on_exit(fn ->
      try do
        _ = PipelineStatus.delete(run_id, server: journal_name)
      catch
        :exit, _ -> :ok
      end

      try do
        GenServer.stop(journal, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    %{journal_name: journal_name, store_name: store_name, run_id: run_id, journal: journal}
  end

  defp tmp_logs(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbor_g3c1_#{label}_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp flush_keyed(acc \\ []) do
    receive do
      {:g3c1_keyed, exec_id} -> flush_keyed(acc ++ [exec_id])
    after
      0 -> acc
    end
  end

  defp replace_exec_handler! do
    Code.compile_string("""
    defmodule #{inspect(ExecHandler)} do
      @behaviour Arbor.Orchestrator.Handlers.Handler

      def execute(_node, _context, _graph, _opts) do
        %Arbor.Orchestrator.Engine.Outcome{status: :success}
      end

      def idempotency, do: :idempotent_with_key
      def idempotency(_node), do: :idempotent_with_key

      def execution_classification(_node, _opts) do
        {:ok, %{idempotency: :idempotent_with_key, binding: nil}}
      end

      def execution_delegates(node), do: execution_delegates(node, [])

      def execution_delegates(_node, opts) do
        {:ok,
         [
           {"exec:action",
            Keyword.get(opts, :actions_executor, Arbor.Orchestrator.ActionsExecutor)}
         ]}
      end
    end
    """)

    :ok
  end

  defp restore_loaded_module!(module, filename, beam) do
    :code.purge(module)
    {:module, ^module} = :code.load_binary(module, filename, beam)
    :code.purge(module)
    :ok
  end

  defp ensure_action_registry_started! do
    unless Process.whereis(ActionRegistry) do
      start_supervised!({ActionRegistry, []})
    end
  end

  defp install_fixture_bindings!(bindings) do
    {entries, locked?} = ActionRegistry.snapshot()
    names = Map.keys(bindings)

    retained =
      Enum.reject(entries, fn {name, _module, _metadata, _failures, _core?} -> name in names end)

    fixtures =
      Enum.map(bindings, fn {name, module} ->
        {name, module, %{category: :test}, 0, false}
      end)

    :ok = ActionRegistry.restore({fixtures ++ retained, locked?})
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_orchestrator, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_orchestrator, key, value)
end
