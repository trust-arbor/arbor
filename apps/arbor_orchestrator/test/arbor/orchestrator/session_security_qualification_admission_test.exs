defmodule Arbor.Orchestrator.SessionSecurityQualificationAdmissionTest do
  @moduledoc """
  Admission integration only: synthetic EvalRun observations exercise the gate,
  not a claim that a model or deployment passed the security qualification suite.
  Real Session, signed capabilities, owner policy, SQL and macOS native identity
  remain in the path. The only evidence seam is the producer identity module.
  """
  use Arbor.Persistence.DatabaseCase, async: false

  alias Arbor.Common.ComputeRegistry
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.LLM.Adapter.ReqLLM, as: ReqLLMAdapter
  alias Arbor.LLM.Client
  alias Arbor.Orchestrator.Session
  alias Arbor.Orchestrator.Handlers.{LlmHandler, RoutingHandler}
  alias Arbor.Persistence
  alias Arbor.Security
  alias Arbor.Security.AuditJournalOwner
  alias Arbor.Trust

  @moduletag :database
  @moduletag :integration
  if :os.type() != {:unix, :darwin},
    do: @moduletag(skip: "positive qualification requires the macOS native containment backend")

  @checks ~w(hostile_export_journey audit_restart native_containment skill_revocation)
  @producer_digest "sha256:" <> String.duplicate("c", 64)

  defmodule EvidenceProducer do
    def security_qualification_producer_identity,
      do:
        {:ok,
         %{"kind" => "admission_test_fixture", "digest" => "sha256:" <> String.duplicate("c", 64)}}
  end

  setup context do
    for {key, value} <- [
          identity_verification: true,
          capability_signing_required: true,
          constraint_enforcement_enabled: true,
          delegation_chain_verification_enabled: true,
          egress_gate_enforcing: true,
          uri_registry_enforcement: true,
          invocation_audit_mode: :required,
          invocation_audit_sink: Arbor.Historian
        ],
        do: set_env(:arbor_security, key, value)

    set_env(:arbor_shell, :agent_authorizer, Arbor.Actions.Shell)
    set_env(:arbor_orchestrator, :security_qualification_producer, EvidenceProducer)
    set_env(:arbor_orchestrator, :preprocessor_enabled, false)
    set_env(:arbor_orchestrator, :private_conversation_memory, false)
    set_env(:arbor_llm, :tool_invocation_auditor, Arbor.Security)
    set_env(:arbor_trust, :policy_enforcer_enabled, true)
    set_env(:arbor_trust, :approval_guard_enabled, true)

    if Process.whereis(Arbor.Trust.Store) == nil, do: start_supervised!(Arbor.Trust.Store)

    if Process.whereis(Arbor.Trust.Manager) == nil do
      start_supervised!(
        {Arbor.Trust.Manager, circuit_breaker: false, decay: false, event_store: false}
      )
    end

    root =
      Path.join(
        System.tmp_dir!(),
        "qualification_admission_" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    :ok = File.mkdir(root)
    :ok = File.chmod(root, 0o700)
    dot_path = Path.join(root, "turn.dot")

    {compute_branch, compute_purpose} = optional_compute_branch(context)

    File.write!(dot_path, """
    digraph QualificationAdmission {
      start [shape=Mdiamond]
      echo [type="transform", transform="identity", source_key="session.input", output_key="session.response"]
      done [shape=Msquare]
      start -> echo -> done
      #{compute_branch}
    }
    """)

    on_exit(fn -> File.rm_rf!(root) end)
    journal_supervisor = durable_journal!(Path.join(root, "authority-journal"))

    endpoint = metadata_server!()
    set_env(:arbor_orchestrator, :lm_studio, base_url: endpoint <> "/v1")
    set_env(:arbor_llm, :lm_studio_base_url, endpoint <> "/v1")

    previous_client = Client.default_client()
    on_exit(fn -> Client.set_default_client(previous_client) end)

    Client.from_env(
      adapters: %{"lm_studio" => ReqLLMAdapter},
      discover_local: false,
      discover_acp: false
    )
    |> Client.set_default_client()

    {:ok, identity} = Security.generate_identity(name: "synthetic qualification admission")
    :ok = Security.register_identity(identity)

    {:ok, _} =
      Trust.ensure_trust_profile(identity.agent_id,
        baseline: :block,
        rules: %{"arbor://orchestrator/execute" => :allow}
      )

    {:ok, _} =
      Security.grant(principal: identity.agent_id, resource: "arbor://orchestrator/execute/**")

    on_exit(fn ->
      {:ok, caps} = Security.list_capabilities(identity.agent_id)
      for cap <- caps, do: Security.revoke(cap.id)
      Trust.delete_trust_profile(identity.agent_id)
      Security.deregister_identity(identity.agent_id)
    end)

    session_id = "qualification_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    session =
      start_supervised!(
        {Session,
         session_id: session_id,
         agent_id: identity.agent_id,
         turn_dot: dot_path,
         signer: fn resource ->
           SignedRequest.sign(resource, identity.agent_id, identity.private_key)
         end,
         config: %{
           "llm_provider" => "lmstudio",
           "llm_model" => "qualification-model",
           "llm_runtime" => "arbor",
           "llm_fallback_chain" => [],
           "tools" => [],
           "stream" => false,
           "preprocessor_enabled" => false,
           "recover_session" => false
         }}
      )

    # Public component assertions distinguish fixture prerequisites from a
    # profile/gate failure; none substitutes a caller-supplied profile.
    assert {:ok, %{"supported" => true}} = Arbor.Shell.agent_execution_identity()
    assert {:ok, _} = Trust.execution_policy_snapshot(identity.agent_id)
    assert {:ok, _} = Arbor.Memory.skill_version_manifest(identity.agent_id)
    policy = Security.execution_policy_snapshot()

    assert policy.identity_verification and policy.capability_signing and
             policy.constraint_enforcement

    assert policy.delegation_verification and policy.egress_enforcing and
             policy.uri_registry_enforcement

    assert policy.invocation_audit == :required
    assert {:ok, %{"durability" => "node_restart"}} = policy.audit_identity

    assert {:ok, %{"mode" => "durable", "durability" => "durable", "serving" => true}} =
             Security.audit_journal_status()

    assert {:ok, _} = Arbor.LLM.execution_provider_identity("lmstudio", "qualification-model")

    assert {:ok, %{"local_endpoint" => true}} =
             Arbor.LLM.stock_tool_transport_identity("lmstudio")

    assert {:ok, _} = Security.execution_capability_snapshot(identity.agent_id)

    descriptor_failures =
      for module <-
            Arbor.Orchestrator.ActionsExecutor.build_action_map() |> Map.values() |> Enum.uniq(),
          result = Arbor.Actions.runtime_descriptor(module),
          not match?({:ok, _}, result),
          do: {module, result}

    assert descriptor_failures == []

    assert {:ok, profile} = Session.security_qualification_profile(session)

    run_id = "qualification_run_" <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)

    assert {:ok, _} =
             Persistence.insert_eval_run(%{
               id: run_id,
               domain: "security_verify",
               model: "qualification-model",
               provider: "lmstudio",
               dataset: "admission-fixture-only",
               status: "completed",
               sample_count: 4,
               config_fingerprint: profile.fingerprint,
               metadata: %{
                 "qualification_schema" => "arbor.security.qualification.v1",
                 "live_model_status" => "safe_without_export",
                 "fixture_only" => true
               }
             })

    for kind <- @checks do
      observations = %{"fixture" => "admission-only", "kind" => kind}

      assert {:ok, _} =
               Persistence.insert_eval_result(%{
                 id: run_id <> "_" <> kind,
                 run_id: run_id,
                 sample_id: kind,
                 passed: true,
                 precondition_met: true,
                 actual: "synthetic admission evidence",
                 metadata: %{
                   "kind" => kind,
                   "profile_fingerprint" => profile.fingerprint,
                   "producer" => "source_owner",
                   "producer_digest" => @producer_digest,
                   "artifact_digest" => Persistence.eval_config_fingerprint(observations),
                   "observations" => observations
                 }
               })
    end

    set_env(:arbor_orchestrator, :security_qualification_profiles, %{
      identity.agent_id => %{turn: %{run_id: run_id}}
    })

    assert {:ok, prepared} = Session.prepare_security_qualification(session, run_id)
    assert prepared.profile.fingerprint == profile.fingerprint

    assert {:ok, cap} =
             Security.grant(principal: identity.agent_id, resource: prepared.approval_uri)

    assert {:ok, after_approval} = Session.security_qualification_profile(session)
    assert after_approval.fingerprint == profile.fingerprint

    %{
      session: session,
      agent_id: identity.agent_id,
      run_id: run_id,
      cap: cap,
      journal_supervisor: journal_supervisor,
      compute_purpose: compute_purpose,
      profile: profile,
      approval_uri: prepared.approval_uri
    }
  end

  test "real public Session admits exact signed qualification approval and completes a turn", c do
    assert {:ok, response} = Session.send_message(c.session, "qualified fixture response")
    assert response.content == "qualified fixture response"
    assert Session.get_state(c.session).turn_count == 1
    assert_receive {:qualification_metadata_request, "GET /api/v1/models HTTP/1.1"}
    refute_received {:qualification_unexpected_http, _}
  end

  test "an explicit Session preprocessing opt-out qualifies under an enabled host master", c do
    set_env(:arbor_orchestrator, :preprocessor_enabled, true)
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:arbor, :preprocessor, :run, :start],
        &__MODULE__.preprocessing_started/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, profile} = Session.security_qualification_profile(c.session)
    assert profile.fingerprint == c.profile.fingerprint
    assert {:ok, response} = Session.send_message(c.session, "qualified preprocessing opt-out")
    assert response.content == "qualified preprocessing opt-out"
    refute_received :qualification_preprocessing_started
    refute_received {:qualification_unexpected_http, _}
  end

  def preprocessing_started(_event, _measurements, _metadata, owner),
    do: send(owner, :qualification_preprocessing_started)

  test "security regression: revoking the exact approval refuses before the next turn", c do
    :ok = Security.revoke(c.cap.id)
    assert_refused_without_turn(c.session)
  end

  test "security regression: editing stored evidence invalidates an existing approval", c do
    assert {:ok, run} = Persistence.get_eval_run(c.run_id)

    assert {:ok, _} =
             Persistence.update_eval_run(
               c.run_id,
               %{metadata: Map.put(run.metadata, "operator_annotation", "changed after approval")}
             )

    assert {:ok, changed} = Session.prepare_security_qualification(c.session, c.run_id)
    refute changed.approval_uri == c.approval_uri
    assert_refused_without_turn(c.session)
  end

  test "security regression: actual public model configuration drift rejects old evidence", c do
    assert {:ok, "qualification-model-2"} = Session.set_model(c.session, "qualification-model-2")
    assert {:ok, changed} = Session.security_qualification_profile(c.session)
    refute changed.fingerprint == c.profile.fingerprint

    assert {:error, :security_qualification_required} =
             Session.prepare_security_qualification(c.session, c.run_id)

    assert_refused_without_turn(c.session)
  end

  for flag <- [:policy_enforcer_enabled, :approval_guard_enabled] do
    test "security regression: disabling Trust #{flag} invalidates qualification", c do
      set_env(:arbor_trust, unquote(flag), false)
      assert_refused_without_turn(c.session)
    end
  end

  test "security regression: widening current capabilities invalidates qualification", c do
    assert {:ok, _} =
             Security.grant(
               principal: c.agent_id,
               resource: "arbor://memory/read/#{c.agent_id}"
             )

    assert_refused_without_turn(c.session)
  end

  test "security regression: selected Trust policy implementation invalidates prepared evidence",
       c do
    before = Session.get_state(c.session)
    set_env(:arbor_trust, :policy_module, Arbor.Trust.ApprovalContext)

    assert {:error, :security_qualification_required} =
             Session.prepare_security_qualification(c.session, c.run_id)

    assert Session.get_state(c.session).turn_count == before.turn_count
    refute_received {:qualification_unexpected_http, _}
  end

  @tag compute_delegate: true
  test "security regression: selected compute delegate invalidates prepared evidence", c do
    assert {:ok, response} = Session.send_message(c.session, "the compute branch stays unused")
    assert response.content == "the compute branch stays unused"
    before = Session.get_state(c.session)
    assert {:ok, LlmHandler} = ComputeRegistry.resolve_stable(c.compute_purpose)
    :ok = ComputeRegistry.deregister(c.compute_purpose)
    :ok = ComputeRegistry.register(c.compute_purpose, RoutingHandler)
    assert {:ok, RoutingHandler} = ComputeRegistry.resolve_stable(c.compute_purpose)

    assert {:error, :security_qualification_required} =
             Session.prepare_security_qualification(c.session, c.run_id)

    assert Session.get_state(c.session).turn_count == before.turn_count
    refute_received {:qualification_unexpected_http, _}
  end

  test "security regression: replacing the durable authority journal with ephemeral invalidates qualification",
       c do
    :ok = Supervisor.terminate_child(c.journal_supervisor, AuditJournalOwner)
    :ok = Supervisor.delete_child(c.journal_supervisor, AuditJournalOwner)

    assert {:ok, _} =
             Supervisor.start_child(c.journal_supervisor, {AuditJournalOwner, mode: :ephemeral})

    assert {:ok, %{"mode" => "ephemeral", "serving" => true}} = Security.audit_journal_status()
    assert_refused_without_turn(c.session)
  end

  defp assert_refused_without_turn(session) do
    before = Session.get_state(session)

    assert {:error, :security_qualification_required} =
             Session.send_message(session, "must not start")

    after_refusal = Session.get_state(session)
    assert after_refusal.turn_count == before.turn_count
    assert after_refusal.messages == before.messages
    refute after_refusal.turn_in_flight
    refute_received {:qualification_unexpected_http, _}
  end

  defp set_env(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(app, key, old)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp optional_compute_branch(%{compute_delegate: true}) do
    if Process.whereis(ComputeRegistry) == nil, do: start_supervised!(ComputeRegistry)
    purpose = "qualification_" <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)
    :ok = ComputeRegistry.register(purpose, LlmHandler)

    on_exit(fn ->
      if Process.whereis(ComputeRegistry), do: ComputeRegistry.deregister(purpose)
    end)

    {"""
     dormant [type="compute", purpose="#{purpose}", use_tools="true"]
     echo -> dormant [condition="context.run_compute=true"]
     dormant -> done
     """, purpose}
  end

  defp optional_compute_branch(_context), do: {"", nil}

  # Test lifecycle only: suspend the helper-owned child without deleting its
  # original spec. The test owns a real journal supervisor and private files;
  # teardown restores the original child in its original supervision slot.
  defp durable_journal!(root) do
    :ok = File.mkdir(root)
    :ok = File.chmod(root, 0o700)
    :ok = Supervisor.terminate_child(Arbor.Security.Supervisor, AuditJournalOwner)

    {:ok, supervisor} =
      Supervisor.start_link([{AuditJournalOwner, mode: :durable, root: root}],
        strategy: :one_for_one
      )

    Process.unlink(supervisor)

    on_exit(fn ->
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
      {:ok, _} = Supervisor.restart_child(Arbor.Security.Supervisor, AuditJournalOwner)
    end)

    supervisor
  end

  defp metadata_server! do
    owner = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    pid = spawn_link(fn -> metadata_loop(listener, owner) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp metadata_loop(listener, owner) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
        line = hd(String.split(request, "\r\n"))

        {status, body} =
          if line == "GET /api/v1/models HTTP/1.1" do
            send(owner, {:qualification_metadata_request, line})

            {"200 OK",
             %{
               "models" => [
                 %{
                   "type" => "llm",
                   "key" => "synthetic/qualification-model",
                   "selected_variant" => "synthetic/qualification-model@fixture",
                   "loaded_instances" =>
                     for(
                       id <- ["qualification-model", "qualification-model-2"],
                       do: %{"id" => id, "config" => %{"context_length" => 8192}}
                     )
                 }
               ]
             }}
          else
            send(owner, {:qualification_unexpected_http, line})
            {"500 Unexpected Request", %{"error" => "metadata only; inference forbidden"}}
          end

        data = Jason.encode!(body)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 ",
            status,
            "\r\nContent-Type: application/json\r\nContent-Length: ",
            Integer.to_string(byte_size(data)),
            "\r\nConnection: close\r\n\r\n",
            data
          ])

        :gen_tcp.close(socket)
        metadata_loop(listener, owner)

      {:error, :closed} ->
        :ok
    end
  end
end
