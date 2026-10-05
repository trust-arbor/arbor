Code.require_file(
  Path.expand("../../../../arbor_security/test/support/oidc_test_helper.ex", __DIR__)
)

defmodule Arbor.Agent.SessionCreationSQLContentionJourneyTest do
  use ExUnit.Case, async: false
  alias Arbor.Agent.SessionManager
  alias Arbor.Contracts.Security.{Identity, SignedRequest}
  alias Arbor.Orchestrator.Session
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Test.SessionCreationContentionFixture, as: Contention
  alias Arbor.Security
  alias Arbor.Security.{OIDCTestHelper, SessionToken}
  @moduletag :integration
  @moduletag :database
  @moduletag :isolated_repo
  @turn_dot Path.expand(
              "../../../../arbor_orchestrator/specs/pipelines/session/turn.dot",
              __DIR__
            )
  @migrations Path.expand("../../../../arbor_persistence/priv/repo/migrations", __DIR__)

  defmodule OfflineProvider do
    def provider, do: "lm_studio"
    def runtime_contract, do: %Arbor.Contracts.AI.RuntimeContract{}

    def complete(request, _opts) do
      observer = Application.fetch_env!(:arbor_orchestrator, :session_sql_observer)
      send(observer, {:actual_engine_model, self(), List.last(request.messages).content})

      receive do
        :release_model -> :ok
      after
        15_000 -> raise "actual Engine model barrier missing"
      end

      {:ok,
       %Arbor.LLM.Response{
         text: "Persisted response.",
         finish_reason: :stop,
         content_parts: [Arbor.LLM.ContentPart.text("Persisted response.")],
         usage: %{input_tokens: 3, output_tokens: 2, total_tokens: 5},
         raw: %{}
       }}
    end

    def complete_single_attempt(request, opts), do: complete(request, opts)
  end

  setup_all do
    assert Process.whereis(Repo) == nil,
           "Run this SQL journey separately with --include isolated_repo."

    root =
      Path.join(System.tmp_dir!(), "session-sql-journey-#{System.unique_integer([:positive])}")

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
    Contention.start_peers!(database)

    set_env(:arbor_historian, :durable_event_log_target, %{
      name: :historian_durable_event_log,
      backend: Arbor.Persistence.EventLog.Ecto,
      opts: [repo: Repo]
    })

    assert Process.whereis(Arbor.Historian.AuthorityAuditPuller) == nil
    start_supervised!({Arbor.Historian.AuthorityAuditPuller, poll_interval_ms: 25})

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
            collection: "session_sql_aliases"}}
        ] do
      if Process.whereis(name) == nil,
        do: start_supervised!(Supervisor.child_spec(child, id: name))
    end

    :ok
  end

  setup context do
    for {app, key, value} <- [
          {:arbor_security, :identity_verification, true},
          {:arbor_security, :capability_signing_required, true},
          {:arbor_security, :strict_identity_mode, false},
          {:arbor_security, :identity_alias_resolver, Arbor.Agent.IdentityAliasResolver},
          {:arbor_security, :session_token_secret, :crypto.strong_rand_bytes(32)},
          {:arbor_orchestrator, :private_conversation_memory, false},
          {:arbor_orchestrator, :preprocessor_enabled, false},
          {:arbor_orchestrator, :session_sql_observer, self()},
          {:arbor_comms, :conversation_journal,
           [
             backend: Arbor.Persistence.EventLog.Ecto,
             name: :conversation_journal,
             opts: [repo: Repo]
           ]}
        ],
        do: set_env(app, key, value)

    previous = Arbor.LLM.Client.default_client()

    Arbor.LLM.Client.set_default_client(
      Arbor.LLM.Client.new(default_provider: "lm_studio")
      |> Arbor.LLM.Client.register_adapter(OfflineProvider)
    )

    on_exit(fn -> Arbor.LLM.Client.set_default_client(previous) end)

    fixture =
      OIDCTestHelper.issue_identity(subject: "sql-journey-#{System.unique_integer([:positive])}")

    :ok = Security.register_oidc_identity(fixture.identity, fixture.id_token, fixture.provider)

    on_exit(fn ->
      Security.deregister_identity(fixture.identity.agent_id)
      fixture.cleanup.()
    end)

    human = fixture.identity
    {:ok, agent} = Identity.generate(name: "Signed Session SQL journey")
    :ok = Security.register_identity(Identity.public_only(agent))
    on_exit(fn -> Security.deregister_identity(agent.agent_id) end)

    for {principal, uri} <-
          [{human.agent_id, "arbor://chat/agent/" <> agent.agent_id}] ++
            Enum.map(
              [
                "arbor://orchestrator/execute",
                "arbor://orchestrator/execute/llm_query",
                "arbor://orchestrator/execute/transform",
                "arbor://orchestrator/execute/unknown",
                "arbor://memory/read/" <> agent.agent_id,
                "arbor://memory/write/" <> agent.agent_id
              ],
              &{agent.agent_id, &1}
            ) do
      {:ok, cap} = Security.grant(principal: principal, resource: uri)
      on_exit(fn -> Security.revoke(cap.id) end)
    end

    {:ok, token} = SessionToken.generate(human.agent_id)
    observer = self()

    ensure = fn id, owner, opts ->
      {:links, [guard]} = Process.info(self(), :links)
      send(observer, {:actual_session_writer, self(), guard})

      if Map.get(context, :ensure_barrier, false) do
        receive do
          :release_ensure -> :ok
        after
          15_000 -> raise "ensure barrier missing"
        end
      end

      Arbor.Persistence.ensure_session(id, owner, opts)
    end

    config = %{
      "llm_provider" => "lm_studio",
      "llm_model" => "sql-fixture",
      "stream" => false,
      "recover_session" => false,
      "tools" => []
    }

    config =
      if context[:commit_timeout],
        do: Map.put(config, "turn_commit_timeout_ms", context.commit_timeout),
        else: config

    session_id = "agent-session-" <> agent.agent_id

    {:ok, session} =
      Session.start_link(
        session_id: session_id,
        agent_id: agent.agent_id,
        turn_dot: @turn_dot,
        start_heartbeat: false,
        signer: fn resource -> SignedRequest.sign(resource, agent.agent_id, agent.private_key) end,
        adapters: %{ensure_session: ensure},
        config: config
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
      :ets.insert(SessionManager, {agent.agent_id, session})
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

    {:ok, %{pending: 0}} = Arbor.Historian.flush_authority_audit()

    {:ok,
     caller: human.agent_id,
     target: agent.agent_id,
     token: token,
     session: session,
     session_id: session_id}
  end

  @tag ensure_barrier: true
  test "security regression actual signed Agent Session first commit retains default-deadline progress under native contention",
       c do
    assert {:ok, _} = submit(c, "first", "first creation")
    assert_receive {:actual_engine_model, model, "first creation"}, 5_000

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM sessions WHERE session_id = ?", [c.session_id])

    writer = Contention.hold_writer!()
    handler = Contention.observe_lookups!()
    send(model, :release_model)
    assert_receive {:actual_session_writer, session_writer, _guard}, 5_000
    send(session_writer, :release_ensure)
    assert_receive {:creation_lookup_complete, ^session_writer}, 5_000
    # The actual Session writer plus eleven public creators use twelve normal
    # connections across three pools; the pinned native IO worker count is ten.
    creators = Contention.start_creators!(handler: handler, canonical_count: 3)
    result = Contention.release_after_lookups!(writer, creators, 9)
    command = terminal!(c, "first")
    history = history!(c)

    IO.puts(
      "SESSION_FIRST_COMMIT=" <>
        Jason.encode!(%{
          command_status: command.status,
          transcript_entries: length(history),
          creator_successes: Enum.count(result.results, &match?({:ok, _}, &1)),
          creator_total: length(result.results),
          writer_release_ms: result.writer_release_ms
        })
    )

    assert %{status: :completed} = command
    assert Enum.all?(result.results, &match?({:ok, _}, &1))
    assert result.writer_release_ms < 5_000

    assert history |> Enum.map(&{&1.role, &1.content, &1.entry_ordinal}) ==
             [{"user", "first creation", 1}, {"assistant", "Persisted response.", 2}]

    refute_receive {:actual_engine_model, _, _}, 100
  end

  @tag commit_timeout: 150
  test "actual guard cancels a deadline-expired SQL writer and never publishes its transcript later",
       c do
    assert {:ok, _} = submit(c, "expired", "expired creation")
    assert_receive {:actual_engine_model, model, "expired creation"}, 5_000
    writer = Contention.hold_writer!()
    send(model, :release_model)
    assert_receive {:actual_session_writer, session_writer, guard}, 5_000
    writer_monitor = Process.monitor(session_writer)
    guard_monitor = Process.monitor(guard)
    # Observe production-owned termination, without a fixture kill.
    assert_receive {:DOWN, ^writer_monitor, :process, ^session_writer, _}, 7_000
    assert_receive {:DOWN, ^guard_monitor, :process, ^guard, _}, 7_000
    send(writer.pid, :release)
    assert {:ok, :ok} = Task.await(writer, 5_000)
    assert %{status: :uncertain} = terminal!(c, "expired")
    assert history!(c) == []
    refute Session.get_state(c.session).turn_in_flight
    assert {:ok, _} = submit(c, "fresh", "fresh explicit creation")
    assert_receive {:actual_engine_model, fresh_model, "fresh explicit creation"}, 5_000
    send(fresh_model, :release_model)
    assert %{status: :completed} = terminal!(c, "fresh")

    assert history!(c) |> Enum.map(&{&1.role, &1.content, &1.entry_ordinal}) ==
             [{"user", "fresh explicit creation", 1}, {"assistant", "Persisted response.", 2}]

    assert %{status: :uncertain} = terminal!(c, "expired")
  end

  defp submit(c, id, text),
    do:
      Arbor.Agent.submit_conversation_command(c.caller, c.target, %{id: id, text: text},
        session_token: c.token
      )

  defp terminal!(c, id, attempts \\ 600)
  defp terminal!(_, _, 0), do: flunk("public command never settled")

  defp terminal!(c, id, attempts) do
    case Arbor.Agent.conversation_command(c.caller, c.target, id, session_token: c.token) do
      {:ok, %{status: status} = result} when status in [:completed, :uncertain] ->
        result

      {:ok, %{status: status}} when status in [:admitted, :dispatch_started] ->
        Process.sleep(20)
        terminal!(c, id, attempts - 1)

      other ->
        flunk("unexpected public command: #{inspect(other)}")
    end
  end

  defp history!(c) do
    assert {:ok, %{entries: entries}} =
             Arbor.Agent.conversation_history(c.caller, c.target, session_token: c.token)

    entries
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
