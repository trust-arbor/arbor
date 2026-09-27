Code.require_file(
  Path.expand("../../../../../arbor_security/test/support/oidc_test_helper.ex", __DIR__)
)

defmodule Arbor.Orchestrator.Session.TranscriptFreshnessSecurityRegressionTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias Arbor.Contracts.Security.{Identity, SignedRequest}
  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.Orchestrator.Session
  alias Arbor.Persistence.Repo
  alias Arbor.Security

  @moduletag :integration
  @moduletag :database
  @moduletag :isolated_repo
  @migrations Path.expand("../../../../../arbor_persistence/priv/repo/migrations", __DIR__)

  defmodule Capture do
    def provider, do: "lm_studio"

    def complete(request, _opts) do
      observer = Application.fetch_env!(:arbor_orchestrator, :_freshness_observer)
      send(observer, {:model_request, request.messages, self()})

      if Application.get_env(:arbor_orchestrator, :_freshness_block_model, false) do
        receive do
          :release_model -> :ok
        after
          10_000 -> raise "model barrier timeout"
        end
      end

      text = Application.get_env(:arbor_orchestrator, :_freshness_response, "acknowledged answer")
      {:ok, %Arbor.LLM.Response{text: text, finish_reason: :stop, raw: %{}}}
    end

    def complete_single_attempt(request, opts), do: complete(request, opts)
  end

  defmodule Compactor do
    defstruct messages: [], appends: 0, compactions: 0, generation: nil, projection: nil
    def new(_opts), do: %__MODULE__{generation: make_ref()}

    def append(state, message) do
      if observer = Application.get_env(:arbor_orchestrator, :_freshness_compactor_observer),
        do: send(observer, :compactor_invoked)

      %{
        state
        | messages: state.messages ++ [message],
          appends: state.appends + 1,
          projection: if(state.projection, do: state.projection ++ [message])
      }
    end

    def maybe_compact(state) do
      if observer = Application.get_env(:arbor_orchestrator, :_freshness_compactor_observer),
        do: send(observer, :compactor_invoked)

      %{state | compactions: state.compactions + 1}
    end

    def llm_messages(state), do: state.projection || state.messages
    def full_transcript(state), do: state.messages
    def stats(_state), do: %{}
  end

  defmodule OwnerResolver do
    def resolve(id) do
      case Application.get_env(:arbor_orchestrator, :_freshness_aliases, %{}) do
        aliases when is_map(aliases) -> {:ok, Map.get(aliases, id, id)}
        _ -> {:error, :unavailable}
      end
    end
  end

  setup_all do
    assert Process.whereis(Repo) == nil, "run standalone with a private SQLite Repo"
    root = Path.join(System.tmp_dir!(), "freshness_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    start_supervised!(
      {Repo,
       database: Path.join(root, "test.sqlite3"),
       pool: DBConnection.ConnectionPool,
       pool_size: 4,
       busy_timeout: 5_000,
       journal_mode: :wal}
    )

    Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)

    if Process.whereis(Arbor.Orchestrator.EventRegistry) == nil,
      do: start_supervised!({Registry, keys: :duplicate, name: Arbor.Orchestrator.EventRegistry})

    if Process.whereis(Arbor.Comms.EngagementStore) == nil,
      do: start_supervised!(Arbor.Comms.EngagementStore)

    path = Path.join(root, "turn.dot")

    File.write!(path, """
    digraph Freshness {
      start [shape=Mdiamond]
      call [type="compute", simulate="false", prompt="Reply to the user", use_tools="false", messages_context_key="session.messages"]
      copy [type="transform", transform="identity", source_key="last_response", output_key="session.response"]
      done [shape=Msquare]
      start -> call -> copy -> done
    }
    """)

    on_exit(fn -> File.rm_rf!(root) end)
    %{path: path}
  end

  setup ctx do
    for {app, key, value} <- [
          {:arbor_security, :identity_verification, true},
          {:arbor_security, :identity_alias_resolver, OwnerResolver},
          {:arbor_orchestrator, :_freshness_aliases, %{}},
          {:arbor_security, :policy_enforcer_enabled, false},
          {:arbor_security, :approval_guard_enabled, false},
          {:arbor_security, :reflex_checking_enabled, false},
          {:arbor_security, :uri_registry_enforcement, false},
          {:arbor_trust, :policy_enforcer_enabled, false},
          {:arbor_orchestrator, :private_conversation_memory, false},
          {:arbor_orchestrator, :_freshness_observer, self()},
          {:arbor_orchestrator, :_freshness_block_model, false},
          {:arbor_orchestrator, :_freshness_response, "acknowledged answer"},
          {:arbor_orchestrator, :_freshness_compactor_observer, nil}
        ],
        do: set_env(app, key, value)

    old_client = Arbor.LLM.Client.default_client()

    Arbor.LLM.Client.set_default_client(
      Arbor.LLM.Client.new(default_provider: "lm_studio")
      |> Arbor.LLM.Client.register_adapter(Capture)
    )

    on_exit(fn -> Arbor.LLM.Client.set_default_client(old_client) end)
    {:ok, agent} = Identity.generate()
    :ok = Security.register_identity(Identity.public_only(agent))
    on_exit(fn -> Security.deregister_identity(agent.agent_id) end)

    for resource <- [
          "arbor://orchestrator/execute",
          "arbor://orchestrator/execute/llm_query",
          "arbor://orchestrator/execute/transform"
        ] do
      {:ok, cap} = Security.grant(principal: agent.agent_id, resource: resource)
      on_exit(fn -> Security.revoke(cap.id) end)
    end

    owner = owner!(agent)
    %{agent: agent, owner: owner, path: ctx.path, session_id: "agent-session-#{agent.agent_id}"}
  end

  test "security regression live authenticated prompt incorporates acknowledged voice pair without restart or duplicates",
       ctx do
    session = start_session!(ctx)
    assert {:ok, _} = turn(session, ctx.owner, "web first")
    assert_receive {:model_request, _, _}
    first = Session.get_state(session)
    record_voice!(ctx, ctx.owner, "spoken sentinel")
    assert {:ok, _} = turn(session, ctx.owner, "web second")
    assert_receive {:model_request, prompt, _}
    assert count_text(prompt, "spoken sentinel") == 1
    assert count_text(prompt, "web first") == 1
    state = Session.get_state(session)
    assert state.compactor.generation == first.compactor.generation
    assert state.session_state.messages == state.messages
    voice = Enum.find(state.messages, &(inspect(&1["content"]) =~ "spoken sentinel"))
    assert voice["metadata"]["transport"] == "voice"
    assert voice["taint_status"] == :verified
    assert is_list(voice["content"])
    assert {:ok, _} = turn(session, ctx.owner, "web third")
    assert_receive {:model_request, third, _}
    assert count_text(third, "spoken sentinel") == 1
    assert count_text(third, "web second") == 1
    assert Session.get_state(session).compactor.appends == 8
    assert Session.get_state(session).compactor.compactions == 3
  end

  test "identical text is preserved as distinct durable messages", ctx do
    session = start_session!(ctx)
    assert {:ok, _} = turn(session, ctx.owner, "identical")
    assert_receive {:model_request, _, _}
    record_voice!(ctx, ctx.owner, "identical")
    assert {:ok, _} = turn(session, ctx.owner, "identical")
    assert_receive {:model_request, prompt, _}
    assert count_text(prompt, "identical") == 3
    messages = Session.get_state(session).messages
    ids = Enum.map(messages, & &1["id"])
    assert length(Enum.uniq(ids)) == length(ids)
  end

  test "own-only reconciliation preserves the current compacted summary byte for byte", ctx do
    session = start_session!(ctx)
    assert {:ok, _} = turn(session, ctx.owner, "summarized old detail")
    assert_receive {:model_request, _, _}
    summary = %{"role" => "system", "content" => "Exact summary\nwith spacing  retained."}

    :sys.replace_state(session, fn state ->
      %{state | compactor: %{state.compactor | projection: [summary]}}
    end)

    before = Session.get_state(session).compactor
    assert {:ok, _} = turn(session, ctx.owner, "new detail")
    assert_receive {:model_request, prompt, _}
    assert inspect(prompt) =~ "Exact summary"
    refute inspect(prompt) =~ "summarized old detail"
    after_compactor = Session.get_state(session).compactor
    assert hd(after_compactor.projection) == summary
    assert after_compactor.generation == before.generation
    assert after_compactor.appends == before.appends + 2
    assert after_compactor.compactions == before.compactions + 1
  end

  test "acknowledged empty assistant pair retains the absent live projection on reconciliation",
       ctx do
    session = start_session!(ctx)
    Application.put_env(:arbor_orchestrator, :_freshness_response, "")
    assert {:ok, _} = turn(session, ctx.owner, "empty response request")
    assert_receive {:model_request, _, _}
    assert [%{"role" => "user"}] = Session.get_state(session).messages
    Application.put_env(:arbor_orchestrator, :_freshness_response, "acknowledged answer")
    record_voice!(ctx, ctx.owner, "after empty")
    assert {:ok, _} = turn(session, ctx.owner, "continue")
    assert_receive {:model_request, prompt, _}
    assert count_text(prompt, "empty response request") == 1
    assert count_text(prompt, "after empty") == 1
    assert length(Session.get_state(session).messages) == 5
  end

  test "source outage preserves cached transcript and can recover on the next admitted turn",
       ctx do
    switch = start_supervised!({Agent, fn -> :available end})

    reader = fn session, agent, engagement, opts ->
      previous =
        if Agent.get(switch, & &1) == :offline,
          do: Repo.put_dynamic_repo(:offline_freshness_repo),
          else: nil

      try do
        Arbor.Persistence.read_session_transcript(session, agent, engagement, opts)
      after
        if previous, do: Repo.put_dynamic_repo(previous)
      end
    end

    session = start_session!(ctx, %{read_session_transcript: reader})
    assert {:ok, _} = turn(session, ctx.owner, "keep this")
    assert_receive {:model_request, _, _}
    before = Session.get_state(session)
    Agent.update(switch, fn _ -> :offline end)
    assert {:error, :transcript_unavailable} = turn(session, ctx.owner, "unavailable")
    refute_receive {:model_request, _, _}, 50
    assert Session.get_state(session).messages == before.messages
    assert Session.get_state(session).compactor == before.compactor
    Agent.update(switch, fn _ -> :available end)
    record_voice!(ctx, ctx.owner, "after outage")
    assert {:ok, _} = turn(session, ctx.owner, "recover")
    assert_receive {:model_request, prompt, _}
    assert count_text(prompt, "after outage") == 1
  end

  test "stashed engagement catches up and never incorporates another owner's rows", ctx do
    session = start_session!(ctx)
    other = owner!(ctx.agent)
    assert {:ok, _} = turn(session, ctx.owner, "owner one")
    assert_receive {:model_request, _, _}
    first = Session.get_state(session)
    assert {:ok, _} = turn(session, other, "foreign secret")
    assert_receive {:model_request, foreign_prompt, _}
    refute inspect(foreign_prompt) =~ "owner one"
    record_voice!(ctx, ctx.owner, "stashed voice")
    assert {:ok, _} = turn(session, ctx.owner, "back again")
    assert_receive {:model_request, prompt, _}
    assert count_text(prompt, "stashed voice") == 1
    refute inspect(prompt) =~ "foreign secret"
    assert Session.get_state(session).compactor.generation == first.compactor.generation
  end

  test "external pair committed before the local pair rebases only the unobserved suffix", ctx do
    session = start_session!(ctx)
    assert {:ok, _} = turn(session, ctx.owner, "prior anchor")
    assert_receive {:model_request, _, _}
    anchor = Session.get_state(session).compactor
    Application.put_env(:arbor_orchestrator, :_freshness_block_model, true)
    task = Task.async(fn -> turn(session, ctx.owner, "blocked local") end)
    assert_receive {:model_request, _, model}, 5_000
    record_voice!(ctx, ctx.owner, "interleaved voice")
    send(model, :release_model)
    assert {:ok, _} = Task.await(task, 15_000)
    Application.put_env(:arbor_orchestrator, :_freshness_block_model, false)
    assert {:ok, _} = turn(session, ctx.owner, "after interleave")
    assert_receive {:model_request, prompt, _}
    texts = Enum.map(prompt, &inspect/1)
    voice_position = Enum.find_index(texts, &String.contains?(&1, "interleaved voice"))
    local_position = Enum.find_index(texts, &String.contains?(&1, "blocked local"))
    assert voice_position < local_position
    assert count_text(prompt, "blocked local") == 1
    assert Session.get_state(session).compactor.generation == anchor.generation
    assert Session.get_state(session).compactor.appends == 8
  end

  test "security regression malformed durable row denies model admission and preserves cached transcript",
       ctx do
    session = start_session!(ctx)
    assert {:ok, _} = turn(session, ctx.owner, "retained history")
    assert_receive {:model_request, _, _}
    record_voice!(ctx, ctx.owner, "corrupt voice")
    before = Session.get_state(session)
    {:ok, persisted} = Arbor.Persistence.ensure_session(ctx.session_id, ctx.agent.agent_id)

    Repo.update_all(
      from(e in Arbor.Persistence.Schemas.SessionEntry,
        where: e.session_id == ^persisted.id and e.entry_ordinal == 3
      ),
      set: [metadata: %{"engagement_id" => ctx.owner.engagement.id, "taint" => %{"bad" => true}}]
    )

    assert {:error, :transcript_unavailable} = turn(session, ctx.owner, "must not run")
    refute_receive {:model_request, _, _}, 50
    after_state = Session.get_state(session)
    assert after_state.messages == before.messages
    assert after_state.compactor == before.compactor
    assert after_state.session_state.messages == before.session_state.messages
  end

  for denial <- [:revocation, :owner_change, :resolver_outage] do
    @denial denial
    test "security regression #{@denial} during source read prevents staged adoption", ctx do
      observer = self()

      reader = fn session, agent, engagement, opts ->
        result = Arbor.Persistence.read_session_transcript(session, agent, engagement, opts)

        if opts != [] do
          send(observer, {:read_blocked, self()})

          receive do
            :release_read -> :ok
          after
            5_000 -> raise "read timeout"
          end
        end

        result
      end

      session = start_session!(ctx, %{read_session_transcript: reader})
      assert {:ok, _} = turn(session, ctx.owner, "retained")
      assert_receive {:model_request, _, _}
      before = Session.get_state(session)
      record_voice!(ctx, ctx.owner, "must remain unpublished")
      Application.put_env(:arbor_orchestrator, :_freshness_compactor_observer, self())
      task = Task.async(fn -> turn(session, ctx.owner, "blocked read") end)
      assert_receive {:read_blocked, reader_pid}, 5_000

      case @denial do
        :revocation ->
          assert :ok = Security.revoke(ctx.owner.cap.id)

        :owner_change ->
          other = owner!(ctx.agent)

          Application.put_env(:arbor_orchestrator, :_freshness_aliases, %{
            ctx.owner.human.agent_id => other.human.agent_id
          })

        :resolver_outage ->
          Application.put_env(:arbor_orchestrator, :_freshness_aliases, :offline)
      end

      send(reader_pid, :release_read)
      assert {:error, :private_memory_admission_unavailable} = Task.await(task, 15_000)
      refute_receive {:model_request, _, _}, 50
      refute_receive :compactor_invoked, 50
      assert Session.get_state(session).messages == before.messages
      assert Session.get_state(session).compactor == before.compactor
    end
  end

  test "an oversized delta denies admission instead of silently skipping acknowledged entries",
       ctx do
    session = start_session!(ctx)
    assert {:ok, _} = turn(session, ctx.owner, "bounded anchor")
    assert_receive {:model_request, _, _}
    before = Session.get_state(session)
    {:ok, persisted} = Arbor.Persistence.ensure_session(ctx.session_id, ctx.agent.agent_id)

    entries =
      for index <- 1..1_001 do
        %{
          entry_type: "user",
          role: "user",
          content: [%{"type" => "text", "text" => "external #{index}"}],
          timestamp: DateTime.utc_now(),
          metadata: %{"engagement_id" => ctx.owner.engagement.id}
        }
      end

    assert {:ok, 1_001} = Arbor.Persistence.append_session_entries(persisted.id, entries)
    assert {:error, :transcript_unavailable} = turn(session, ctx.owner, "do not skip")
    refute_receive {:model_request, _, _}, 50
    assert Session.get_state(session).messages == before.messages
    assert Session.get_state(session).compactor == before.compactor
  end

  test "explicit checkpoint import retains content but cannot assert a durable freshness anchor",
       ctx do
    session = start_session!(ctx)
    assert {:ok, _} = turn(session, ctx.owner, "checkpoint content")
    assert_receive {:model_request, _, _}

    checkpoint =
      Arbor.Orchestrator.Session.Persistence.extract_checkpoint_data(Session.get_state(session))

    assert :ok = Session.restore_checkpoint(session, checkpoint)
    before = Session.get_state(session)
    assert {:error, :transcript_unavailable} = turn(session, ctx.owner, "unanchored continuation")
    refute_receive {:model_request, _, _}, 50
    assert Session.get_state(session).messages == before.messages
    assert inspect(before.messages) =~ "checkpoint content"
  end

  defp start_session!(ctx, adapters \\ %{}) do
    {:ok, session} =
      Session.start_link(
        session_id: ctx.session_id,
        agent_id: ctx.agent.agent_id,
        turn_dot: ctx.path,
        start_heartbeat: false,
        compactor: {Compactor, []},
        adapters: adapters,
        signer: fn resource ->
          SignedRequest.sign(resource, ctx.agent.agent_id, ctx.agent.private_key)
        end,
        config: %{
          "llm_provider" => "lm_studio",
          "llm_model" => "test",
          "stream" => false,
          "recover_session" => false
        }
      )

    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)
    session
  end

  defp owner!(agent) do
    fixture = Arbor.Security.OIDCTestHelper.issue_identity()
    :ok = Security.register_oidc_identity(fixture.identity, fixture.id_token, fixture.provider)
    human = fixture.identity

    {:ok, cap} =
      Security.grant(principal: human.agent_id, resource: "arbor://chat/agent/" <> agent.agent_id)

    {:ok, engagement} = Arbor.Comms.resolve_user_engagement(agent.agent_id, human.agent_id)

    on_exit(fn ->
      Security.revoke(cap.id)
      fixture.cleanup.()
      Security.deregister_identity(human.agent_id)
    end)

    %{human: human, agent: agent, cap: cap, engagement: engagement}
  end

  defp turn(session, owner, text) do
    resource = "arbor://chat/agent/" <> owner.agent.agent_id
    {:ok, signed} = SignedRequest.sign(resource, owner.human.agent_id, owner.human.private_key)

    {:ok, receipt} =
      Security.authorize_and_issue_delivery_receipt(owner.human.agent_id, resource, :chat,
        signed_request: signed,
        expected_resource: resource
      )

    Session.send_authenticated_message(
      session,
      UserMessage.from_voice(text, sender_id: owner.human.agent_id),
      receipt,
      15_000
    )
  end

  defp record_voice!(ctx, owner, text) do
    old = ~U[2020-01-01 00:00:00Z]

    assert {:ok, 2} =
             Arbor.Comms.record_engagement_turn(
               ctx.agent.agent_id,
               owner.engagement.id,
               %{content: text, sent_at: old, metadata: %{"transport" => "voice"}},
               %{content: "voice answer", completed_at: old, metadata: %{"transport" => "voice"}}
             )
  end

  defp count_text(messages, text), do: Enum.count(messages, &(inspect(&1) =~ text))

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
