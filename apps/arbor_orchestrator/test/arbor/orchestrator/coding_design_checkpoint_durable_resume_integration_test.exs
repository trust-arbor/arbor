defmodule Arbor.Orchestrator.CodingDesignCheckpointDurableResumeIntegrationTest do
  @moduledoc """
  Real-boundary crash/recovery proof for the Coding Plan v2 design checkpoint.

  The backend attests `:node_restart`, but this topology exercises run-owner
  death plus a Comms application restart on one BEAM. It does not simulate a
  BEAM node restart, network partition, host failure, or storage failover.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :security_regression
  @moduletag timeout: 120_000

  alias Arbor.Contracts.Coding.{Plan, WorkPacket}
  alias Arbor.Orchestrator
  alias Arbor.Orchestrator.ActionsExecutor
  alias Arbor.Orchestrator.CodingPlan.Compiler
  alias Arbor.Orchestrator.L4ClusterRecoverySupport.CentralStore
  alias Arbor.Orchestrator.L4ClusterRecoverySupport.NodeRestartProxy
  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RunJournal
  alias Arbor.Orchestrator.RunLifecycle.Record

  @open_action_name "coding_design_checkpoint_open"
  @await_action_name "coding_design_checkpoint_await"

  defmodule DeliveryAdapter do
    @moduledoc false
    @behaviour Arbor.Contracts.Comms.ChannelAdapter

    @impl true
    def send_interaction(channel_metadata, interaction) do
      send(
        Map.fetch!(channel_metadata, :test_pid),
        {:durable_design_checkpoint_delivery, interaction}
      )

      :ok
    end

    @impl true
    def parse_response(_raw), do: :not_interaction

    @impl true
    def channel_kind, do: :dashboard
  end

  setup do
    ensure_security_and_trust_started!()

    saved = %{
      checkpoints: Application.get_env(:arbor_orchestrator, :engine_checkpoints, :__unset__),
      durable_store: Application.get_env(:arbor_comms, :durable_interaction_store, :__unset__),
      durable_dispatch:
        Application.get_env(:arbor_comms, :durable_interaction_dispatch, :__unset__),
      adapters: Application.get_env(:arbor_comms, :interaction_adapters, :__unset__),
      signal: Application.get_env(:arbor_comms, :signal, :__unset__),
      policy_enforcer: Application.get_env(:arbor_trust, :policy_enforcer_enabled, :__unset__),
      approval_guard: Application.get_env(:arbor_trust, :approval_guard_enabled, :__unset__)
    }

    Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
    Application.put_env(:arbor_trust, :approval_guard_enabled, true)

    on_exit(fn ->
      restore_env(:arbor_orchestrator, :engine_checkpoints, saved.checkpoints)
      restore_env(:arbor_comms, :durable_interaction_store, saved.durable_store)
      restore_env(:arbor_comms, :durable_interaction_dispatch, saved.durable_dispatch)
      restore_env(:arbor_comms, :interaction_adapters, saved.adapters)
      restore_env(:arbor_comms, :signal, saved.signal)
      restore_env(:arbor_trust, :policy_enforcer_enabled, saved.policy_enforcer)
      restore_env(:arbor_trust, :approval_guard_enabled, saved.approval_guard)
      restart_comms_safely()
    end)

    :ok
  end

  test "security regression: crash after durable Open resumes only Await with exact authority" do
    suffix = System.unique_integer([:positive, :monotonic])
    controller_name = :"design_checkpoint_central_#{suffix}"
    journal_store = :"design_checkpoint_journal_#{suffix}"
    checkpoint_store = :"design_checkpoint_engine_checkpoint_#{suffix}"
    comms_store = :"design_checkpoint_comms_#{suffix}"
    journal_name = :"design_checkpoint_run_journal_#{suffix}"
    journal_table = :"design_checkpoint_run_hot_#{suffix}"
    run_id = "design_checkpoint_durable_resume_#{suffix}"
    task_id = "coding-task-#{suffix}"
    agent_id = "agent_design_checkpoint_#{suffix}"
    operator_id = "operator_design_checkpoint_#{suffix}"
    workspace_id = "workspace_design_checkpoint_#{suffix}"
    worker_session_id = "acp_worker_design_checkpoint_#{suffix}"
    provider_session_id = "grok_provider_session_#{suffix}"
    design_attempt = 1
    design = "Keep the change scoped, preserve durable authority, and run the focused proof."
    design_digest = sha256_prefixed(design)
    run_deadline_unix_ms = System.system_time(:millisecond) + 600_000
    identity_private_key = :crypto.strong_rand_bytes(32)
    repo_root = repo_root()
    logs_root = tmp_root("logs", suffix)
    dot_root = tmp_root("dot", suffix)
    dot_path = Path.join(dot_root, "durable-design-checkpoint.dot")

    start_supervised!(
      {CentralStore,
       name: controller_name,
       parent: self(),
       hold_store: journal_store,
       hold_on: :completed_progress,
       hold_node: "open_design_checkpoint"}
    )

    on_exit(fn -> safe_release_hold(controller_name) end)

    backend_opts = [controller_name: controller_name, controller_node: node()]

    start_supervised!(
      {RunJournal,
       name: journal_name,
       ets_table: journal_table,
       backend: NodeRestartProxy,
       store_name: journal_store,
       backend_opts: backend_opts}
    )

    configure_engine_checkpoints!(checkpoint_store, backend_opts)
    configure_comms!(comms_store, backend_opts, operator_id)
    restart_comms!()
    assert_eventually(&Arbor.Comms.durable_ready?/0)
    track_operator!(operator_id)

    {plan, compilation} = compile_v2_plan!(repo_root, design)
    assert plan.version == 2
    assert plan.work_packet["checkpoint_policy"] == "design_required"
    assert compilation.initial_values["coding_plan_work_packet"] == plan.work_packet

    assert compilation.initial_values["coding_plan_work_packet_digest"] ==
             plan.work_packet_digest

    initial_values =
      Map.merge(compilation.initial_values, %{
        "session.agent_id" => agent_id,
        "session.task_id" => task_id,
        "session.run_deadline_unix_ms" => run_deadline_unix_ms,
        "workdir" => repo_root,
        "work_packet" => plan.work_packet,
        "packet_digest" => plan.work_packet_digest,
        "plan_fingerprint" => compilation.plan_fingerprint,
        "workspace_id" => workspace_id,
        "worker_session_id" => worker_session_id,
        "worker_provider_session_id" => provider_session_id,
        "design_attempt" => design_attempt,
        "design" => design,
        "design_digest" => design_digest
      })

    dot = design_checkpoint_dot()
    File.mkdir_p!(dot_root)
    File.write!(dot_path, dot)
    assert {:ok, parsed} = Orchestrator.parse(dot)
    assert {:ok, _compiled} = Arbor.Orchestrator.IR.Compiler.compile(parsed)

    exact_action_resources = grant_exact_action_authority!(agent_id, task_id)
    assert_exact_trust_authority!(agent_id, task_id, exact_action_resources)
    trace_design_actions!()

    on_exit(fn ->
      untrace_design_actions()
      safe_untrack_operator(operator_id)
      Arbor.Orchestrator.TestCapabilities.revoke_all(agent_id)
      Arbor.Trust.delete_trust_profile(agent_id)
      PipelineStatus.delete(run_id)
      File.rm_rf(logs_root)
      File.rm_rf(dot_root)
    end)

    parent = self()

    {engine_pid, engine_monitor} =
      spawn_monitor(fn ->
        :erlang.trace(self(), true, [:call, {:tracer, parent}])

        result =
          Orchestrator.run_file(dot_path,
            run_id: run_id,
            logs_root: logs_root,
            journal_opts: [server: journal_name],
            identity_private_key: identity_private_key,
            resumable: true,
            initial_values: initial_values,
            actions_executor: ActionsExecutor
          )

        send(parent, {:initial_design_checkpoint_run_finished, self(), result})
      end)

    assert_receive {:trace, ^engine_pid, :call,
                    {Arbor.Actions, :authorize_and_execute,
                     [^agent_id, open_action_module, open_params, _]}},
                   10_000

    assert_action_name!(open_action_module, @open_action_name)

    assert_exact_design_input!(
      open_params,
      plan,
      compilation.plan_fingerprint,
      task_id,
      workspace_id,
      worker_session_id,
      provider_session_id,
      design_attempt,
      design,
      design_digest,
      run_deadline_unix_ms
    )

    assert_receive {:durable_design_checkpoint_delivery, interaction}, 10_000
    request_id = interaction.request_id
    assert String.match?(request_id, ~r/^irq_design_[0-9a-f]{64}$/)
    assert interaction.agent_id == agent_id
    assert interaction.user_id == operator_id
    assert interaction.metadata["work_packet"] == plan.work_packet
    assert interaction.metadata["packet_digest"] == plan.work_packet_digest
    assert interaction.metadata["workspace_id"] == workspace_id
    assert interaction.metadata["worker_session_id"] == worker_session_id
    assert interaction.metadata["provider_session_id"] == provider_session_id
    assert interaction.metadata["design_attempt"] == design_attempt
    assert interaction.metadata["design_digest"] == design_digest

    assert_receive {:l4_store_held, :completed_progress, held}, 10_000
    assert held.logical == journal_store
    assert held.effect["node_id"] == "open_design_checkpoint"
    assert held.effect["status"] == "completed"
    assert "open_design_checkpoint" in held.completed_nodes

    assert CentralStore.has_key?(
             controller_name,
             checkpoint_store,
             "checkpoint:#{run_id}"
           )

    assert {:ok, receipt} =
             Arbor.Comms.request_durable_interaction(interaction,
               owner_deadline_unix_ms: run_deadline_unix_ms
             )

    assert receipt.request_id == request_id
    assert is_binary(receipt.operation_id)
    assert receipt.operation_id != ""
    assert receipt.owner_deadline_unix_ms == run_deadline_unix_ms

    assert :ok = CentralStore.release_hold(controller_name)

    assert_receive {:trace, ^engine_pid, :call,
                    {Arbor.Actions, :authorize_and_execute,
                     [^agent_id, await_action_module, await_params, _]}},
                   10_000

    assert_action_name!(await_action_module, @await_action_name)

    assert_exact_design_input!(
      await_params,
      plan,
      compilation.plan_fingerprint,
      task_id,
      workspace_id,
      worker_session_id,
      provider_session_id,
      design_attempt,
      design,
      design_digest,
      run_deadline_unix_ms
    )

    assert await_params.request_id == request_id
    assert await_params.operation_id == receipt.operation_id
    assert await_params.owner_deadline_unix_ms == run_deadline_unix_ms
    assert await_params.evidence["request_id"] == request_id
    assert Process.alive?(engine_pid)
    refute_receive {:initial_design_checkpoint_run_finished, ^engine_pid, _}, 50

    Process.exit(engine_pid, :kill)
    assert_receive {:DOWN, ^engine_monitor, :process, ^engine_pid, :killed}, 5_000
    refute Process.alive?(engine_pid)

    interrupted =
      assert_eventually_value(fn ->
        case PipelineStatus.get_record(run_id, server: journal_name) do
          %Record{status: :interrupted} = record -> {:ok, record}
          _other -> :retry
        end
      end)

    assert "open_design_checkpoint" in interrupted.completed_nodes
    refute "await_design_checkpoint" in interrupted.completed_nodes
    assert Enum.any?(Arbor.Comms.pending_interactions(), &(&1.request_id == request_id))

    approval_metadata = %{
      "decision" => "approve",
      "operation_id" => receipt.operation_id,
      "evidence" => await_params.evidence
    }

    assert :ok =
             Arbor.Comms.respond_to_interaction(request_id, :approved, approval_metadata)

    assert {:ok, %{response: :approved, metadata: ^approval_metadata}} =
             Arbor.Comms.get_interaction_response(request_id)

    assert :ok = Arbor.Comms.untrack_presence(self(), operator_id, :dashboard)
    restart_comms!()
    assert_eventually(&Arbor.Comms.durable_ready?/0)
    track_operator!(operator_id)

    assert {:ok, %{response: :approved, metadata: ^approval_metadata}} =
             Arbor.Comms.get_interaction_response(request_id)

    refute Enum.any?(Arbor.Comms.pending_interactions(), &(&1.request_id == request_id))
    refute_receive {:durable_design_checkpoint_delivery, _}, 150

    publish_for_public_resume!(interrupted)

    resume_task =
      Task.async(fn ->
        :erlang.trace(self(), true, [:call, {:tracer, parent}])

        Orchestrator.resume(run_id,
          identity_private_key: identity_private_key,
          actions_executor: ActionsExecutor
        )
      end)

    assert_receive {:trace, resume_pid, :call,
                    {Arbor.Actions, :authorize_and_execute,
                     [^agent_id, resumed_action_module, resumed_params, _]}},
                   10_000

    assert resume_pid == resume_task.pid
    assert_action_name!(resumed_action_module, @await_action_name)

    assert resumed_params == await_params
    assert resumed_params.request_id == request_id
    assert resumed_params.operation_id == receipt.operation_id
    assert resumed_params.owner_deadline_unix_ms == run_deadline_unix_ms

    assert {:ok, result} = Task.await(resume_task, 10_000)
    assert result.context["accepted_design_request_id"] == request_id
    assert result.context["accepted_design_evidence"] == await_params.evidence
    assert result.context["design_checkpoint.checkpoint_outcome"] == "approve"
    assert result.context["session.run_deadline_unix_ms"] == run_deadline_unix_ms

    assert result.context["design_checkpoint_open.owner_deadline_unix_ms"] ==
             run_deadline_unix_ms

    assert result.context["accepted_design_evidence"]["packet_digest"] ==
             plan.work_packet_digest

    assert result.context["accepted_design_evidence"]["workspace_id"] == workspace_id
    assert result.context["accepted_design_evidence"]["worker_session_id"] == worker_session_id

    assert result.context["accepted_design_evidence"]["provider_session_id"] ==
             provider_session_id

    assert result.context["accepted_design_evidence"]["design_attempt"] == design_attempt
    assert result.context["accepted_design_evidence"]["design_digest"] == design_digest

    refute_receive {:durable_design_checkpoint_delivery, _}, 150

    refute_receive {:trace, ^resume_pid, :call, {Arbor.Actions, :authorize_and_execute, _}},
                   100
  end

  defp compile_v2_plan!(repo_root, design) do
    packet = %{
      "version" => WorkPacket.schema_version(),
      "success_criteria" => [
        "Open is durable before Await",
        "resume observes the exact terminal authority"
      ],
      "non_goals" => ["network partition proof"],
      "constraints" => ["use production action boundaries"],
      "architecture_refs" => [
        "apps/arbor_actions/lib/arbor/actions/coding/design_checkpoint.ex"
      ],
      "required_evidence" => ["one adapter delivery", "no Open replay"],
      "checkpoint_policy" => "design_required"
    }

    assert {:ok, packet_digest} = WorkPacket.digest(packet)

    assert {:ok, plan} =
             Plan.new(%{
               version: Plan.latest_schema_version(),
               task: design,
               repo_root: repo_root,
               task_class: "security_regression",
               worker: %{
                 provider: "grok",
                 model: "grok-4.5",
                 permission_mode: "default",
                 use_pool: true
               },
               validation_profile: "security_regression",
               review_profile: "binding",
               requested_paths: [
                 "apps/arbor_orchestrator/test/arbor/orchestrator/coding_design_checkpoint_durable_resume_integration_test.exs"
               ],
               budgets: %{
                 wall_clock_ms: 600_000,
                 inactivity_timeout_ms: 300_000,
                 parallelism: 1
               },
               work_packet: packet,
               work_packet_digest: packet_digest
             })

    assert {:ok, compilation} = Compiler.compile(plan)
    {plan, compilation}
  end

  defp design_checkpoint_dot do
    """
    digraph DurableDesignCheckpoint {
      start [shape=Mdiamond]
      open_design_checkpoint [
        type="exec",
        target="action",
        action="coding_design_checkpoint_open",
        context_keys="work_packet,packet_digest,session.task_id,task,plan_fingerprint,coding_plan_fingerprint,workspace_id,worker_session_id,worker_provider_session_id,design_attempt,design,design_digest,session.run_deadline_unix_ms",
        param.timeout=600000,
        output_prefix="design_checkpoint_open",
        max_retries="0"
      ]
      hoist_design_checkpoint_request_id [
        type="transform",
        transform="identity",
        source_key="design_checkpoint_open.request_id",
        output_key="request_id"
      ]
      await_design_checkpoint [
        type="exec",
        target="action",
        action="coding_design_checkpoint_await",
        context_keys="request_id,design_checkpoint_open.operation_id,design_checkpoint_open.owner_deadline_unix_ms,design_checkpoint_open.evidence,work_packet,packet_digest,session.task_id,task,plan_fingerprint,coding_plan_fingerprint,workspace_id,worker_session_id,worker_provider_session_id,design_attempt,design,design_digest,session.run_deadline_unix_ms",
        output_prefix="design_checkpoint",
        max_retries="0"
      ]
      hoist_accepted_design_evidence [
        type="transform",
        transform="identity",
        source_key="design_checkpoint.evidence",
        output_key="accepted_design_evidence"
      ]
      hoist_accepted_design_request_id [
        type="transform",
        transform="identity",
        source_key="design_checkpoint.request_id",
        output_key="accepted_design_request_id"
      ]
      done [shape=Msquare]

      start -> open_design_checkpoint -> hoist_design_checkpoint_request_id
      hoist_design_checkpoint_request_id -> await_design_checkpoint
      await_design_checkpoint -> hoist_accepted_design_evidence
      hoist_accepted_design_evidence -> hoist_accepted_design_request_id -> done
    }
    """
  end

  defp assert_exact_design_input!(
         params,
         plan,
         plan_fingerprint,
         task_id,
         workspace_id,
         worker_session_id,
         provider_session_id,
         design_attempt,
         design,
         design_digest,
         run_deadline_unix_ms
       ) do
    assert params.work_packet == plan.work_packet
    assert params.packet_digest == plan.work_packet_digest
    assert params.task_id == task_id
    assert params.task == plan.task
    assert params.plan_fingerprint == plan_fingerprint
    assert params.coding_plan_fingerprint == plan_fingerprint
    assert params.workspace_id == workspace_id
    assert params.worker_session_id == worker_session_id
    assert params.worker_provider_session_id == provider_session_id
    assert params.design_attempt == design_attempt
    assert params.design == design
    assert params.design_digest == design_digest
    assert params.run_deadline_unix_ms == run_deadline_unix_ms
  end

  defp grant_exact_action_authority!(agent_id, task_id) do
    resources =
      Enum.map([@open_action_name, @await_action_name], fn action_name ->
        assert {:ok, resource} = Arbor.Actions.tool_name_to_canonical_uri(action_name)
        resource
      end)

    assert resources == [
             "arbor://action/coding/design_checkpoint/open",
             "arbor://action/coding/design_checkpoint/await"
           ]

    Enum.each(resources, fn resource ->
      assert {:ok, _capability} =
               Arbor.Security.grant(
                 principal: agent_id,
                 resource: resource,
                 task_id: task_id
               )
    end)

    assert {:ok, _profile} =
             Arbor.Trust.ensure_trust_profile(agent_id,
               baseline: :block,
               rules: Map.new(resources, &{&1, :allow})
             )

    resources
  end

  defp assert_exact_trust_authority!(agent_id, task_id, resources) do
    Enum.each(resources, fn resource ->
      assert :allow = Arbor.Trust.effective_mode(agent_id, resource)
      assert :auto = Arbor.Trust.confirmation_mode(agent_id, resource)

      assert {:ok, :authorized} =
               Arbor.Trust.authorize(agent_id, resource, :execute, task_id: task_id)
    end)

    assert {:ok, capabilities} = Arbor.Security.list_capabilities(agent_id)

    assert capabilities
           |> Enum.map(& &1.resource_uri)
           |> Enum.sort() == Enum.sort(resources)
  end

  defp configure_engine_checkpoints!(store_name, backend_opts) do
    Application.put_env(:arbor_orchestrator, :engine_checkpoints,
      store: NodeRestartProxy,
      store_name: store_name,
      store_opts: backend_opts,
      start_store: false,
      store_child_opts: [],
      durability_class: :node_restart
    )
  end

  defp configure_comms!(store_name, backend_opts, operator_id) do
    Application.put_env(:arbor_comms, :durable_interaction_store,
      backend: NodeRestartProxy,
      namespace: store_name,
      opts: backend_opts,
      max_data_bytes: 65_536,
      max_items: 32
    )

    Application.put_env(:arbor_comms, :durable_interaction_dispatch,
      sweep_interval_ms: 25,
      startup_delay_ms: 10,
      batch_size: 16,
      retry_base_ms: 10,
      retry_max_ms: 50,
      send_timeout_ms: 1_000,
      max_concurrency: 2
    )

    Application.put_env(:arbor_comms, :interaction_adapters, %{
      dashboard: DeliveryAdapter
    })

    signal =
      Application.get_env(:arbor_comms, :signal, [])
      |> Keyword.put(:enabled, false)
      |> Keyword.put(:interaction_user_id, operator_id)

    Application.put_env(:arbor_comms, :signal, signal)
  end

  defp track_operator!(operator_id) do
    case Arbor.Comms.track_presence(self(), operator_id, :dashboard, %{test_pid: self()}) do
      {:ok, _ref} -> :ok
      {:error, {:already_tracked, pid, _topic, :dashboard}} when pid == self() -> :ok
    end
  end

  defp publish_for_public_resume!(%Record{} = interrupted) do
    published = %Record{
      interrupted
      | status: :interrupted,
        failure_reason: nil,
        finished_at: nil,
        duration_ms: nil,
        owner_node: nil
    }

    assert :ok = PipelineStatus.put(published)
  end

  defp trace_design_actions! do
    :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, true, [])
  end

  defp untrace_design_actions do
    :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, false, [])
  end

  defp assert_action_name!(action_module, expected_name) do
    assert {:ok, %{"name" => ^expected_name}} = Arbor.Actions.runtime_descriptor(action_module)
  end

  defp ensure_security_and_trust_started! do
    ensure_started(Arbor.Security.Identity.Registry)
    ensure_started(Arbor.Security.Identity.NonceCache)
    ensure_started(Arbor.Security.SystemAuthority)
    ensure_started(Arbor.Security.CapabilityStore)
    ensure_started(Arbor.Security.Reflex.Registry)
    ensure_started(Arbor.Security.Constraint.RateLimiter)
    ensure_started(Arbor.Trust.EventStore)
    ensure_started(Arbor.Trust.Store)

    ensure_started(Arbor.Trust.Manager,
      circuit_breaker: false,
      decay: false,
      event_store: true
    )
  end

  defp ensure_started(module, opts \\ []) do
    unless Process.whereis(module) do
      start_supervised!({module, opts})
    end
  end

  defp restart_comms! do
    stop_comms()
    assert {:ok, _started} = Application.ensure_all_started(:arbor_comms)
  end

  defp restart_comms_safely do
    stop_comms()
    _ = Application.ensure_all_started(:arbor_comms)
    :ok
  end

  defp stop_comms do
    case Application.stop(:arbor_comms) do
      :ok -> :ok
      {:error, {:not_started, :arbor_comms}} -> :ok
    end
  end

  defp assert_eventually(fun, timeout_ms \\ 5_000) do
    assert :ok ==
             assert_eventually_value(
               fn -> if fun.(), do: {:ok, :ok}, else: :retry end,
               timeout_ms
             )
  end

  defp assert_eventually_value(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually_value(fun, deadline)
  end

  defp do_assert_eventually_value(fun, deadline) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("condition not met within timeout")
        else
          receive do
          after
            10 -> do_assert_eventually_value(fun, deadline)
          end
        end
    end
  end

  defp safe_release_hold(controller_name) do
    try do
      CentralStore.release_hold(controller_name)
    catch
      :exit, _reason -> :ok
    end
  end

  defp safe_untrack_operator(operator_id) do
    try do
      Arbor.Comms.untrack_presence(self(), operator_id, :dashboard)
    catch
      :exit, _reason -> :ok
    end
  end

  defp restore_env(app, key, :__unset__), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp repo_root do
    cwd = File.cwd!() |> Path.expand()

    if File.dir?(Path.join(cwd, "apps/arbor_orchestrator")) do
      cwd
    else
      Path.expand("../..", cwd)
    end
  end

  defp tmp_root(label, suffix) do
    Path.join(System.tmp_dir!(), "arbor_#{label}_#{suffix}")
  end

  defp sha256_prefixed(value) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, value), case: :lower)
  end
end
