defmodule Arbor.Orchestrator.CodingDesignCheckpointDurableResumeIntegrationTest do
  @moduledoc """
  Phase C same-node BEAM-restart durability proof for Coding Plan v2 design checkpoints.

  Topology:
  - Controller ExUnit node owns `CentralStore` (journal, engine checkpoint, Comms).
  - One LocalCluster member runs Open/Await against that store.
  - The entire member BEAM is killed, then a fresh LocalCluster with the **same
    prefix** boots a replacement with the same node atom and a new BEAM.
  - Replacement rehydrates before public pending exposure, races public response
    against the restored absolute-deadline timeout, and resumes at Await only.

  Explicit non-claims: network partition, cross-node takeover, storage failover,
  host durability. Postgres is unused.

  Run: `./bin/mix test path/to/this_file.exs --include distributed`
  """

  use ExUnit.Case, async: false

  @moduletag :distributed
  @moduletag :integration
  @moduletag :security_regression
  @moduletag :slow
  @moduletag timeout: 180_000

  alias Arbor.Contracts.Coding.{Plan, WorkPacket}
  alias Arbor.Orchestrator
  alias Arbor.Orchestrator.ActionsExecutor
  alias Arbor.Orchestrator.CodingPlan.Compiler
  alias Arbor.Orchestrator.L4ClusterRecoverySupport, as: Support
  alias Arbor.Orchestrator.L4ClusterRecoverySupport.CentralStore
  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RunLifecycle.Record

  @open_action_name "coding_design_checkpoint_open"
  @await_action_name "coding_design_checkpoint_await"
  @owner_timeout_ms 20_000
  @support_file Path.expand("../../../support/l4_cluster_recovery_support.ex", __DIR__)

  setup_all do
    started_distribution? = not Node.alive?()

    if started_distribution? do
      assert :ok = LocalCluster.start()

      on_exit(fn ->
        assert :ok = LocalCluster.stop()
      end)
    end

    :ok
  end

  test "security regression: same-node BEAM restart rehydrates design checkpoint at Await" do
    suffix = System.unique_integer([:positive, :monotonic])
    prefix = "dckpt_#{suffix}_"
    controller_name = :"design_checkpoint_central_#{suffix}"
    journal_store = :"design_checkpoint_journal_#{suffix}"
    checkpoint_store = :"design_checkpoint_engine_checkpoint_#{suffix}"
    comms_store = :"design_checkpoint_comms_#{suffix}"
    run_id = "design_checkpoint_beam_restart_#{suffix}"
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
    recovery_root = tmp_root("recovery", suffix)
    dot_path = Path.join(dot_root, "durable-design-checkpoint.dot")
    parent = self()

    start_supervised!(
      {CentralStore,
       name: controller_name,
       parent: parent,
       hold_store: journal_store,
       hold_on: :completed_progress,
       hold_node: "open_design_checkpoint"}
    )

    on_exit(fn ->
      safe_release_hold(controller_name)
      File.rm_rf(logs_root)
      File.rm_rf(dot_root)
      File.rm_rf(recovery_root)
    end)

    {plan, compilation} = compile_v2_plan!(repo_root, design)
    assert plan.version == 2
    assert plan.work_packet["checkpoint_policy"] == "design_required"

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

    File.mkdir_p!(dot_root)
    File.mkdir_p!(logs_root)
    File.mkdir_p!(recovery_root)
    File.write!(dot_path, design_checkpoint_dot())
    assert {:ok, parsed} = Orchestrator.parse(design_checkpoint_dot())
    assert {:ok, _compiled} = Arbor.Orchestrator.IR.Compiler.compile(parsed)

    peer_opts =
      peer_opts(prefix, %{
        controller_name: controller_name,
        journal_store: journal_store,
        checkpoint_store: checkpoint_store,
        comms_store: comms_store,
        operator_id: operator_id,
        agent_id: agent_id,
        task_id: task_id,
        recovery_root: recovery_root
      })

    {:ok, cluster} = start_cluster(prefix)
    on_exit(fn -> safe_stop_cluster(cluster) end)

    {:ok, [owner]} = LocalCluster.nodes(cluster)
    assert :ok = :erpc.call(owner, Support, :prepare_design_checkpoint_peer!, [peer_opts], 90_000)
    assert true = :erpc.call(owner, Arbor.Comms, :durable_ready?, [], 5_000)
    assert_peer_authority!(owner, agent_id, task_id)

    assert {:ok, _holder} =
             :erpc.call(owner, Support, :start_presence_holder!, [operator_id, parent], 10_000)

    run_opts = [
      run_id: run_id,
      logs_root: logs_root,
      identity_private_key: identity_private_key,
      resumable: true,
      agent_id: agent_id,
      execution_principal: agent_id,
      initial_values: initial_values,
      actions_executor: ActionsExecutor
    ]

    assert {:ok, engine_pid} =
             :erpc.call(
               owner,
               Support,
               :start_design_run_async,
               [dot_path, run_opts, parent],
               10_000
             )

    assert_receive {:l4_engine_started, ^owner, ^engine_pid}, 10_000

    assert_receive {:trace, ^engine_pid, :call,
                    {Arbor.Actions, :authorize_and_execute,
                     [^agent_id, open_action_module, open_params, _]}},
                   30_000

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

    assert_receive {:durable_design_checkpoint_delivery, interaction}, 30_000
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

    assert_receive {:l4_store_held, :completed_progress, held}, 30_000
    assert held.logical == journal_store
    assert held.effect["node_id"] == "open_design_checkpoint"
    assert held.effect["status"] == "completed"
    assert "open_design_checkpoint" in held.completed_nodes

    assert CentralStore.has_key?(
             controller_name,
             checkpoint_store,
             Support.checkpoint_key(run_id)
           )

    assert CentralStore.has_key?(controller_name, comms_store, request_id)

    checkpoint_path = Path.join(logs_root, "checkpoint.json")
    assert File.exists?(checkpoint_path)
    File.rm!(checkpoint_path)
    refute File.exists?(checkpoint_path)

    assert :ok = CentralStore.release_hold(controller_name)

    assert_receive {:trace, ^engine_pid, :call,
                    {Arbor.Actions, :authorize_and_execute,
                     [^agent_id, await_action_module, await_params, _]}},
                   30_000

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
    assert is_binary(await_params.operation_id)
    assert await_params.operation_id != ""
    owner_deadline_unix_ms = await_params.owner_deadline_unix_ms
    assert owner_deadline_unix_ms < run_deadline_unix_ms
    assert owner_deadline_unix_ms > System.system_time(:millisecond)
    assert await_params.evidence["request_id"] == request_id
    operation_id = await_params.operation_id
    evidence = await_params.evidence

    assert {:ok, before_restart} =
             CentralStore.get(controller_name, comms_store, request_id)

    assert before_restart.data["status"] == "pending"
    assert before_restart.data["operation_id"] == operation_id
    assert before_restart.data["owner_deadline_unix_ms"] == owner_deadline_unix_ms
    assert before_restart.data["terminal"] == nil

    refute_receive {:l4_engine_finished, ^owner, ^engine_pid, _}, 50

    # Kill the whole original BEAM (not Application.stop / process kill only).
    engine_ref = Process.monitor(engine_pid)
    assert :ok = LocalCluster.stop(cluster)

    assert_receive {:DOWN, ^engine_ref, :process, ^engine_pid, _}, 15_000

    assert :ok =
             Support.await_until(15_000, fn ->
               if owner in Node.list() do
                 {:error, :still_visible}
               else
                 :ok
               end
             end)

    # Fresh LocalCluster with the same prefix → same node atom, new BEAM.
    {:ok, replacement_cluster} = start_cluster(prefix)
    on_exit(fn -> safe_stop_cluster(replacement_cluster) end)

    {:ok, [replacement]} = LocalCluster.nodes(replacement_cluster)
    assert replacement == owner

    assert :ok =
             :erpc.call(
               replacement,
               Support,
               :prepare_design_checkpoint_peer!,
               [peer_opts],
               90_000
             )

    # Application startup returns only after durable hydration is authoritative.
    assert true = :erpc.call(replacement, Arbor.Comms, :durable_ready?, [], 5_000)
    assert_peer_authority!(replacement, agent_id, task_id)

    pending =
      :erpc.call(replacement, Arbor.Comms, :pending_interactions, [], 5_000)

    assert [%{request_id: ^request_id}] = Enum.filter(pending, &(&1.request_id == request_id))

    assert {:ok, after_restart} =
             CentralStore.get(controller_name, comms_store, request_id)

    assert after_restart.data["status"] == "pending"
    assert after_restart.data["operation_id"] == operation_id
    assert after_restart.data["owner_deadline_unix_ms"] == owner_deadline_unix_ms
    assert after_restart.data["interaction"] == before_restart.data["interaction"]
    assert after_restart.data["terminal"] == nil

    assert {:ok, _holder2} =
             :erpc.call(
               replacement,
               Support,
               :start_presence_holder!,
               [operator_id, parent],
               10_000
             )

    refute_receive {:durable_design_checkpoint_delivery, _}, 100

    approval_metadata = %{
      "decision" => "approve",
      "operation_id" => operation_id,
      "evidence" => evidence
    }

    # Submit at the restored deadline. Either the public response or the
    # authority-owned deadline CAS may win; the durable record decides.
    responder =
      Task.async(fn ->
        remaining = max(owner_deadline_unix_ms - System.system_time(:millisecond), 0)
        Process.sleep(remaining)

        :erpc.call(
          replacement,
          Arbor.Comms,
          :respond_to_interaction,
          [request_id, :approved, approval_metadata],
          10_000
        )
      end)

    terminal_record =
      assert_eventually_value(
        fn ->
          case CentralStore.get(controller_name, comms_store, request_id) do
            {:ok, %{data: %{"status" => status}} = record}
            when status in ["responded", "abandoned"] ->
              {:ok, record}

            _ ->
              :retry
          end
        end,
        @owner_timeout_ms + 10_000
      )

    response_result = Task.await(responder, 10_000)
    terminal_status = terminal_record.data["status"]
    first_terminal = terminal_record.data["terminal"]

    {checkpoint_outcome, terminal_atom} =
      case terminal_status do
        "responded" ->
          assert response_result == :ok
          assert first_terminal["response"] == %{"kind" => "approved"}
          assert first_terminal["metadata"] == approval_metadata
          {"approve", :responded}

        "abandoned" ->
          assert response_result == {:error, {:already_terminal, :abandoned}}
          assert first_terminal["response"] == nil
          {"timeout", :abandoned}
      end

    # Late competing settlement cannot change the first terminal.
    late =
      :erpc.call(
        replacement,
        Arbor.Comms,
        :respond_to_interaction,
        [request_id, :rejected, %{"duplicate" => true}],
        10_000
      )

    assert late == {:error, {:already_terminal, terminal_atom}}

    assert {:ok, after_late_response} =
             CentralStore.get(controller_name, comms_store, request_id)

    assert after_late_response == terminal_record
    assert after_late_response.data["terminal"] == first_terminal

    assert {:ok, [^request_id]} = CentralStore.list(controller_name, comms_store)

    refute Enum.any?(
             :erpc.call(replacement, Arbor.Comms, :pending_interactions, [], 5_000),
             &(&1.request_id == request_id)
           )

    # Lifecycle rehydrates to claimable interrupted with Open completed only.
    interrupted =
      assert_eventually_value(
        fn ->
          case :erpc.call(replacement, PipelineStatus, :get_record, [run_id], 5_000) do
            %Record{status: :interrupted} = record ->
              if "open_design_checkpoint" in (record.completed_nodes || []) and
                   "await_design_checkpoint" not in (record.completed_nodes || []) do
                {:ok, record}
              else
                :retry
              end

            _other ->
              :retry
          end
        end,
        30_000
      )

    assert "open_design_checkpoint" in interrupted.completed_nodes
    refute "await_design_checkpoint" in interrupted.completed_nodes

    assert {:ok, resumable} =
             :erpc.call(replacement, Orchestrator, :list_resumable, [], 10_000)

    assert Enum.any?(resumable, &(&1.run_id == run_id))

    resume_parent = self()

    resume_opts = [
      identity_private_key: identity_private_key,
      agent_id: agent_id,
      execution_principal: agent_id,
      actions_executor: ActionsExecutor
    ]

    resume_task =
      Task.async(fn ->
        :erpc.call(
          replacement,
          Support,
          :resume_design_run,
          [run_id, resume_opts, resume_parent],
          60_000
        )
      end)

    assert_receive {:trace, resume_pid, :call,
                    {Arbor.Actions, :authorize_and_execute,
                     [^agent_id, resumed_action_module, resumed_params, _]}},
                   30_000

    assert node(resume_pid) == replacement
    assert_action_name!(resumed_action_module, @await_action_name)
    assert resumed_params.request_id == request_id
    assert resumed_params.operation_id == operation_id
    assert resumed_params.owner_deadline_unix_ms == owner_deadline_unix_ms
    assert resumed_params.evidence == evidence

    assert_exact_design_input!(
      resumed_params,
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

    assert {:ok, result} = Task.await(resume_task, 60_000)
    assert result.context["accepted_design_request_id"] == request_id
    assert result.context["accepted_design_evidence"] == evidence
    assert result.context["design_checkpoint.checkpoint_outcome"] == checkpoint_outcome
    assert result.context["session.run_deadline_unix_ms"] == run_deadline_unix_ms

    assert result.context["design_checkpoint_open.owner_deadline_unix_ms"] ==
             owner_deadline_unix_ms

    assert result.context["accepted_design_evidence"]["packet_digest"] ==
             plan.work_packet_digest

    assert result.context["accepted_design_evidence"]["workspace_id"] == workspace_id
    assert result.context["accepted_design_evidence"]["worker_session_id"] == worker_session_id

    assert result.context["accepted_design_evidence"]["provider_session_id"] ==
             provider_session_id

    assert result.context["accepted_design_evidence"]["design_attempt"] == design_attempt
    assert result.context["accepted_design_evidence"]["design_digest"] == design_digest

    # No Open replay and no second adapter delivery after the original Open.
    refute_receive {:durable_design_checkpoint_delivery, _}, 150

    refute_receive {:trace, ^resume_pid, :call,
                    {Arbor.Actions, :authorize_and_execute,
                     [^agent_id, ^open_action_module, _, _]}},
                   100
  end

  defp peer_opts(prefix, ctx) do
    [
      controller_name: ctx.controller_name,
      controller_node: Node.self(),
      journal_store: ctx.journal_store,
      checkpoint_store: ctx.checkpoint_store,
      comms_store: ctx.comms_store,
      operator_id: ctx.operator_id,
      agent_id: ctx.agent_id,
      task_id: ctx.task_id,
      durability_class: :node_restart,
      recovery_enabled: false,
      recovery_root: ctx.recovery_root,
      cluster_prefix: prefix
    ]
  end

  defp start_cluster(prefix) do
    LocalCluster.start_link(1,
      prefix: prefix,
      applications: [],
      files: [@support_file]
    )
  end

  defp safe_stop_cluster(cluster) do
    try do
      LocalCluster.stop(cluster)
    catch
      :exit, _ -> :ok
    end
  end

  defp compile_v2_plan!(repo_root, design) do
    packet = %{
      "version" => WorkPacket.schema_version(),
      "success_criteria" => [
        "Open is durable before Await",
        "same-node BEAM restart rehydrates exact authority",
        "resume observes the exact terminal authority"
      ],
      "non_goals" => ["network partition proof", "cross-node takeover"],
      "constraints" => ["use production action boundaries", "LocalCluster same-prefix restart"],
      "architecture_refs" => [
        "apps/arbor_actions/lib/arbor/actions/coding/design_checkpoint.ex",
        "apps/arbor_orchestrator/test/support/l4_cluster_recovery_support.ex"
      ],
      "required_evidence" => ["one adapter delivery", "no Open replay", "same node atom"],
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
        param.timeout=#{@owner_timeout_ms},
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

  defp assert_action_name!(action_module, expected_name) do
    assert {:ok, %{"name" => ^expected_name}} = Arbor.Actions.runtime_descriptor(action_module)
  end

  defp assert_peer_authority!(peer, agent_id, task_id) do
    open_resource = "arbor://action/coding/design_checkpoint/open"
    await_resource = "arbor://action/coding/design_checkpoint/await"

    assert {:ok, capabilities} =
             :erpc.call(peer, Arbor.Security, :list_capabilities, [agent_id], 5_000)

    assert capabilities
           |> Enum.map(&{&1.resource_uri, &1.task_id})
           |> Enum.sort() ==
             Enum.sort([
               {open_resource, task_id},
               {await_resource, task_id},
               {"arbor://orchestrator/execute/**", nil}
             ])

    Enum.each([open_resource, await_resource], fn resource ->
      assert :allow =
               :erpc.call(peer, Arbor.Trust, :effective_mode, [agent_id, resource], 5_000)

      assert :auto =
               :erpc.call(peer, Arbor.Trust, :confirmation_mode, [agent_id, resource], 5_000)

      assert {:ok, :authorized} =
               :erpc.call(
                 peer,
                 Arbor.Trust,
                 :authorize,
                 [agent_id, resource, :execute, [task_id: task_id]],
                 5_000
               )
    end)
  end

  defp assert_eventually_value(fun, timeout_ms) do
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
            20 -> do_assert_eventually_value(fun, deadline)
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
