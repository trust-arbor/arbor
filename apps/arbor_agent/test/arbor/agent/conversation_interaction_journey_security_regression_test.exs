Code.require_file(
  Path.expand("../../../../arbor_security/test/support/approval_answer_fixture.ex", __DIR__)
)

defmodule Arbor.Agent.ConversationInteractionJourneySecurityRegressionTest do
  use ExUnit.Case, async: false

  defmodule AuditRepo do
    use Ecto.Repo, otp_app: :arbor_agent, adapter: Ecto.Adapters.SQLite3
  end

  alias Arbor.Agent.SessionManager
  alias Arbor.Contracts.Security.{Identity, SignedRequest}
  alias Arbor.Orchestrator.Session
  alias Arbor.Persistence.Repo
  alias Arbor.Security
  alias Arbor.Security.TestSupport.ApprovalAnswerFixture, as: Humans
  @moduletag :integration
  @moduletag :database
  @moduletag :isolated_repo
  @migrations Path.expand("../../../../arbor_persistence/priv/repo/migrations", __DIR__)

  @native_action Arbor.Actions.ConversationJourney.Counted
  @native_source """
  defmodule Arbor.Actions.ConversationJourney.Counted do
    use Jido.Action,
      name: "conversation_journey_counted",
      description: "Count a harmless native invocation in the approval journey",
      schema: []
    def taint_roles, do: %{}
    @impl true
    def run(_params, context) do
      send(Application.fetch_env!(:arbor_agent, :conversation_journey_observer),
        {:native_invoked, Map.has_key?(context, :conversation_source)})
      {:ok, %{done: true}}
    end
  end
  """
  @native_dot """
  digraph RealConversationNativeApproval {
    start [shape=Mdiamond]
    effect [type=exec, target=action, action="conversation_journey.counted", max_retries=0, output_prefix=native]
    response [type=transform, transform=constant, expression="Native action approved once", output_key="session.response"]
    exit [shape=Msquare]
    start -> effect -> response -> exit
  }
  """

  @dot """
  digraph RealConversationChoice {
    start [shape=Mdiamond]
    gate [shape=hexagon, label="Choose the actual destination", human.timeout_seconds=30, fan_out="false"]
    first [type=transform, transform=constant, expression="First destination", output_key="session.response"]
    second [type=transform, transform=constant, expression="Second destination", output_key="session.response"]
    exit [shape=Msquare]
    start -> gate
    gate -> first [label="Same destination label"]
    gate -> second [label="Same destination label"]
    first -> exit
    second -> exit
  }
  """

  setup_all do
    assert Process.whereis(Repo) == nil, "Run this journey alone with --include isolated_repo."

    root =
      Path.join(
        System.tmp_dir!(),
        "conversation-interaction-journey-" <>
          Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir_p!(root)
    # The actual Actions boundary pins retrievable loaded BEAM bytes, so this
    # plugin fixture is compiled once and given a private code-path artifact.
    beam_dir = Path.join(root, "native-action")
    File.mkdir_p!(beam_dir)
    [{@native_action, beam}] = Code.compile_string(@native_source)
    File.write!(Path.join(beam_dir, "#{@native_action}.beam"), beam)
    true = :code.add_patha(String.to_charlist(beam_dir))

    if Process.whereis(Arbor.Common.ActionRegistry) == nil,
      do: start_supervised!(Arbor.Common.ActionRegistry)

    :ok = Arbor.Common.ActionRegistry.register_action(@native_action, %{category: :test_plugin})

    on_exit(fn ->
      if Process.whereis(Arbor.Common.ActionRegistry) do
        Arbor.Common.ActionRegistry.deregister("conversation_journey.counted")
        Arbor.Common.ActionRegistry.deregister("conversation_journey_counted")
      end

      :code.del_path(String.to_charlist(beam_dir))
      :code.purge(@native_action)
      :code.delete(@native_action)
    end)

    start_supervised!(
      {Repo,
       database: Path.join(root, "conversation.sqlite3"),
       pool: DBConnection.ConnectionPool,
       pool_size: 1,
       busy_timeout: 5_000,
       journal_mode: :wal}
    )

    Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)
    # Keep real durable Security audit effects, with a private database separate
    # from the command journal. One connection per private database qualifies
    # serialized behavior; public polling is not a write-load/availability test.
    start_supervised!(
      {AuditRepo,
       database: Path.join(root, "security-audit.sqlite3"),
       pool: DBConnection.ConnectionPool,
       pool_size: 1,
       busy_timeout: 5_000,
       journal_mode: :wal}
    )

    Ecto.Migrator.run(AuditRepo, @migrations, :up, all: true, log: false)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  setup %{root: root} = tags do
    for {app, key, value} <- [
          {:arbor_security, :identity_verification, true},
          {:arbor_security, :capability_signing_required, true},
          {:arbor_security, :policy_enforcer_enabled, false},
          {:arbor_security, :approval_guard_enabled, false},
          {:arbor_security, :reflex_checking_enabled, false},
          {:arbor_security, :uri_registry_enforcement, false},
          {:arbor_security, :use_interaction_router_for_approval, true},
          {:arbor_security, :identity_alias_resolver,
           Arbor.Security.OIDCTestHelper.UnlinkedIdentityResolver},
          {:arbor_trust, :policy_enforcer_enabled, false},
          {:arbor_trust, :approval_guard_enabled, true},
          {:arbor_orchestrator, :private_conversation_memory, false},
          {:arbor_orchestrator, :preprocessor_enabled, false},
          {:arbor_comms, :conversation_journal,
           [
             backend: Arbor.Persistence.EventLog.Ecto,
             name: :conversation_interaction_journal,
             opts: [repo: Repo]
           ]},
          {:arbor_comms, :durable_interaction_store,
           [
             backend: Arbor.Security.Store.JSONFile,
             namespace: :journey_interactions,
             opts: [base_dir: root]
           ]},
          {:arbor_historian, :durable_event_log_target,
           %{
             name: :conversation_journey_audit,
             backend: Arbor.Persistence.EventLog.Ecto,
             opts: [repo: AuditRepo]
           }},
          {:arbor_comms, :interaction_adapters, %{}}
        ],
        do: set_env(app, key, value)

    restart_authority()
    on_exit(&restart_authority/0)
    Humans.setup!()
    oidc = Arbor.Security.OIDCTestHelper.issue_identity()
    :ok = Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)
    {:ok, token} = Arbor.Security.SessionToken.generate(oidc.identity.agent_id)
    human = %{human_id: oidc.identity.agent_id, token: token, identity: oidc.identity}

    on_exit(fn ->
      Security.deregister_identity_fixture(human.human_id)
      oidc.cleanup.()
    end)

    {:ok, identity} = Identity.generate(name: "Real interaction Engine owner")
    :ok = Security.register_identity_fixture(Identity.public_only(identity))
    on_exit(fn -> Security.deregister_identity_fixture(identity.agent_id) end)
    Humans.grant!(human.human_id, "arbor://chat/agent/" <> identity.agent_id)

    for uri <- [
          "arbor://orchestrator/execute",
          "arbor://orchestrator/execute/human_interaction",
          "arbor://orchestrator/execute/transform",
          "arbor://orchestrator/execute/unknown",
          "arbor://orchestrator/execute/action",
          "arbor://orchestrator/execute/compose",
          "arbor://action/pipeline/run",
          "arbor://memory/read/" <> identity.agent_id,
          "arbor://memory/write/" <> identity.agent_id
        ],
        do: Humans.grant!(identity.agent_id, uri)

    if tags[:native_approval] do
      set_env(:arbor_agent, :conversation_journey_observer, self())

      Humans.grant!(identity.agent_id, Arbor.Actions.canonical_uri_for(@native_action, %{}),
        constraints: %{requires_approval: true}
      )
    end

    dot_source =
      cond do
        tags[:native_approval] ->
          @native_dot

        tags[:nested_choice] ->
          """
          digraph ParentConversationChoice {
            start [shape=Mdiamond]
            child [type=compose, mode=invoke, graph_source_key="session.input"]
            exit [shape=Msquare]
            start -> child -> exit
          }
          """

        true ->
          @dot
      end

    path = Path.join(root, identity.agent_id <> ".dot")
    File.write!(path, dot_source)

    {:ok, session} =
      Session.start_link(
        session_id: "agent-session-" <> identity.agent_id,
        agent_id: identity.agent_id,
        turn_dot: path,
        start_heartbeat: false,
        signer: fn resource ->
          SignedRequest.sign(resource, identity.agent_id, identity.private_key)
        end,
        config: %{"recover_session" => false, "tools" => []}
      )

    :ok =
      Arbor.Agent.Registry.register(identity.agent_id, session, %{
        runtime: :arbor,
        model_config: %{runtime: :arbor},
        host_pid: session,
        module: Session,
        agent_id: identity.agent_id
      })

    :sys.replace_state(SessionManager, fn state ->
      :ets.insert(SessionManager, {identity.agent_id, session})
      state
    end)

    on_exit(fn ->
      if Process.alive?(session), do: GenServer.stop(session)
      Arbor.Agent.Registry.unregister(identity.agent_id)

      :sys.replace_state(SessionManager, fn state ->
        :ets.delete(SessionManager, identity.agent_id)
        state
      end)
    end)

    {:ok, engagement} = Arbor.Comms.resolve_user_engagement(identity.agent_id, human.human_id)
    %{human: human, target: identity.agent_id, session: session, engagement: engagement.id}
  end

  test "security regression: actual Agent command reaches Engine human gate and resumes its exact second choice",
       c do
    assert {:ok, _} =
             Arbor.Agent.submit_conversation_command(
               c.human.human_id,
               c.target,
               %{id: "choose-second", text: "Run the real source gate"},
               session_token: c.human.token,
               timeout: 10_000
             )

    prompt = pending_prompt!(c, "choose-second")
    assert prompt.kind == "choice"

    assert prompt.choices == [
             %{id: "choice_1", label: "Same destination label"},
             %{id: "choice_2", label: "Same destination label"}
           ]

    operation = %{
      command_id: "choose-second",
      request_id: prompt.request_id,
      operation_id: prompt.operation_id,
      revision: 1,
      choice_id: "choice_2"
    }

    assert {:error, _} =
             Arbor.Agent.answer_conversation_choice(
               c.human.human_id,
               c.target,
               %{operation | revision: 2},
               session_token: c.human.token
             )

    assert pending_prompt!(c, "choose-second").status == :pending

    {:ok, payload} =
      Arbor.Agent.conversation_interaction_request_payload(
        :interaction_choice,
        c.human.human_id,
        c.target,
        operation,
        c.engagement
      )

    {:ok, proof} = SignedRequest.sign(payload, c.human.human_id, c.human.identity.private_key)

    assert {:error, _} =
             Arbor.Agent.answer_conversation_choice(
               c.human.human_id,
               c.target,
               %{operation | choice_id: "choice_1"},
               signed_request: proof,
               expected_engagement_id: c.engagement
             )

    assert {:ok, answer} =
             Arbor.Agent.answer_conversation_choice(c.human.human_id, c.target, operation,
               signed_request: proof,
               expected_engagement_id: c.engagement
             )

    assert answer == %{
             status: :responded,
             request_id: prompt.request_id,
             operation_id: prompt.operation_id,
             revision: 1,
             command_id: "choose-second",
             engagement_id: c.engagement
           }

    command = completed!(c, "choose-second")
    assert command.outcome.text == "Second destination"
    refute inspect(command) =~ "claim_token"

    assert {:error, _} =
             Arbor.Agent.answer_conversation_choice(
               c.human.human_id,
               c.target,
               %{operation | choice_id: "choice_1"},
               session_token: c.human.token
             )

    state = Session.get_state(c.session)
    assert state.conversation_source == nil
  end

  test "security regression: cancellation retires an actual waiting Engine source before another generation starts",
       c do
    assert {:ok, _} =
             Arbor.Agent.submit_conversation_command(
               c.human.human_id,
               c.target,
               %{id: "cancel-choice", text: "Wait for an answer"},
               session_token: c.human.token,
               timeout: 10_000
             )

    prompt = pending_prompt!(c, "cancel-choice")

    operation = %{
      command_id: "cancel-choice",
      request_id: prompt.request_id,
      operation_id: prompt.operation_id,
      revision: 1,
      choice_id: "choice_1"
    }

    assert {:ok, %{termination_observation: :confirmed}} =
             Arbor.Agent.cancel_conversation_command(c.human.human_id, c.target, "cancel-choice",
               session_token: c.human.token
             )

    assert {:error, _} =
             Arbor.Agent.answer_conversation_choice(c.human.human_id, c.target, operation,
               session_token: c.human.token
             )

    assert {:ok, _} =
             Arbor.Agent.submit_conversation_command(
               c.human.human_id,
               c.target,
               %{id: "fresh-choice", text: "A new exact generation"},
               session_token: c.human.token,
               timeout: 10_000
             )

    fresh = pending_prompt!(c, "fresh-choice")
    refute fresh.operation_id == prompt.operation_id

    assert {:error, _} =
             Arbor.Agent.answer_conversation_choice(
               c.human.human_id,
               c.target,
               %{operation | command_id: "fresh-choice"},
               session_token: c.human.token
             )

    assert {:ok, _} =
             Arbor.Agent.answer_conversation_choice(
               c.human.human_id,
               c.target,
               %{
                 command_id: "fresh-choice",
                 request_id: fresh.request_id,
                 operation_id: fresh.operation_id,
                 revision: 1,
                 choice_id: "choice_1"
               },
               session_token: c.human.token
             )

    assert completed!(c, "fresh-choice").outcome.text == "First destination"
  end

  @tag native_approval: true
  test "security regression: actual native Exec requires a source-bound general-human approval before one action invocation",
       c do
    assert {:ok, _} =
             Arbor.Agent.submit_conversation_command(
               c.human.human_id,
               c.target,
               %{id: "native-once", text: "Run the protected native effect"},
               session_token: c.human.token,
               timeout: 10_000
             )

    prompt = pending_prompt!(c, "native-once")
    assert prompt.kind == "approval"
    refute_receive {:native_invoked, _}, 20

    operation = %{
      command_id: "native-once",
      request_id: prompt.request_id,
      operation_id: prompt.operation_id,
      revision: 1,
      decision: "approve",
      note: nil
    }

    assert {:error, :scoped_answer_required} =
             Arbor.Comms.respond_to_interaction(prompt.request_id, :approved)

    assert {:error, :approval_answer_required} =
             Arbor.Agent.answer_conversation_approval(
               c.human.human_id,
               c.target,
               operation,
               session_token: c.human.token
             )

    assert pending_prompt!(c, "native-once").status == :pending
    Humans.grant!(c.human.human_id, "arbor://approval/answer/" <> c.target)

    {:ok, chat_token} =
      Arbor.Security.issue_conversation_session_fixture(c.human.human_id, c.target)

    assert {:error, :approval_answer_required} =
             Arbor.Agent.answer_conversation_approval(
               c.human.human_id,
               c.target,
               operation,
               session_token: chat_token
             )

    refute_receive {:native_invoked, _}, 20

    assert {:ok, answer} =
             Arbor.Agent.answer_conversation_approval(
               c.human.human_id,
               c.target,
               operation,
               session_token: c.human.token
             )

    assert answer == %{
             status: :responded,
             request_id: prompt.request_id,
             operation_id: prompt.operation_id,
             revision: 1,
             command_id: "native-once",
             engagement_id: c.engagement
           }

    assert_receive {:native_invoked, false}, 2_000
    assert completed!(c, "native-once").outcome.text == "Native action approved once"

    assert {:error, _} =
             Arbor.Agent.answer_conversation_approval(
               c.human.human_id,
               c.target,
               operation,
               session_token: c.human.token
             )

    refute_receive {:native_invoked, _}, 20
    assert Session.get_state(c.session).conversation_source == nil
  end

  @tag nested_choice: true
  test "security regression: child graph human choice retains its parent command and cancellation retires its prompt",
       c do
    assert {:ok, _} =
             Arbor.Agent.submit_conversation_command(
               c.human.human_id,
               c.target,
               %{id: "nested-choice", text: @dot},
               session_token: c.human.token,
               timeout: 10_000
             )

    prompt = pending_prompt!(c, "nested-choice")
    assert prompt.kind == "choice"

    operation = %{
      command_id: "nested-choice",
      request_id: prompt.request_id,
      operation_id: prompt.operation_id,
      revision: 1,
      choice_id: "choice_1"
    }

    assert {:ok, %{termination_observation: :confirmed}} =
             Arbor.Agent.cancel_conversation_command(c.human.human_id, c.target, "nested-choice",
               session_token: c.human.token
             )

    assert {:error, _} =
             Arbor.Agent.answer_conversation_choice(c.human.human_id, c.target, operation,
               session_token: c.human.token
             )

    assert Session.get_state(c.session).conversation_source == nil
  end

  for {label, native?} <- [{"ordinary", false}, {"native", true}] do
    @tag native_approval: native?
    test "security regression: unavailable source Authority prevents the #{label} Engine turn",
         c do
      name = Module.concat([Arbor, Comms, InteractionRegistry, Authority])
      authority = Process.whereis(name)
      assert is_pid(authority)
      assert Process.unregister(name)

      try do
        assert {:ok, _} =
                 Arbor.Agent.submit_conversation_command(
                   c.human.human_id,
                   c.target,
                   %{id: "source-unavailable", text: "The bound source must refuse this turn"},
                   session_token: c.human.token,
                   timeout: 10_000
                 )

        command = uncertain!(c, "source-unavailable")
        assert command.outcome == %{status: :uncertain, reason: :delivery_unknown}
        assert Session.get_state(c.session).phase == :idle
        assert Session.get_state(c.session).conversation_source == nil
        refute_receive {:native_invoked, _}, 20
      after
        assert Process.register(authority, name)
      end

      assert {:ok, %{interactions: []}} =
               Arbor.Agent.conversation_interactions(
                 c.human.human_id,
                 c.target,
                 "source-unavailable",
                 session_token: c.human.token
               )
    end
  end

  defp uncertain!(c, command, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    case Arbor.Agent.conversation_command(c.human.human_id, c.target, command,
           session_token: c.human.token
         ) do
      {:ok, %{status: :uncertain} = result} ->
        result

      _ ->
        pause_until_deadline!(deadline, "source outage did not settle the actual command")
        uncertain!(c, command, deadline)
    end
  end

  defp pending_prompt!(c, command, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    case Arbor.Agent.conversation_interactions(c.human.human_id, c.target, command,
           session_token: c.human.token
         ) do
      {:ok, %{interactions: [%{status: :pending} = prompt | _]} = envelope} ->
        assert envelope.engagement_id == c.engagement
        assert envelope.command_id == command
        prompt

      {:ok, %{interactions: []} = envelope} ->
        assert envelope.engagement_id == c.engagement
        assert envelope.command_id == command
        retry_pending_prompt!(c, command, deadline)

      _ ->
        retry_pending_prompt!(c, command, deadline)
    end
  end

  defp retry_pending_prompt!(c, command, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      result =
        Arbor.Agent.conversation_command(c.human.human_id, c.target, command,
          session_token: c.human.token
        )

      state = Session.get_state(c.session)

      flunk(
        "actual Engine source prompt did not appear; command=#{inspect(result)}; source_open=#{is_tuple(state.conversation_source)}; phase=#{inspect(state.phase)}"
      )
    end

    Process.sleep(50)
    pending_prompt!(c, command, deadline)
  end

  defp completed!(c, command, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    case Arbor.Agent.conversation_command(c.human.human_id, c.target, command,
           session_token: c.human.token
         ) do
      {:ok, %{status: :completed} = result} ->
        result

      _ ->
        pause_until_deadline!(deadline, "actual Engine command did not complete")
        completed!(c, command, deadline)
    end
  end

  defp pause_until_deadline!(deadline, message) do
    if System.monotonic_time(:millisecond) >= deadline, do: flunk(message)
    Process.sleep(50)
  end

  defp set_env(app, key, value) do
    old = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp restart_authority do
    :ok = Supervisor.terminate_child(Arbor.Comms.Supervisor, Arbor.Comms.InteractionRegistry)
    {:ok, _} = Supervisor.restart_child(Arbor.Comms.Supervisor, Arbor.Comms.InteractionRegistry)
  end
end
