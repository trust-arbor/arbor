Code.require_file(
  Path.expand("../../../../arbor_security/test/support/oidc_test_helper.ex", __DIR__)
)

defmodule Arbor.Agent.ConversationEntrypointJourneyTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.{IdentityAliases, IdentityAliasProof, SessionManager}
  alias Arbor.Contracts.Security.{Identity, SignedRequest}
  alias Arbor.Dashboard.Live.ConversationLive.Surface
  alias Arbor.Gateway.Chat.Socket, as: GatewaySocket
  alias Arbor.Orchestrator.Session
  alias Arbor.Persistence.Repo
  alias Arbor.Security
  alias Arbor.Security.{OIDCTestHelper, SessionToken}

  @moduletag :integration
  @moduletag :database
  @moduletag :isolated_repo
  @moduletag :conversation_convergence
  @turn_dot Path.expand(
              "../../../../arbor_orchestrator/specs/pipelines/session/turn.dot",
              __DIR__
            )
  @migrations Path.expand("../../../../arbor_persistence/priv/repo/migrations", __DIR__)

  defmodule CaptureProvider do
    def provider, do: "lm_studio"
    def runtime_contract, do: %Arbor.Contracts.AI.RuntimeContract{}

    def complete(request, opts) do
      observer = Application.fetch_env!(:arbor_orchestrator, :conversation_journey_observer)
      send(observer, {:actual_model_request, request.messages, opts})

      if List.last(request.messages).content == "binding blocker" do
        send(observer, {:binding_model_blocked, self()})

        receive do
          :release_binding_model -> :ok
        after
          10_000 -> raise "execution binding model barrier was not released"
        end
      end

      {:ok,
       %Arbor.LLM.Response{
         text: "Conversation received.",
         finish_reason: :stop,
         content_parts: [Arbor.LLM.ContentPart.text("Conversation received.")],
         usage: %{input_tokens: 3, output_tokens: 2, total_tokens: 5},
         raw: %{}
       }}
    end

    def complete_single_attempt(request, opts), do: complete(request, opts)

    def complete_streaming(request, callback, opts) do
      callback.(%Arbor.LLM.StreamEvent{type: :delta, data: %{text: "Live prefix 👋"}})
      complete(request, opts)
    end

    def complete_streaming_single_attempt(request, callback, opts),
      do: complete_streaming(request, callback, opts)
  end

  defmodule ActivityStorage do
    alias Arbor.Persistence.EventLog.Ecto, as: Backend
    defdelegate durability_class(opts), to: Backend
    defdelegate append(stream, events, opts), to: Backend
    defdelegate reconcile_append(operation, opts), to: Backend
    defdelegate read_stream_head(stream, opts), to: Backend
    defdelegate read_event_records(stream, ids, opts), to: Backend

    def read_stream_range(stream, opts) do
      if observer = Application.get_env(:arbor_orchestrator, :conversation_activity_read_observer),
        do: send(observer, {:activity_range_read, self(), Keyword.get(opts, :limit)})

      Backend.read_stream_range(stream, opts)
    end
  end

  setup_all do
    assert Process.whereis(Repo) == nil, "Run this journey alone with --include isolated_repo."

    root =
      Path.join(System.tmp_dir!(), "entrypoint-journey-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    database = Path.join(root, "conversation.sqlite3")

    start_supervised!(
      {Repo,
       database: database,
       pool: DBConnection.ConnectionPool,
       pool_size: 4,
       busy_timeout: 5_000,
       journal_mode: :wal}
    )

    assert [_ | _] = Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)

    # Real turns create authority mutations at each gated pipeline boundary.
    # Own the production consumer as well as its private SQL target; leaving
    # effect_applied records undelivered eventually refuses otherwise valid
    # turns. Legacy security:events observation remains a separate fixture.
    set_env(:arbor_historian, :durable_event_log_target, %{
      name: :historian_durable_event_log,
      backend: Arbor.Persistence.EventLog.Ecto,
      opts: [repo: Repo]
    })

    set_env(:arbor_security, :authority_audit_consumer_name, Arbor.Historian.AuthorityAuditPuller)
    set_env(:arbor_security, :authority_audit_consumer_application, :arbor_historian)

    assert Process.whereis(Arbor.Historian.AuthorityAuditPuller) == nil,
           "Run this journey alone with its own authority audit consumer."

    # The consumer gate admits only the Historian application's child. An
    # ExUnit-supervised puller is registered, then flush returns
    # :audit_source_unavailable.
    start_authority_audit_puller!()

    for {name, child} <- [
          {Arbor.Orchestrator.EventRegistry,
           {Registry, keys: :duplicate, name: Arbor.Orchestrator.EventRegistry}},
          {Arbor.Comms.EngagementStore, Arbor.Comms.EngagementStore},
          {Arbor.Comms.ConversationActivity, Arbor.Comms.ConversationActivity},
          {Arbor.Agent.Orchestration.TaskSupervisor,
           {Task.Supervisor, name: Arbor.Agent.Orchestration.TaskSupervisor}},
          {:arbor_user_config,
           {Arbor.Persistence.BufferedStore,
            name: :arbor_user_config,
            backend: Arbor.Security.Store.JSONFile,
            write_mode: :sync,
            ack_mode: :backend,
            backend_opts: [base_dir: Path.join(root, "aliases")],
            collection: "entrypoint_aliases"}}
        ] do
      if Process.whereis(name) == nil,
        do: start_supervised!(Supervisor.child_spec(child, id: name))
    end

    {:ok, database: database}
  end

  setup context do
    for {app, key, value} <- [
          {:arbor_security, :identity_verification, true},
          {:arbor_security, :capability_signing_required, true},
          {:arbor_security, :strict_identity_mode, false},
          {:arbor_security, :policy_enforcer_enabled, false},
          {:arbor_security, :approval_guard_enabled, false},
          {:arbor_security, :reflex_checking_enabled, false},
          {:arbor_security, :uri_registry_enforcement, false},
          {:arbor_security, :identity_alias_resolver, Arbor.Agent.IdentityAliasResolver},
          {:arbor_security, :session_token_secret, :crypto.strong_rand_bytes(32)},
          {:arbor_trust, :policy_enforcer_enabled, false},
          {:arbor_trust, :approval_guard_enabled, false},
          {:arbor_orchestrator, :private_conversation_memory, false},
          {:arbor_orchestrator, :preprocessor_enabled, false},
          {:arbor_orchestrator, :conversation_journey_observer, self()},
          {:arbor_dashboard, :conversation_api, Arbor.Agent},
          {:arbor_gateway, :chat_agent_facade, Arbor.Agent},
          {:arbor_comms, :conversation_journal,
           [
             backend: Arbor.Persistence.EventLog.Ecto,
             name: :conversation_journal,
             opts: [repo: Repo]
           ]}
        ],
        do: set_env(app, key, value)

    previous = Arbor.LLM.Client.default_client()

    client =
      Arbor.LLM.Client.new(default_provider: "lm_studio")
      |> Arbor.LLM.Client.register_adapter(CaptureProvider)

    Arbor.LLM.Client.set_default_client(client)
    on_exit(fn -> Arbor.LLM.Client.set_default_client(previous) end)

    primary = human!()
    secondary = human!()
    {:ok, agent} = Identity.generate(name: "Real entrypoint convergence journey")
    :ok = Security.register_identity_fixture(Identity.public_only(agent))
    on_exit(fn -> Security.deregister_identity_fixture(agent.agent_id) end)
    resource = "arbor://chat/agent/" <> agent.agent_id
    primary_cap = grant!(primary.agent_id, resource)
    {:ok, %{operation_id: primary_audit_id}} = Security.capability_mutation_audit_status()
    secondary_cap = grant!(secondary.agent_id, resource)
    grant!(primary.agent_id, "arbor://identity/alias/manage")

    for uri <- [
          "arbor://orchestrator/execute",
          "arbor://orchestrator/execute/llm_query",
          "arbor://orchestrator/execute/transform",
          "arbor://orchestrator/execute/unknown",
          "arbor://memory/read/" <> agent.agent_id,
          "arbor://memory/write/" <> agent.agent_id
        ],
        do: grant!(agent.agent_id, uri)

    link!(primary, secondary)
    on_exit(fn -> unlink(primary, secondary) end)
    {:ok, token} = SessionToken.generate(primary.agent_id)

    {:ok, counter} = Agent.start_link(fn -> 0 end)
    observer = self()

    append = fn session_id, entries ->
      Agent.update(counter, &(&1 + 1))

      if inspect(entries) =~ "disconnect barrier" do
        send(observer, {:at_transcript_commit, self()})

        receive do
          :release_commit -> :ok
        after
          10_000 -> raise "journey commit barrier not released"
        end
      end

      Arbor.Persistence.append_session_entries(session_id, entries)
    end

    session_id = "agent-session-" <> agent.agent_id

    {:ok, session} =
      Session.start_link(
        session_id: session_id,
        agent_id: agent.agent_id,
        turn_dot: @turn_dot,
        start_heartbeat: false,
        signer: fn resource -> SignedRequest.sign(resource, agent.agent_id, agent.private_key) end,
        adapters: %{append_session_entries: append},
        config: %{
          "llm_provider" => "lm_studio",
          "llm_model" => "convergence-response",
          "stream" => Map.get(context, :activity_stream, false),
          "recover_session" => false,
          "tools" => []
        }
      )

    :ok =
      Arbor.Agent.Registry.register(agent.agent_id, session, %{
        runtime: :arbor,
        model_config: %{runtime: :arbor},
        host_pid: session,
        module: Session,
        agent_id: agent.agent_id
      })

    :sys.replace_state(SessionManager, fn state ->
      true = :ets.insert(SessionManager, {agent.agent_id, session})
      state
    end)

    on_exit(fn ->
      if Process.alive?(session), do: GenServer.stop(session)
      Arbor.Agent.Registry.unregister(agent.agent_id)

      :sys.replace_state(SessionManager, fn state ->
        :ets.delete(SessionManager, agent.agent_id)
        state
      end)
    end)

    {:ok,
     primary: primary,
     secondary: secondary,
     target: agent.agent_id,
     token: token,
     session: session,
     session_id: session_id,
     counter: counter,
     primary_cap: primary_cap,
     primary_audit_id: primary_audit_id,
     secondary_cap: secondary_cap}
  end

  @tag local_commands: true
  test "security regression: authenticated slash input admits no journal command or provider turn",
       c do
    for {text, index} <-
          Enum.with_index(["/model anything", "  /model anything", "\n\t/unknown", "/help", "/"]) do
      id = "slash-refused-#{index}"

      assert {:error, :invalid_command} =
               Arbor.Agent.submit_conversation_command(
                 c.primary.agent_id,
                 c.target,
                 %{id: id, text: text},
                 session_token: c.token
               )

      assert {:error, :not_found} =
               Arbor.Agent.conversation_command(c.primary.agent_id, c.target, id,
                 session_token: c.token
               )
    end

    assert {:ok, %{events: []}} =
             Arbor.Agent.conversation_events(c.primary.agent_id, c.target, 0,
               session_token: c.token
             )

    refute_receive {:actual_model_request, _, _}, 100
    assert Agent.get(c.counter, & &1) == 0

    text = "  café 東京\nsecond line  "

    assert {:ok, _} =
             Arbor.Agent.submit_conversation_command(
               c.primary.agent_id,
               c.target,
               %{id: "ordinary-after-slash", text: text},
               session_token: c.token
             )

    assert %{status: :completed, text: ^text} = completed!(c, "ordinary-after-slash")
    assert_receive {:actual_model_request, _, _}, 5_000
    assert Agent.get(c.counter, & &1) == 1

    assert {:ok, history} =
             Arbor.Agent.conversation_window(c.primary.agent_id, c.target, session_token: c.token)

    assert Enum.any?(history.entries, &(&1.role == "user" and &1.content == text))
  end

  test "security regression: unavailable private conversation source refuses the actual Agent Session before provider execution",
       c do
    authority = Arbor.Comms.InteractionRegistry.Authority
    authority_pid = Process.whereis(authority)
    assert is_pid(authority_pid)
    true = Process.unregister(authority)

    on_exit(fn ->
      if Process.alive?(authority_pid) and is_nil(Process.whereis(authority)),
        do: Process.register(authority_pid, authority)
    end)

    assert {:ok, _} =
             Arbor.Agent.submit_conversation_command(
               c.primary.agent_id,
               c.target,
               %{id: "source-unavailable", text: "must never reach the provider"},
               session_token: c.token
             )

    assert %{status: :uncertain, outcome: %{reason: :delivery_unknown}} =
             terminal_command!(c, "source-unavailable")

    refute_receive {:actual_model_request, _, _}, 100
    assert Agent.get(c.counter, & &1) == 0
    state = :sys.get_state(c.session)
    assert state.phase == :idle
    refute state.turn_in_flight
    assert state.turn_task_pid == nil
    assert state.conversation_source == nil
    assert state.turn_egress_fence == nil
    assert map_size(state.conversation_bindings) == 0

    true = Process.register(authority_pid, authority)

    assert {:ok, %{interactions: []}} =
             Arbor.Agent.conversation_interactions(
               c.primary.agent_id,
               c.target,
               "source-unavailable",
               session_token: c.token
             )

    assert {:ok, _} =
             Arbor.Agent.submit_conversation_command(
               c.primary.agent_id,
               c.target,
               %{id: "source-restored", text: "provider runs after source restoration"},
               session_token: c.token
             )

    assert %{status: :completed} = completed!(c, "source-restored")
    assert_receive {:actual_model_request, _, _}, 5_000
    assert Agent.get(c.counter, & &1) == 1
  end

  @tag activity_stream: true
  test "security regression: authenticated cumulative activity and exact queued/active cancellation use the real Session generation",
       c do
    assert :ok = Session.cancel_task(c.session, "legacy-missing-task")

    assert {:error, :not_found} =
             Arbor.Agent.cancel_conversation_command(
               c.primary.agent_id,
               c.target,
               "legacy-missing-task",
               session_token: c.token
             )

    assert {:ok, _} =
             Arbor.Agent.submit_conversation_command(
               c.primary.agent_id,
               c.target,
               %{id: "active-cancel", text: "binding blocker"},
               session_token: c.token,
               timeout: 5_000
             )

    assert_receive {:binding_model_blocked, worker}, 5_000
    assert_receive {:actual_model_request, _, provider_opts}, 5_000
    refute Keyword.has_key?(provider_opts, :conversation_source)
    active = activity_command!(c, "active-cancel")
    assert active.execution == :running
    assert active.preview == "Live prefix 👋"
    assert active.progress == %{type: :stage_started, node_id: "call_llm"}
    refute inspect(active) =~ "claim_token"
    assert Session.get_state(c.session).conversation_source == nil
    assert Session.get_state(c.session).conversation_bindings == %{}

    for {id, text} <- [
          {"queued-cancel", "must never execute"},
          {"fifo-survivor", "surviving FIFO command"}
        ] do
      assert {:ok, _} =
               Arbor.Agent.submit_conversation_command(
                 c.primary.agent_id,
                 c.target,
                 %{id: id, text: text},
                 session_token: c.token,
                 timeout: 5_000
               )
    end

    wait_for_queue!(c.session, 2)

    assert {:ok,
            %{
              cancellation: %{status: :confirmed, termination: :queued_removed},
              termination_observation: :confirmed
            }} =
             Arbor.Agent.cancel_conversation_command(
               c.primary.agent_id,
               c.target,
               "queued-cancel",
               session_token: c.token
             )

    queued = wait_for_queue!(c.session)
    [{message, _, _}] = queued.turn_queue
    assert message.content == "surviving FIFO command"
    assert Process.alive?(worker)
    monitor = Process.monitor(worker)

    assert {:ok,
            %{
              cancellation: %{status: :confirmed, termination: :engine_terminated},
              termination_observation: :confirmed
            }} =
             Arbor.Agent.cancel_conversation_command(
               c.primary.agent_id,
               c.target,
               "active-cancel",
               session_token: c.token
             )

    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000
    assert_receive {:actual_model_request, next, _}, 5_000
    assert List.last(next).content == "surviving FIFO command"
    assert %{status: :completed} = completed!(c, "fifo-survivor")
    wait_for_empty_queue!(c.session)

    assert {:ok, %{status: :uncertain, cancellation: %{status: :confirmed}}} =
             Arbor.Agent.conversation_command(c.primary.agent_id, c.target, "active-cancel",
               session_token: c.token
             )

    refute_receive {:actual_model_request, _, _}, 100
  end

  @tag activity_stream: true
  test "security regression: a fresh authenticated activity read discovers an older active command without client replay amid completed history",
       c do
    set_env(:arbor_comms, :conversation_journal,
      backend: ActivityStorage,
      name: :conversation_journal,
      opts: [repo: Repo]
    )

    set_env(:arbor_orchestrator, :conversation_activity_read_observer, self())
    projector = Process.whereis(Arbor.Comms.ConversationActivity)
    :ok = :sys.suspend(projector)
    on_exit(fn -> if Process.alive?(projector), do: :sys.resume(projector) end)

    assert {:ok, _} =
             Arbor.Agent.submit_conversation_command(
               c.primary.agent_id,
               c.target,
               %{id: "old-active", text: "binding blocker"},
               session_token: c.token,
               timeout: 30_000
             )

    assert_receive {:binding_model_blocked, worker}, 5_000
    assert_receive {:actual_model_request, _, _}, 5_000
    {:ok, engagement} = Arbor.Comms.resolve_user_engagement(c.target, c.primary.agent_id)
    scope = %{principal_id: c.primary.agent_id, agent_id: c.target, engagement_id: engagement.id}

    for n <- 1..120 do
      id = "history-#{n}"

      assert {:ok, _} =
               Arbor.Comms.admit_conversation_command(scope, %{
                 id: id,
                 text: "historical input body #{n}"
               })

      assert {:ok, claim} = Arbor.Comms.claim_conversation_command(scope, id)

      assert {:ok, _} =
               Arbor.Comms.settle_conversation_command(scope, id, claim, %{
                 status: :completed,
                 text: "historical reply body #{n}"
               })
    end

    assert {:ok, %{commands: [], incomplete: true, source_watermark: 362, index_watermark: 0}} =
             Arbor.Agent.conversation_activity(c.primary.agent_id, c.target,
               session_token: c.token
             )

    refute_receive {:activity_range_read, _, _}, 100
    :ok = :sys.resume(projector)
    observed = activity_command!(c, "old-active", 400)
    assert observed.preview == "Live prefix 👋"

    assert %{commands: [only], incomplete: false, source_watermark: 362, index_watermark: 362} =
             complete_activity_page!(c, 362)

    assert only.command_id == "old-active"
    refute inspect(only) =~ "historical input body"
    refute inspect(only) =~ "historical reply body"
    assert_receive {:activity_range_read, ^projector, limit}, 5_000
    assert limit <= 100
    send(worker, :release_binding_model)
    assert %{status: :completed} = completed!(c, "old-active")
  end

  test "security regression: an unobserved DOWN timeout never confirms conversation cancellation",
       c do
    assert {:ok, _} =
             Arbor.Agent.submit_conversation_command(
               c.primary.agent_id,
               c.target,
               %{id: "down-proof-timeout", text: "binding blocker"},
               session_token: c.token,
               timeout: 10_000
             )

    assert_receive {:binding_model_blocked, worker}, 5_000
    assert_receive {:actual_model_request, _, _}, 5_000
    monitor = Process.monitor(worker)

    :sys.replace_state(c.session, fn state ->
      Process.demonitor(state.turn_task_ref, [:flush])
      %{state | turn_task_ref: make_ref()}
    end)

    assert {:ok, %{cancellation: %{status: :requested}, termination_observation: :unconfirmed}} =
             Arbor.Agent.cancel_conversation_command(
               c.primary.agent_id,
               c.target,
               "down-proof-timeout",
               session_token: c.token,
               control_timeout: 7_000
             )

    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000

    assert {:ok, %{cancellation: %{status: :requested}}} =
             Arbor.Agent.conversation_command(c.primary.agent_id, c.target, "down-proof-timeout",
               session_token: c.token
             )
  end

  test "security regression: missing Session retains durable intent and completed delivery stays immutable",
       c do
    assert {:ok, _} =
             Arbor.Agent.submit_conversation_command(
               c.primary.agent_id,
               c.target,
               %{id: "already-completed", text: "complete once"},
               session_token: c.token
             )

    %{outcome: outcome} = completed!(c, "already-completed")

    assert {:ok,
            %{
              delivery_status: :completed,
              cancellation: %{status: :requested},
              termination_observation: :unconfirmed
            }} =
             Arbor.Agent.cancel_conversation_command(
               c.primary.agent_id,
               c.target,
               "already-completed",
               session_token: c.token
             )

    assert {:ok, %{status: :completed, outcome: ^outcome}} =
             Arbor.Agent.conversation_command(c.primary.agent_id, c.target, "already-completed",
               session_token: c.token
             )

    assert {:ok, engagement} = Arbor.Comms.resolve_user_engagement(c.target, c.primary.agent_id)
    scope = %{principal_id: c.primary.agent_id, agent_id: c.target, engagement_id: engagement.id}

    assert {:ok, _} =
             Arbor.Comms.admit_conversation_command(scope, %{
               id: "lost-session",
               text: "never reaches Session"
             })

    assert {:ok, _} = Arbor.Comms.claim_conversation_command(scope, "lost-session")

    :sys.replace_state(SessionManager, fn state ->
      :ets.delete(SessionManager, c.target)
      state
    end)

    assert {:ok, %{cancellation: %{status: :requested}, termination_observation: :unconfirmed}} =
             Arbor.Agent.cancel_conversation_command(c.primary.agent_id, c.target, "lost-session",
               session_token: c.token
             )

    assert {:ok, %{cancellation: %{status: :requested}}} =
             Arbor.Comms.get_conversation_command(scope, "lost-session")
  end

  test "security regression: activity/cancel signed payloads bind exact options and alias/fence revocation",
       c do
    for {operation, input} <- [activity: nil, cancel: "missing"] do
      assert {:ok, payload} =
               Arbor.Agent.conversation_request_payload(
                 operation,
                 c.secondary.agent_id,
                 c.target,
                 input,
                 control_timeout: 1_000
               )

      assert String.starts_with?(payload, "[\"arbor.conversation.#{operation}")

      assert {:ok, proof} =
               SignedRequest.sign(payload, c.secondary.agent_id, c.secondary.private_key)

      result =
        if operation == :activity,
          do:
            Arbor.Agent.conversation_activity(c.secondary.agent_id, c.target,
              signed_request: proof,
              control_timeout: 2_000
            ),
          else:
            Arbor.Agent.cancel_conversation_command(c.secondary.agent_id, c.target, input,
              signed_request: proof
            )

      assert result == {:error, :unauthorized}
    end

    {:ok, scope} = Arbor.Comms.resolve_user_engagement(c.target, c.primary.agent_id)

    assert {:error, :conversation_scope_changed} =
             Arbor.Agent.conversation_activity(c.primary.agent_id, c.target,
               session_token: c.token,
               expected_engagement_id: "eng_" <> String.duplicate("f", 32)
             )

    assert :ok = Security.revoke_fixture(c.primary_cap.id)

    assert {:error, :unauthorized} =
             Arbor.Agent.conversation_activity(c.primary.agent_id, c.target,
               session_token: c.token,
               expected_engagement_id: scope.id
             )

    assert {:error, :unauthorized} =
             Arbor.Agent.cancel_conversation_command(c.primary.agent_id, c.target, "missing",
               session_token: c.token
             )
  end

  test "web token and linked signed terminal share durable history and the next real model context",
       c do
    web = web_connect(c)
    assert web.assigns.conversation_authorized
    engagement = web.assigns.conversation_engagement_id
    web = web_send(web, "web sentinel LARCH-217", "web-first")

    assert web.assigns.conversation_snapshot.receipt["status"] in [
             "admitted",
             "dispatch_started",
             "completed"
           ]

    assert %{status: :completed} = completed!(c, "web-first")
    assert_receive {:actual_model_request, first_prompt, _}, 5_000
    assert inspect(first_prompt) =~ "LARCH-217"

    {:ok, terminal} = GatewaySocket.init(%{principal: c.secondary.agent_id})
    {history, terminal} = frame(c, terminal, :history, nil)
    assert history["data"]["engagement_id"] == engagement
    assert Enum.any?(history["data"]["entries"], &String.contains?(&1["content"], "LARCH-217"))
    input = %{id: "terminal-second", text: "terminal sentinel CEDAR-842"}
    {receipt, terminal} = frame(c, terminal, :submit, input, expected_engagement_id: engagement)
    assert receipt["data"]["principal_id"] == c.primary.agent_id
    assert %{status: :completed} = completed!(c, input.id)
    assert_receive {:actual_model_request, second_prompt, _}, 5_000
    assert inspect(second_prompt) =~ "LARCH-217"
    assert inspect(second_prompt) =~ "CEDAR-842"

    web =
      web
      |> Surface.event("conversation:refresh", %{})
      |> await_web(&(web_text(&1) =~ "CEDAR-842"))

    assert web.assigns.conversation_engagement_id == engagement
    assert web.assigns.conversation_snapshot.window.last == 4
    assert length(web.assigns.conversation_snapshot.projection["messages"]) == 4
    before = Agent.get(c.counter, & &1)
    {retry, _} = frame(c, terminal, :submit, input, expected_engagement_id: engagement)
    assert retry["data"]["status"] == "completed"
    refute_receive {:actual_model_request, _, _}, 100
    assert Agent.get(c.counter, & &1) == before

    {:ok, page} =
      Arbor.Agent.conversation_history(c.primary.agent_id, c.target, session_token: c.token)

    assert Enum.map(page.entries, & &1.role) == ["user", "assistant", "user", "assistant"]
    assert length(Enum.uniq_by(page.entries, & &1.id)) == 4
    assert Enum.map(page.entries, & &1.entry_ordinal) == [1, 2, 3, 4]
  end

  test "security regression: public journal command binds the actual Session RunAuthorization task and ordinary metadata cannot impersonate it",
       c do
    input = %{id: "execution-bound", text: "source command identity"}

    assert {:ok, admitted} =
             Arbor.Agent.submit_conversation_command(
               c.primary.agent_id,
               c.target,
               input,
               session_token: c.token
             )

    assert admitted.status in [:admitted, :dispatch_started, :completed]
    assert %{status: :completed} = completed!(c, input.id)
    assert_receive {:actual_model_request, _, opts}, 5_000
    refute Keyword.has_key?(opts, :conversation_source)

    assert %Arbor.Orchestrator.Engine.RunAuthorization{task_id: task_id} =
             Keyword.fetch!(opts, :run_authorization)

    assert String.starts_with?(task_id, "conversation_")
    assert Keyword.get(opts, :provider_usage_context).task_id == task_id
    refute inspect(opts) =~ "claim_token"
    refute inspect(Session.get_state(c.session)) =~ "execution-bound"

    ordinary = %{
      Arbor.Contracts.Session.UserMessage.from_string("ordinary authenticated")
      | sender_id: c.primary.agent_id,
        transport_metadata: %{task_id: task_id}
    }

    assert {:ok, _} =
             Arbor.Agent.send_message_response(
               c.primary.agent_id,
               c.target,
               ordinary,
               session_token: c.token
             )

    assert_receive {:actual_model_request, _, ordinary_opts}, 5_000

    assert %Arbor.Orchestrator.Engine.RunAuthorization{task_id: nil} =
             Keyword.fetch!(ordinary_opts, :run_authorization)

    forged = %{ordinary | transport_metadata: %{"command_binding" => %{task_id: task_id}}}

    assert {:error, :invalid_message} =
             Arbor.Agent.send_message_response(
               c.primary.agent_id,
               c.target,
               forged,
               session_token: c.token
             )

    refute_receive {:actual_model_request, _, _}, 100
  end

  test "security regression: separate FIFO commands skip a settled claim and activate the next live claim",
       c do
    assert {:ok, _} =
             Arbor.Agent.submit_conversation_command(
               c.primary.agent_id,
               c.target,
               %{id: "binding-blocker", text: "binding blocker"},
               session_token: c.token,
               timeout: 5_000
             )

    assert_receive {:binding_model_blocked, worker}, 5_000
    assert_receive {:actual_model_request, _, _}, 5_000

    assert {:ok, _} =
             Arbor.Agent.submit_conversation_command(
               c.primary.agent_id,
               c.target,
               %{id: "binding-queued", text: "must never execute"},
               session_token: c.token,
               timeout: 5_000
             )

    queued = wait_for_queue!(c.session)
    [{message, authority, {caller, _}}] = queued.turn_queue
    assert Process.alive?(caller)

    assert {:ok, _} =
             Arbor.Comms.get_conversation_command(
               queued.conversation_bindings[authority.turn_id].binding.scope,
               "binding-queued"
             )

    assert :none =
             Session.take_steering(
               c.session,
               queued.turn_token,
               queued.turn_user_message.engagement_id,
               {make_ref(), 1}
             )

    assert [{^message, ^authority, _}] = :sys.get_state(c.session).turn_queue

    binding = queued.conversation_bindings[authority.turn_id].binding

    assert {:ok, _} =
             Arbor.Comms.settle_conversation_command(
               binding.scope,
               binding.command_id,
               binding.claim_token,
               %{status: :uncertain, reason: :delivery_unknown}
             )

    assert {:ok, _} =
             Arbor.Agent.submit_conversation_command(
               c.primary.agent_id,
               c.target,
               %{id: "binding-next", text: "next live queued command"},
               session_token: c.token,
               timeout: 5_000
             )

    waiting = wait_for_queue!(c.session, 2)
    [{^message, ^authority, {^caller, _}}, {_, _, {next_caller, _}}] = waiting.turn_queue
    assert Process.alive?(caller)
    assert Process.alive?(next_caller)

    send(worker, :release_binding_model)
    assert %{status: :completed} = completed!(c, "binding-blocker")
    assert_receive {:actual_model_request, next_messages, _}, 5_000
    assert List.last(next_messages).content == "next live queued command"
    assert %{status: :completed} = completed!(c, "binding-next")
    wait_for_empty_queue!(c.session)
    refute_receive {:actual_model_request, _, _}, 100
    assert :sys.get_state(c.session).conversation_bindings == %{}
  end

  test "security regression: actual Session admission rejects private binding text, scope, token and metadata substitutions",
       c do
    {:ok, engagement} = Arbor.Comms.resolve_user_engagement(c.target, c.primary.agent_id)
    scope = %{principal_id: c.primary.agent_id, agent_id: c.target, engagement_id: engagement.id}
    input = %{id: "admission-fence", text: "exact source command"}
    assert {:ok, _} = Arbor.Comms.admit_conversation_command(scope, input)
    assert {:ok, claim} = Arbor.Comms.claim_conversation_command(scope, input.id)
    assert {:ok, binding} = Arbor.Comms.bind_conversation_command_claim(scope, input.id, claim)

    message = %{
      Arbor.Contracts.Session.UserMessage.from_string(input.text)
      | sender_id: c.primary.agent_id
    }

    for {candidate, envelope} <- [
          {binding, %{message | content: input.text <> " "}},
          {binding, %{message | content: nil}},
          {binding, %{message | content: 7}},
          {binding, %{message | content: ""}},
          {binding, %{message | content: " "}},
          {binding, %{message | content: String.duplicate("a", 32_769)}},
          {%{binding | scope: %{scope | principal_id: c.secondary.agent_id}}, message},
          {%{binding | scope: %{scope | agent_id: "agent_other"}}, message},
          {%{binding | scope: %{scope | engagement_id: "eng_" <> String.duplicate("f", 32)}},
           message},
          {%{binding | claim_token: String.duplicate("0", 64)}, message},
          {binding, %{message | transport_metadata: %{"nested" => [%{claim_token: claim}]}}}
        ] do
      assert {:ok, receipt} =
               Security.authorize_and_issue_conversation_receipt(
                 c.primary.agent_id,
                 "arbor://chat/agent/" <> c.target,
                 :chat,
                 session_token: c.token
               )

      assert {:error, :unauthenticated} =
               Session.send_conversation_command(
                 c.session,
                 envelope,
                 receipt,
                 candidate,
                 2_000
               )

      assert :sys.get_state(c.session).conversation_bindings == %{}
      refute Session.get_state(c.session).turn_in_flight
    end

    refute_receive {:actual_model_request, _, _}, 100
  end

  test "security regression: MessageFacade timeout closes a queued command without later execution",
       c do
    assert {:ok, _} =
             Arbor.Agent.submit_conversation_command(
               c.primary.agent_id,
               c.target,
               %{id: "timeout-blocker", text: "binding blocker"},
               session_token: c.token,
               timeout: 5_000
             )

    assert_receive {:binding_model_blocked, worker}, 5_000
    assert_receive {:actual_model_request, _, _}, 5_000

    assert {:ok, _} =
             Arbor.Agent.submit_conversation_command(
               c.primary.agent_id,
               c.target,
               %{id: "timeout-queued", text: "abandoned queued input"},
               session_token: c.token,
               timeout: 300
             )

    queued = wait_for_queue!(c.session)
    [{_, authority, _}] = queued.turn_queue
    binding = queued.conversation_bindings[authority.turn_id].binding
    wait_for_uncertain!(c, "timeout-queued")

    assert {:error, :invalid_claim} =
             Arbor.Comms.validate_conversation_command_binding(
               binding,
               binding.scope,
               "abandoned queued input"
             )

    send(worker, :release_binding_model)
    assert %{status: :completed} = completed!(c, "timeout-blocker")
    wait_for_empty_queue!(c.session)
    refute_receive {:actual_model_request, _, _}, 100
    assert :sys.get_state(c.session).conversation_bindings == %{}
  end

  test "security regression: unlink and revocation prevent old-content release or pending redirection",
       c do
    web = c |> web_connect() |> web_send("private prior owner", "prior-owner")
    completed!(c, "prior-owner")

    web =
      web
      |> Surface.event("conversation:refresh", %{})
      |> await_web(&(web_text(&1) =~ "private prior owner"))

    assert_receive {:actual_model_request, _, _}, 5_000
    {:ok, terminal} = GatewaySocket.init(%{principal: c.secondary.agent_id})
    {history, terminal} = frame(c, terminal, :history, nil)
    engagement = history["data"]["engagement_id"]
    assert history["data"]["entries"] != []
    assert :ok = unlink(c.primary, c.secondary)

    {denied, invalidated} =
      frame(c, terminal, :submit, %{id: "stale-draft", text: "must not redirect"},
        expected_engagement_id: engagement
      )

    assert denied["reason"] == "conversation_scope_changed"
    assert invalidated.invalidated?
    refute inspect(denied) =~ "private prior owner"
    refute_receive {:actual_model_request, _, _}, 100

    {:ok, fresh} = GatewaySocket.init(%{principal: c.secondary.agent_id})
    {new_history, fresh} = frame(c, fresh, :history, nil)
    new_engagement = new_history["data"]["engagement_id"]
    assert new_engagement != engagement
    assert new_history["data"]["entries"] == []

    {new_receipt, fresh} =
      frame(c, fresh, :submit, %{id: "new-owner", text: "fresh secondary context"},
        expected_engagement_id: new_engagement
      )

    assert new_receipt["data"]["principal_id"] == c.secondary.agent_id
    assert %{"status" => "completed"} = terminal_completed!(c, fresh, "new-owner")
    assert_receive {:actual_model_request, new_prompt, _}, 5_000
    assert inspect(new_prompt) =~ "fresh secondary context"
    refute inspect(new_prompt) =~ "private prior owner"
    assert :ok = Security.revoke_fixture(c.secondary_cap.id)

    for {operation, input} <- [
          history: nil,
          events: 0,
          command: "new-owner",
          submit: %{id: "revoked-owner", text: "cannot dispatch"}
        ] do
      {denied, _} = frame(c, fresh, operation, input, expected_engagement_id: new_engagement)
      assert denied["reason"] == "unauthorized"
      refute inspect(denied) =~ "fresh secondary context"
    end

    refute_receive {:actual_model_request, _, _}, 100
    assert :ok = Security.revoke_fixture(c.primary_cap.id)
    # The browser's synchronous access check (the same one that admits voice)
    # clears every private projection once authority is gone.
    cleared = Surface.refresh_access(web)
    refute cleared.assigns.conversation_authorized
    assert cleared.assigns.conversation_rebind_required
    assert cleared.assigns.conversation_snapshot.projection["messages"] == []
    assert cleared.assigns.input == ""
    refute web_text(cleared) =~ "private prior owner"

    assert {:error, :unauthorized} =
             Arbor.Agent.conversation_history(c.primary.agent_id, c.target,
               session_token: c.token
             )
  end

  test "durable admission continues when its submitting interface process disconnects", c do
    owner = self()

    {submitter, monitor} =
      spawn_monitor(fn ->
        {:ok, terminal} = GatewaySocket.init(%{principal: c.secondary.agent_id})
        {history, terminal} = frame(c, terminal, :history, nil)

        {receipt, terminal} =
          frame(c, terminal, :submit, %{id: "departed-interface", text: "disconnect barrier"},
            expected_engagement_id: history["data"]["engagement_id"]
          )

        send(owner, {:admission, receipt})
        :ok = GatewaySocket.terminate(:normal, terminal)
      end)

    assert_receive {:admission,
                    %{"type" => "conversation_command", "data" => %{"id" => "departed-interface"}}},
                   5_000

    assert_receive {:DOWN, ^monitor, :process, ^submitter, :normal}, 5_000
    assert_receive {:at_transcript_commit, worker}, 5_000
    send(worker, :release_commit)
    assert %{status: :completed} = completed!(c, "departed-interface")

    {:ok, page} =
      Arbor.Agent.conversation_history(c.primary.agent_id, c.target, session_token: c.token)

    assert length(page.entries) == 2
    assert Agent.get(c.counter, & &1) == 1

    assert {:ok, %{pending: 0}} = Arbor.Historian.flush_authority_audit()
    assert {:ok, []} = Security.audit_journal_pending_operations()

    assert {:ok, [audit]} =
             Arbor.Persistence.read_stream(
               :historian_durable_event_log,
               Arbor.Persistence.EventLog.Ecto,
               "security:authority_mutation:" <> c.primary_audit_id,
               repo: Repo
             )

    assert audit.id == c.primary_audit_id
    assert audit.data["intent"]["audit"]["data"]["capability_id"] == c.primary_cap.id
    assert audit.data["effect"] == "applied"
  end

  @tag :transport
  @tag timeout: 900_000
  @tag skip: System.get_env("ARBOR_TRANSPORT_JOURNEY") != "1"
  test "real browser and signed terminal sockets converge through production entrypoints", c do
    Code.require_file(Path.expand("../../support/conversation_transport/web.exs", __DIR__))
    endpoint = Arbor.Dashboard.Endpoint
    config = Application.get_env(:arbor_dashboard, endpoint, [])
    set_env(:arbor_dashboard, endpoint, Keyword.merge(config, server: false, check_origin: false))

    set_env(:arbor_security, :oidc,
      providers: [%{issuer: "https://fixture.invalid", client_id: "fixture"}]
    )

    if Process.whereis(Arbor.Dashboard.PubSub) == nil,
      do: start_supervised!({Phoenix.PubSub, name: Arbor.Dashboard.PubSub})

    if Process.whereis(endpoint) == nil, do: start_supervised!(endpoint)

    fixture =
      Map.merge(c, %{
        owner: self(),
        secret: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      })

    set_env(:arbor_agent, :conversation_transport_fixture, fixture)

    start_supervised!(
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: Arbor.Gateway.Router,
        options: [ip: {127, 0, 0, 1}, port: 47_871, ref: :conversation_gateway_fixture]
      )
    )

    start_supervised!(
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: Arbor.Agent.Test.ConversationTransportWeb,
        options: [ip: {127, 0, 0, 1}, port: 47_872, ref: :conversation_web_fixture]
      )
    )

    info = %{
      gateway: "ws://127.0.0.1:47871",
      web: "http://127.0.0.1:47872",
      login: "http://127.0.0.1:47872/_journey/" <> fixture.secret <> "/login",
      revoke: "http://127.0.0.1:47872/_journey/" <> fixture.secret <> "/revoke",
      finish: "http://127.0.0.1:47872/_journey/" <> fixture.secret <> "/finish",
      target: c.target,
      principal: c.secondary.agent_id,
      private_key: Base.encode64(c.secondary.private_key)
    }

    path = "/private/tmp/convergence-transport.json"
    File.write!(path, Jason.encode!(info))
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm(path) end)

    modules = [
      Arbor.Agent,
      Arbor.Agent.ConversationFacade,
      Arbor.Agent.MessageFacade,
      Arbor.Security,
      Arbor.Security.DeliveryReceiptBroker,
      Arbor.Orchestrator.Session,
      Arbor.Gateway.Chat.Socket,
      Arbor.Dashboard.Live.ConversationLive,
      Arbor.Dashboard.Live.ConversationLive.Surface,
      ConversationKit.Arbor,
      ConversationKit.Arbor.Connection
    ]

    beams =
      Map.new(modules, fn module ->
        Code.ensure_loaded!(module)
        {^module, binary, _path} = :code.get_object_code(module)
        {inspect(module), Base.encode16(:crypto.hash(:sha256, binary), case: :lower)}
      end)

    asset = Application.app_dir(:arbor_web, "priv/static/arbor_web.js") |> File.read!()

    manifest = %{
      beam_sha256: beams,
      browser_asset_sha256: Base.encode16(:crypto.hash(:sha256, asset), case: :lower)
    }

    File.write!("/private/tmp/convergence-transport-build.json", Jason.encode!(manifest))
    IO.puts("CONVERSATION_TRANSPORT_READY")
    assert_receive :transport_revoked, 840_000
    assert_receive :transport_finish, 60_000
    assert Agent.get(c.counter, & &1) == 2
    assert_receive {:actual_model_request, first, _}, 5_000
    assert inspect(first) =~ "BROWSER-LARCH-217"
    assert_receive {:actual_model_request, second, _}, 5_000
    assert inspect(second) =~ "BROWSER-LARCH-217"
    assert inspect(second) =~ "TERMINAL-CEDAR-842"
    refute_receive {:actual_model_request, _, _}, 100

    assert {:error, :unauthorized} =
             Arbor.Agent.conversation_history(c.primary.agent_id, c.target,
               session_token: c.token
             )

    result = %{
      model_calls: 2,
      durable_appends: 2,
      actual_second_context_includes_both: true,
      revoked_history_denied: true,
      browser: "production ConversationLive",
      terminal: "production WSClient + App reducer"
    }

    File.write!("/private/tmp/convergence-transport-host-result.json", Jason.encode!(result))
  end

  defp human! do
    fixture =
      OIDCTestHelper.issue_identity(subject: "entrypoint-#{System.unique_integer([:positive])}")

    :ok = Security.register_oidc_identity(fixture.identity, fixture.id_token, fixture.provider)

    on_exit(fn ->
      Security.deregister_identity_fixture(fixture.identity.agent_id)
      fixture.cleanup.()
    end)

    fixture.identity
  end

  defp grant!(principal, resource) do
    {:ok, cap} = Security.grant_fixture(principal: principal, resource: resource)
    on_exit(fn -> Security.revoke_fixture(cap.id) end)
    cap
  end

  defp link!(primary, secondary) do
    {:ok, proof} = IdentityAliasProof.sign(primary, {:link, secondary.agent_id, primary.agent_id})

    :ok =
      IdentityAliases.link(primary.agent_id, secondary.agent_id, primary.agent_id,
        signed_request: proof
      )
  end

  defp unlink(primary, secondary) do
    {:ok, proof} = IdentityAliasProof.sign(primary, {:unlink, secondary.agent_id})
    IdentityAliases.unlink(primary.agent_id, secondary.agent_id, signed_request: proof)
  end

  defp frame(c, state, operation, input, opts \\ []) do
    {:ok, payload} =
      Arbor.Agent.conversation_request_payload(
        operation,
        c.secondary.agent_id,
        c.target,
        input,
        opts
      )

    {:ok, proof} = SignedRequest.sign(payload, c.secondary.agent_id, c.secondary.private_key)

    envelope = %{
      agent_id: proof.agent_id,
      timestamp: DateTime.to_iso8601(proof.timestamp),
      nonce: Base.encode64(proof.nonce),
      signature: Base.encode64(proof.signature)
    }

    wire =
      Jason.encode!(%{
        payload: payload,
        authorization: "Signature " <> Base.encode64(Jason.encode!(envelope), padding: false)
      })

    {:push, [{:text, json}], next} = GatewaySocket.handle_in({wire, [opcode: :text]}, state)
    {Jason.decode!(json), next}
  end

  defp activity_command!(c, id, attempts \\ 200)
  defp activity_command!(_, _, 0), do: flunk("command did not appear in bounded activity")

  defp activity_command!(c, id, attempts) do
    case Arbor.Agent.conversation_activity(c.primary.agent_id, c.target, session_token: c.token) do
      {:ok, %{commands: commands}} ->
        case Enum.find(commands, &(&1.command_id == id)) do
          nil ->
            Process.sleep(20)
            activity_command!(c, id, attempts - 1)

          command ->
            command
        end

      other ->
        flunk("unexpected activity result: #{inspect(other)}")
    end
  end

  defp complete_activity_page!(c, source, attempts \\ 400)
  defp complete_activity_page!(_, _, 0), do: flunk("activity index did not catch up")

  defp complete_activity_page!(c, source, attempts) do
    case Arbor.Agent.conversation_activity(c.primary.agent_id, c.target, session_token: c.token) do
      {:ok, %{source_watermark: ^source, index_watermark: ^source, incomplete: false} = page} ->
        page

      {:ok, %{incomplete: true}} ->
        Process.sleep(20)
        complete_activity_page!(c, source, attempts - 1)

      other ->
        flunk("unexpected catchup activity result: #{inspect(other)}")
    end
  end

  defp terminal_command!(c, id, attempts \\ 200)
  defp terminal_command!(_, _, 0), do: flunk("command did not reach a delivery terminal")

  defp terminal_command!(c, id, attempts) do
    case Arbor.Agent.conversation_command(c.primary.agent_id, c.target, id,
           session_token: c.token
         ) do
      {:ok, %{status: status} = command} when status in [:completed, :uncertain] ->
        command

      {:ok, %{status: status}} when status in [:admitted, :dispatch_started] ->
        Process.sleep(20)
        terminal_command!(c, id, attempts - 1)

      other ->
        flunk("unexpected delivery result: #{inspect(other)}")
    end
  end

  defp completed!(c, id, attempts \\ 200)
  defp completed!(_, _, 0), do: flunk("command did not settle")

  defp completed!(c, id, attempts) do
    case Arbor.Agent.conversation_command(c.primary.agent_id, c.target, id,
           session_token: c.token
         ) do
      {:ok, %{status: :completed} = command} ->
        command

      {:ok, %{status: status}} when status in [:admitted, :dispatch_started] ->
        Process.sleep(20)
        completed!(c, id, attempts - 1)

      other ->
        flunk("unexpected delivery result: #{inspect(other)}")
    end
  end

  defp wait_for_queue!(session, expected \\ 1, attempts \\ 200)
  defp wait_for_queue!(_, _, 0), do: flunk("command never reached the actual Session queue")

  defp wait_for_queue!(session, expected, attempts) do
    state = :sys.get_state(session)

    if length(state.turn_queue) == expected,
      do: state,
      else:
        (
          Process.sleep(10)
          wait_for_queue!(session, expected, attempts - 1)
        )
  end

  defp wait_for_empty_queue!(session, attempts \\ 200)
  defp wait_for_empty_queue!(_, 0), do: flunk("Session did not retire the queued command")

  defp wait_for_empty_queue!(session, attempts) do
    state = :sys.get_state(session)

    if state.turn_queue == [] and not state.turn_in_flight,
      do: state,
      else:
        (
          Process.sleep(10)
          wait_for_empty_queue!(session, attempts - 1)
        )
  end

  defp wait_for_uncertain!(c, id, attempts \\ 200)
  defp wait_for_uncertain!(_, _, 0), do: flunk("timed out command did not settle uncertain")

  defp wait_for_uncertain!(c, id, attempts) do
    case Arbor.Agent.conversation_command(c.primary.agent_id, c.target, id,
           session_token: c.token
         ) do
      {:ok, %{status: :uncertain}} ->
        :ok

      _ ->
        Process.sleep(10)
        wait_for_uncertain!(c, id, attempts - 1)
    end
  end

  defp terminal_completed!(c, state, id, attempts \\ 200)
  defp terminal_completed!(_, _, _, 0), do: flunk("terminal command did not settle")

  defp terminal_completed!(c, state, id, attempts) do
    {reply, next} = frame(c, state, :command, id, expected_engagement_id: state.engagement_id)

    case reply do
      %{"data" => %{"status" => "completed"} = command} ->
        command

      %{"data" => %{"status" => status}} when status in ["admitted", "dispatch_started"] ->
        Process.sleep(20)
        terminal_completed!(c, next, id, attempts - 1)

      other ->
        flunk("unexpected terminal delivery result: #{inspect(other)}")
    end
  end

  # The production browser path: ConversationLive's Surface performs the
  # synchronous access check and owns a private ConversationKit connection to
  # the public Arbor.Agent conversation facade. This test process stands in for
  # the LiveView process and applies each connection snapshot exactly as
  # ConversationLive.handle_info/2 does.
  defp web_connect(c) do
    %Phoenix.LiveView.Socket{
      endpoint: Arbor.Dashboard.Endpoint,
      view: Arbor.Dashboard.Live.ConversationLive,
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}},
      assigns: %{__changed__: %{}, current_agent_id: c.primary.agent_id, session_token: c.token}
    }
    |> Surface.mount(c.target)
    |> Surface.connect()
  end

  defp web_send(socket, text, id) do
    socket = await_web(socket, & &1.assigns.conversation_snapshot.send_allowed)

    # Admission is durable before the browser shows its receipt for this ID.
    socket
    |> Surface.event("update-input", %{"message" => text})
    |> Surface.event("send-message", %{"message" => text, "command_id" => id})
    |> await_web(&(&1.assigns.conversation_snapshot.receipt["id"] == id))
  end

  defp await_web(socket, predicate, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 10_000

    if predicate.(socket) do
      socket
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:conversation_updated, pid, snapshot} ->
          socket |> Surface.update(pid, snapshot) |> await_web(predicate, deadline)
      after
        remaining -> flunk("browser conversation did not reach the expected state")
      end
    end
  end

  defp web_text(socket),
    do:
      Enum.map_join(
        socket.assigns.conversation_snapshot.projection["messages"],
        "\n",
        & &1["text"]
      )

  defp start_authority_audit_puller! do
    supervisor = Process.whereis(Arbor.Historian.Supervisor)
    assert is_pid(supervisor), "historian supervisor is not running"

    assert {:ok, puller} =
             Supervisor.start_child(
               supervisor,
               {Arbor.Historian.AuthorityAuditPuller, [poll_interval_ms: 25]}
             )

    assert Process.whereis(Arbor.Historian.AuthorityAuditPuller) == puller

    on_exit(fn ->
      if is_pid(supervisor) and Process.alive?(supervisor) do
        Supervisor.terminate_child(supervisor, Arbor.Historian.AuthorityAuditPuller)
        Supervisor.delete_child(supervisor, Arbor.Historian.AuthorityAuditPuller)
      end
    end)
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
end
