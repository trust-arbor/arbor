defmodule Arbor.Commands.CodingG3C2CancellationAndCleanupTest do
  @moduledoc """
  G3C2 proofs: cancel a live recovered CrossApp coding run during an active
  validation window and between capacity windows. Lives in arbor_commands so
  it may depend on both arbor_agent and arbor_orchestrator.
  """
  use ExUnit.Case, async: false

  @moduletag :slow
  @moduletag :integration
  @moduletag :security_regression

  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Agent.Orchestration
  alias Arbor.Agent.Orchestration.{TaskControlLease, TaskControlRecoveryMemory, TaskStore}
  alias Arbor.Contracts.Coding.{Plan, WorkPacket}
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Orchestrator
  alias Arbor.Orchestrator.CodingPlan.{ArtifactStore, Readiness}
  alias Arbor.Orchestrator.CodingRunRecovery
  alias Arbor.Orchestrator.Engine.{Checkpoint, Context, Outcome, RunAuthorization}
  alias Arbor.Orchestrator.RunJournal
  alias Arbor.Orchestrator.RunLifecycle.Record
  alias Arbor.Orchestrator.CodingTaskExecutor
  alias Arbor.Security

  @secret_needles [
    "SigningAuthority",
    "private_key",
    "signing_key",
    "fence_token",
    "bearer",
    "BEGIN "
  ]

  defmodule CheckpointHoldStore do
    @moduledoc false
    use GenServer

    def durability_class(_opts), do: :process_lifetime

    def child_spec(opts) do
      name = Keyword.fetch!(opts, :name)
      %{id: name, start: {__MODULE__, :start_link, [opts]}}
    end

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    def put(key, value, opts),
      do: GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value}, :infinity)

    def get(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
    def delete(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})
    def list(opts), do: GenServer.call(Keyword.fetch!(opts, :name), :list)
    def drop_held_caller(name), do: GenServer.call(name, :drop_held_caller)
    def dump(name), do: GenServer.call(name, :dump)

    @impl true
    def init(opts) do
      {:ok,
       %{
         data: %{},
         parent: Keyword.fetch!(opts, :parent),
         mode: Keyword.fetch!(opts, :mode),
         hold_node: Keyword.fetch!(opts, :hold_node),
         hold_fired?: false,
         held_from: nil
       }}
    end

    @impl true
    def handle_call({:put, key, value}, from, state) do
      node = current_node(value)

      if not state.hold_fired? and node == state.hold_node and
           state.mode == :persist_then_hold do
        send(state.parent, {:checkpoint_held, :persisted, node, key})

        {:noreply,
         %{
           state
           | data: Map.put(state.data, key, value),
             hold_fired?: true,
             held_from: from
         }}
      else
        {:reply, :ok, %{state | data: Map.put(state.data, key, value)}}
      end
    end

    def handle_call({:get, key}, _from, state) do
      case Map.fetch(state.data, key) do
        {:ok, value} -> {:reply, {:ok, value}, state}
        :error -> {:reply, {:error, :not_found}, state}
      end
    end

    def handle_call({:delete, key}, _from, state),
      do: {:reply, :ok, %{state | data: Map.delete(state.data, key)}}

    def handle_call(:list, _from, state), do: {:reply, {:ok, Map.keys(state.data)}, state}

    def handle_call(:drop_held_caller, _from, state) do
      {:reply, :ok, %{state | held_from: nil}}
    end

    def handle_call(:dump, _from, state), do: {:reply, state.data, state}

    defp current_node(value) do
      data =
        case value do
          %Arbor.Contracts.Persistence.Record{data: data} when is_map(data) -> data
          %{data: data} when is_map(data) -> data
          data when is_map(data) -> data
          _ -> %{}
        end

      Map.get(data, "current_node") || Map.get(data, :current_node)
    end
  end

  defmodule MixHoldStore do
    @moduledoc false
    use GenServer

    def child_spec(opts) do
      name = Keyword.fetch!(opts, :name)
      %{id: name, start: {__MODULE__, :start_link, [opts]}}
    end

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    def hold_first_test(name, files),
      do: GenServer.call(name, {:hold_first_test, files}, :infinity)

    def drop_held_caller(name), do: GenServer.call(name, :drop_held_caller)

    @impl true
    def init(opts) do
      {:ok,
       %{
         parent: Keyword.fetch!(opts, :parent),
         hold_fired?: false,
         held_from: nil
       }}
    end

    @impl true
    def handle_call({:hold_first_test, files}, from, state) do
      if state.hold_fired? do
        {:noreply, state}
      else
        send(state.parent, {:validation_window_active, files})

        {:noreply, %{state | hold_fired?: true, held_from: from}}
      end
    end

    def handle_call(:drop_held_caller, _from, state) do
      {:reply, :ok, %{state | held_from: nil}}
    end
  end

  defmodule MixLog do
    @moduledoc false

    def child_spec(name) do
      %{id: name, start: {__MODULE__, :start_link, [name]}}
    end

    def start_link(name), do: Agent.start_link(fn -> [] end, name: name)
    def record(name, event), do: Agent.update(name, &(&1 ++ [event]))
    def events(name), do: Agent.get(name, & &1)
  end

  defmodule TestClock do
    @moduledoc false

    def child_spec(name) do
      %{id: name, start: {__MODULE__, :start_link, [name]}}
    end

    def start_link(name),
      do: Agent.start_link(fn -> %{children: 0, after_first_ms: 0} end, name: name)

    def now(name) do
      Agent.get(name, fn state ->
        if state.children == 0, do: 0, else: state.after_first_ms
      end)
    end

    def set_after_first(name, value) when is_integer(value) and value > 0,
      do: Agent.update(name, &Map.put(&1, :after_first_ms, value))

    def mark_test_child(name),
      do: Agent.update(name, &Map.update!(&1, :children, fn count -> count + 1 end))
  end

  defmodule TrackingSecurity do
    @moduledoc false
    @table :g3c2_cancel_task_control_security

    def ensure_table! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ok
    end

    def reset! do
      ensure_table!()
      :ets.insert(@table, {:revokes_by_task, []})
      :ets.insert(@table, {:caps, %{}})
      :ok
    end

    def grant(opts) do
      ensure_table!()
      task_id = opts[:task_id]
      kind = get_in(opts, [:metadata, :kind]) || "k"
      id = "cap_#{kind}_#{System.unique_integer([:positive])}"
      caps = lookup_caps()
      record = %{id: id, resource_uri: opts[:resource], task_id: task_id}
      :ets.insert(@table, {:caps, Map.put(caps, task_id, [record | Map.get(caps, task_id, [])])})
      {:ok, record}
    end

    def revoke(capability_id) do
      ensure_table!()

      caps =
        Map.new(lookup_caps(), fn {task_id, records} ->
          {task_id, Enum.reject(records, &(&1.id == capability_id))}
        end)

      :ets.insert(@table, {:caps, caps})
      :ok
    end

    def revoke_by_task(task_id) do
      ensure_table!()
      revokes = lookup(:revokes_by_task, [])
      :ets.insert(@table, {:revokes_by_task, [task_id | revokes]})
      caps = lookup_caps()
      :ets.insert(@table, {:caps, Map.put(caps, task_id, [])})
      {:ok, 0}
    end

    def list_capabilities(_principal, opts \\ []) do
      ensure_table!()
      {:ok, Map.get(lookup_caps(), Keyword.get(opts, :task_id), [])}
    end

    def authorize(_principal, resource_uri, _action, opts \\ []) do
      ensure_table!()
      task_id = Keyword.get(opts, :task_id)

      cond do
        not is_binary(task_id) or task_id == "" ->
          {:error, :unauthorized}

        not is_binary(resource_uri) or resource_uri == "" ->
          {:error, :unauthorized}

        Enum.any?(Map.get(lookup_caps(), task_id, []), &(&1.resource_uri == resource_uri)) ->
          {:ok, :authorized}

        true ->
          {:error, :unauthorized}
      end
    end

    def caps_for(task_id), do: Map.get(lookup_caps(), task_id, [])
    def revokes_by_task, do: lookup(:revokes_by_task, [])

    defp lookup_caps do
      case :ets.lookup(@table, :caps) do
        [{:caps, map}] -> map
        _ -> %{}
      end
    end

    defp lookup(key, default) do
      case :ets.lookup(@table, key) do
        [{^key, value}] -> value
        _ -> default
      end
    end
  end

  setup do
    :ok = Arbor.Security.TestBootstrap.start!()
    {:ok, _} = Application.ensure_all_started(:arbor_actions)
    {:ok, _} = Application.ensure_all_started(:arbor_orchestrator)
    start_test_baseline_materializer!()
    restart_workspace_lease_registry!()

    unless Process.whereis(Arbor.Security.UriRegistry) do
      start_supervised!({Arbor.Security.UriRegistry, []})
    end

    originals = %{
      checkpoints: Application.get_env(:arbor_orchestrator, :engine_checkpoints),
      logs: Application.get_env(:arbor_orchestrator, :coding_pipeline_logs_root),
      repos: Application.get_env(:arbor_orchestrator, :coding_repo_roots),
      worktrees: Application.get_env(:arbor_orchestrator, :coding_worktree_roots),
      available: Application.get_env(:arbor_orchestrator, :security_available_override),
      executors: Application.get_env(:arbor_agent, :task_executors),
      mix_runner: Application.get_env(:arbor_actions, :cross_app_mix_runner),
      mix_shell: Application.get_env(:arbor_actions, :mix_shell_module),
      clock: Application.get_env(:arbor_actions, :cross_app_monotonic_ms),
      frozen: Application.get_env(:arbor_actions, :cross_app_frozen_binding_observer),
      resumer: Application.get_env(:arbor_orchestrator, :coding_pipeline_resumer)
    }

    tmp = Path.join(System.tmp_dir!(), "g3c2-cancel-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo_scope = Path.join(tmp, "repo-scope")
    worktrees = Path.join(tmp, "worktrees")
    artifacts = Path.join(tmp, "artifacts")
    File.mkdir_p!(repo_scope)
    File.mkdir_p!(worktrees)
    File.mkdir_p!(artifacts)
    {:ok, tmp} = Arbor.Common.SafePath.resolve_real(tmp)
    {:ok, repo_scope} = Arbor.Common.SafePath.resolve_real(repo_scope)
    {:ok, worktrees} = Arbor.Common.SafePath.resolve_real(worktrees)
    {:ok, artifacts} = Arbor.Common.SafePath.resolve_real(artifacts)

    Application.put_env(:arbor_orchestrator, :coding_pipeline_logs_root, artifacts)
    Application.put_env(:arbor_orchestrator, :coding_repo_roots, [repo_scope])
    Application.put_env(:arbor_orchestrator, :coding_worktree_roots, [worktrees])
    Application.put_env(:arbor_orchestrator, :security_available_override, true)
    Application.put_env(:arbor_orchestrator, :coding_pipeline_resumer, Arbor.Orchestrator)

    Application.put_env(
      :arbor_agent,
      :task_executors,
      %{"coding_change" => CodingTaskExecutor}
    )

    Application.put_env(:arbor_actions, :mix_shell_module, Arbor.Actions.TestMixShell)

    TaskControlRecoveryMemory.reset!()
    TrackingSecurity.reset!()

    on_exit(fn ->
      restore(:arbor_orchestrator, :engine_checkpoints, originals.checkpoints)
      restore(:arbor_orchestrator, :coding_pipeline_logs_root, originals.logs)
      restore(:arbor_orchestrator, :coding_repo_roots, originals.repos)
      restore(:arbor_orchestrator, :coding_worktree_roots, originals.worktrees)
      restore(:arbor_orchestrator, :security_available_override, originals.available)
      restore(:arbor_orchestrator, :coding_pipeline_resumer, originals.resumer)
      restore(:arbor_agent, :task_executors, originals.executors)
      restore(:arbor_actions, :cross_app_mix_runner, originals.mix_runner)
      restore(:arbor_actions, :mix_shell_module, originals.mix_shell)
      restore(:arbor_actions, :cross_app_monotonic_ms, originals.clock)
      restore(:arbor_actions, :cross_app_frozen_binding_observer, originals.frozen)
      File.rm_rf(tmp)
    end)

    %{tmp: tmp, repo_scope: repo_scope, worktrees: worktrees, artifacts: artifacts}
  end

  test "Proof A: cancel during an active CrossApp validation window", ctx do
    fixture = build_fixture(ctx, :persist_then_hold, "never_hold")
    install_mix_hold!(fixture)

    {_store_id, _sup_id, store, _sup} = start_ownership()

    assert_receive {:validation_window_active, files}, 30_000
    assert files == [fixture.batch1_file]
    assert mix_test_files(fixture) == [fixture.batch1_file]
    refute_validate_in_published_checkpoint(fixture)
    assert_owner_resources_present(fixture)
    refute File.exists?(engine_terminal_path(fixture))

    runner_pid = running_pid!(store, fixture.task_id)
    assert Process.alive?(runner_pid)
    assert_recovered_runner_authority_live(fixture, runner_pid)

    assert {:ok, %{state: :cancelled}} =
             Orchestration.cancel_task(fixture.task_id, control_opts(fixture, store))

    assert_owner_resources_present(fixture)
    refute File.exists?(engine_terminal_path(fixture))
    refute_validate_in_published_checkpoint(fixture)
    assert mix_test_files(fixture) == [fixture.batch1_file]
    refute fixture.batch2_file in mix_test_files(fixture)

    MixHoldStore.drop_held_caller(fixture.mix_hold)

    assert_single_cancelled_terminal(fixture, store)
    assert_control_capability_retirement(fixture)
    assert_convergence(fixture, store, runner_pid)
    refute_secrets(fixture)
  end

  test "Proof B: cancel between capacity windows does not start the next original batch", ctx do
    fixture = build_fixture(ctx, :persist_then_hold, "hoist_cross_app_progress_binding")
    install_mix_and_clock!(fixture)

    {store_id, sup_id, store, _sup} = start_ownership()

    assert_receive {:checkpoint_held, :persisted, "hoist_cross_app_progress_binding", _key},
                   30_000

    assert mix_test_files(fixture) == [fixture.batch1_file]
    payload = published_payload!(fixture)
    assert payload["current_node"] == "hoist_cross_app_progress_binding"
    progress = payload_progress(payload)
    assert progress["status"] == "in_progress"
    assert progress["next_batch_index"] == 2
    assert progress["window_ordinal"] == 1
    assert length(progress["passed_receipts"]) == 1
    assert hd(progress["passed_receipts"])["index"] == 1
    assert progress["capacity"]["available_budget_ms"] == 0
    refute Map.has_key?(progress["capacity"], "unstarted_batches")
    lineage = lineage_snapshot(payload)
    assert_owner_resources_present(fixture)
    refute File.exists?(engine_terminal_path(fixture))

    runner_pid = running_pid!(store, fixture.task_id)
    assert Process.alive?(runner_pid)
    assert_recovered_runner_authority_live(fixture, runner_pid)

    assert {:ok, %{state: :cancelled}} =
             Orchestration.cancel_task(fixture.task_id, control_opts(fixture, store))

    assert mix_test_files(fixture) == [fixture.batch1_file]
    refute fixture.batch2_file in mix_test_files(fixture)
    held_progress = published_progress!(fixture)
    assert held_progress["status"] == "in_progress"
    assert held_progress["next_batch_index"] == 2
    assert length(held_progress["passed_receipts"]) == 1
    assert_owner_resources_present(fixture)
    refute File.exists?(engine_terminal_path(fixture))

    CheckpointHoldStore.drop_held_caller(fixture.store_name)

    assert_single_cancelled_terminal(fixture, store)
    original_archive = File.read!(task_terminal_path(fixture))
    assert_control_capability_retirement(fixture)
    assert_convergence(fixture, store, runner_pid)

    {:ok, expected_digest} =
      Arbor.Actions.coding_cross_app_digest(held_progress["passed_receipts"])

    final_progress = published_progress!(fixture)
    assert final_progress["status"] == "in_progress"
    assert final_progress["passed_receipts_digest"] == expected_digest
    assert lineage_snapshot(published_payload!(fixture)) == lineage
    refute_secrets(fixture)

    _ = stop_supervised(store_id)
    refute Process.alive?(store)
    _ = stop_supervised(sup_id)

    {_store_id2, _sup_id2, store2, _sup2} = start_ownership()

    unless wait_until(fn ->
             match?(
               {:ok, %{state: :cancelled}},
               TaskStore.status(fixture.task_id, name: store2)
             )
           end) do
      flunk(
        "expected cancelled after restart, got " <>
          inspect(TaskStore.status(fixture.task_id, name: store2))
      )
    end

    status2 = TaskStore.status(fixture.task_id, name: store2)

    # Security/lifecycle regression: reconstructing a cancelled CrossApp run
    # after TaskStore restart must keep the original first-writer
    # task_cancelled archive instead of rewriting it as task_runner_failed
    # and wrapping that as task_finalization_failed.
    refute match?({:ok, %{state: :failed}}, status2)
    refute match?({:ok, %{outcome: %{"code" => "task_finalization_failed"}}}, status2)
    refute match?({:ok, %{state: :running}}, status2)
    refute match?({:ok, %{state: :done}}, status2)
    assert {:ok, %{state: :cancelled}} = status2

    assert {:ok, envelope} = TaskStore.result(fixture.task_id, name: store2)
    assert envelope["terminal_state"] == "cancelled"
    assert get_in(envelope, ["evidence", "kind"]) == "task_cancelled"
    assert get_in(envelope, ["outcome", "code"]) == "task_cancelled"
    refute get_in(envelope, ["outcome", "code"]) == "task_finalization_failed"
    assert File.read!(task_terminal_path(fixture)) == original_archive

    assert mix_test_files(fixture) == [fixture.batch1_file]
    refute fixture.batch2_file in mix_test_files(fixture)
    refute File.exists?(engine_terminal_path(fixture))
  end

  defp build_fixture(ctx, mode, hold_node) do
    suffix = System.unique_integer([:positive, :monotonic])
    store_name = :"g3c2_ckpt_#{suffix}"
    mix_hold = :"g3c2_mix_hold_#{suffix}"
    mix_log = :"g3c2_mix_#{suffix}"
    clock = :"g3c2_clock_#{suffix}"
    task_id = "task_g3c2_cancel_#{suffix}"
    worker_session_id = "worker_g3c2_#{suffix}"
    provider_session_id = "provider_g3c2_#{suffix}"

    start_supervised!(
      {CheckpointHoldStore, name: store_name, parent: self(), mode: mode, hold_node: hold_node}
    )

    start_supervised!({MixHoldStore, name: mix_hold, parent: self()})
    start_supervised!({MixLog, mix_log})
    start_supervised!({TestClock, clock})

    Application.put_env(:arbor_orchestrator, :engine_checkpoints,
      store: CheckpointHoldStore,
      store_name: store_name,
      store_opts: [],
      start_store: false,
      durability_class: :process_lifetime
    )

    repo = create_umbrella(Path.join(ctx.repo_scope, "repo-#{suffix}"))
    {:ok, repo} = Arbor.Common.SafePath.resolve_real(repo)

    {:ok, identity} = Identity.generate(name: "g3c2-cancel-#{suffix}")
    {:ok, caller_identity} = Identity.generate(name: "g3c2-control-#{suffix}")
    :ok = Security.register_identity(Identity.public_only(identity))
    :ok = Security.register_identity(Identity.public_only(caller_identity))
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)

    on_exit(fn ->
      _ = Security.delete_signing_key(identity.agent_id)
      _ = Security.deregister_identity(identity.agent_id)
      _ = Security.deregister_identity(caller_identity.agent_id)
    end)

    agent = identity.agent_id
    caller = caller_identity.agent_id
    grant_capability!(agent, "arbor://orchestrator/execute/**")
    grant_capability!(agent, "arbor://action/coding/reviewed_validation")
    grant_capability!(agent, "arbor://action/coding/cross_app/validate")
    grant_capability!(agent, "arbor://action/coding/workspace/acquire")
    grant_capability!(caller, "arbor://orchestrator/execute/**")
    grant_capability!(caller, "arbor://action/coding/reviewed_validation")
    grant_capability!(caller, "arbor://action/coding/cross_app/validate")

    {:ok, task_read_uri} = TaskControlLease.uri(:task_read, task_id)
    {:ok, task_cancel_uri} = TaskControlLease.uri(:task_cancel, task_id)
    grant_capability!(caller, task_read_uri)
    grant_capability!(caller, task_cancel_uri)

    on_exit(fn -> _ = Arbor.Security.CapabilityStore.revoke_all(agent) end)
    on_exit(fn -> _ = Arbor.Security.CapabilityStore.revoke_all(caller) end)

    lease_context = %{task_id: task_id, agent_id: agent}

    {:ok, lease} =
      Workspace.Acquire.run(
        %{
          repo_path: repo,
          branch_name: "test/g3c2-cancel-#{suffix}",
          worktree_base_dir: ctx.worktrees
        },
        lease_context
      )

    File.write!(
      Path.join(lease.worktree_path, "apps/alpha/lib/alpha.ex"),
      "defmodule Alpha do\n  def value, do: 2\nend\n"
    )

    assert {:ok, candidate_view} =
             Workspace.Inspect.run(
               %{workspace_id: lease.workspace_id, include_committable_tree: true},
               lease_context
             )

    candidate_tree_oid = candidate_view.committable_tree_oid

    on_exit(fn ->
      _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, lease_context)
    end)

    packet = %{
      "version" => 1,
      "success_criteria" => ["prove cancellation and cleanup convergence"],
      "non_goals" => ["g4 continuation removal"],
      "constraints" => ["preserve fail-closed admission"],
      "architecture_refs" => [
        "apps/arbor_orchestrator/lib/arbor/orchestrator/coding_task_executor.ex"
      ],
      "required_evidence" => ["focused cancellation proofs"],
      "checkpoint_policy" => "design_required"
    }

    {:ok, packet_digest} = WorkPacket.digest(packet)

    {:ok, plan} =
      Plan.new(%{
        "version" => 2,
        "task" => "prove cancellation and cleanup convergence",
        "repo_root" => repo,
        "worker" => %{"provider" => "codex"},
        "validation_profile" => "cross_app",
        "workspace_policy" => %{
          "mode" => "isolated",
          "worktree_base_dir" => ctx.worktrees
        },
        "work_packet" => packet,
        "work_packet_digest" => packet_digest
      })

    {:ok, canonical, compilation} = Readiness.prepare(plan)

    digest = :crypto.hash(:sha256, task_id) |> Base.encode16(case: :lower)
    logs_root = Path.join(ctx.artifacts, "task-" <> digest)
    File.mkdir_p!(logs_root)
    File.chmod!(logs_root, 0o700)
    {:ok, logs_root} = Arbor.Common.SafePath.resolve_real(logs_root)

    {:ok, artifacts} =
      ArtifactStore.archive(
        logs_root,
        Plan.to_map(canonical),
        compilation.dot_source,
        compilation.manifest
      )

    {:ok, bundle} = ArtifactStore.read_task_compilation(ctx.artifacts, task_id)

    binding = %{
      "schema_version" => 1,
      "task_id" => task_id,
      "run_id" => task_id,
      "agent_id" => agent,
      "execution_principal" => agent,
      "control_principal_id" => caller,
      "executor_kind" => "coding_change",
      "graph_hash" => artifacts["graph_hash"],
      "compiler_version" => artifacts["compiler_version"],
      "artifact_identity" => bundle["artifact_identity"]
    }

    assert :ok = ArtifactStore.archive_run_binding(logs_root, binding)

    {:ok, graph} = Orchestrator.compile(compilation.dot_source)
    tree_oid = candidate_tree_oid

    frozen = %{
      "work_packet_digest" => packet_digest,
      "toolchain_digest" => String.duplicate("2", 64),
      "wrapper_digest" => String.duplicate("4", 64),
      "dependency_baseline_digest" => String.duplicate("3", 64)
    }

    context_values =
      Map.merge(compilation.initial_values, %{
        "workspace_id" => lease.workspace_id,
        "worker_session_id" => worker_session_id,
        "worker_provider_session_id" => provider_session_id,
        "validation_candidate_tree_oid" => tree_oid,
        "coding_plan_work_packet_digest" => packet_digest,
        "coding_budget.validation_ms" => 1_200_000,
        "coding_budget.validation_completion_reserve_ms" => 60_000,
        "session.agent_id" => agent,
        "session.task_id" => task_id,
        "session.caller_id" => caller,
        "session.run_deadline_unix_ms" => System.system_time(:millisecond) + 1_800_000,
        "outcome" => "success"
      })

    test_stage_timeout_ms =
      get_in(compilation.initial_values, [
        "coding_plan_validation_program",
        "static_parameters",
        "test_stage_timeout"
      ])

    {:ok, authority, security} = CodingRunRecovery.acquire_resume_authority(agent)

    {:ok, {run_auth, _opts}} =
      RunAuthorization.prepare(graph,
        authorization: true,
        signing_authority: authority,
        agent_id: agent,
        execution_principal: agent,
        caller_id: caller,
        task_id: task_id,
        run_id: task_id,
        graph_hash: compilation.graph_hash,
        execution_manifest: compilation.execution_manifest,
        execution_manifest_digest: compilation.execution_manifest_digest,
        workdir: repo,
        logs_root: logs_root
      )

    {:ok, hmac_secret} =
      Security.derive_secret_with_authority(authority, :engine_checkpoint_hmac_v3)

    :ok = CodingRunRecovery.close_authority(security, authority)

    ctx_struct =
      Context.new(context_values,
        taint: %{
          "workspace_id" => :trusted,
          "coding_plan_work_packet_digest" => :trusted,
          "coding_budget.validation_ms" => :trusted,
          "coding_budget.validation_completion_reserve_ms" => :trusted,
          "session.run_deadline_unix_ms" => :trusted
        }
      )

    current = "hoist_validation_observed_at"

    checkpoint =
      Checkpoint.from_state(
        current,
        [current],
        %{},
        ctx_struct,
        %{current => %Outcome{status: :success}},
        run_id: task_id,
        graph_hash: compilation.graph_hash,
        run_authorization: RunAuthorization.projection(run_auth)
      )

    store_opts = Arbor.Orchestrator.Config.engine_checkpoint_store_opts()

    assert {:ok, _receipt} =
             Checkpoint.persist(checkpoint, logs_root, store_opts ++ [hmac_secret: hmac_secret])

    now = DateTime.utc_now()

    record = %Record{
      run_id: task_id,
      pipeline_id: task_id,
      status: :interrupted,
      graph_hash: compilation.graph_hash,
      dot_source_path: Path.join(logs_root, "coding-pipeline.dot"),
      logs_root: logs_root,
      execution_principal: agent,
      owner_node: node(),
      started_at: now,
      last_heartbeat: now,
      current_node: current,
      completed_nodes: [current],
      completed_count: 1
    }

    assert :ok = RunJournal.put(record)

    {:ok, marker} =
      TaskControlLease.marker_new(task_id, now, %{
        agent_id: agent,
        executor_kind: "coding_change",
        control_principal_id: caller,
        cleanup: %{"caller_id" => caller, "principal_id" => agent}
      })

    assert {:ok, _} =
             TaskControlRecoveryMemory.buffered_store_acknowledged_put(
               :arbor_agent_task_control_recovery,
               task_id,
               marker
             )

    for kind <- TaskControlLease.grant_order() do
      {:ok, spec} = TaskControlLease.grant_spec(kind, caller, task_id, now)
      assert {:ok, _} = TrackingSecurity.grant(spec)
    end

    %{
      agent: agent,
      caller: caller,
      task_id: task_id,
      repo: repo,
      lease: lease,
      logs_root: logs_root,
      artifacts: ctx.artifacts,
      store_name: store_name,
      mix_hold: mix_hold,
      mix_log: mix_log,
      clock: clock,
      frozen: frozen,
      packet_digest: packet_digest,
      worker_session_id: worker_session_id,
      provider_session_id: provider_session_id,
      tree_oid: tree_oid,
      test_stage_timeout_ms: test_stage_timeout_ms,
      batch1_file: "apps/alpha/test/alpha_test.exs",
      batch2_file: "apps/beta/test/beta_test.exs",
      graph: graph,
      compilation: compilation,
      canonical: canonical
    }
  end

  defp install_mix_hold!(fixture) do
    Application.put_env(:arbor_actions, :cross_app_frozen_binding_observer, fn _ctx ->
      {:ok, fixture.frozen}
    end)

    Application.put_env(:arbor_actions, :cross_app_monotonic_ms, fn ->
      TestClock.now(fixture.clock)
    end)

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      MixLog.record(fixture.mix_log, args)

      case args do
        ["test", "--no-deps-check", "--" | files] ->
          MixHoldStore.hold_first_test(fixture.mix_hold, files)

        _ ->
          {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}
      end
    end)
  end

  defp install_mix_and_clock!(fixture) do
    reserve_ms = Arbor.Actions.Mix.postflight_tree_binding_reserve_ms()
    TestClock.set_after_first(fixture.clock, fixture.test_stage_timeout_ms - reserve_ms)

    Application.put_env(:arbor_actions, :cross_app_frozen_binding_observer, fn _ctx ->
      {:ok, fixture.frozen}
    end)

    Application.put_env(:arbor_actions, :cross_app_monotonic_ms, fn ->
      TestClock.now(fixture.clock)
    end)

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      MixLog.record(fixture.mix_log, args)

      if match?(["test", "--no-deps-check", "--" | _], args) do
        TestClock.mark_test_child(fixture.clock)
      end

      {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}
    end)
  end

  defp start_test_baseline_materializer! do
    unless Process.whereis(Arbor.Actions.TestLinuxBaselineMaterializer) do
      start_supervised!(Arbor.Actions.TestLinuxBaselineMaterializer)
    end

    Arbor.Actions.TestLinuxBaselineMaterializer.reset_seams()
  end

  defp restart_workspace_lease_registry! do
    case Supervisor.terminate_child(Arbor.Actions.Supervisor, WorkspaceLeaseRegistry) do
      :ok ->
        :ok = Supervisor.delete_child(Arbor.Actions.Supervisor, WorkspaceLeaseRegistry)

      {:error, :not_found} ->
        :ok
    end

    assert {:ok, _pid} =
             Supervisor.start_child(
               Arbor.Actions.Supervisor,
               {WorkspaceLeaseRegistry,
                [
                  linux_dependency_baseline_materializer:
                    Arbor.Actions.TestLinuxBaselineMaterializer,
                  retention_journal: :disabled
                ]}
             )
  end

  defp start_ownership do
    sup_name = unique(:sup)
    store_name = unique(:store)
    sup_id = unique(:sup_id)
    store_id = unique(:store_id)

    start_supervised!({Task.Supervisor, name: sup_name}, id: sup_id)

    store =
      start_supervised!(
        {TaskStore,
         name: store_name,
         task_supervisor: sup_name,
         cleanup_supervisor: sup_name,
         recovery_force_ready: false,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: TrackingSecurity,
         runner: CodingTaskExecutor},
        id: store_id
      )

    assert wait_until(fn -> TaskStore.recovery_ready?(name: store) end)
    {store_id, sup_id, store, sup_name}
  end

  defp control_opts(fixture, store) do
    [
      caller_id: fixture.caller,
      name: store,
      security_module: TrackingSecurity
    ]
  end

  defp running_pid!(store, task_id) do
    assert wait_until(fn ->
             match?({:ok, %{state: :running}}, TaskStore.status(task_id, name: store))
           end)

    pid = get_in(:sys.get_state(store), [:tasks, task_id, :pid])
    assert is_pid(pid)
    pid
  end

  defp assert_owner_resources_present(fixture) do
    assert File.dir?(fixture.lease.worktree_path)
    assert File.dir?(fixture.logs_root)
  end

  defp engine_terminal_path(fixture),
    do: Path.join(fixture.logs_root, "coding-engine-terminal.json")

  defp task_terminal_path(fixture),
    do: Path.join(fixture.logs_root, "coding-task-terminal.json")

  defp assert_single_cancelled_terminal(fixture, store) do
    assert {:ok, %{state: :cancelled}} = TaskStore.status(fixture.task_id, name: store)

    assert {:ok, envelope} = TaskStore.result(fixture.task_id, name: store)
    assert is_map(envelope)
    assert envelope["terminal_state"] == "cancelled"
    assert get_in(envelope, ["evidence", "kind"]) == "task_cancelled"
    assert get_in(envelope, ["outcome", "code"]) == "task_cancelled"
    refute get_in(envelope, ["outcome", "code"]) in ["change_committed", "succeeded"]

    refute File.exists?(engine_terminal_path(fixture))
    assert File.exists?(task_terminal_path(fixture))

    assert {:ok, archive} = ArtifactStore.read_task_terminal(fixture.logs_root, fixture.task_id)
    assert get_in(archive, ["terminal_envelope", "evidence", "kind"]) == "task_cancelled"
    assert get_in(archive, ["terminal_envelope", "terminal_state"]) == "cancelled"

    refute fixture.batch2_file in mix_test_files(fixture)
  end

  defp assert_control_capability_retirement(fixture) do
    {:ok, task_read_uri} = TaskControlLease.uri(:task_read, fixture.task_id)

    assert wait_until(fn ->
             fixture.task_id
             |> TrackingSecurity.caps_for()
             |> Enum.map(& &1.resource_uri)
             |> MapSet.new() == MapSet.new([task_read_uri])
           end)

    refute fixture.task_id in TrackingSecurity.revokes_by_task()
  end

  defp assert_convergence(fixture, store, runner_pid) do
    refute Process.alive?(runner_pid)

    store_state = :sys.get_state(store)
    record = get_in(store_state, [:tasks, fixture.task_id])
    assert record.state == :cancelled

    if is_pid(record.pid) do
      refute Process.alive?(record.pid)
    end

    assert wait_until(fn -> fixture_principal_authorities_closed?(fixture) end),
           "expected no live SigningAuthority for fixture principal after cancel"

    assert wait_until(fn ->
             case RunJournal.get_record(fixture.task_id) do
               {:ok, %{status: :abandoned}} ->
                 true

               {:ok, %{status: status}}
               when status in [:running, :recovering, :interrupted] ->
                 false

               {:error, :not_found} ->
                 File.exists?(task_terminal_path(fixture))

               {:ok, %{status: status}} when status in [:completed, :failed] ->
                 true
             end
           end)

    case RunJournal.get_record(fixture.task_id) do
      {:ok, journal} ->
        assert journal.status == :abandoned

      {:error, :not_found} ->
        assert File.exists?(task_terminal_path(fixture))

      other ->
        flunk("unexpected journal result #{inspect(other)}")
    end

    assert {:ok, marker} =
             TaskControlRecoveryMemory.buffered_store_authoritative_get(
               :arbor_agent_task_control_recovery,
               fixture.task_id
             )

    assert is_map(marker)
    assert marker["task_id"] == fixture.task_id

    assert_owner_resources_present(fixture)
    assert File.exists?(task_terminal_path(fixture))
    refute File.exists?(engine_terminal_path(fixture))
  end

  defp assert_recovered_runner_authority_live(fixture, runner_pid) do
    assert wait_until(fn ->
             Enum.any?(fixture_principal_authority_entries(fixture), fn entry ->
               entry.owner_pid == runner_pid and
                 entry.purpose in [:coding_task_recovery, "coding_task_recovery"]
             end)
           end),
           "expected recovered runner to hold a live coding_task_recovery SigningAuthority"
  end

  defp fixture_principal_authorities_closed?(fixture) do
    case Arbor.Security.SigningAuthorityBroker.debug_state() do
      %{entries: entries} when is_list(entries) ->
        not Enum.any?(entries, fn
          %{principal_id: principal_id} -> principal_id == fixture.agent
          _other -> false
        end)

      _unavailable ->
        false
    end
  end

  defp fixture_principal_authority_entries(fixture) do
    case Arbor.Security.SigningAuthorityBroker.debug_state() do
      %{entries: entries} when is_list(entries) ->
        Enum.filter(entries, fn
          %{principal_id: principal_id} -> principal_id == fixture.agent
          _other -> false
        end)

      _unavailable ->
        []
    end
  end

  defp refute_validate_in_published_checkpoint(fixture) do
    payload = published_payload!(fixture)
    assert payload["current_node"] == "hoist_validation_observed_at"
    refute "validate" in List.wrap(payload["completed_nodes"])
    values = payload["context_values"] || %{}
    refute is_map(values["cross_app_progress"])
    refute is_map(values["validation.progress"])
    refute is_map(get_in(values, ["validation", "progress"]))
  end

  defp published_payload!(fixture) do
    opts = Arbor.Orchestrator.Config.engine_checkpoint_store_opts()
    assert {:ok, payload} = Checkpoint.fetch_persisted(fixture.task_id, opts)
    payload
  end

  defp published_progress!(fixture) do
    payload_progress(published_payload!(fixture))
  end

  defp payload_progress(payload) do
    values = payload["context_values"] || %{}

    values["validation.progress"] ||
      get_in(values, ["validation", "progress"]) ||
      values["cross_app_progress"] ||
      flunk("missing compact progress in checkpoint #{inspect(Map.keys(values))}")
  end

  defp mix_test_files(fixture) do
    fixture.mix_log
    |> MixLog.events()
    |> Enum.flat_map(fn
      ["test", "--no-deps-check", "--" | files] -> files
      _ -> []
    end)
  end

  defp lineage_snapshot(payload) do
    progress = payload_progress(payload)
    identities = progress["identities"] || flunk("missing CrossApp progress identities")
    values = payload["context_values"] || %{}
    authorization = payload["run_authorization"] || flunk("missing checkpoint run authorization")

    %{
      progress_task_id: identities["task_id"],
      progress_principal_id: identities["principal_id"],
      run_id: payload["run_id"],
      authorization_execution_principal: authorization["execution_principal"],
      authorization_caller_id: authorization["caller_id"],
      authorization_task_id: authorization["task_id"],
      workspace_id: values["workspace_id"],
      worker_session_id: values["worker_session_id"],
      worker_provider_session_id: values["worker_provider_session_id"],
      candidate_tree_oid: identities["candidate_tree_oid"],
      plan_digest: identities["validation_plan_digest"],
      toolchain_digest: identities["toolchain_digest"],
      baseline_digest: identities["dependency_baseline_digest"],
      wrapper_digest: identities["wrapper_digest"],
      work_packet_digest: identities["work_packet_digest"],
      configuration_digest: identities["configuration_digest"],
      validator_id: identities["validator_id"]
    }
  end

  defp refute_secrets(fixture) do
    payload = published_payload!(fixture)
    encoded = Jason.encode!(payload)
    dumped = inspect(CheckpointHoldStore.dump(fixture.store_name))
    files = Path.wildcard(Path.join(fixture.logs_root, "**/*"))

    bodies =
      files
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&File.read!/1)
      |> Enum.join("\n")

    Enum.each(@secret_needles, fn needle ->
      refute encoded =~ needle
      refute dumped =~ needle
      refute bodies =~ needle
    end)
  end

  defp create_umbrella(path) do
    File.mkdir_p!(path)
    {_out, 0} = System.cmd("git", ["init", "--quiet", path], stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["-C", path, "config", "user.email", "test@example.com"])
    {_out, 0} = System.cmd("git", ["-C", path, "config", "user.name", "Test User"])

    File.write!(Path.join(path, "mix.exs"), """
    defmodule CrossAppFixture.MixProject do
      use Mix.Project
      def project, do: [apps_path: "apps", version: "0.1.0", deps: []]
    end
    """)

    File.mkdir_p!(Path.join(path, "config"))
    File.write!(Path.join(path, "config/config.exs"), "import Config\n")
    File.write!(Path.join(path, "mix.lock"), "%{}\n")
    write_app(path, "alpha", [], "defmodule Alpha do\n  def value, do: 1\nend\n")
    write_app(path, "beta", ["alpha"], "defmodule Beta do\n  def value, do: Alpha.value()\nend\n")

    File.write!(Path.join(path, "apps/alpha/test/alpha_test.exs"), """
    defmodule AlphaTest do
      use ExUnit.Case
      test "value", do: assert Alpha.value() == 1
    end
    """)

    File.write!(Path.join(path, "apps/beta/test/beta_test.exs"), """
    defmodule BetaTest do
      use ExUnit.Case
      test "uses alpha", do: assert Beta.value() == 1
    end
    """)

    File.mkdir_p!(Path.join(path, "bin"))
    File.write!(Path.join(path, "bin/mix"), "#!/usr/bin/env bash\nexec mix \"$@\"\n")
    File.chmod!(Path.join(path, "bin/mix"), 0o755)
    {_out, 0} = System.cmd("git", ["-C", path, "add", "."], stderr_to_stdout: true)

    {_out, 0} =
      System.cmd("git", ["-C", path, "commit", "-m", "umbrella base"], stderr_to_stdout: true)

    path
  end

  defp write_app(root, name, umbrella_deps, lib_source) do
    app_root = Path.join(root, "apps/#{name}")
    File.mkdir_p!(Path.join(app_root, "lib"))
    File.mkdir_p!(Path.join(app_root, "test"))

    deps =
      umbrella_deps
      |> Enum.map(fn dep -> "      {:#{dep}, in_umbrella: true}" end)
      |> Enum.join(",\n")

    deps_block =
      if deps == "" do
        "  defp deps, do: []"
      else
        "  defp deps do\n    [\n#{deps}\n    ]\n  end"
      end

    File.write!(Path.join(app_root, "mix.exs"), """
    defmodule #{Macro.camelize(name)}.MixProject do
      use Mix.Project
      def project do
        [
          app: :#{name},
          version: "0.1.0",
          elixir: "~> 1.18",
          start_permanent: Mix.env() == :prod,
          deps: deps()
        ]
      end
    #{deps_block}
    end
    """)

    File.write!(Path.join(app_root, "lib/#{name}.ex"), lib_source)
    File.write!(Path.join(app_root, "test/test_helper.exs"), "ExUnit.start()\n")
  end

  defp wait_until(fun, attempts \\ 1_500) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end

  defp grant_capability!(agent_id, resource_uri) do
    {:ok, cap} =
      Arbor.Contracts.Security.Capability.new(
        resource_uri: resource_uri,
        principal_id: agent_id,
        delegation_depth: 0,
        constraints: %{},
        metadata: %{test: true}
      )

    {:ok, :stored} = Arbor.Security.CapabilityStore.put(cap)
    :ok
  end

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
