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
    ensure_trust_started()

    prev = %{
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      identity: Application.get_env(:arbor_security, :strict_identity_mode),
      receipts: Application.get_env(:arbor_security, :invocation_receipts_enabled),
      delegation: Application.get_env(:arbor_security, :delegation_chain_verification_enabled),
      uri_registry: Application.get_env(:arbor_security, :uri_registry_enforcement),
      escalation: Application.get_env(:arbor_security, :consensus_escalation_enabled),
      trust_guard: Application.get_env(:arbor_trust, :approval_guard_enabled),
      trust_enforcer: Application.get_env(:arbor_trust, :policy_enforcer_enabled),
      policy_module: Application.get_env(:arbor_trust, :policy_module),
      allow_permissive_baseline: Application.get_env(:arbor_trust, :allow_permissive_baseline)
    }

    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :invocation_receipts_enabled, false)
    Application.put_env(:arbor_security, :delegation_chain_verification_enabled, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, false)
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

    agent_id = "agent_policy_auth_#{:erlang.unique_integer([:positive])}"
    {:ok, _profile} = Trust.create_trust_profile(agent_id)

    {:ok, agent_id: agent_id}
  end

  test "security regression: trust-gated shell cap does not auto-authorize", %{
    agent_id: agent_id
  } do
    uri = "arbor://shell/exec/echo"
    grant_capability(agent_id, uri)

    assert Arbor.Trust.Policy.confirmation_mode(agent_id, uri) == :gated
    assert {:error, :escalation_disabled} = Trust.authorize(agent_id, uri, :execute)
  end

  test "trust-auto URI with a held cap authorizes", %{agent_id: agent_id} do
    uri = "arbor://code/read/#{agent_id}/file.ex"
    grant_capability(agent_id, uri)

    assert {:ok, :authorized} = Trust.authorize(agent_id, uri, :read)
  end

  test "TRUST-15 security regression: hostile taint gates held auto capabilities", %{
    agent_id: agent_id
  } do
    uri = "arbor://test/process"
    set_profile_rules(agent_id, %{uri => :auto})
    grant_capability(agent_id, uri)

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
    agent_id: agent_id
  } do
    uri = "arbor://fs/read/b6/note.txt"
    set_profile_rules(agent_id, %{"arbor://fs/read" => :auto})

    assert {:ok, :authorized} =
             Trust.authorize(agent_id, uri, :read, verify_identity: false)

    assert {:ok, cap} = CapabilityStore.find_authorizing(agent_id, uri)
    assert cap.constraints == %{rate_limit: 300}
    assert cap.metadata[:source] == :trust_policy_enforcer
    assert cap.metadata[:mode] == :auto
    assert cap.metadata[:profile_uri] == "arbor://fs/read"
  end

  test "B6 security regression: irreversible profile-backed actions escalate instead of auto-run",
       %{
         agent_id: agent_id
       } do
    uri = "arbor://agent/create"
    set_profile_rules(agent_id, %{uri => :auto})

    assert {:error, :escalation_disabled} =
             Trust.authorize(agent_id, uri, :execute, verify_identity: false)

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
    agent_id: agent_id
  } do
    uri = "arbor://memory/recall"

    {:ok, _profile} =
      Arbor.Trust.Store.update_profile(agent_id, fn profile ->
        %{profile | baseline: :block, rules: %{uri => :auto}}
      end)

    assert {:ok, :authorized} =
             Trust.authorize(agent_id, uri, :read,
               security_ceilings: %{},
               verify_identity: false
             )

    assert {:ok, cap} = CapabilityStore.find_authorizing(agent_id, uri)
    assert cap.metadata[:source] == :trust_policy_enforcer
    assert cap.metadata[:profile_uri] == uri
  end

  test "security ceilings gate code/write even for permissive profiles", %{agent_id: agent_id} do
    promote_to_hands_off(agent_id)
    uri = "arbor://code/write/foo.ex"
    grant_capability(agent_id, uri)

    assert {:error, :escalation_disabled} = Trust.authorize(agent_id, uri, :execute)
  end

  test "security regression: trust-ask minting does not encode kernel approval constraints", %{
    agent_id: agent_id
  } do
    uri = "arbor://code/write/minted-ask.ex"
    Application.put_env(:arbor_trust, :policy_module, AskPolicy)

    assert {:error, :escalation_disabled} = Trust.authorize(agent_id, uri, :execute)
    assert {:ok, cap} = CapabilityStore.find_authorizing(agent_id, uri)
    assert cap.metadata[:source] == :trust_policy_enforcer
    assert cap.metadata[:mode] == :ask
    refute cap.constraints[:requires_approval]
  end

  test "security regression: baseline-only profile migration revokes stale policy caps", %{
    agent_id: agent_id
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
        metadata: %{source: :trust_policy_enforcer, mode: :auto}
      )

    assert {:ok, ^stale_cap} = CapabilityStore.get(stale_cap.id)

    {:ok, _profile} =
      Arbor.Trust.Store.update_profile(agent_id, fn profile ->
        %{profile | baseline: :ask}
      end)

    Process.sleep(50)
    assert {:error, :not_found} = CapabilityStore.get(stale_cap.id)
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

  test "trust subsystem error fails closed to gated", %{agent_id: agent_id} do
    uri = "arbor://historian/query"
    grant_capability(agent_id, uri)
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
    agent_id: agent_id
  } do
    workspace =
      System.tmp_dir!()
      |> Path.join("trust_auth_uri_workspace_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "public"))
    file_path = Path.join([workspace, "secret", "..", "public", "note.txt"])
    File.write!(Path.join(workspace, "public/note.txt"), "ok")
    on_exit(fn -> File.rm_rf!(workspace) end)

    set_profile_rules(agent_id, %{"arbor://fs/read/public" => :allow})

    assert {:ok, :authorized} =
             Trust.authorize(agent_id, "arbor://fs/read", :execute,
               file_path: file_path,
               workspace: workspace,
               verify_identity: false
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

  defp grant_capability(agent_id, resource_uri) do
    {:ok, cap} = Arbor.Security.grant(principal: agent_id, resource: resource_uri)
    cap
  end

  defp grant_preapproved_capability(agent_id, resource_uri) do
    cap = %Capability{
      id: "cap_preapproved_#{:erlang.unique_integer([:positive])}",
      resource_uri: resource_uri,
      principal_id: agent_id,
      granted_at: DateTime.utc_now(),
      expires_at: nil,
      constraints: %{},
      delegation_depth: 0,
      delegation_chain: [],
      metadata: %{provenance: %{source: :caps_file, issuer_id: "agent_test_issuer"}}
    }

    {:ok, :stored} = CapabilityStore.put(cap)
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

  defp restore_security(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_security(key, value), do: Application.put_env(:arbor_security, key, value)
  defp restore_trust(key, nil), do: Application.delete_env(:arbor_trust, key)
  defp restore_trust(key, value), do: Application.put_env(:arbor_trust, key, value)
end
