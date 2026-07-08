defmodule Arbor.Agent.OrchestrationLiveApprovalTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Arbor.Agent.Orchestration

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

    Application.put_env(:arbor_trust, :approval_guard_enabled, true)
    Application.put_env(:arbor_trust, :policy_module, GatedPolicy)
    Application.put_env(:arbor_security, :approval_guard_enabled, true)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, true)
    Application.put_env(:arbor_security, :consensus_module, Arbor.Consensus)
    Application.put_env(:arbor_security, :use_interaction_router_for_approval, false)
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

  test "gated operations enter the shared queue and approve/deny/rework resolve them", ctx do
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

  defp bootstrap_security! do
    {:ok, _} = Application.ensure_all_started(:arbor_security)

    security_backend =
      Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

    for {name, collection} <- [
          {:arbor_security_capabilities, "capabilities"},
          {:arbor_security_identities, "identities"},
          {:arbor_security_signing_keys, "signing_keys"},
          {:arbor_security_issuers, "issuers"}
        ] do
      child =
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           name: name, backend: security_backend, write_mode: :sync, collection: collection},
          id: name
        )

      start_child(Arbor.Security.Supervisor, child)
    end

    for child <- [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.IssuerRegistry, []},
          {Arbor.Security.Identity.NonceCache, []},
          {Arbor.Security.SystemAuthority, []},
          {Arbor.Security.Constraint.RateLimiter, []},
          {Arbor.Security.CapabilityStore, []},
          {Arbor.Security.Reflex.Registry, []},
          {Arbor.Security.UriRegistry, []}
        ] do
      start_child(Arbor.Security.Supervisor, child)
    end
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
      {:arbor_security, :approval_guard_enabled},
      {:arbor_security, :consensus_escalation_enabled},
      {:arbor_security, :consensus_module},
      {:arbor_security, :use_interaction_router_for_approval},
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
