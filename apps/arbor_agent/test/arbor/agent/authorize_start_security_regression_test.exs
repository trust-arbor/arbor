defmodule Arbor.Agent.AuthorizeStartSecurityRegressionTest do
  @moduledoc """
  `Arbor.Agent.authorize_start/3` (decision 2026-10-08 D3): a human starts an
  existing agent only with `arbor://agent/lifecycle/start/<id>` and a lifecycle
  authority of their own, opened from their session (or passed in by an
  in-process caller that opened it, such as the Gateway). Nothing else starts
  an agent: no proof, another human's authority, or another human's session
  token fails closed before any lifecycle effect.

  Starts use `start_session: false` and a test-owned TaskStore, as in
  `Arbor.Agent.LifecycleStartAuthoritySecurityRegressionTest`.
  """
  use ExUnit.Case, async: false

  alias Arbor.Agent, as: Agents
  alias Arbor.Agent.BranchSupervisor
  alias Arbor.Agent.Test.{RuntimeAdmissionTopology, TrustTopology}
  alias Arbor.Security
  alias Arbor.Security.OIDCTestHelper
  alias Arbor.Security.SessionToken
  alias Arbor.Security.TestSupport.ApprovalAnswerFixture, as: Humans

  @moduletag :security_regression
  @moduletag :fast

  defmodule ApprovalProbe do
    @moduledoc false
    def healthy?, do: true
    def submit(%{topic: :authorization_request}, _opts), do: {:ok, "start-pending-fixture"}
  end

  setup_all do
    {:ok, principal} = Agents.open_lifecycle_actor_fixture()
    on_exit(fn -> Agents.close_lifecycle_actor_fixture(principal) end)
    {:ok, lifecycle_principal: principal}
  end

  setup %{lifecycle_principal: principal} do
    # Session-token secret and identity verification, as in production.
    _ = Humans.setup!()
    TrustTopology.ensure_owned!()

    if Process.whereis(:arbor_agent_profiles) == nil do
      start_supervised!(
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           name: :arbor_agent_profiles, backend: nil, write_mode: :sync},
          id: :arbor_agent_profiles
        )
      )
    end

    %{store: store} = RuntimeAdmissionTopology.start_owned!()
    {:ok, actor} = Agents.reopen_lifecycle_actor_fixture(principal)
    human = human_with_key!()
    {:ok, token} = SessionToken.generate(human)

    {:ok, actor: actor, store: store, human: human, token: token}
  end

  test "a human session with the exact start capability starts the agent", ctx do
    agent_id = create!(ctx.actor)
    grant!(ctx.human, start_resource(agent_id))

    assert {:ok, ^agent_id, pid} =
             Agents.authorize_start(
               ctx.human,
               agent_id,
               [session_token: ctx.token] ++ start_opts(ctx.store)
             )

    assert BranchSupervisor.whereis(agent_id) == pid
    assert Process.alive?(pid)
  end

  test "an in-process caller's own lifecycle authority starts the agent", ctx do
    agent_id = create!(ctx.actor)
    grant!(ctx.human, start_resource(agent_id))
    {:ok, authority} = Security.open_agent_lifecycle_authority(ctx.token)
    on_exit(fn -> Security.close_signing_authority(authority) end)

    assert {:ok, ^agent_id, pid} =
             Agents.authorize_start(
               ctx.human,
               agent_id,
               # The session binds the capability check to the human; the
               # explicit authority is used for the start itself.
               [session_token: ctx.token, actor_authority: authority] ++ start_opts(ctx.store)
             )

    assert BranchSupervisor.whereis(agent_id) == pid
  end

  test "security regression: without a session or authority nothing starts", ctx do
    agent_id = create!(ctx.actor)
    grant!(ctx.human, start_resource(agent_id))

    for proof <- [[], [signed_request: nil], [identity_verified: true]] do
      assert {:error, {:unauthorized, :capability_mutation_unauthorized}} =
               Agents.authorize_start(ctx.human, agent_id, proof ++ start_opts(ctx.store))

      refute_started(agent_id)
    end

    # The legacy unauthenticated resume path stays closed as well.
    assert {:error, :capability_mutation_unauthorized} =
             Arbor.Agent.Manager.resume_agent(agent_id, start_opts(ctx.store))

    refute_started(agent_id)
  end

  test "security regression: another human's authority cannot start the agent", ctx do
    agent_id = create!(ctx.actor)
    grant!(ctx.human, start_resource(agent_id))
    other = human_with_key!()
    grant!(other, start_resource(agent_id))
    {:ok, other_token} = SessionToken.generate(other)
    {:ok, other_authority} = Security.open_agent_lifecycle_authority(other_token)
    on_exit(fn -> Security.close_signing_authority(other_authority) end)

    assert {:error, {:unauthorized, :capability_mutation_unauthorized}} =
             Agents.authorize_start(
               ctx.human,
               agent_id,
               [session_token: ctx.token, actor_authority: other_authority] ++
                 start_opts(ctx.store)
             )

    refute_started(agent_id)
  end

  test "security regression: a session token for a different human cannot start the agent",
       ctx do
    agent_id = create!(ctx.actor)
    grant!(ctx.human, start_resource(agent_id))
    other = human_with_key!()
    grant!(other, start_resource(agent_id))
    {:ok, other_token} = SessionToken.generate(other)

    for token <- [other_token, "forged", ""] do
      assert {:error, {:unauthorized, _reason}} =
               Agents.authorize_start(
                 ctx.human,
                 agent_id,
                 [session_token: token] ++ start_opts(ctx.store)
               )

      refute_started(agent_id)
    end
  end

  test "security regression: the start capability is exact to one agent", ctx do
    agent_id = create!(ctx.actor)
    other_agent = create!(ctx.actor)
    grant!(ctx.human, start_resource(other_agent))
    grant!(ctx.human, "arbor://agent/lifecycle/restore")

    assert {:error, {:unauthorized, _reason}} =
             Agents.authorize_start(
               ctx.human,
               agent_id,
               [session_token: ctx.token] ++ start_opts(ctx.store)
             )

    refute_started(agent_id)
  end

  test "security regression: pending approval starts nothing", ctx do
    for {key, value} <- [
          consensus_escalation_enabled: true,
          use_interaction_router_for_approval: false,
          consensus_module: ApprovalProbe
        ],
        do: put_security_env(key, value)

    agent_id = create!(ctx.actor)
    grant!(ctx.human, start_resource(agent_id), constraints: %{requires_approval: true})

    assert {:ok, :pending_approval, "start-pending-fixture"} =
             Agents.authorize_start(
               ctx.human,
               agent_id,
               [session_token: ctx.token] ++ start_opts(ctx.store)
             )

    refute_started(agent_id)
  end

  defp start_opts(store),
    do: [start_session: false, recover_session: false, task_store: store]

  defp start_resource(agent_id), do: "arbor://agent/lifecycle/start/" <> agent_id

  defp refute_started(agent_id), do: assert(BranchSupervisor.whereis(agent_id) == nil)

  defp create!(actor) do
    assert {:ok, profile} =
             Arbor.Agent.Lifecycle.create(
               "Authorize Start Probe #{System.unique_integer([:positive])}",
               template: "test_agent",
               actor_authority: actor.authority
             )

    agent_id = profile.agent_id
    on_exit(fn -> Agents.destroy_agent_fixture(agent_id, actor) end)
    agent_id
  end

  defp grant!(principal, resource, opts \\ []) do
    assert {:ok, capability} =
             Security.grant_fixture([principal: principal, resource: resource] ++ opts)

    on_exit(fn -> Security.revoke_fixture(capability.id) end)
    capability
  end

  # A registered OIDC human whose signing key the server holds, like every
  # human that can open a lifecycle authority.
  defp human_with_key! do
    oidc = OIDCTestHelper.issue_identity()
    human_id = oidc.identity.agent_id
    assert :ok = Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)
    assert :ok = Security.store_signing_key_fixture(human_id, oidc.identity.private_key)

    on_exit(fn ->
      oidc.cleanup.()
      _ = Security.delete_signing_key_fixture(human_id)
      _ = Security.deregister_identity_fixture(human_id)
    end)

    human_id
  end

  defp put_security_env(key, value) do
    previous = Application.fetch_env(:arbor_security, key)
    Application.put_env(:arbor_security, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:arbor_security, key, old)
        :error -> Application.delete_env(:arbor_security, key)
      end
    end)
  end
end
