# Runs alone from the umbrella with --include isolated_repo. All identities,
# profiles, SQL stores, signing keys and supervised targets belong to this fixture.
# Parent Router performs actual Ed25519 verification; Agent authorization and
# lifecycle effects are real. Only cognition is disabled in the start adapter.
defmodule Arbor.Gateway.Chat.SignedManagementJourneyTest.PrivateStart do
  def list_agents, do: Arbor.Agent.Lifecycle.list_agents()

  def start(id, opts) do
    Arbor.Agent.Lifecycle.start(
      id,
      opts ++
        [
          start_session: false,
          start_heartbeat: false,
          recover_session: false,
          task_store: Application.fetch_env!(:arbor_gateway, :signed_management_fixture_store)
        ]
    )
  end
end

defmodule Arbor.Gateway.Chat.SignedManagementJourneyTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias Arbor.Agent, as: Agents
  alias Arbor.Agent.Test.{ManagementSessionFixture, RuntimeAdmissionTopology, TrustTopology}
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Gateway.Chat.LifecycleAuthority
  alias Arbor.Gateway.Router
  alias Arbor.Security
  alias Arbor.Security.TestSupport.ApprovalAnswerFixture, as: Grants
  @moduletag :integration
  @moduletag :database
  @moduletag :isolated_repo

  setup_all do
    fixture = ManagementSessionFixture.initialize!()
    TrustTopology.ensure_owned!()

    if Process.whereis(Arbor.Agent.UserSupervisor) == nil,
      do: start_supervised!(Arbor.Agent.UserSupervisor)

    if Process.whereis(:arbor_user_config) == nil do
      start_supervised!(
        {Arbor.Persistence.BufferedStore,
         name: :arbor_user_config,
         backend: Arbor.Security.Store.JSONFile,
         write_mode: :sync,
         ack_mode: :backend,
         backend_opts: [base_dir: Path.join(fixture.root, "aliases")],
         collection: "aliases"}
      )
    end

    fixture
  end

  setup %{root: root} do
    human = ManagementSessionFixture.setup!(root)
    topology = RuntimeAdmissionTopology.start_owned!()

    for {key, value} <- [
          api_key: "private-fixture-no-bearer-auth",
          chat_agent_facade: Agents,
          chat_security: Security,
          chat_agent_manager: Arbor.Agent.Manager,
          chat_lifecycle: __MODULE__.PrivateStart,
          chat_template_store: Arbor.Agent.TemplateStore,
          chat_user_config: Arbor.Agent.UserConfig,
          signed_management_fixture_store: topology.store
        ],
        do: ManagementSessionFixture.set_env(:arbor_gateway, key, value)

    {:ok, identity} = Security.generate_identity()
    assert :ok = Security.register_identity_fixture(identity)

    # Create opens this stored key from the supervised lifecycle owner.
    # Registration alone does not deposit the private key.
    assert :ok = Security.store_signing_key_fixture(identity.agent_id, identity.private_key)

    on_exit(fn ->
      assert :ok = Security.delete_signing_key_fixture(identity.agent_id)
      assert :ok = Security.deregister_identity_fixture(identity.agent_id)
    end)

    template = "signed-private-#{System.unique_integer([:positive])}"
    Arbor.Agent.TemplateStore.set_templates_dir(Path.join(root, "templates"))

    assert :ok =
             Agents.put_template(template, %{
               "name" => template,
               "character" => %{"name" => "Private signed fixture"},
               "required_capabilities" => [],
               "tools" => []
             })

    on_exit(fn ->
      Arbor.Agent.TemplateStore.set_templates_dir(Path.join(root, "templates"))
      Agents.delete_template(template)
      Arbor.Agent.TemplateStore.clear_templates_dir_override()
    end)

    %{identity: identity, template: template, human_id: human.human_id}
  end

  test "public signed directory resolution and aliases stay scoped to the exact signing principal",
       ctx do
    a = ManagementSessionFixture.target!()
    b = ManagementSessionFixture.target!()
    cap = Grants.grant!(ctx.identity.agent_id, "arbor://chat/agent/" <> a.target)
    first = request(ctx.identity, "GET", "/api/chat/agents")
    assert first.status == 200
    assert %{"agents" => [%{"agent_id" => id}]} = Jason.decode!(first.resp_body)
    assert id == a.target
    conn = request(ctx.identity, "POST", "/api/chat/aliases", %{name: "cedar", target: a.target})
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"name" => "cedar", "agent_id" => a.target}
    assert request(ctx.identity, "GET", "/api/chat/agents/resolve/cedar").status == 200
    assert request(ctx.identity, "GET", "/api/chat/agents/resolve/" <> b.target).status == 404
    assert request(ctx.identity, "GET", "/api/chat/aliases").status == 200
    assert request(ctx.identity, "DELETE", "/api/chat/aliases/cedar").status == 200
    assert request(ctx.identity, "GET", "/api/chat/agents/resolve/cedar").status == 404
    assert :ok = Security.revoke_fixture(cap.id)

    assert Jason.decode!(request(ctx.identity, "GET", "/api/chat/agents").resp_body) == %{
             "agents" => []
           }

    ManagementSessionFixture.preserved!(a)
    ManagementSessionFixture.preserved!(b)
  end

  test "security regression: raw callers cannot run callbacks inside lifecycle authority", ctx do
    assert {:error, :capability_mutation_unauthorized} =
             GenServer.call(
               LifecycleAuthority,
               {:with_principal, ctx.identity.agent_id, fn _authority -> :callback_executed end}
             )
  end

  test "security regression: full Router verifies method path body and nonce before exact stop capability and actual effect",
       ctx do
    a = ManagementSessionFixture.target!()
    b = ManagementSessionFixture.target!()
    Grants.grant!(ctx.identity.agent_id, "arbor://chat/agent/" <> a.target)
    path = "/api/chat/agents/" <> a.target <> "/stop"
    {denied, effects} = observe(fn -> request(ctx.identity, "POST", path, %{}) end)
    assert denied.status == 403
    assert effects == []
    ManagementSessionFixture.preserved!(a)

    pending =
      Grants.grant!(ctx.identity.agent_id, "arbor://agent/stop/" <> a.target,
        constraints: %{requires_approval: true}
      )

    {denied, effects} = observe(fn -> request(ctx.identity, "POST", path, %{}) end)
    assert denied.status == 403
    assert Jason.decode!(denied.resp_body)["error"] =~ "approval required"
    assert effects == []
    assert :ok = Security.revoke_fixture(pending.id)
    stop = Grants.grant!(ctx.identity.agent_id, "arbor://agent/stop/" <> a.target)

    {wrong, effects} =
      observe(fn ->
        request(ctx.identity, "POST", "/api/chat/agents/" <> b.target <> "/stop", %{})
      end)

    assert wrong.status == 403
    assert effects == []
    header = signed_header(ctx.identity, "POST", path, "{}")

    for {method, target, body} <- [
          {"GET", path, "{}"},
          {"POST", path <> "x", "{}"},
          {"POST", path, "{\"changed\":true}"}
        ] do
      conn = raw_request(method, target, body, header)
      assert conn.status == 401
      ManagementSessionFixture.preserved!(a)
    end

    Grants.grant!(ctx.human_id, "arbor://agent/stop/" <> a.target)
    {:ok, chat_token} = Security.issue_conversation_session_fixture(ctx.human_id, a.target)
    assert raw_request("POST", path, "{}", "Conversation " <> chat_token).status == 401
    assert :ok = Security.revoke_fixture(stop.id)
    {revoked, effects} = observe(fn -> request(ctx.identity, "POST", path, %{}) end)
    assert revoked.status == 403
    assert effects == []
    Grants.grant!(ctx.identity.agent_id, "arbor://agent/stop/" <> a.target)
    fresh = signed_header(ctx.identity, "POST", path, "{}")
    {ok, effects} = observe(fn -> raw_request("POST", path, "{}", fresh) end)
    assert ok.status == 200
    assert effects == [{:stop, a.target}]
    assert Jason.decode!(ok.resp_body) == %{"agent_id" => a.target, "running" => false}
    refute Process.alive?(a.pid)
    replay = raw_request("POST", path, "{}", fresh)
    assert replay.status == 401
    ManagementSessionFixture.preserved!(b)
  end

  test "public signed create and start use their independent gates and real private lifecycle effects",
       ctx do
    body = %{
      template: ctx.template,
      name: "Signed new private fixture",
      model: "sealed-no-provider"
    }

    before = MapSet.new(Arbor.Agent.Lifecycle.list_agents(), & &1.agent_id)
    assert request(ctx.identity, "POST", "/api/chat/agents", body).status == 403
    assert MapSet.new(Arbor.Agent.Lifecycle.list_agents(), & &1.agent_id) == before

    pending =
      Grants.grant!(ctx.identity.agent_id, "arbor://agent/lifecycle/create",
        constraints: %{requires_approval: true}
      )

    refused = request(ctx.identity, "POST", "/api/chat/agents", body)
    assert refused.status == 403
    assert Jason.decode!(refused.resp_body)["error"] =~ "approval required"
    assert MapSet.new(Arbor.Agent.Lifecycle.list_agents(), & &1.agent_id) == before
    assert :ok = Security.revoke_fixture(pending.id)
    Grants.grant!(ctx.identity.agent_id, "arbor://agent/lifecycle/create")

    # Creating an agent registers and endorses a new identity. The lifecycle
    # capability alone does not authorize those security mutations.
    for resource <- [
          "arbor://security/identity/register",
          "arbor://security/identity/endorse/**",
          "arbor://security/grant/**",
          "arbor://security/revoke/**",
          "arbor://security/identity/deregister/**"
        ] do
      Grants.grant!(ctx.identity.agent_id, resource)
    end

    created = request(ctx.identity, "POST", "/api/chat/agents", body)
    assert created.status == 200, created.resp_body
    assert %{"agent_id" => id, "running" => true} = Jason.decode!(created.resp_body)
    on_exit(fn -> Agents.destroy_agent(id) end)
    assert {:ok, profile} = Agents.load_profile(id)
    assert profile.display_name == "Signed new private fixture"
    pids = Arbor.Agent.BranchSupervisor.child_pids(id)
    assert is_pid(pids.host) and is_pid(pids.executor)
    assert is_nil(pids.session) and is_nil(pids.heartbeat_service)
    assert :ok = Agents.stop(id)
    path = "/api/chat/agents/" <> id <> "/start"
    assert request(ctx.identity, "POST", path, %{}).status == 403
    assert {:error, :not_found} = Arbor.Agent.Registry.whereis(id)
    Grants.grant!(ctx.identity.agent_id, "arbor://agent/lifecycle/restore")
    started = request(ctx.identity, "POST", path, %{})
    assert started.status == 200, started.resp_body
    assert Jason.decode!(started.resp_body) == %{"agent_id" => id, "running" => true}
    assert {:ok, pid} = Arbor.Agent.Registry.whereis(id)
    assert Process.alive?(pid)
    assert :ok = Agents.stop(id)
  end

  defp observe(fun), do: ManagementSessionFixture.observe!(self(), fun)

  defp request(identity, method, path, value \\ "") do
    body = if is_binary(value), do: value, else: Jason.encode!(value)
    raw_request(method, path, body, signed_header(identity, method, path, body))
  end

  defp raw_request(method, path, body, header) do
    Process.delete(:arbor_authenticated_agent_id)

    method
    |> conn(path, body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", header)
    |> Router.call(Router.init([]))
  end

  defp signed_header(identity, method, path, body) do
    {:ok, signed} =
      SignedRequest.sign(
        method <> "\n" <> path <> "\n" <> body,
        identity.agent_id,
        identity.private_key
      )

    envelope = %{
      agent_id: signed.agent_id,
      timestamp: DateTime.to_iso8601(signed.timestamp),
      nonce: Base.encode64(signed.nonce),
      signature: Base.encode64(signed.signature)
    }

    "Signature " <> Base.encode64(Jason.encode!(envelope), padding: false)
  end
end
