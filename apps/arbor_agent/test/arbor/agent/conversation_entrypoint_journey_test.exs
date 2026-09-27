Code.require_file(
  Path.expand("../../../../arbor_security/test/support/oidc_test_helper.ex", __DIR__)
)

defmodule Arbor.Agent.ConversationEntrypointJourneyTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.{IdentityAliases, IdentityAliasProof, SessionManager}
  alias Arbor.Contracts.Security.{Identity, SignedRequest}
  alias Arbor.Dashboard.Live.ChatLive
  alias Arbor.Dashboard.Live.ChatLive.Conversation
  alias Arbor.Gateway.Chat.Socket, as: GatewaySocket
  alias Arbor.Orchestrator.Session
  alias Arbor.Persistence.Repo
  alias Arbor.Security
  alias Arbor.Security.{OIDCTestHelper, SessionToken}
  import Phoenix.Component, only: [assign: 2]

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

    for {name, child} <- [
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
     session: session,
     session_id: session_id,
     counter: counter,
     primary_cap: primary_cap,
     secondary_cap: secondary_cap}
  end

  test "web token and linked signed terminal share durable history and the next real model context",
       c do
    web = web_socket(c) |> Conversation.connect()
    assert web.assigns.conversation_authorized
    engagement = web.assigns.conversation_engagement_id
    web = Conversation.submit(web, "web sentinel LARCH-217", "web-first")
    assert web.assigns.conversation_status in [:admitted, :dispatch_started, :completed]
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

    web = Conversation.refresh(web)
    assert web.assigns.conversation_history_cursor == 4
    assert web.assigns.conversation_journal_cursor == 6
    assert inspect(web.assigns.streams.messages.inserts) =~ "CEDAR-842"
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

  test "security regression: unlink and revocation prevent old-content release or pending redirection",
       c do
    web =
      web_socket(c)
      |> Conversation.connect()
      |> Conversation.submit("private prior owner", "prior-owner")

    completed!(c, "prior-owner")
    web = Conversation.refresh(web)
    assert inspect(web.assigns.streams.messages.inserts) =~ "private prior owner"
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
    assert :ok = Security.revoke(c.secondary_cap.id)

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
    assert :ok = Security.revoke(c.primary_cap.id)
    cleared = Conversation.refresh(web)
    refute cleared.assigns.conversation_authorized
    assert cleared.assigns.streams.messages.inserts == []
    assert cleared.assigns.streams.messages.reset?

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
      Arbor.Dashboard.Live.ChatLive.Conversation
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
      browser: "production ChatLive",
      terminal: "production WSClient + App reducer"
    }

    File.write!("/private/tmp/convergence-transport-host-result.json", Jason.encode!(result))
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

  defp web_socket(c) do
    socket = %Phoenix.LiveView.Socket{
      endpoint: Arbor.Dashboard.Endpoint,
      view: ChatLive,
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}},
      assigns: %{__changed__: %{}, current_agent_id: c.primary.agent_id, session_token: c.token}
    }

    {:ok, socket} = ChatLive.mount(%{}, %{}, socket)
    assign(socket, agent_id: c.target, agent_host_pid: c.session, input: "")
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
