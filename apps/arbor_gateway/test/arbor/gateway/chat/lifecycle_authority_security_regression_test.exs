# Full Router (real Ed25519 verification, nonce consumption, real Arbor.Agent
# authorization and real Lifecycle effects) for the chat lifecycle routes that
# need the human's `:agent_lifecycle` authority (decision 2026-10-08 D2). Only
# the start options are test-specific: a test-owned TaskStore and no cognition.
defmodule Arbor.Gateway.Chat.LifecycleAuthoritySecurityRegressionTest.PrivateStart do
  @moduledoc false
  def start(agent_id, opts), do: Arbor.Agent.Lifecycle.start(agent_id, opts ++ test_opts())

  def test_opts do
    [
      start_session: false,
      start_heartbeat: false,
      recover_session: false,
      task_store: Application.fetch_env!(:arbor_gateway, :lifecycle_authority_fixture_store)
    ]
  end
end

defmodule Arbor.Gateway.Chat.LifecycleAuthoritySecurityRegressionTest.PrivateAgents do
  @moduledoc false
  # The production facade. It only records the authority each route handed it
  # and adds the test-owned start options to authorize_start/3.
  alias Arbor.Gateway.Chat.LifecycleAuthoritySecurityRegressionTest.PrivateStart

  def authorize_create(principal, name, opts) do
    notify({:lifecycle_authority, :create, Keyword.get(opts, :actor_authority)})
    Arbor.Agent.authorize_create(principal, name, opts)
  end

  def authorize_start(principal, agent_id, opts) do
    notify({:lifecycle_authority, :start, Keyword.get(opts, :actor_authority)})
    Arbor.Agent.authorize_start(principal, agent_id, opts ++ PrivateStart.test_opts())
  end

  def authorize_stop(principal, agent_id, opts) do
    notify({:lifecycle_authority, :stop, Keyword.get(opts, :actor_authority)})
    Arbor.Agent.authorize_stop(principal, agent_id, opts)
  end

  # Create runs inside Chat.LifecycleAuthority (a named GenServer). send(self())
  # therefore landed in the owner's mailbox, not the test process — the route
  # still answered 200/403 via Arbor.Agent, so it looked like the real facade
  # was used. Notify the test pid stored by setup.
  defp notify(message) do
    case Application.get_env(:arbor_gateway, :lifecycle_authority_notify) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> send(self(), message)
    end
  end
end

