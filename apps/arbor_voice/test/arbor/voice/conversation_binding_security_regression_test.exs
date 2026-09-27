Code.require_file(
  Path.expand("../../../../arbor_security/test/support/oidc_test_helper.ex", __DIR__)
)

defmodule Arbor.Voice.ConversationBindingSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.{IdentityAliases, IdentityAliasProof, SessionManager}
  alias Arbor.Contracts.Security.{Identity, SignedRequest}
  alias Arbor.Orchestrator.Session
  alias Arbor.Persistence.Repo
  alias Arbor.Security
  alias Arbor.Security.{OIDCTestHelper, SessionToken}

  @moduletag :integration
  @moduletag :database
  @moduletag :isolated_repo
  @moduletag :voice_conversation_binding
  @moduletag :security_regression
  @moduletag capture_log: true
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
  end

  setup_all do
    :ok = Arbor.Security.TestBootstrap.start!()
    :ok = Arbor.Memory.TestBootstrap.start!()

    assert Process.whereis(Repo) == nil, "Run this journey alone with --include isolated_repo."

    root =
      Path.join(
        System.tmp_dir!(),
        "voice-binding-journey-#{System.pid()}-#{Base.encode16(:crypto.strong_rand_bytes(8))}"
      )

    File.mkdir!(root)
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

    for {name, child} <- [
          {Arbor.Agent.Registry, Arbor.Agent.Registry},
          {Arbor.Agent.SessionManager, Arbor.Agent.SessionManager},
          {Arbor.Orchestrator.EventRegistry,
           {Registry, keys: :duplicate, name: Arbor.Orchestrator.EventRegistry}},
          {Arbor.Comms.EngagementStore, Arbor.Comms.EngagementStore},
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

  setup do
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
          {:arbor_voice, :security_module, Arbor.Security},
          {:arbor_voice, :agent_module, Arbor.Agent},
          {:arbor_voice, :trust_module,
           Arbor.Voice.ConversationBindingSecurityRegressionTest.TrustFixture},
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
    :ok = Security.register_identity(Identity.public_only(agent))
    on_exit(fn -> Security.deregister_identity(agent.agent_id) end)
    resource = "arbor://chat/agent/" <> agent.agent_id
    primary_cap = grant!(primary.agent_id, resource)
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
    {:ok, voice_token} = SessionToken.generate(secondary.agent_id)

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
          "stream" => false,
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
     voice_token: voice_token,
     session: session,
     session_id: session_id,
     counter: counter,
     primary_cap: primary_cap,
     secondary_cap: secondary_cap}
  end

  defmodule TrustFixture do
    def authorize_egress(_, _, _), do: :allow
  end

  defmodule Backend do
    @behaviour Arbor.Voice.RealtimeBackend
    def egress_route, do: :none
    def open(opts), do: {:ok, Map.new(opts)}

    def configure(s, config) do
      send(s.observer, {:voice_configured, config})
      {:ok, s}
    end

    def send_text(s, text) do
      send(s.observer, {:voice_sent, text})
      {:ok, s}
    end

    def send_audio(s, pcm) do
      send(s.observer, {:voice_audio_sent, pcm})
      {:ok, s}
    end

    def send_tool_result(s, id, output) do
      send(s.observer, {:voice_tool_result, id, output})
      Agent.update(s.script, &(&1 ++ [{:turn_done, %{text: "VOICE-FIR-913"}}]))
      {:ok, s}
    end

    def recv(s, timeout) do
      item =
        Agent.get_and_update(s.script, fn
          [event | rest] -> {event, rest}
          [] -> {:timeout, []}
        end)

      case item do
        :timeout ->
          Process.sleep(timeout)
          {:error, :timeout}

        {:barrier, event} ->
          send(s.observer, {:voice_recv_barrier, self()})

          receive do
            :release -> {:ok, s, event}
          after
            5_000 -> {:error, :timeout}
          end

        event ->
          {:ok, s, event}
      end
    end

    def close(s) do
      send(s.observer, :voice_backend_closed)
      :ok
    end

    def meta(%{pcm: true}),
      do: %{
        backend: :binding_fixture,
        mode: :local,
        input_format: Arbor.Voice.PcmFormat.mono_s16le(16_000),
        output_format: Arbor.Voice.PcmFormat.mono_s16le(24_000)
      }

    def meta(_),
      do: %{backend: :binding_fixture, mode: :local, input_format: nil, output_format: nil}
  end

  defmodule WireTransport do
    def connect(opts), do: {:ok, Map.new(opts)}

    def send_frame(s, frame, _deadline) do
      send(s.observer, {:wire_send, frame})

      case frame do
        %{"type" => "session.update", "session" => config} ->
          Agent.update(s.script, &[%{"type" => "session.updated", "session" => config} | &1])

        _ ->
          :ok
      end

      {:ok, s}
    end

    def recv_frame(s, _timeout) do
      item =
        Agent.get_and_update(s.script, fn
          [event | rest] -> {event, rest}
          [] -> {:timeout, []}
        end)

      case item do
        :timeout ->
          {:error, :timeout}

        {:barrier, event} ->
          send(s.observer, {:voice_recv_barrier, self()})

          receive do
            :release -> {:ok, s, event}
          after
            5_000 -> {:error, :timeout}
          end

        event ->
          {:ok, s, event}
      end
    end

    def close(s) do
      send(s.observer, :voice_backend_closed)
      :ok
    end
  end

  defmodule BarrierRecorder do
    def record(agent, message, raw, completed, opts) do
      result = Arbor.Voice.TranscriptRecorder.record(agent, message, raw, completed, opts)
      observer = Application.fetch_env!(:arbor_voice, :binding_observer)
      send(observer, {:after_voice_append, self()})

      receive do
        :release -> result
      after
        5_000 -> {:error, :fixture_timeout}
      end
    end
  end

  defmodule NonPairRecorder do
    def record(_, _, _, _, _),
      do: {:ok, Application.fetch_env!(:arbor_voice, :binding_record_count)}
  end

  defmodule BarrierSpeakable do
    def render(text, opts) do
      observer = Application.fetch_env!(:arbor_voice, :binding_observer)
      send(observer, {:at_voice_presentation, self()})

      receive do
        :release -> Arbor.Voice.Speakable.render(text, opts)
      after
        5_000 -> {:error, :fixture_timeout}
      end
    end

    defdelegate tts_guard!(verdict), to: Arbor.Voice.Speakable
  end

  defmodule ConsultBarrier do
    def send_message(caller, target, message, opts) do
      result = Arbor.Agent.send_message(caller, target, message, opts)

      send(
        Application.fetch_env!(:arbor_voice, :binding_observer),
        {:consult_returned, self(), elem(result, 0)}
      )

      receive do
        :release -> result
      after
        5_000 -> {:error, :fixture_timeout}
      end
    end
  end

  defmodule ForeignComms do
    def resolve_user_engagement(agent, owner, opts) do
      with {:ok, engagement} <- Arbor.Comms.resolve_user_engagement(agent, owner, opts),
           do: {:ok, %{engagement | owner_tenant: "human_foreign"}}
    end
  end

  test "security regression: local backend requires proof before opening", c do
    {opts, _script} = voice_opts(c, [])

    assert {:error, :invalid_opts} =
             Arbor.Voice.start_session(
               c.secondary.agent_id,
               c.target,
               Keyword.delete(opts, :session_token)
             )

    assert {:error, :start_failed} =
             Arbor.Voice.start_session(
               c.secondary.agent_id,
               c.target,
               Keyword.put(opts, :session_token, c.token)
             )

    refute_receive {:voice_configured, _}, 50
    refute_receive {:voice_sent, _}, 50
  end

  test "linked Voice uses the web owner's transcript and source-fenced Agent consultation", c do
    assert {:ok, "Conversation received."} = send_agent(c, "WEB-LARCH-217")
    assert_receive {:actual_model_request, first, _}, 5_000
    assert inspect(first) =~ "WEB-LARCH-217"

    call =
      {:tool_call,
       %{id: "consult", name: "consult_agent", arguments: %{"message" => "CONSULT-CEDAR-842"}}}

    {opts, _script} = voice_opts(c, [call, {:turn_done, %{text: ""}}])
    assert {:ok, key} = Arbor.Voice.start_session(c.secondary.agent_id, c.target, opts)
    assert_receive {:voice_configured, %{tools: tools}}
    assert Enum.map(tools, & &1["name"]) == ["consult_agent"]

    assert {:ok, "VOICE-FIR-913"} =
             Arbor.Voice.text_turn(c.secondary.agent_id, c.target, "VOICE-PINE-431")

    assert_receive {:actual_model_request, consult_context, _}, 5_000
    assert inspect(consult_context) =~ "WEB-LARCH-217"
    assert inspect(consult_context) =~ "CONSULT-CEDAR-842"
    assert_receive {:voice_tool_result, "consult", tool_json}
    assert Jason.decode!(tool_json)["result"]["reply"] == "Conversation received."
    assert :ok = Arbor.Voice.stop_session(key)

    assert {:ok, history} =
             Arbor.Agent.conversation_history(c.primary.agent_id, c.target,
               session_token: c.token
             )

    assert Enum.map(history.entries, & &1.content) == [
             "WEB-LARCH-217",
             "Conversation received.",
             "CONSULT-CEDAR-842",
             "Conversation received.",
             "VOICE-PINE-431",
             "VOICE-FIR-913"
           ]

    assert {:ok, "Conversation received."} = send_agent(c, "WEB-FOLLOWUP-663")
    assert_receive {:actual_model_request, following_context, _}, 5_000
    assert inspect(following_context) =~ "VOICE-PINE-431"
    assert inspect(following_context) =~ "VOICE-FIR-913"
  end

  test "security regression: resolver's foreign scope is refused before local backend effects",
       c do
    {opts, _script} = voice_opts(c, [])

    assert {:error, :start_failed} =
             Arbor.Voice.start_session(
               c.secondary.agent_id,
               c.target,
               Keyword.put(opts, :comms, ForeignComms)
             )

    refute_receive {:voice_configured, _}, 50
  end

  test "security regression: owner unlink before the next turn never retargets a live Voice session",
       c do
    {opts, _script} = voice_opts(c, [{:turn_done, %{text: "must not retarget"}}])
    assert {:ok, key} = Arbor.Voice.start_session(c.secondary.agent_id, c.target, opts)
    assert :ok = unlink(c.primary, c.secondary)

    assert {:error, :turn_failed} =
             Arbor.Voice.text_turn(
               c.secondary.agent_id,
               c.target,
               "new owner must not receive this"
             )

    refute_receive {:voice_sent, _}, 50

    assert {:ok, history} =
             Arbor.Agent.conversation_history(c.primary.agent_id, c.target,
               session_token: c.token
             )

    assert history.entries == []
    Arbor.Voice.stop_session(key)
  end

  test "security regression: real token expiry while receiving blocks transcript and output", c do
    {:ok, token} = SessionToken.generate(c.secondary.agent_id, ttl: 2)
    {opts, _script} = voice_opts(%{c | voice_token: token}, [{:barrier, terminal_event(:local)}])
    assert {:ok, key} = Arbor.Voice.start_session(c.secondary.agent_id, c.target, opts)

    turn =
      Task.async(fn ->
        Arbor.Voice.text_turn(c.secondary.agent_id, c.target, "expiry barrier")
      end)

    assert_receive {:voice_recv_barrier, worker}, 5_000
    await_expired(token)
    send(worker, :release)
    assert {:error, reason} = Task.await(turn, 10_000)
    assert reason in [:turn_failed, :cleanup_pending]
    refute_receive {:voice_spoken, _}, 50

    assert {:ok, history} =
             Arbor.Agent.conversation_history(c.primary.agent_id, c.target,
               session_token: c.token
             )

    assert history.entries == []
    Arbor.Voice.stop_session(key)
  end

  test "security regression: unlink after Agent consultation blocks its return to the Voice provider",
       c do
    set_env(:arbor_voice, :binding_observer, self())
    set_env(:arbor_voice, :agent_module, ConsultBarrier)

    call =
      {:tool_call,
       %{id: "consult", name: "consult_agent", arguments: %{"message" => "consult before unlink"}}}

    {opts, _script} = voice_opts(c, [call, {:turn_done, %{text: ""}}])
    assert {:ok, key} = Arbor.Voice.start_session(c.secondary.agent_id, c.target, opts)

    turn =
      Task.async(fn ->
        Arbor.Voice.text_turn(c.secondary.agent_id, c.target, "withhold consult result")
      end)

    assert_receive {:consult_returned, worker, :ok}, 5_000
    assert :ok = unlink(c.primary, c.secondary)
    send(worker, :release)
    assert {:error, reason} = Task.await(turn, 10_000)
    assert reason in [:turn_failed, :cleanup_pending]
    refute_receive {:voice_tool_result, _, _}, 50
    refute_receive {:voice_spoken, _}, 50

    assert {:ok, history} =
             Arbor.Agent.conversation_history(c.primary.agent_id, c.target,
               session_token: c.token
             )

    assert Enum.map(history.entries, & &1.content) == [
             "consult before unlink",
             "Conversation received."
           ]

    Arbor.Voice.stop_session(key)
  end

  for kind <- [:local, :cloud] do
    test "security regression: #{kind} revoked between receive and result cannot commit or disclose",
         c do
      kind = unquote(kind)
      event = terminal_event(kind)
      {opts, _script} = voice_opts(c, [{:barrier, event} | terminal_tail(kind)], kind)
      assert {:ok, key} = Arbor.Voice.start_session(c.secondary.agent_id, c.target, opts)

      turn =
        Task.async(fn ->
          Arbor.Voice.text_turn(c.secondary.agent_id, c.target, "revocation barrier")
        end)

      assert_receive {:voice_recv_barrier, worker}, 5_000
      assert :ok = Security.revoke(c.secondary_cap.id)
      send(worker, :release)
      assert {:error, reason} = Task.await(turn, 10_000)
      assert reason in [:turn_failed, :cleanup_pending]
      refute_receive {:voice_spoken, _}, 50

      assert {:ok, history} =
               Arbor.Agent.conversation_history(c.primary.agent_id, c.target,
                 session_token: c.token
               )

      assert history.entries == []
      Arbor.Voice.stop_session(key)
    end
  end

  test "security regression: unlink after append suppresses speech and public reply", c do
    set_env(:arbor_voice, :binding_observer, self())
    {opts, _script} = voice_opts(c, [{:turn_done, %{text: "committed-but-withheld"}}])
    opts = Keyword.put(opts, :transcript_recorder, BarrierRecorder)
    assert {:ok, key} = Arbor.Voice.start_session(c.secondary.agent_id, c.target, opts)

    turn =
      Task.async(fn ->
        Arbor.Voice.text_turn(c.secondary.agent_id, c.target, "commit barrier")
      end)

    assert_receive {:after_voice_append, session}, 5_000
    assert :ok = unlink(c.primary, c.secondary)
    send(session, :release)
    assert {:error, :turn_failed} = Task.await(turn, 10_000)
    refute_receive {:voice_spoken, _}, 50

    assert {:ok, history} =
             Arbor.Agent.conversation_history(c.primary.agent_id, c.target,
               session_token: c.token
             )

    assert Enum.map(history.entries, & &1.content) == ["commit barrier", "committed-but-withheld"]
    Arbor.Voice.stop_session(key)
  end

  test "security regression: revoke during rendering prevents guarded publication and reply", c do
    set_env(:arbor_voice, :binding_observer, self())
    {opts, _script} = voice_opts(c, [{:turn_done, %{text: "never speak this"}}])
    opts = Keyword.put(opts, :speakable, BarrierSpeakable)
    assert {:ok, key} = Arbor.Voice.start_session(c.secondary.agent_id, c.target, opts)

    turn =
      Task.async(fn ->
        Arbor.Voice.text_turn(c.secondary.agent_id, c.target, "render barrier")
      end)

    assert_receive {:at_voice_presentation, session}, 5_000
    assert :ok = Security.revoke(c.secondary_cap.id)
    send(session, :release)
    assert {:error, :turn_failed} = Task.await(turn, 10_000)
    refute_receive {:voice_spoken, _}, 50
    Arbor.Voice.stop_session(key)
  end

  for count <- [0, 1, 3] do
    @tag :voice_invalid_pair
    test "security regression: transcript count #{count} cannot publish a Voice turn", c do
      set_env(:arbor_voice, :binding_record_count, unquote(count))
      {opts, _} = voice_opts(c, [{:turn_done, %{text: "uncommitted answer"}}])
      opts = Keyword.put(opts, :transcript_recorder, NonPairRecorder)
      assert {:ok, key} = Arbor.Voice.start_session(c.secondary.agent_id, c.target, opts)

      assert {:error, :transcript_record_failed} =
               Arbor.Voice.text_turn(c.secondary.agent_id, c.target, "require a pair")

      refute_receive {:voice_spoken, _}, 50

      assert {:ok, history} =
               Arbor.Agent.conversation_history(c.primary.agent_id, c.target,
                 session_token: c.token
               )

      assert history.entries == []
      Arbor.Voice.stop_session(key)
    end
  end

  test "completed audio shares durable web history and next actual provider context", c do
    assert {:ok, "Conversation received."} = send_agent(c, "WEB-BEFORE-AUDIO-278")
    assert_receive {:actual_model_request, _, _}, 5_000

    {opts, _} =
      audio_opts(c, [
        {:input_transcript, "AUDIO-TRANSCRIPT-640"},
        {:output_audio, <<7, 8, 9, 10>>},
        {:turn_done, %{text: "Audio answer."}}
      ])

    assert {:ok, key} = Arbor.Voice.start_session(c.secondary.agent_id, c.target, opts)
    [{session, _}] = Registry.lookup(Arbor.Voice.Registry, key)
    session_ref = Process.monitor(session)
    assert {:ok, result} = audio_turn(c, "audio-positive")
    assert result.reply == "Audio answer."
    assert result.input_transcript == "AUDIO-TRANSCRIPT-640"
    assert result.presentation.audio == <<7, 8, 9, 10>>
    assert result.presentation.spoken_text == "Audio answer."
    assert result.presentation.format == Arbor.Voice.PcmFormat.mono_s16le(24_000)
    assert_receive :voice_backend_closed
    assert_receive {:DOWN, ^session_ref, :process, ^session, _}, 5_000

    assert {:ok, history} =
             Arbor.Agent.conversation_history(c.primary.agent_id, c.target,
               session_token: c.token
             )

    assert Enum.map(history.entries, & &1.content) == [
             "WEB-BEFORE-AUDIO-278",
             "Conversation received.",
             "AUDIO-TRANSCRIPT-640",
             "Audio answer."
           ]

    assert {:ok, "Conversation received."} = send_agent(c, "WEB-AFTER-AUDIO-975")
    assert_receive {:actual_model_request, following_context, _}, 5_000
    assert inspect(following_context) =~ "AUDIO-TRANSCRIPT-640"
    assert inspect(following_context) =~ "Audio answer."
  end

  test "security regression: real grant revocation during audio receive withholds PCM and transcript",
       c do
    {opts, _} =
      audio_opts(c, [
        {:input_transcript, "private audio utterance"},
        {:barrier, {:output_audio, <<7, 8, 9, 10>>}},
        {:turn_done, %{text: "private audio answer"}}
      ])

    assert {:ok, key} = Arbor.Voice.start_session(c.secondary.agent_id, c.target, opts)
    turn = Task.async(fn -> audio_turn(c, "audio-revoked") end)
    assert_receive {:voice_recv_barrier, worker}, 5_000
    assert :ok = Security.revoke(c.secondary_cap.id)
    send(worker, :release)
    assert {:error, reason} = Task.await(turn, 10_000)
    assert reason in [:turn_failed, :cleanup_pending]
    refute_receive {:voice_spoken, _}, 50

    assert {:ok, history} =
             Arbor.Agent.conversation_history(c.primary.agent_id, c.target,
               session_token: c.token
             )

    assert history.entries == []
    Arbor.Voice.stop_session(key)
  end

  defp audio_opts(c, events) do
    {opts, script} = voice_opts(c, events)

    opts =
      opts
      |> Keyword.put(:audio_mode, :pcm16)
      |> Keyword.update!(:backend_opts, &Keyword.put(&1, :pcm, true))

    {opts, script}
  end

  defp audio_turn(c, operation_id) do
    Arbor.Voice.audio_turn(
      c.secondary.agent_id,
      c.target,
      %{pcm: <<1, 2>>, sample_rate: 16_000, channels: 1, sample_format: :s16le},
      operation_id: operation_id,
      utterance_ended_at: DateTime.utc_now()
    )
  end

  defp voice_opts(c, events, kind \\ :local) do
    on_exit(fn -> Arbor.Voice.stop_session({c.secondary.agent_id, c.target}) end)
    {:ok, _ledger} = Arbor.Voice.Test.SessionFakes.FakeLedger.start()
    script = start_supervised!({Agent, fn -> events end})
    observer = self()

    base = [
      session_token: c.voice_token,
      ledger: Arbor.Voice.Test.SessionFakes.FakeLedger,
      backend: Backend,
      backend_opts: [observer: observer, script: script],
      session_budget_ms: 60_000,
      daily_budget_ms: 120_000,
      speech_output: fn text ->
        send(observer, {:voice_spoken, text})
        :ok
      end,
      resource_owner_opts: [close_timeout_ms: 5_000]
    ]

    opts =
      if kind == :cloud do
        Keyword.merge(base,
          backend: Arbor.Voice.Backend.XaiRealtime,
          backend_opts: [
            transport: WireTransport,
            transport_opts: [observer: observer, script: script],
            oauth_resolver: fn :xai -> {:ok, "scripted-provider-token"} end
          ]
        )
      else
        base
      end

    {opts, script}
  end

  defp send_agent(c, text) do
    message = Arbor.Contracts.Session.UserMessage.from_dashboard(text, c.primary.agent_id)
    Arbor.Agent.send_message(c.primary.agent_id, c.target, message, session_token: c.token)
  end

  defp terminal_event(:local), do: {:turn_done, %{text: "blocked-private-answer"}}

  defp terminal_event(:cloud),
    do: %{"type" => "response.output_text.delta", "delta" => "blocked-private-answer"}

  defp terminal_tail(:local), do: []
  defp terminal_tail(:cloud), do: [%{"type" => "response.done"}]

  defp await_expired(token, attempts \\ 150)
  defp await_expired(_, 0), do: flunk("real session token did not expire")

  defp await_expired(token, attempts) do
    case SessionToken.verify(token) do
      {:error, :token_expired} ->
        :ok

      {:ok, _} ->
        Process.sleep(20)
        await_expired(token, attempts - 1)

      other ->
        flunk("unexpected token verification: #{inspect(other)}")
    end
  end

  defp human! do
    fixture =
      OIDCTestHelper.issue_identity(subject: "entrypoint-#{System.unique_integer([:positive])}")

    :ok = Security.register_oidc_identity(fixture.identity, fixture.id_token, fixture.provider)

    on_exit(fn ->
      Security.deregister_identity(fixture.identity.agent_id)
      fixture.cleanup.()
    end)

    fixture.identity
  end

  defp grant!(principal, resource) do
    {:ok, cap} = Security.grant(principal: principal, resource: resource)
    on_exit(fn -> Security.revoke(cap.id) end)
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
