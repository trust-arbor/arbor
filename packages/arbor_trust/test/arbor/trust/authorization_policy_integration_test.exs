defmodule Arbor.Trust.AuthorizationPolicyIntegrationTest do
  @moduledoc """
  A1 boundary regression tests.

  Trust policy no longer runs inside `Arbor.Security.AuthDecision`. The policy
  layer owns ask/auto/deny modulation through `Arbor.Trust.authorize/4`; the
  security kernel owns capability existence and validity.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Trust.Event
  alias Arbor.Security.CapabilityStore
  alias Arbor.Trust
  alias Arbor.Trust.EventStore
  alias Arbor.Trust.PolicyEnforcer

  import Arbor.Trust.TestHelpers,
    only: [
      actor_authority!: 0,
      ensure_provisioned_grant_owner!: 0,
      authorize_opts_with_grant!: 3
    ]

  alias Arbor.Contracts.Security.Identity

  defmodule RaisingPolicy do
    def effective_mode(_principal, _uri, _opts), do: :ask
    def confirmation_mode(_principal, _uri), do: raise("simulated trust subsystem failure")
  end

  defmodule AskPolicy do
    def effective_mode(_principal, _uri, _opts), do: :ask
    def confirmation_mode(_principal, _uri), do: :gated
  end

  setup do
    ensure_security_started()
    :ok = ensure_provisioned_grant_owner!()
    ensure_trust_started()

    prev = %{
      reflex: Application.get_env(:arbor_capabilities, :reflex_checking_enabled),
      signing: Application.get_env(:arbor_capabilities, :capability_signing_required),
      identity: Application.get_env(:arbor_capabilities, :strict_identity_mode),
      receipts: Application.get_env(:arbor_capabilities, :invocation_receipts_enabled),
      delegation:
        Application.get_env(:arbor_capabilities, :delegation_chain_verification_enabled),
      uri_registry: Application.get_env(:arbor_capabilities, :uri_registry_enforcement),
      escalation: Application.get_env(:arbor_capabilities, :consensus_escalation_enabled),
      trust_guard: Application.get_env(:arbor_trust, :approval_guard_enabled),
      trust_enforcer: Application.get_env(:arbor_trust, :policy_enforcer_enabled),
      policy_module: Application.get_env(:arbor_trust, :policy_module),
      allow_permissive_baseline: Application.get_env(:arbor_trust, :allow_permissive_baseline)
    }

    Application.put_env(:arbor_capabilities, :reflex_checking_enabled, false)
    Application.put_env(:arbor_capabilities, :capability_signing_required, false)
    Application.put_env(:arbor_capabilities, :strict_identity_mode, false)
    Application.put_env(:arbor_capabilities, :invocation_receipts_enabled, false)
    Application.put_env(:arbor_capabilities, :delegation_chain_verification_enabled, false)
    Application.put_env(:arbor_capabilities, :uri_registry_enforcement, false)
    Application.put_env(:arbor_capabilities, :consensus_escalation_enabled, false)
    Application.put_env(:arbor_trust, :approval_guard_enabled, true)
    Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
    Application.delete_env(:arbor_trust, :policy_module)

    on_exit(fn ->
      restore_security(:reflex_checking_enabled, prev.reflex)
      restore_security(:capability_signing_required, prev.signing)
      restore_security(:strict_identity_mode, prev.identity)
      restore_security(:invocation_receipts_enabled, prev.receipts)
      restore_security(:delegation_chain_verification_enabled, prev.delegation)
      restore_security(:uri_registry_enforcement, prev.uri_registry)
      restore_security(:consensus_escalation_enabled, prev.escalation)
      restore_trust(:approval_guard_enabled, prev.trust_guard)
      restore_trust(:policy_enforcer_enabled, prev.trust_enforcer)
      restore_trust(:policy_module, prev.policy_module)
      restore_trust(:allow_permissive_baseline, prev.allow_permissive_baseline)
    end)

    {:ok, agent_identity} = Identity.generate(name: "trust-policy-auth")
    :ok = Arbor.Security.register_identity_fixture(agent_identity)

    on_exit(fn ->
      _ = Arbor.Security.deregister_identity_fixture(agent_identity.agent_id)
    end)

    agent_id = agent_identity.agent_id
    {:ok, _profile} = Trust.create_trust_profile(agent_id)
    {_identity, actor_authority} = actor_authority!()

    {:ok, agent_id: agent_id, agent_identity: agent_identity, actor_authority: actor_authority}
  end

  test "security regression: trust-gated shell cap does not auto-authorize", %{
    agent_id: agent_id,
    actor_authority: actor_authority
  } do
    uri = "arbor://shell/exec/echo"
    grant_capability(agent_id, uri, actor_authority)

    assert Arbor.Trust.Policy.confirmation_mode(agent_id, uri) == :gated
    assert {:error, :escalation_disabled} = Trust.authorize(agent_id, uri, :execute)
  end

  test "trust-auto URI with a held cap authorizes", %{
    agent_id: agent_id,
    actor_authority: actor_authority
  } do
    uri = "arbor://code/read/#{agent_id}/file.ex"
    grant_capability(agent_id, uri, actor_authority)

    assert {:ok, :authorized} = Trust.authorize(agent_id, uri, :read)
  end

  test "TRUST-15 security regression: hostile taint gates held auto capabilities", %{
    agent_id: agent_id,
    actor_authority: actor_authority
  } do
    uri = "arbor://test/process"
    set_profile_rules(agent_id, %{uri => :auto})
    grant_capability(agent_id, uri, actor_authority)

    assert {:ok, :authorized} =
             Trust.authorize(agent_id, uri, :execute,
               security_ceilings: %{},
               effect_class: :process_spawn,
               operation_taint: :trusted
             )

    assert {:error, :escalation_disabled} =
             Trust.authorize(agent_id, uri, :execute,
               security_ceilings: %{},
               effect_class: :process_spawn,
               operation_taint: :hostile
             )
  end

  test "B6 security regression: low-risk read auto-grants with profile constraints", %{
    agent_id: agent_id,
    agent_identity: agent_identity,
    actor_authority: actor_authority
  } do
    uri = "arbor://fs/read/b6/note.txt"
    set_profile_rules(agent_id, %{"arbor://fs/read" => :auto})
    opts = [verify_identity: false, actor_authority: actor_authority]

    assert {:ok, :authorized} =
             Trust.authorize(
               agent_id,
               uri,
               :read,
               authorize_opts_with_grant!(opts, agent_identity, uri)
             )

    assert {:ok, cap} = CapabilityStore.find_authorizing(agent_id, uri)
    assert cap.constraints == %{rate_limit: 300}
    assert cap.metadata[:source] == :trust_policy_enforcer
    assert cap.metadata[:mode] == :auto
    assert cap.metadata[:profile_uri] == "arbor://fs/read"
  end

  test "B6 security regression: irreversible profile-backed actions escalate instead of auto-run",
       %{
         agent_id: agent_id,
         agent_identity: agent_identity,
         actor_authority: actor_authority
       } do
    uri = "arbor://agent/create"
    set_profile_rules(agent_id, %{uri => :auto})
    opts = [verify_identity: false, actor_authority: actor_authority]

    assert {:error, :escalation_disabled} =
             Trust.authorize(
               agent_id,
               uri,
               :execute,
               authorize_opts_with_grant!(opts, agent_identity, uri)
             )

    assert {:ok, cap} = CapabilityStore.find_authorizing(agent_id, uri)
    assert cap.metadata[:source] == :trust_policy_enforcer
    assert cap.metadata[:mode] == :ask
    assert cap.metadata[:profile_uri] == "arbor://agent/create"
  end

  test "B6 security regression: permissive baseline alone cannot mint unprofiled caps", %{
    agent_id: agent_id
  } do
    uri = "arbor://unprofiled/baseline-only"
    Application.put_env(:arbor_trust, :allow_permissive_baseline, true)

    {:ok, _profile} =
      Arbor.Trust.Store.update_profile(agent_id, fn profile ->
        %{profile | baseline: :allow, rules: %{}}
      end)

    assert {:error, :unauthorized} =
             Trust.authorize(agent_id, uri, :execute,
               security_ceilings: %{},
               verify_identity: false
             )

    assert {:error, :not_found} = CapabilityStore.find_authorizing(agent_id, uri)
  end

  test "B8 security regression: score state alone cannot widen authorization", %{
    agent_id: agent_id
  } do
    uri = "arbor://memory/recall"

    {:ok, _profile} =
      Arbor.Trust.Store.update_profile(agent_id, fn profile ->
        %{profile | baseline: :block, rules: %{}}
      end)

    {:ok, event} =
      Event.new(
        agent_id: agent_id,
        event_type: :action_success,
        previous_score: 0,
        new_score: 10_000,
        reason: :score_threshold,
        metadata: %{source: :b8_authorize_regression}
      )

    assert :ok = EventStore.record_event(event)
    assert {:ok, %{current_score: 10_000}} = EventStore.get_trust_progression(agent_id)

    assert {:error, :unauthorized} =
             Trust.authorize(agent_id, uri, :read,
               security_ceilings: %{},
               verify_identity: false
             )

    assert {:error, :not_found} = CapabilityStore.find_authorizing(agent_id, uri)
  end

  test "B8 negative control: explicit profile policy can still widen authorization", %{
    agent_id: agent_id,
    agent_identity: agent_identity,
    actor_authority: actor_authority
  } do
    uri = "arbor://memory/recall"

    {:ok, _profile} =
      Arbor.Trust.Store.update_profile(agent_id, fn profile ->
        %{profile | baseline: :block, rules: %{uri => :auto}}
      end)

    opts = [security_ceilings: %{}, verify_identity: false, actor_authority: actor_authority]

    assert {:ok, :authorized} =
             Trust.authorize(
               agent_id,
               uri,
               :read,
               authorize_opts_with_grant!(opts, agent_identity, uri)
             )

    assert {:ok, cap} = CapabilityStore.find_authorizing(agent_id, uri)
    assert cap.metadata[:source] == :trust_policy_enforcer
    assert cap.metadata[:profile_uri] == uri
  end

  test "security ceilings gate code/write even for permissive profiles", %{
    agent_id: agent_id,
    actor_authority: actor_authority
  } do
    promote_to_hands_off(agent_id)
    uri = "arbor://code/write/foo.ex"
    grant_capability(agent_id, uri, actor_authority)

    assert {:error, :escalation_disabled} = Trust.authorize(agent_id, uri, :execute)
  end

  test "security regression: trust-ask minting does not encode kernel approval constraints", %{
    agent_id: agent_id,
    agent_identity: agent_identity,
    actor_authority: actor_authority
  } do
    uri = "arbor://code/write/minted-ask.ex"
    Application.put_env(:arbor_trust, :policy_module, AskPolicy)
    opts = [actor_authority: actor_authority]

    assert {:error, :escalation_disabled} =
             Trust.authorize(
               agent_id,
               uri,
               :execute,
               authorize_opts_with_grant!(opts, agent_identity, uri)
             )

    assert {:ok, cap} = CapabilityStore.find_authorizing(agent_id, uri)
    assert cap.metadata[:source] == :trust_policy_enforcer
    assert cap.metadata[:mode] == :ask
    refute cap.constraints[:requires_approval]
  end

  test "security regression: explicit authenticated sync revokes stale policy caps", %{
    agent_id: agent_id,
    actor_authority: actor_authority
  } do
    uri = "arbor://memory/recall"
    Application.put_env(:arbor_trust, :allow_permissive_baseline, true)

    {:ok, _profile} =
      Arbor.Trust.Store.update_profile(agent_id, fn profile ->
        %{profile | baseline: :allow, rules: %{}}
      end)

    {:ok, stale_cap} =
      Arbor.Security.grant(
        principal: agent_id,
        resource: uri,
        metadata: %{source: :trust_policy_enforcer, mode: :auto},
        actor_authority: actor_authority
      )

    assert {:ok, ^stale_cap} = Arbor.Security.get_capability_fixture(stale_cap.id)

    {:ok, _profile} =
      Arbor.Trust.Store.update_profile(agent_id, fn profile ->
        %{profile | baseline: :ask}
      end)

    assert {:ok, ^stale_cap} = Arbor.Security.get_capability_fixture(stale_cap.id)

    # The profile write above asked the owner to sync. This grant is not the
    # owner's, so it stays; a status call orders this process behind that
    # attempt before it runs its own.
    ExUnit.CaptureLog.capture_log(fn -> _ = Trust.capability_grant_owner_status() end)

    assert {:ok, 1} =
             PolicyEnforcer.sync_capabilities(agent_id,
               actor_authority: actor_authority
             )

    assert {:error, :not_found} = Arbor.Security.get_capability_fixture(stale_cap.id)
  end

  # Until 2026-11-22 nothing called the sync above: a tightened profile left
  # the capabilities minted under the old one in the store, where any caller
  # of `Arbor.Security.authorize/4` still honoured them. These run the real
  # store, the real grant owner and the real security kernel. The owner holds
  # no revoke right; it revokes because it is the recorded granter.
  test "security regression: tightening a profile revokes the grant the owner minted, " <>
         "with no caller involved",
       %{agent_id: agent_id, agent_identity: agent_identity, actor_authority: actor_authority} do
    uri = "arbor://fs/read/profile-change/note.txt"
    set_profile_rules(agent_id, %{"arbor://fs/read" => :auto})
    opts = [verify_identity: false, actor_authority: actor_authority]
    grant_opts = authorize_opts_with_grant!(opts, agent_identity, uri)
    direct_opts = [verify_identity: false, session_id: Keyword.fetch!(grant_opts, :session_id)]

    assert {:ok, :authorized} = Trust.authorize(agent_id, uri, :read, grant_opts)

    assert {:ok, minted} = CapabilityStore.find_authorizing(agent_id, uri)
    assert minted.metadata[:source] == :trust_policy_enforcer

    # The pure capability check, with no trust policy in it: the path that
    # kept honouring a stale grant.
    assert {:ok, :authorized} = Arbor.Security.authorize(agent_id, uri, :read, direct_opts)

    %{state: :ready, principal_id: owner_id} = Trust.capability_grant_owner_status()
    assert minted.metadata["granter_id"] == owner_id
    {:ok, owner_caps} = Arbor.Security.list_capabilities(owner_id)
    refute Enum.any?(owner_caps, &String.starts_with?(&1.resource_uri, "arbor://security/revoke"))

    {:ok, operator_cap} =
      Arbor.Security.grant(
        principal: agent_id,
        resource: "arbor://memory/index",
        actor_authority: actor_authority
      )

    set_profile_rules(agent_id, %{"arbor://fs/read" => :block})

    # The store casts to the owner; a synchronous no-op sync orders this
    # process behind that cast.
    assert {:ok, 0} = Arbor.Trust.CapabilityGrantOwner.sync(agent_id, :profile_updated)

    assert {:error, :not_found} = Arbor.Security.get_capability_fixture(minted.id)
    assert {:ok, ^operator_cap} = Arbor.Security.get_capability_fixture(operator_cap.id)
    assert {:error, _denied} = Arbor.Security.authorize(agent_id, uri, :read, direct_opts)
  end

  test "security regression: a trust-minted grant cannot be delegated out of the owner's reach",
       %{agent_id: agent_id, agent_identity: agent_identity, actor_authority: actor_authority} do
    uri = "arbor://fs/read/profile-delegate/note.txt"
    set_profile_rules(agent_id, %{"arbor://fs/read" => :auto})
    opts = [verify_identity: false, actor_authority: actor_authority]

    assert {:ok, :authorized} =
             Trust.authorize(
               agent_id,
               uri,
               :read,
               authorize_opts_with_grant!(opts, agent_identity, uri)
             )

    assert {:ok, minted} = CapabilityStore.find_authorizing(agent_id, uri)
    assert minted.delegation_depth == 0

    # A delegated copy would name the agent as its granter and survive the
    # sync. Delegating to itself was the way to launder the grant.
    {:ok, proof} =
      Arbor.Security.build_signing_authority_acquisition_proof(
        agent_id,
        agent_identity.private_key,
        purpose: :trust_test_delegation,
        owner: self()
      )

    {:ok, agent_authority} =
      Arbor.Security.open_ephemeral_signing_authority(proof, agent_identity.private_key)

    assert {:error, _refused} =
             Arbor.Security.delegate(minted.id, agent_id, actor_authority: agent_authority)

    set_profile_rules(agent_id, %{"arbor://fs/read" => :block})
    assert {:ok, 0} = Arbor.Trust.CapabilityGrantOwner.sync(agent_id, :profile_updated)
    assert {:error, :not_found} = CapabilityStore.find_authorizing(agent_id, uri)
  end

  # Agent creation hands a parent's capabilities to a new agent with
  # Arbor.Security.delegate_to_agent/3. A trust-minted grant is not handed
  # over that way: it is non-delegable, because a delegated copy would outlive
  # the parent's profile change. The new agent gets its own grant from its own
  # trust profile instead. This pins both halves.
  test "a trust-minted grant is not delegated to a new agent; the agent mints from its own profile",
       %{agent_id: agent_id, agent_identity: agent_identity, actor_authority: actor_authority} do
    uri = "arbor://fs/read/profile-handoff/note.txt"
    set_profile_rules(agent_id, %{"arbor://fs/read" => :auto})
    opts = [verify_identity: false, actor_authority: actor_authority]
    grant_opts = authorize_opts_with_grant!(opts, agent_identity, uri)

    assert {:ok, :authorized} = Trust.authorize(agent_id, uri, :read, grant_opts)
    assert {:ok, minted} = CapabilityStore.find_authorizing(agent_id, uri)
    assert minted.metadata[:source] == :trust_policy_enforcer

    {:ok, child} = Identity.generate(name: "trust-policy-handoff-child")
    :ok = Arbor.Security.register_identity_fixture(child)

    on_exit(fn ->
      _ = Arbor.Security.revoke_all_fixture(child.agent_id)
      _ = Arbor.Security.deregister_identity_fixture(child.agent_id)
    end)

    {:ok, proof} =
      Arbor.Security.build_signing_authority_acquisition_proof(
        agent_id,
        agent_identity.private_key,
        purpose: :trust_test_handoff,
        owner: self()
      )

    {:ok, parent_authority} =
      Arbor.Security.open_ephemeral_signing_authority(proof, agent_identity.private_key)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, []} =
                 Arbor.Security.delegate_to_agent(agent_id, child.agent_id,
                   actor_authority: parent_authority,
                   resources: [uri]
                 )
      end)

    assert log =~ "delegation_depth_exhausted"
    {:ok, child_caps} = Arbor.Security.list_capabilities(child.agent_id)
    assert child_caps == []

    # The child is governed by its own profile, not the parent's.
    {:ok, _profile} = Trust.create_trust_profile(child.agent_id)
    set_profile_rules(child.agent_id, %{"arbor://fs/read" => :auto})

    assert {:ok, :authorized} =
             Trust.authorize(
               child.agent_id,
               uri,
               :read,
               authorize_opts_with_grant!(opts, child, uri)
             )

    assert {:ok, own} = CapabilityStore.find_authorizing(child.agent_id, uri)
    assert own.parent_capability_id == nil
    assert own.metadata[:source] == :trust_policy_enforcer
  end

  test "security regression: a clamped high-risk grant is not revoked by an unrelated profile edit",
       %{agent_id: agent_id, agent_identity: agent_identity, actor_authority: actor_authority} do
    uri = "arbor://agent/create"
    Application.put_env(:arbor_trust, :allow_permissive_baseline, true)
    set_profile_rules(agent_id, %{uri => :auto})
    opts = [verify_identity: false, actor_authority: actor_authority]

    # Minted as :ask although the rule says :auto; the outcome of the call is
    # not what this test is about.
    _ =
      Trust.authorize(
        agent_id,
        uri,
        :execute,
        authorize_opts_with_grant!(opts, agent_identity, uri)
      )

    assert {:ok, clamped} = CapabilityStore.find_authorizing(agent_id, uri)
    assert clamped.metadata[:mode] == :ask

    set_profile_rules(agent_id, %{uri => :auto, "arbor://fs/read" => :allow})
    assert {:ok, 0} = Arbor.Trust.CapabilityGrantOwner.sync(agent_id, :profile_updated)
    assert {:ok, ^clamped} = Arbor.Security.get_capability_fixture(clamped.id)
  end

  test "security regression: deleting a profile revokes every grant the owner minted",
       %{agent_id: agent_id, agent_identity: agent_identity, actor_authority: actor_authority} do
    uri = "arbor://fs/read/profile-delete/note.txt"
    set_profile_rules(agent_id, %{"arbor://fs/read" => :auto})
    opts = [verify_identity: false, actor_authority: actor_authority]

    assert {:ok, :authorized} =
             Trust.authorize(
               agent_id,
               uri,
               :read,
               authorize_opts_with_grant!(opts, agent_identity, uri)
             )

    assert {:ok, minted} = CapabilityStore.find_authorizing(agent_id, uri)

    :ok = Arbor.Trust.Store.delete_profile(agent_id)
    assert {:ok, 0} = Arbor.Trust.CapabilityGrantOwner.sync(agent_id, :profile_deleted)

    assert {:error, :not_found} = Arbor.Security.get_capability_fixture(minted.id)

    # With the profile gone the owner must not mint again. Policy resolution
    # substitutes an :ask stub for a missing profile, and :ask is mintable.
    assert {:error, _refused} =
             Trust.authorize(
               agent_id,
               uri,
               :read,
               authorize_opts_with_grant!(opts, agent_identity, uri)
             )

    assert {:error, :not_found} = CapabilityStore.find_authorizing(agent_id, uri)
  end

  test "security regression: the owner cannot revoke a trust-marked grant it did not make, " <>
         "says so, and still revokes its own",
       %{agent_id: agent_id, agent_identity: agent_identity, actor_authority: actor_authority} do
    set_profile_rules(agent_id, %{"arbor://fs/read" => :auto, "arbor://memory/recall" => :auto})

    {:ok, foreign} =
      Arbor.Security.grant(
        principal: agent_id,
        resource: "arbor://memory/recall",
        metadata: %{source: :trust_policy_enforcer, mode: :auto},
        actor_authority: actor_authority
      )

    # A grant the owner did make, for the same agent. The foreign one must not
    # shield it.
    own_uri = "arbor://fs/read/profile-foreign/note.txt"
    opts = [verify_identity: false, actor_authority: actor_authority]

    assert {:ok, :authorized} =
             Trust.authorize(
               agent_id,
               own_uri,
               :read,
               authorize_opts_with_grant!(opts, agent_identity, own_uri)
             )

    assert {:ok, own} = CapabilityStore.find_authorizing(agent_id, own_uri)

    set_profile_rules(agent_id, %{"arbor://fs/read" => :block, "arbor://memory/recall" => :block})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:capability_revocation_failed, cap_id, _refusal}} =
                 Arbor.Trust.CapabilityGrantOwner.sync(agent_id, :profile_updated)

        assert cap_id == foreign.id
      end)

    assert log =~ "were not all revoked"
    assert {:ok, ^foreign} = Arbor.Security.get_capability_fixture(foreign.id)
    assert {:error, :not_found} = Arbor.Security.get_capability_fixture(own.id)
  end

  test "pre-approved bounded code/write cap bypasses the ceiling", %{agent_id: agent_id} do
    promote_to_hands_off(agent_id)
    uri = "arbor://code/write/lib/foo/bar.ex"
    grant_preapproved_capability(agent_id, uri)

    assert {:ok, :authorized} = Trust.authorize(agent_id, uri, :execute)
  end

  test "pre-approved shell cap still requires approval because shell is always locked", %{
    agent_id: agent_id
  } do
    uri = "arbor://shell/exec/git"
    grant_preapproved_capability(agent_id, uri)

    assert {:error, :escalation_disabled} = Trust.authorize(agent_id, uri, :execute)
  end

  test "trust subsystem error fails closed to gated", %{
    agent_id: agent_id,
    actor_authority: actor_authority
  } do
    uri = "arbor://historian/query"
    grant_capability(agent_id, uri, actor_authority)
    Application.put_env(:arbor_trust, :policy_module, RaisingPolicy)

    assert {:error, :escalation_disabled} = Trust.authorize(agent_id, uri, :query)
  end

  test "security regression: trust policy sees normalized file_path before minting", %{
    agent_id: agent_id
  } do
    set_profile_rules(agent_id, %{
      "arbor://fs/write" => :allow,
      "arbor://fs/write/secret" => :block
    })

    assert {:error, :unauthorized} =
             Trust.authorize(agent_id, "arbor://fs/write", :execute,
               file_path: "public/../secret/keys.txt",
               verify_identity: false
             )

    assert {:error, :not_found} =
             CapabilityStore.find_authorizing(agent_id, "arbor://fs/write/secret/keys.txt")
  end

  test "workspace file_path trust grants are minted against workspace-relative URIs", %{
    agent_id: agent_id,
    agent_identity: agent_identity,
    actor_authority: actor_authority
  } do
    workspace =
      System.tmp_dir!()
      |> Path.join("trust_auth_uri_workspace_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "public"))
    file_path = Path.join([workspace, "secret", "..", "public", "note.txt"])
    File.write!(Path.join(workspace, "public/note.txt"), "ok")
    on_exit(fn -> File.rm_rf!(workspace) end)

    set_profile_rules(agent_id, %{"arbor://fs/read/public" => :allow})

    opts = [
      file_path: file_path,
      workspace: workspace,
      verify_identity: false,
      actor_authority: actor_authority
    ]

    assert {:ok, :authorized} =
             Trust.authorize(
               agent_id,
               "arbor://fs/read",
               :execute,
               authorize_opts_with_grant!(opts, agent_identity, "arbor://fs/read")
             )

    assert {:ok, cap} =
             CapabilityStore.find_authorizing(agent_id, "arbor://fs/read/public/note.txt")

    assert cap.resource_uri == "arbor://fs/read/public/note.txt"
  end

  defp promote_to_hands_off(agent_id) do
    {baseline, rules} = Arbor.Trust.Authority.preset_rules(:hands_off)

    Arbor.Trust.Store.update_profile(agent_id, fn profile ->
      %{profile | baseline: baseline, rules: rules}
    end)
  end

  defp set_profile_rules(agent_id, rules) do
    Arbor.Trust.Store.update_profile(agent_id, fn profile ->
      %{profile | baseline: :ask, rules: rules}
    end)
  end

  defp grant_capability(agent_id, resource_uri, actor_authority) do
    {:ok, cap} =
      Arbor.Security.grant(
        principal: agent_id,
        resource: resource_uri,
        actor_authority: actor_authority
      )

    cap
  end

  defp grant_preapproved_capability(agent_id, resource_uri) do
    cap = %Capability{
      id: canonical_cap_id(),
      resource_uri: resource_uri,
      principal_id: agent_id,
      granted_at: DateTime.utc_now(),
      expires_at: nil,
      constraints: %{},
      delegation_depth: 0,
      delegation_chain: [],
      metadata: %{provenance: %{source: :caps_file, issuer_id: "agent_test_issuer"}}
    }

    {:ok, :stored} = Arbor.Security.put_capability_fixture(cap)
    cap
  end

  defp ensure_security_started do
    ensure_started(Arbor.Security.Identity.Registry)
    ensure_started(Arbor.Security.SystemAuthority)
    ensure_started(Arbor.Security.CapabilityStore)
    ensure_started(Arbor.Security.Reflex.Registry)
    ensure_started(Arbor.Security.Constraint.RateLimiter)
  end

  defp ensure_trust_started do
    ensure_started(Arbor.Trust.EventStore)
    ensure_started(Arbor.Trust.Store)

    ensure_started(Arbor.Trust.Manager,
      circuit_breaker: false,
      decay: false,
      event_store: true
    )
  end

  defp ensure_started(module, opts \\ []) do
    if Process.whereis(module), do: :ok, else: start_supervised!({module, opts})
  end

  defp restore_security(key, nil), do: Application.delete_env(:arbor_capabilities, key)
  defp restore_security(key, value), do: Application.put_env(:arbor_capabilities, key, value)
  defp restore_trust(key, nil), do: Application.delete_env(:arbor_trust, key)
  defp restore_trust(key, value), do: Application.put_env(:arbor_trust, key, value)

  # The capability audit journal (2026-09-24) admits only canonical
  # `cap_<32 hex>` ids, the form Capability.new/1 generates.
  defp canonical_cap_id, do: "cap_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
