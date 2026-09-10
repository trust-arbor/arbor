Code.require_file(
  Path.expand("../../../../arbor_security/test/support/approval_answer_fixture.ex", __DIR__)
)

defmodule Arbor.Agent.OrchestrationLiveApprovalTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Arbor.Agent.Orchestration
  alias Arbor.Security.TestSupport.ApprovalAnswerFixture, as: ApprovalFixture

  defmodule GatedPolicy do
    def confirmation_mode(_principal, _uri, _opts), do: :gated
    def confirmation_mode(_principal, _uri), do: :gated
  end

  setup_all do
    bootstrap_security!()
    bootstrap_consensus!()
    :ok
  end

  setup do
    original_config = snapshot_config()
    start_supervised!(Arbor.Trust.ConfirmationTracker)
    Application.put_env(:arbor_trust, :approval_evidence_provider, Arbor.Agent.ApprovalEvidence)

    # This test uses synthetic local identities and no signed request; pin the
    # full auth posture it needs instead of inheriting suite-global state.
    Application.put_env(:arbor_trust, :approval_guard_enabled, true)
    Application.put_env(:arbor_trust, :policy_module, GatedPolicy)
    Application.put_env(:arbor_trust, :policy_enforcer_enabled, false)
    Application.put_env(:arbor_security, :approval_guard_enabled, true)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, true)
    Application.put_env(:arbor_security, :consensus_module, Arbor.Consensus)
    Application.put_env(:arbor_security, :use_interaction_router_for_approval, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :identity_verification, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)
    Application.put_env(:arbor_security, :egress_gate_enforcing, false)
    Application.put_env(:arbor_security, :policy_enforcer_enabled, false)
    Application.put_env(:arbor_consensus, :llm_topic_classification_enabled, false)

    unique = System.unique_integer([:positive])
    tmp_dir = Path.join(Path.expand(System.tmp_dir!()), "arbor_orchestration_live_#{unique}")
    File.mkdir_p!(tmp_dir)

    agent_id = "agent_live_approval_#{unique}"
    operator_id = "agent_live_operator_#{unique}"

    {:ok, _} =
      Arbor.Security.grant(principal: agent_id, resource: "arbor://fs/write#{tmp_dir}/**")

    {:ok, _} = Arbor.Security.grant(principal: operator_id, resource: "arbor://approval/read")

    {:ok, _} =
      Arbor.Security.grant(
        principal: operator_id,
        resource: "arbor://approval/answer/#{agent_id}"
      )

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      Arbor.Security.CapabilityStore.revoke_all(agent_id)
      Arbor.Security.CapabilityStore.revoke_all(operator_id)
      restore_config(original_config)
    end)

    {:ok, agent_id: agent_id, operator_id: operator_id, tmp_dir: tmp_dir}
  end

  test "security regression: winning approvals feed one exact confirmation and rejections reset it",
       ctx do
    cases = [
      {:approve, :approved, "approved after inspection"},
      {:deny, :rejected, "not the requested file"},
      {:rework, :rejected, "rewrite with narrower output"}
    ]

    for {decision, expected_status, note} <- cases do
      file_path = Path.join(ctx.tmp_dir, "#{decision}.md")
      content = "approval #{decision}\n"

      assert {:ok, :pending_approval, approval_id} =
               Arbor.Actions.authorize_and_execute(
                 ctx.agent_id,
                 Arbor.Actions.File.Write,
                 %{path: file_path, content: content},
                 %{
                   workspace: ctx.tmp_dir,
                   taint: :untrusted,
                   session_id: "session_#{decision}",
                   turn_id: "turn_#{decision}"
                 }
               )

      refute File.exists?(file_path)

      assert {:ok, submitted_proposal} = Arbor.Consensus.get_proposal(approval_id)
      assert submitted_proposal.status == :pending
      assert submitted_proposal.topic == :authorization_request

      pending_consensus =
        Arbor.Consensus.list_pending()
        |> Enum.map(&{&1.id, &1.proposer, &1.topic, &1.status})

      assert Enum.any?(pending_consensus, fn {id, _, _, _} -> id == approval_id end),
             "expected #{approval_id} in consensus pending #{inspect(pending_consensus)}"

      assert {:ok, all_approvals} =
               Orchestration.list_pending_approvals(caller_id: ctx.operator_id)

      assert {:ok, approvals} =
               Orchestration.list_pending_approvals(
                 caller_id: ctx.operator_id,
                 agent_id: ctx.agent_id
               )

      approval = Enum.find(approvals, &(&1.id == approval_id))

      assert approval,
             "expected #{approval_id} in filtered #{inspect(Enum.map(approvals, &{&1.id, &1.agent_id, &1.resource_uri}))}; all #{inspect(Enum.map(all_approvals, &{&1.id, &1.agent_id, &1.resource_uri}))}"

      assert approval.source == :consensus
      assert approval.agent_id == ctx.agent_id
      assert approval.principal_id == ctx.agent_id
      assert approval.resource_uri == "arbor://fs/write#{file_path}"
      assert approval.context.target == file_path
      assert approval.context.payload_preview.preview == content
      assert approval.context.gate == :trust_policy
      assert approval.context.reason == :policy_gated
      assert approval.context.risk_hints.operation_taint == :untrusted

      assert :ok =
               Orchestration.answer_approval(approval_id, decision,
                 caller_id: ctx.operator_id,
                 note: note
               )

      evidence = Arbor.Trust.confirmation_status(ctx.agent_id, "arbor://fs/write")
      assert evidence.approvals == 1
      assert evidence.unknown_approvals == 1
      assert evidence.verified_human_approvals == 0
      assert evidence.streak == if(decision == :approve, do: 1, else: 0)
      assert evidence.rejections == Enum.find_index(cases, &(elem(&1, 0) == decision))

      assert {:error, :not_found} =
               Orchestration.answer_approval(approval_id, decision, caller_id: ctx.operator_id)

      assert Arbor.Trust.confirmation_status(ctx.agent_id, "arbor://fs/write") == evidence

      assert {:ok, remaining} =
               Orchestration.list_pending_approvals(
                 caller_id: ctx.operator_id,
                 agent_id: ctx.agent_id
               )

      refute Enum.any?(remaining, &(&1.id == approval_id))

      assert {:ok, proposal} = Arbor.Consensus.get_proposal(approval_id)
      assert proposal.status == expected_status

      refute File.exists?(file_path)
    end
  end

  test "security regression: real interaction answers feed unknown streaks and ignore fabricated human metadata",
       ctx do
    if Process.whereis(Arbor.Comms.PubSub) == nil do
      start_supervised!({Phoenix.PubSub, name: Arbor.Comms.PubSub})
    end

    if Process.whereis(Arbor.Comms.InteractionRegistry) == nil do
      start_supervised!(Arbor.Comms.InteractionRegistry)
    end

    resource = "arbor://code/write/exact/file.ex"

    for decision <- [:approve, :approve, :approve, :rework] do
      assert {:ok, request} =
               Arbor.Contracts.Comms.Interaction.new(%{
                 kind: :approval,
                 agent_id: ctx.agent_id,
                 user_id: ctx.operator_id,
                 resource_uri: resource,
                 description: "Record one approval answer",
                 metadata: %{verified_human: true, actor: "human_forged"}
               })

      assert {:ok, _} = Arbor.Comms.InteractionRegistry.put(request)

      assert :ok =
               Orchestration.answer_approval(request.request_id, decision,
                 caller_id: ctx.operator_id
               )

      assert {:error, :not_found} =
               Orchestration.answer_approval(request.request_id, decision,
                 caller_id: ctx.operator_id
               )
    end

    status = Arbor.Trust.confirmation_status(ctx.agent_id, "arbor://code/write")
    assert status.approvals == 3
    assert status.unknown_approvals == 3
    assert status.rejections == 1
    assert status.streak == 0
    assert status.human_streak == 0
    assert status.verified_human_approvals == 0
    refute Arbor.Trust.graduated?(ctx.agent_id, resource)
  end

  test "human SessionToken travels through Orchestration and winning Comms answer into exact Trust evidence" do
    ctx = ApprovalFixture.setup!()

    if Process.whereis(Arbor.Comms.PubSub) == nil,
      do: start_supervised!({Phoenix.PubSub, name: Arbor.Comms.PubSub})

    if Process.whereis(Arbor.Comms.InteractionRegistry) == nil,
      do: start_supervised!(Arbor.Comms.InteractionRegistry)

    ApprovalFixture.grant!(ctx.human_id, "arbor://approval/read")
    ApprovalFixture.grant!(ctx.human_id, "arbor://approval/answer/#{ctx.agent_id}")
    resource = "arbor://code/write/exact/file.ex"

    for {decision, count, streak} <- [{:approve, 1, 1}, {:approve, 2, 2}, {:rework, 2, 0}] do
      assert {:ok, request} =
               Arbor.Contracts.Comms.Interaction.new(%{
                 kind: :approval,
                 agent_id: ctx.agent_id,
                 user_id: ctx.human_id,
                 resource_uri: resource,
                 description: "Human reviews exact write",
                 metadata: %{actor: "human_forged", verified_human_id: "human_forged"}
               })

      assert {:ok, _} = Arbor.Comms.InteractionRegistry.put(request)

      assert :ok =
               Orchestration.answer_approval(request.request_id, decision,
                 caller_id: ctx.human_id,
                 session_token: ctx.token
               )

      assert {:ok, evidence} = Arbor.Comms.get_answered_approval(request.request_id)
      assert evidence.verified_human_id == ctx.human_id

      status = Arbor.Trust.confirmation_status(ctx.agent_id, "arbor://code/write")
      assert status.approvals == count
      assert status.verified_human_approvals == count
      assert status.unknown_approvals == 0
      assert status.human_streak == streak
      expected = Map.take(evidence, [:agent_id, :principal_id, :resource_uri, :decision])

      assert {:ok, :duplicate} =
               Arbor.Trust.record_approval_answer(:interaction, request.request_id, expected)

      assert Arbor.Trust.confirmation_status(ctx.agent_id, "arbor://code/write") == status
    end
  end

  # Canonical bootstrap: it freezes the authority root and starts the whole
  # topology in the required order, instead of a hand-copied subset that can
  # drift from it. Idempotent, so it also restores children a test stopped.
  defp bootstrap_security! do
    :ok = Arbor.Security.TestBootstrap.start!()
  end

  defp bootstrap_consensus! do
    Application.put_env(:arbor_consensus, :llm_topic_classification_enabled, false)

    {:ok, _} = Application.ensure_all_started(:arbor_consensus)

    for child <- [
          Arbor.Consensus.TopicRegistry,
          Arbor.Consensus.EventStore,
          {Registry, keys: :unique, name: Arbor.Consensus.EvaluatorAgent.Registry},
          Arbor.Consensus.EvaluatorAgent.Supervisor,
          Arbor.Consensus.Coordinator
        ] do
      start_child(Arbor.Consensus.Supervisor, child)
    end
  end

  defp start_child(supervisor, child) do
    case Supervisor.start_child(supervisor, child) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_present} -> :ok
      {:error, {:already_present, _}} -> :ok
      {:error, {:shutdown, {:failed_to_start_child, _, {:already_started, _}}}} -> :ok
      {:error, reason} -> raise "failed to start #{inspect(child)}: #{inspect(reason)}"
    end
  end

  defp snapshot_config do
    [
      {:arbor_trust, :approval_guard_enabled},
      {:arbor_trust, :policy_module},
      {:arbor_trust, :policy_enforcer_enabled},
      {:arbor_trust, :approval_evidence_provider},
      {:arbor_security, :approval_guard_enabled},
      {:arbor_security, :consensus_escalation_enabled},
      {:arbor_security, :consensus_module},
      {:arbor_security, :use_interaction_router_for_approval},
      {:arbor_security, :capability_signing_required},
      {:arbor_security, :identity_verification},
      {:arbor_security, :strict_identity_mode},
      {:arbor_security, :reflex_checking_enabled},
      {:arbor_security, :uri_registry_enforcement},
      {:arbor_security, :egress_gate_enforcing},
      {:arbor_security, :policy_enforcer_enabled},
      {:arbor_consensus, :llm_topic_classification_enabled}
    ]
    |> Map.new(fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
  end

  defp restore_config(config) do
    Enum.each(config, fn
      {{app, key}, nil} -> Application.delete_env(app, key)
      {{app, key}, value} -> Application.put_env(app, key, value)
    end)
  end
end
