defmodule Arbor.Agent.OwnerDisclosureRightSecurityRegressionTest do
  @moduledoc """
  `mix arbor.agent.grant_disclosure`: the operator-signed backfill of the
  narrow disclosure-issue right for agents created before
  `Lifecycle.create/2` granted it (2026-11-14, 9d8275a7a).

  Such an agent's Session cannot mint the one-turn disclosure capability, so
  every authenticated turn of its owner on an external route is refused at
  route_and_disclosure with `:capability_mutation_unauthorized` (the CLI
  shows `Chat failed: :delivery_failed`). A pre-existing agent is simulated
  here by revoking the right a current creation grants.

  The disclosure check below makes exactly the call the Session makes
  (`TurnEgress.issue_disclosure_if_needed/4` →
  `Arbor.Security.issue_disclosure_capability/1`, with the opts it builds and
  the agent's own session authority); arbor_orchestrator's
  `session_disclosure_issue_right_security_regression_test.exs` pins that
  TurnEgress path to this call.

  The operators hold administrator capabilities from fixtures, including
  `arbor://security/grant/*`, so a refusal here comes from the backfill's own
  binding and ownership checks, not from missing grant authority.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :security_regression
  @moduletag timeout: 180_000

  alias Arbor.Agent, as: Agents
  alias Arbor.Agent.Lifecycle
  alias Arbor.Agent.TemplateStore
  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.TenantContext
  alias Arbor.Security
  alias Mix.Tasks.Arbor.Agent.GrantDisclosure

  @operator_resources [
    "arbor://agent/lifecycle/create",
    "arbor://agent/lifecycle/start/*",
    "arbor://security/identity/register",
    "arbor://security/identity/endorse/*",
    "arbor://security/grant/*",
    "arbor://security/revoke/*",
    "arbor://security/identity/deregister/*",
    "arbor://security/identity/suspend/*",
    "arbor://security/identity/resume/*"
  ]
  @route %{
    destination: "opencode.ai",
    provider: "opencode_zen",
    runtime: "arbor",
    model: "test-model-free"
  }

  setup_all do
    if Process.whereis(:arbor_agent_profiles) == nil do
      start_supervised!(
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           name: :arbor_agent_profiles, backend: nil, write_mode: :sync},
          id: :arbor_agent_profiles
        )
      )
    end

    {:ok, cleanup_principal} = Agents.open_lifecycle_actor_fixture()
    on_exit(fn -> Agents.close_lifecycle_actor_fixture(cleanup_principal) end)
    {:ok, cleanup_principal: cleanup_principal}
  end

  setup %{cleanup_principal: cleanup_principal} do
    previous_flag =
      Application.get_env(:arbor_capabilities, :allow_local_human_identity, :__absent__)

    previous_oidc = Application.get_env(:arbor_capabilities, :oidc, :__absent__)
    Application.put_env(:arbor_capabilities, :allow_local_human_identity, true)
    Application.delete_env(:arbor_capabilities, :oidc)

    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    dir = private_dir!()
    template = "owner-disclosure-#{System.unique_integer([:positive])}"
    TemplateStore.set_templates_dir(Path.join(dir, "templates"))

    assert :ok =
             Agents.put_template(template, %{
               "name" => template,
               "character" => %{"name" => "Owner disclosure fixture"},
               "required_capabilities" => [],
               "tools" => []
             })

    before = agent_ids()

    on_exit(fn ->
      for agent_id <- MapSet.difference(agent_ids(), before) do
        Agents.destroy_agent_fixture(agent_id, cleanup_principal)
      end

      TemplateStore.clear_templates_dir_override()
      Mix.shell(previous_shell)
      restore_env(:allow_local_human_identity, previous_flag)
      restore_env(:oidc, previous_oidc)
      File.rm_rf!(dir)
    end)

    operator = operator!(dir, "operator")
    other = operator!(dir, "other")

    {:ok,
     template: template,
     operator: operator,
     operator_caps: grant_all!(operator.principal, @operator_resources),
     other: other,
     other_caps: grant_all!(other.principal, @operator_resources)}
  end

  test "security regression: a pre-existing agent's turn goes from refused to admitted",
       %{template: template, operator: operator} do
    {agent, name} = pre_existing_agent!(template, operator)
    agent_id = agent.agent_id
    authority = session_authority!(agent)

    # Before the backfill: the Session's mint is refused, as every chat turn was.
    assert {:error, :capability_mutation_unauthorized} =
             mint_turn_disclosure(agent_id, authority, operator.principal)

    assert {:ok, calls} = run_cli({:agent, name}, operator)
    assert infos() =~ "Granted '#{name}' (#{agent_id})"
    refute_secret_crossed(calls, operator.private_key)

    assert [
             {Arbor.Agent, :list_agents},
             {Arbor.Agent, :submit_signed_owner_disclosure_grant}
           ] = called(calls)

    # After: the same call admits the owner's turn, and the Session can revoke
    # what it minted at the end of the turn.
    assert {:ok, disclosure} = mint_turn_disclosure(agent_id, authority, operator.principal)
    assert disclosure.principal_scope == operator.principal
    assert :ok = Security.revoke(disclosure.id, actor_authority: authority)

    # Exactly the narrow right, never the general self-grant.
    assert {:ok, right} = Security.disclosure_issue_right_uri(agent_id, operator.principal)
    assert [granted] = holding(agent_id, right)
    assert granted.delegation_depth == 0
    assert holding(agent_id, "arbor://security/grant/#{agent_id}") == []

    # Idempotent: a second run changes nothing and grants nothing new.
    assert {:ok, _calls} = run_cli({:agent, agent_id}, operator)
    assert infos() =~ "already holds #{right}"
    assert [^granted] = holding(agent_id, right)
  end

  test "security regression: the backfill never binds another human's turns",
       %{template: template, operator: operator, other: other} do
    {agent, _name} = pre_existing_agent!(template, operator)
    agent_id = agent.agent_id
    {:ok, own_right} = Security.disclosure_issue_right_uri(agent_id, operator.principal)
    {:ok, other_right} = Security.disclosure_issue_right_uri(agent_id, other.principal)

    # The key-file builder takes no human: it binds the key's own principal.
    assert {:ok, human, cap, proof} = prepare_disclosure(operator, agent_id)
    assert human == operator.principal
    assert cap.resource_uri == own_right

    # The operator signs a grant naming another human, through the general
    # key-file builder. The operator could grant it directly (it holds
    # arbor://security/grant/*), but the backfill refuses it.
    {:ok, foreign_cap, foreign_proof} =
      prepare_generic(operator, principal: agent_id, resource: other_right)

    assert {:error, :disclosure_right_not_bound_to_signer} =
             Agents.submit_signed_owner_disclosure_grant(foreign_cap, foreign_proof)

    assert {:error, :disclosure_right_not_bound_to_signer} =
             Security.submit_signed_disclosure_right_grant(foreign_cap, foreign_proof)

    # Rebinding a genuine grant after signing is refused too.
    assert {:error, :disclosure_right_not_bound_to_signer} =
             Agents.submit_signed_owner_disclosure_grant(
               %{cap | resource_uri: other_right},
               proof
             )

    # The other human signs a grant of the operator's right: still not bound
    # to its signer, and the other human did not create the agent either.
    {:ok, swapped_cap, swapped_proof} =
      prepare_generic(other, principal: agent_id, resource: own_right)

    assert {:error, :disclosure_right_not_bound_to_signer} =
             Agents.submit_signed_owner_disclosure_grant(swapped_cap, swapped_proof)

    # A grant of anything else is not a disclosure right at all.
    {:ok, wide_cap, wide_proof} =
      prepare_generic(operator,
        principal: agent_id,
        resource: "arbor://security/grant/#{agent_id}"
      )

    assert {:error, :disclosure_right_not_bound_to_signer} =
             Agents.submit_signed_owner_disclosure_grant(wide_cap, wide_proof)

    assert holding(agent_id, other_right) == []
    assert holding(agent_id, own_right) == []
    assert holding(agent_id, "arbor://security/grant/#{agent_id}") == []

    # The other human's turn on this agent is still refused.
    authority = session_authority!(agent)

    assert {:error, :capability_mutation_unauthorized} =
             mint_turn_disclosure(agent_id, authority, other.principal)
  end

  test "security regression: the backfill refuses an agent the signer did not create",
       %{template: template, operator: operator, other: other} do
    {own, own_name} = pre_existing_agent!(template, operator)
    {theirs, theirs_name} = pre_existing_agent!(template, other)
    own_id = own.agent_id
    theirs_id = theirs.agent_id
    {:ok, right_on_theirs} = Security.disclosure_issue_right_uri(theirs_id, operator.principal)

    # Through the API, with a grant correctly bound to the signer: refused,
    # although the operator holds arbor://security/grant/*.
    assert {:ok, _human, cap, proof} = prepare_disclosure(operator, theirs_id)

    assert {:error, :not_agent_owner} =
             Agents.submit_signed_owner_disclosure_grant(cap, proof)

    # Through the CLI by name: refused before anything is signed or sent.
    assert {:error, calls} = run_cli({:agent, theirs_name}, operator)
    assert errors() =~ "was created by #{other.principal}, not #{operator.principal}"
    assert called(calls) == [{Arbor.Agent, :list_agents}]

    # --all-owned grants the operator's own agent and never touches theirs.
    assert {:ok, calls} = run_cli(:all_owned, operator)
    output = infos()
    assert output =~ "Granted '#{own_name}' (#{own_id})"
    refute output =~ theirs_id

    assert [{_, _, [granted_cap, _proof], {:ok, :granted}}] =
             Enum.filter(calls, &(elem(&1, 1) == :submit_signed_owner_disclosure_grant))

    assert granted_cap.principal_id == own_id

    assert holding(theirs_id, right_on_theirs) == []
    {:ok, their_own_right} = Security.disclosure_issue_right_uri(theirs_id, other.principal)
    assert holding(theirs_id, their_own_right) == []

    authority = session_authority!(theirs)

    assert {:error, :capability_mutation_unauthorized} =
             mint_turn_disclosure(theirs_id, authority, operator.principal)
  end

  test "security regression: the backfill does not widen the signer's grant authority",
       %{template: template, operator: operator, operator_caps: operator_caps} do
    {agent, name} = pre_existing_agent!(template, operator)
    agent_id = agent.agent_id

    # The owner without arbor://security/grant/* cannot grant its agent anything,
    # this right included.
    for cap <- operator_caps, cap.resource_uri == "arbor://security/grant/*" do
      assert :ok = Security.revoke_fixture(cap.id)
    end

    assert {:error, _calls} = run_cli({:agent, name}, operator)
    assert errors() =~ ":capability_mutation_unauthorized"

    {:ok, right} = Security.disclosure_issue_right_uri(agent_id, operator.principal)
    assert holding(agent_id, right) == []
  end

  test "security regression: a consumed or forged backfill proof is refused",
       %{template: template, operator: operator, other: other} do
    {agent, _name} = pre_existing_agent!(template, operator)
    agent_id = agent.agent_id
    {:ok, right} = Security.disclosure_issue_right_uri(agent_id, operator.principal)

    # Forged: right bound to the operator, signed with another key.
    {:ok, _human, forged_cap, proof} = prepare_disclosure(operator, agent_id)
    forged = resign(proof, other.private_key)

    assert {:error, _reason} = Agents.submit_signed_owner_disclosure_grant(forged_cap, forged)
    assert holding(agent_id, right) == []

    {:ok, _human, cap, proof} = prepare_disclosure(operator, agent_id)
    assert {:ok, :granted} = Agents.submit_signed_owner_disclosure_grant(cap, proof)
    assert [granted] = holding(agent_id, right)

    # Replayed after the right is gone again: the proof was single-use.
    assert :ok = Security.revoke_fixture(granted.id)
    assert {:error, _reason} = Agents.submit_signed_owner_disclosure_grant(cap, proof)
    assert holding(agent_id, right) == []
  end

  # -- the Session's mint ------------------------------------------------------

  # The opts `TurnEgress.issue_disclosure_if_needed/4` builds for an
  # authenticated turn on an `:external_provider` route.
  defp mint_turn_disclosure(agent_id, authority, human_id) do
    Security.issue_disclosure_capability(
      principal_id: agent_id,
      session_id: "session_owner_disclosure_" <> hex(6),
      task_id: Arbor.Identifiers.generate_id("turn_"),
      principal_scope: human_id,
      destination: @route.destination,
      provider: @route.provider,
      runtime: @route.runtime,
      model: @route.model,
      actor_authority: authority
    )
  end

  # The agent's own Session-purpose authority, opened from its key as the
  # orchestrator's regression test opens it.
  defp session_authority!(identity) do
    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: :session
      )

    assert {:ok, authority} =
             Security.open_ephemeral_signing_authority(proof, identity.private_key)

    on_exit(fn -> _ = Security.close_signing_authority(authority) end)
    authority
  end

  # -- agents ------------------------------------------------------------------

  # Created for `owner` the way the signed CLI start creates it: a lifecycle
  # authority opened from the owner's signed request, with the owner named in
  # the tenant context (so the profile records it as `created_by`). Then the
  # right a current creation grants is revoked, which is the state of an agent
  # created before 2026-11-14.
  defp pre_existing_agent!(template, owner) do
    name = "Backfill #{System.unique_integer([:positive])}"

    request = %{
      operation: :start,
      template: template,
      display_name: name,
      provider: "openrouter",
      model: "sealed-no-provider"
    }

    {:ok, payload} = Agents.lifecycle_request_payload(owner.principal, request)
    {:ok, signed} = SignedRequest.sign(payload, owner.principal, owner.private_key)

    assert {:ok, principal, authority} =
             Security.verify_request_and_open_agent_lifecycle_authority(signed, payload)

    assert principal == owner.principal

    created =
      try do
        Lifecycle.create(name,
          template: template,
          tenant_context: TenantContext.new(owner.principal),
          actor_authority: authority,
          return_identity: true
        )
      after
        _ = Security.close_signing_authority(authority)
      end

    assert {:ok, profile, identity} = created
    assert profile.metadata[:created_by] == owner.principal

    {:ok, right} = Security.disclosure_issue_right_uri(identity.agent_id, owner.principal)
    assert [_ | _] = current = holding(identity.agent_id, right)
    for cap <- current, do: assert(:ok = Security.revoke_fixture(cap.id))
    assert holding(identity.agent_id, right) == []

    {identity, name}
  end

  # -- CLI seam ----------------------------------------------------------------

  # Each server call runs in its own process, as `:rpc` runs it.
  defp run_cli(target, operator) do
    Process.put(:grant_disclosure_calls, [])

    remote = fn module, fun, args ->
      result = Task.await(Task.async(fn -> apply(module, fun, args) end), 60_000)

      Process.put(:grant_disclosure_calls, [
        {module, fun, args, result} | Process.get(:grant_disclosure_calls, [])
      ])

      result
    end

    result = GrantDisclosure.grant_operator(target, [key_file: operator.key_path], remote)
    calls = Enum.reverse(Process.get(:grant_disclosure_calls, []))
    if result == :ok, do: {:ok, calls}, else: {:error, calls}
  end

  defp called(calls), do: Enum.map(calls, fn {m, f, _a, _r} -> {m, f} end)

  defp refute_secret_crossed(calls, private_key) do
    for {_m, f, args, result} <- calls do
      assert :binary.match(:erlang.term_to_binary({args, result}), private_key) == :nomatch,
             "private key material crossed the server boundary in #{f}"
    end
  end

  defp infos, do: drain(:info)
  defp errors, do: drain(:error)

  defp drain(kind) do
    receive do
      {:mix_shell, ^kind, [message]} -> message <> "\n" <> drain(kind)
    after
      0 -> ""
    end
  end

  # -- signing -----------------------------------------------------------------

  defp prepare_disclosure(operator, agent_id) do
    with_key_file(operator, &Security.prepare_key_file_disclosure_right_grant(&1, agent_id))
  end

  defp prepare_generic(operator, opts) do
    with_key_file(operator, &Security.prepare_key_file_capability_grant(&1, opts))
  end

  defp with_key_file(operator, fun) do
    {:ok, io_device} = :file.open(String.to_charlist(operator.key_path), [:read, :raw, :binary])

    try do
      fun.(io_device)
    after
      :file.close(io_device)
    end
  end

  defp resign(%SignedRequest{} = request, private_key) do
    message = SignedRequest.signing_payload(request)
    %{request | signature: :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])}
  end

  # -- fixtures ----------------------------------------------------------------

  # A local operator registered the way `mix arbor.user.init` registers it.
  defp operator!(dir, tag) do
    claims = [user: "#{tag}-#{System.unique_integer([:positive])}", host: "owner-disclosure.test"]
    principal = Security.local_human_principal_id(claims)
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    key_path = Path.join(dir, "#{tag}-#{System.unique_integer([:positive])}.key")

    assert {:ok, ^key_path} =
             Security.write_key_file(key_path, %{agent_id: principal, private_key: private_key})

    {:ok, payload} = Security.local_human_registration_request_payload(principal, public_key)
    {:ok, proof} = SignedRequest.sign(payload, principal, private_key)

    assert {:ok, _identity, :created} =
             Security.register_local_human_identity(public_key, proof, claims)

    %{principal: principal, private_key: private_key, key_path: key_path}
  end

  defp grant_all!(principal, resources) do
    for resource <- resources do
      assert {:ok, capability} = Security.grant_fixture(principal: principal, resource: resource)
      on_exit(fn -> Security.revoke_fixture(capability.id) end)
      capability
    end
  end

  defp holding(principal, resource) do
    {:ok, caps} = Security.list_capabilities(principal)
    Enum.filter(caps, &(&1.resource_uri == resource))
  end

  defp agent_ids, do: MapSet.new(Lifecycle.list_agents(), & &1.agent_id)

  defp hex(bytes), do: Base.encode16(:crypto.strong_rand_bytes(bytes), case: :lower)

  defp private_dir! do
    {:ok, system_tmp} = SafePath.resolve_real(System.tmp_dir!())
    path = Path.join(system_tmp, "owner-disclosure-#{hex(16)}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp restore_env(key, :__absent__), do: Application.delete_env(:arbor_capabilities, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_capabilities, key, value)
end