defmodule Arbor.Gateway.Chat.LifecycleAuthoritySecurityRegressionTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Arbor.Agent, as: Agents
  alias Arbor.Agent.BranchSupervisor
  alias Arbor.Agent.Test.{RuntimeAdmissionTopology, TrustTopology}
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Gateway.Chat.LifecycleAuthoritySecurityRegressionTest.{PrivateAgents, PrivateStart}
  alias Arbor.Gateway.Router
  alias Arbor.Security
  alias Arbor.Security.OIDCTestHelper
  alias Arbor.Security.TestSupport.ApprovalAnswerFixture, as: Humans

  @moduletag :integration
  @moduletag :security_regression

  # What Lifecycle.create needs from its actor (see Arbor.Agent.LifecycleActorFixture).
  @create_mutation_resources [
    "arbor://security/identity/register",
    "arbor://security/identity/endorse/*",
    "arbor://security/grant/*",
    "arbor://security/revoke/*",
    "arbor://security/identity/deregister/*",
    "arbor://security/identity/suspend/*",
    "arbor://security/identity/resume/*"
  ]

  setup_all do
    for {name, child} <- [
          {Arbor.Agent.ExecutorRegistry,
           {Registry, keys: :unique, name: Arbor.Agent.ExecutorRegistry}},
          {Arbor.Agent.ReasoningLoopRegistry,
           {Registry, keys: :unique, name: Arbor.Agent.ReasoningLoopRegistry}},
          {Arbor.Agent.Registry, Arbor.Agent.Registry},
          {Arbor.Agent.Supervisor, Arbor.Agent.Supervisor},
          {Arbor.Agent.UserSupervisor, Arbor.Agent.UserSupervisor}
        ] do
      if Process.whereis(name) == nil, do: start_supervised!(child)
    end

    # The signing-key store admits the profile key owner only at its
    # production supervision path, so it runs under arbor_agent's app
    # supervisor (as in arbor_agent's test_helper). Removed again on exit so
    # later modules see the gateway suite's usual topology.
    if Process.whereis(Arbor.Agent.ProfileAuthorityOwner) == nil do
      {:ok, _pid} =
        Supervisor.start_child(Arbor.Agent.AppSupervisor, Arbor.Agent.ProfileAuthorityOwner)

      on_exit(fn ->
        _ =
          Supervisor.terminate_child(Arbor.Agent.AppSupervisor, Arbor.Agent.ProfileAuthorityOwner)

        _ = Supervisor.delete_child(Arbor.Agent.AppSupervisor, Arbor.Agent.ProfileAuthorityOwner)
      end)
    end

    if Process.whereis(:arbor_agent_profiles) == nil do
      start_supervised!(
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           name: :arbor_agent_profiles, backend: nil, write_mode: :sync},
          id: :arbor_agent_profiles
        )
      )
    end

    {:ok, principal} = Agents.open_lifecycle_actor_fixture()
    on_exit(fn -> Agents.close_lifecycle_actor_fixture(principal) end)

    root =
      Path.join(
        System.tmp_dir!(),
        "lifecycle-authority-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, lifecycle_principal: principal, root: root}
  end

  setup %{lifecycle_principal: principal, root: root} do
    _ = Humans.setup!()
    TrustTopology.ensure_owned!()
    %{store: store} = RuntimeAdmissionTopology.start_owned!()

    for {key, value} <- [
          api_key: "lifecycle-authority-no-bearer-auth",
          chat_agent_facade: PrivateAgents,
          chat_lifecycle: PrivateStart,
          chat_template_store: Arbor.Agent.TemplateStore,
          chat_security: Security,
          chat_agent_manager: Arbor.Agent.Manager,
          lifecycle_authority_fixture_store: store,
          lifecycle_authority_notify: self()
        ],
        do: put_env(key, value)

    template = "lifecycle-authority-#{System.unique_integer([:positive])}"
    Arbor.Agent.TemplateStore.set_templates_dir(Path.join(root, "templates"))

    assert :ok =
             Agents.put_template(template, %{
               "name" => template,
               "character" => %{"name" => "Lifecycle authority fixture"},
               "required_capabilities" => [],
               "tools" => []
             })

    on_exit(fn ->
      Arbor.Agent.TemplateStore.set_templates_dir(Path.join(root, "templates"))
      Agents.delete_template(template)
      Arbor.Agent.TemplateStore.clear_templates_dir_override()
    end)

    {:ok, actor} = Agents.reopen_lifecycle_actor_fixture(principal)
    %{human: human_with_key!(), template: template, actor: actor, principal: principal}
  end

  describe "POST /api/chat/agents (create + start)" do
    test "a human's valid signed request creates and starts the agent, then closes the authority",
         ctx do
      grant_all!(ctx.human.agent_id, [
        "arbor://agent/lifecycle/create" | @create_mutation_resources
      ])

      before = agent_ids()

      conn = request(ctx.human, "POST", "/api/chat/agents", create_body(ctx))

      assert conn.status == 200, conn.resp_body
      assert %{"agent_id" => agent_id, "running" => true} = Jason.decode!(conn.resp_body)
      on_exit(fn -> Agents.destroy_agent_fixture(agent_id, ctx.principal) end)
      refute MapSet.member?(before, agent_id)
      assert is_pid(BranchSupervisor.whereis(agent_id))

      assert_received {:lifecycle_authority, :create, authority}
      assert authority.principal_id == ctx.human.agent_id
      # Create mutates identity state, so Chat.LifecycleAuthority (the named
      # GenServer) opens the principal's stored key itself. The HTTP-opened
      # `:agent_lifecycle` authority is not reused as a proof (2026-10-08 D2).
      assert authority.purpose == :gateway_agent_lifecycle
      # One operation only: closed once the request completed.
      assert {:error, _} = Security.signing_authority_principal(authority)
    end

    test "security regression: create fails closed without the human's valid signed request",
         ctx do
      grant_all!(ctx.human.agent_id, [
        "arbor://agent/lifecycle/create" | @create_mutation_resources
      ])

      body = Jason.encode!(create_body(ctx))
      before = agent_ids()

      # No credential at all.
      assert raw_request("POST", "/api/chat/agents", body, nil).status == 401

      # Signed for a different body (another template / name).
      other_body = Jason.encode!(%{create_body(ctx) | name: "Swapped name"})
      header = signed_header(ctx.human, "POST", "/api/chat/agents", other_body)
      assert raw_request("POST", "/api/chat/agents", body, header).status == 401

      # A replay of a request that was already served.
      header = signed_header(ctx.human, "POST", "/api/chat/agents", body)
      first = raw_request("POST", "/api/chat/agents", body, header)
      assert first.status == 200, first.resp_body
      %{"agent_id" => created} = Jason.decode!(first.resp_body)
      on_exit(fn -> Agents.destroy_agent_fixture(created, ctx.principal) end)
      assert raw_request("POST", "/api/chat/agents", body, header).status == 401

      assert MapSet.difference(agent_ids(), before) == MapSet.new([created])
    end

    test "security regression: a non-human signer or a human without a server-held key creates nothing",
         ctx do
      body = create_body(ctx)
      before = agent_ids()

      agent = registered_agent!()
      grant_all!(agent.agent_id, ["arbor://agent/lifecycle/create" | @create_mutation_resources])
      refused = request(agent, "POST", "/api/chat/agents", body)
      assert refused.status == 403
      assert Jason.decode!(refused.resp_body)["error"] =~ "capability_mutation_unauthorized"
      # The GenServer fails closed at stored-key proof/open before the facade
      # runs. A non-human therefore never reaches authorize_create.
      refute_received {:lifecycle_authority, :create, _}

      keyless = registered_human!()

      grant_all!(keyless.agent_id, ["arbor://agent/lifecycle/create" | @create_mutation_resources])

      assert request(keyless, "POST", "/api/chat/agents", body).status == 401

      assert agent_ids() == before
    end
  end

  describe "POST /api/chat/agents/:id/start" do
    test "a human's valid signed request starts the stopped agent through authorize_start", ctx do
      agent_id = create_stopped!(ctx.actor, ctx.principal)
      grant_all!(ctx.human.agent_id, ["arbor://agent/lifecycle/start/" <> agent_id])

      conn = request(ctx.human, "POST", start_path(agent_id), %{})

      assert conn.status == 200, conn.resp_body
      assert Jason.decode!(conn.resp_body) == %{"agent_id" => agent_id, "running" => true}
      assert is_pid(BranchSupervisor.whereis(agent_id))
      assert_received {:lifecycle_authority, :start, authority}
      assert authority.principal_id == ctx.human.agent_id
      assert {:error, _} = Security.signing_authority_principal(authority)
    end

    test "security regression: start fails closed without the human's valid signed request",
         ctx do
      agent_id = create_stopped!(ctx.actor, ctx.principal)
      other_id = create_stopped!(ctx.actor, ctx.principal)
      grant_all!(ctx.human.agent_id, ["arbor://agent/lifecycle/start/" <> agent_id])
      path = start_path(agent_id)

      # No credential.
      assert raw_request("POST", path, "{}", nil).status == 401
      # Signed for starting another agent, presented for this one.
      header = signed_header(ctx.human, "POST", start_path(other_id), "{}")
      assert raw_request("POST", path, "{}", header).status == 401
      # Signed for stopping this agent, presented as a start.
      header = signed_header(ctx.human, "POST", "/api/chat/agents/#{agent_id}/stop", "{}")
      assert raw_request("POST", path, "{}", header).status == 401
      # The restore capability (this route's gate before D3) no longer starts an agent.
      other = human_with_key!()
      grant_all!(other.agent_id, ["arbor://agent/lifecycle/restore"])
      assert request(other, "POST", path, %{}).status == 403

      assert BranchSupervisor.whereis(agent_id) == nil
      assert BranchSupervisor.whereis(other_id) == nil

      # A served request cannot be replayed.
      header = signed_header(ctx.human, "POST", path, "{}")
      assert raw_request("POST", path, "{}", header).status == 200
      assert :ok = Agents.stop(agent_id)
      assert raw_request("POST", path, "{}", header).status == 401
      assert BranchSupervisor.whereis(agent_id) == nil
    end

    test "security regression: a non-human signer starts nothing", ctx do
      agent_id = create_stopped!(ctx.actor, ctx.principal)
      agent = registered_agent!()
      grant_all!(agent.agent_id, ["arbor://agent/lifecycle/start/" <> agent_id])

      refused = request(agent, "POST", start_path(agent_id), %{})

      assert refused.status == 403
      assert_received {:lifecycle_authority, :start, nil}
      assert BranchSupervisor.whereis(agent_id) == nil
    end
  end

  test "routes outside create and start never open a lifecycle authority", ctx do
    agent_id = create_stopped!(ctx.actor, ctx.principal)

    grant_all!(ctx.human.agent_id, [
      "arbor://agent/stop/" <> agent_id,
      "arbor://agent/lifecycle/start/" <> agent_id
    ])

    {[listed, stopped], opened} =
      trace_lifecycle_authority_opens(fn ->
        [
          request(ctx.human, "GET", "/api/chat/agents").status,
          request(ctx.human, "POST", "/api/chat/agents/#{agent_id}/stop", %{}).status
        ]
      end)

    assert listed == 200
    assert stopped in [200, 404]
    assert opened == 0

    # Control: the start route opens one, exactly once.
    {[started], opened} =
      trace_lifecycle_authority_opens(fn ->
        [request(ctx.human, "POST", start_path(agent_id), %{}).status]
      end)

    assert started == 200
    assert opened == 1
  end

  # A process cannot trace its own calls, so the requests run in a worker
  # (Plug.Test runs the Router in the calling process).
  defp trace_lifecycle_authority_opens(fun) do
    mfa = {Security, :verify_request_and_open_agent_lifecycle_authority, 2}
    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          :run -> send(parent, {:traced_result, self(), fun.()})
        end
      end)

    try do
      1 = :erlang.trace_pattern(mfa, true, [:global])
      1 = :erlang.trace(worker, true, [:call])
      send(worker, :run)

      result =
        receive do
          {:traced_result, ^worker, result} ->
            result

          {:DOWN, ^monitor, :process, ^worker, reason} ->
            flunk("worker failed: #{inspect(reason)}")
        after
          15_000 -> flunk("traced requests did not return")
        end

      barrier = :erlang.trace_delivered(worker)

      receive do
        {:trace_delivered, ^worker, ^barrier} -> :ok
      after
        5_000 -> flunk("trace messages were not delivered")
      end

      {result, drain_trace_calls(worker, 0)}
    after
      :erlang.trace_pattern(mfa, false, [:global])
    end
  end

  defp drain_trace_calls(worker, count) do
    receive do
      {:trace, ^worker, :call,
       {Security, :verify_request_and_open_agent_lifecycle_authority, _args}} ->
        drain_trace_calls(worker, count + 1)
    after
      0 -> count
    end
  end

  defp create_body(ctx),
    do: %{template: ctx.template, name: "Signed lifecycle fixture", model: "sealed-no-provider"}

  defp start_path(agent_id), do: "/api/chat/agents/" <> agent_id <> "/start"

  defp agent_ids, do: MapSet.new(Arbor.Agent.Lifecycle.list_agents(), & &1.agent_id)

  defp create_stopped!(actor, principal) do
    assert {:ok, profile} =
             Arbor.Agent.Lifecycle.create(
               "Lifecycle authority start probe #{System.unique_integer([:positive])}",
               template: "test_agent",
               actor_authority: actor.authority
             )

    on_exit(fn -> Agents.destroy_agent_fixture(profile.agent_id, principal) end)
    assert BranchSupervisor.whereis(profile.agent_id) == nil
    profile.agent_id
  end

  defp grant_all!(principal, resources) do
    for resource <- resources do
      assert {:ok, capability} = Security.grant_fixture(principal: principal, resource: resource)
      on_exit(fn -> Security.revoke_fixture(capability.id) end)
      capability.id
    end
  end

  defp human_with_key! do
    human = registered_human!()
    assert :ok = Security.store_signing_key_fixture(human.agent_id, human.private_key)
    on_exit(fn -> Security.delete_signing_key_fixture(human.agent_id) end)
    human
  end

  defp registered_human! do
    oidc = OIDCTestHelper.issue_identity()
    assert :ok = Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)

    on_exit(fn ->
      oidc.cleanup.()
      _ = Security.deregister_identity_fixture(oidc.identity.agent_id)
    end)

    oidc.identity
  end

  defp registered_agent! do
    {:ok, identity} = Security.generate_identity()
    assert :ok = Security.register_identity_fixture(identity)
    on_exit(fn -> Security.deregister_identity_fixture(identity.agent_id) end)
    identity
  end

  defp request(identity, method, path, value \\ "") do
    body = if is_binary(value), do: value, else: Jason.encode!(value)
    raw_request(method, path, body, signed_header(identity, method, path, body))
  end

  defp raw_request(method, path, body, header) do
    Process.delete(:arbor_authenticated_agent_id)

    method
    |> conn(path, body)
    |> put_req_header("content-type", "application/json")
    |> then(fn conn ->
      if header, do: put_req_header(conn, "authorization", header), else: conn
    end)
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

  defp put_env(key, value) do
    previous = Application.fetch_env(:arbor_gateway, key)
    Application.put_env(:arbor_gateway, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:arbor_gateway, key, old)
        :error -> Application.delete_env(:arbor_gateway, key)
      end
    end)
  end
end
