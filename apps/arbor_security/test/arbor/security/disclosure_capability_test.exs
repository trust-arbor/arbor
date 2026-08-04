defmodule Arbor.Security.DisclosureCapabilityTest do
  @moduledoc """
  Security regression tests for the interactive-disclosure capability
  convention (VP-05D2A0, prerequisite for VOICE-17, which remains planned).

  These fail on a build without the hardened `DisclosureCapability` module
  (any id would either not exist or would be accepted without the closed
  shape/route/signature/scope checks below) and pass with it.
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.{Capability, Identity}

  alias Arbor.Security.{
    Capability.Signer,
    CapabilityStore,
    Config,
    DisclosureCapability,
    Identity.Registry,
    SystemAuthority
  }

  defp unique, do: :erlang.unique_integer([:positive])

  defp valid_issue_opts(overrides \\ []) do
    n = unique()

    [
      principal_id: Arbor.Identifiers.generate_agent_id(),
      session_id: "session_#{n}",
      task_id: "task_#{n}",
      principal_scope: "human_#{n}",
      destination: "api.anthropic.com",
      provider: "anthropic",
      runtime: "arbor"
    ]
    |> Keyword.merge(overrides)
  end

  defp fetch_opts(cap, overrides \\ []) do
    [
      principal_id: cap.principal_id,
      session_id: cap.session_id,
      task_id: cap.task_id,
      principal_scope: cap.principal_scope,
      egress_destination: get_in(cap.constraints, [:disclosure, :destination]),
      egress_provider: get_in(cap.constraints, [:disclosure, :provider]),
      egress_runtime: get_in(cap.constraints, [:disclosure, :runtime])
    ]
    |> Keyword.merge(overrides)
  end

  describe "issue/1" do
    @tag spec: "VP-05D2A0"
    test "mints a signed capability in the disclosure namespace with forced invariants" do
      assert {:ok, cap} = DisclosureCapability.issue(valid_issue_opts())
      assert Capability.signed?(cap)
      assert String.starts_with?(cap.resource_uri, "arbor://egress/disclose/")
      assert cap.delegation_depth == 0
      assert cap.max_uses == nil
      assert cap.parent_capability_id == nil
      assert cap.delegation_chain == []
      assert cap.constraints.disclosure.kind == :interactive_human
    end

    @tag spec: "VP-05D2A0"
    test "two calls with identical route fields produce distinct resource_uris" do
      opts = valid_issue_opts()
      assert {:ok, cap1} = DisclosureCapability.issue(opts)
      assert {:ok, cap2} = DisclosureCapability.issue(opts)
      refute cap1.resource_uri == cap2.resource_uri
      assert {:ok, _} = CapabilityStore.get(cap1.id)
      assert {:ok, _} = CapabilityStore.get(cap2.id)
    end

    @tag spec: "VP-05D2A0"
    test "rejects an unknown opt key" do
      assert {:error, :unknown_issue_option} =
               DisclosureCapability.issue(valid_issue_opts(extra_flag: true))
    end

    @tag spec: "VP-05D2A0"
    test "rejects a duplicate opt key" do
      opts = valid_issue_opts() ++ [destination: "other.example.com"]
      assert {:error, :duplicate_issue_option} = DisclosureCapability.issue(opts)
    end

    @tag spec: "VP-05D2A0"
    test "max_uses and delegation_depth are not accepted opts at all" do
      assert {:error, :unknown_issue_option} =
               DisclosureCapability.issue(valid_issue_opts(max_uses: 1))

      assert {:error, :unknown_issue_option} =
               DisclosureCapability.issue(valid_issue_opts(delegation_depth: 1))
    end

    @tag spec: "VP-05D2A0"
    test "accepts a canonical future provider id without a stale allowlist" do
      assert {:ok, cap} =
               DisclosureCapability.issue(valid_issue_opts(provider: "some_future_provider"))

      assert cap.constraints.disclosure.provider == "some_future_provider"
    end

    @tag spec: "VP-05D2A0"
    test "rejects a malformed provider route id" do
      assert {:error, :invalid_provider} =
               DisclosureCapability.issue(valid_issue_opts(provider: "Bad Provider/Route"))
    end

    @tag spec: "VP-05D2A0"
    test "rejects a runtime outside the accepted-label allowlist" do
      assert {:error, :invalid_runtime} =
               DisclosureCapability.issue(valid_issue_opts(runtime: "not_a_real_runtime"))
    end

    @tag spec: "VP-05D2A0"
    test "rejects a principal_scope without the human_ prefix" do
      assert {:error, :invalid_binding_field} =
               DisclosureCapability.issue(valid_issue_opts(principal_scope: "agent_not_human"))
    end

    @tag spec: "VP-05D2A0"
    test "security regression: rejects a non-agent executing principal" do
      assert {:error, :invalid_binding_field} =
               DisclosureCapability.issue(valid_issue_opts(principal_id: "human_not_an_agent"))
    end

    @tag spec: "VP-05D2A0"
    test "security regression: rejects an empty human principal suffix" do
      assert {:error, :invalid_binding_field} =
               DisclosureCapability.issue(valid_issue_opts(principal_scope: "human_"))
    end

    @tag spec: "VP-05D2A0"
    test "rejects a control-character destination" do
      assert {:error, :invalid_destination} =
               DisclosureCapability.issue(valid_issue_opts(destination: "bad\tvalue"))
    end

    @tag spec: "VP-05D2A0"
    test "rejects an untrimmed destination" do
      assert {:error, :invalid_destination} =
               DisclosureCapability.issue(valid_issue_opts(destination: " padded "))
    end

    @tag spec: "VP-05D2A0"
    test "rejects a non-positive or non-integer ttl_seconds" do
      assert {:error, :invalid_ttl} = DisclosureCapability.issue(valid_issue_opts(ttl_seconds: 0))

      assert {:error, :invalid_ttl} =
               DisclosureCapability.issue(valid_issue_opts(ttl_seconds: -5))

      assert {:error, :invalid_ttl} =
               DisclosureCapability.issue(valid_issue_opts(ttl_seconds: 1.5))
    end

    @tag spec: "VP-05D2A0"
    test "accepts a positive ttl_seconds" do
      assert {:ok, cap} = DisclosureCapability.issue(valid_issue_opts(ttl_seconds: 60))
      assert DateTime.diff(cap.expires_at, cap.granted_at) == 60
    end
  end

  describe "fetch_and_validate/2" do
    setup do
      {:ok, cap} = DisclosureCapability.issue(valid_issue_opts())
      %{cap: cap}
    end

    @tag spec: "VP-05D2A0"
    test "a valid exact id revalidates successfully (base-fail regression)", %{cap: cap} do
      assert {:ok, found} = DisclosureCapability.fetch_and_validate(cap.id, fetch_opts(cap))
      assert found.id == cap.id
    end

    @tag spec: "VP-05D2A0"
    test "not-found id fails closed", %{cap: cap} do
      assert {:error, :not_found} =
               DisclosureCapability.fetch_and_validate(capability_id(), fetch_opts(cap))
    end

    @tag spec: "VP-05D2A0"
    test "revoked id fails closed", %{cap: cap} do
      :ok = CapabilityStore.revoke(cap.id)

      assert {:error, :not_found} =
               DisclosureCapability.fetch_and_validate(cap.id, fetch_opts(cap))
    end

    @tag spec: "VP-05D2A0"
    test "malformed capability_id fails closed", %{cap: cap} do
      assert {:error, :disclosure_capability_id_malformed} =
               DisclosureCapability.fetch_and_validate("bad id\twith control", fetch_opts(cap))
    end

    @tag spec: "VP-05D2A0"
    test "wrong principal fails closed", %{cap: cap} do
      assert {:error, :disclosure_capability_wrong_principal} =
               DisclosureCapability.fetch_and_validate(
                 cap.id,
                 fetch_opts(cap, principal_id: Arbor.Identifiers.generate_agent_id())
               )
    end

    @tag spec: "VP-05D2A0"
    test "wrong session fails closed", %{cap: cap} do
      # Session/task/human are checked together, inside the ONE linearized
      # CapabilityStore.get_valid_disclosure/3 call (Capability.scope_matches?/2)
      # — see the moduledoc note on fetch_and_validate/2. Distinct from
      # :disclosure_capability_wrong_principal, which the store checks first
      # and separately.
      assert {:error, :disclosure_capability_rejected} =
               DisclosureCapability.fetch_and_validate(
                 cap.id,
                 fetch_opts(cap, session_id: "session_someone_else")
               )
    end

    @tag spec: "VP-05D2A0"
    test "wrong turn/task fails closed", %{cap: cap} do
      assert {:error, :disclosure_capability_rejected} =
               DisclosureCapability.fetch_and_validate(
                 cap.id,
                 fetch_opts(cap, task_id: "task_someone_else")
               )
    end

    @tag spec: "VP-05D2A0"
    test "wrong human fails closed", %{cap: cap} do
      assert {:error, :disclosure_capability_rejected} =
               DisclosureCapability.fetch_and_validate(
                 cap.id,
                 fetch_opts(cap, principal_scope: "human_someone_else")
               )
    end

    @tag spec: "VP-05D2A0"
    test "wrong route fails closed", %{cap: cap} do
      assert {:error, :disclosure_capability_wrong_route} =
               DisclosureCapability.fetch_and_validate(
                 cap.id,
                 fetch_opts(cap, egress_destination: "evil.example.com")
               )
    end

    @tag spec: "VP-05D2A0"
    test "forged signature fails closed", %{cap: cap} do
      forged = %{cap | issuer_signature: :crypto.strong_rand_bytes(64)}
      {:ok, :stored} = CapabilityStore.put(forged)

      assert {:error, :disclosure_capability_rejected} =
               DisclosureCapability.fetch_and_validate(forged.id, fetch_opts(cap))
    end

    @tag spec: "VP-05D2A0"
    test "unsigned capability fails closed even when global signing is not required", %{cap: cap} do
      original = Application.get_env(:arbor_security, :capability_signing_required)
      Application.put_env(:arbor_security, :capability_signing_required, false)
      on_exit(fn -> restore_config(:capability_signing_required, original) end)

      unsigned = %{cap | issuer_signature: nil, issuer_id: nil}
      {:ok, :stored} = CapabilityStore.put(unsigned)

      assert {:error, :disclosure_capability_rejected} =
               DisclosureCapability.fetch_and_validate(unsigned.id, fetch_opts(cap))
    end

    @tag spec: "VP-05D2A0"
    test "expired capability fails closed", %{cap: cap} do
      expired = %{cap | expires_at: DateTime.add(DateTime.utc_now(), -10, :second)}
      {:ok, resigned} = SystemAuthority.sign_capability(expired)
      {:ok, :stored} = CapabilityStore.put(resigned)

      assert {:error, :disclosure_capability_rejected} =
               DisclosureCapability.fetch_and_validate(resigned.id, fetch_opts(cap))
    end

    @tag spec: "VP-05D2A0"
    test "security regression: a future-dated grant fails closed", %{cap: cap} do
      granted_at = DateTime.add(DateTime.utc_now(), 3600, :second)
      future = %{cap | granted_at: granted_at, expires_at: DateTime.add(granted_at, 300, :second)}
      {:ok, resigned} = SystemAuthority.sign_capability(future)
      {:ok, :stored} = CapabilityStore.put(resigned)

      assert {:error, :disclosure_capability_rejected} =
               DisclosureCapability.fetch_and_validate(resigned.id, fetch_opts(cap))
    end

    @tag spec: "VP-05D2A0"
    test "security regression: a non-positive validity window fails closed", %{cap: cap} do
      expires_at = DateTime.add(DateTime.utc_now(), 300, :second)
      invalid = %{cap | granted_at: DateTime.add(expires_at, 1, :second), expires_at: expires_at}
      {:ok, resigned} = SystemAuthority.sign_capability(invalid)
      {:ok, :stored} = CapabilityStore.put(resigned)

      assert {:error, :disclosure_capability_rejected} =
               DisclosureCapability.fetch_and_validate(resigned.id, fetch_opts(cap))
    end

    @tag spec: "VP-05D2A0"
    test "security regression: an overlong validity window fails closed", %{cap: cap} do
      max_ttl = Config.disclosure_capability_max_ttl_seconds()
      granted_at = DateTime.utc_now()

      overlong = %{
        cap
        | granted_at: granted_at,
          expires_at: DateTime.add(granted_at, max_ttl + 1, :second)
      }

      {:ok, resigned} = SystemAuthority.sign_capability(overlong)
      {:ok, :stored} = CapabilityStore.put(resigned)

      assert {:error, :disclosure_capability_rejected} =
               DisclosureCapability.fetch_and_validate(resigned.id, fetch_opts(cap))
    end

    @tag spec: "VP-05D2A0"
    test "security regression: only the current SystemAuthority issuer is accepted", %{cap: cap} do
      {:ok, other_identity} = Identity.generate()
      :ok = Registry.register(Identity.public_only(other_identity))

      signed =
        cap
        |> Map.put(:issuer_id, other_identity.agent_id)
        |> Signer.sign(other_identity.private_key)

      {:ok, :stored} = CapabilityStore.put(signed)

      assert {:error, :disclosure_capability_rejected} =
               DisclosureCapability.fetch_and_validate(signed.id, fetch_opts(cap))
    end

    @tag spec: "VP-05D2A0"
    test "security regression: disclosure resource URI requires one lowercase-hex token segment",
         %{cap: cap} do
      prefix = "arbor://egress/disclose/"
      token = String.replace_prefix(cap.resource_uri, prefix, "")

      for uri <- [cap.resource_uri <> "/extra", prefix <> String.upcase(token)] do
        malformed = %{cap | resource_uri: uri}
        {:ok, resigned} = SystemAuthority.sign_capability(malformed)
        {:ok, :stored} = CapabilityStore.put(resigned)

        assert {:error, :disclosure_capability_uri_malformed} =
                 DisclosureCapability.fetch_and_validate(resigned.id, fetch_opts(cap))
      end
    end

    @tag spec: "VP-05D2A0"
    test "delegated (parent_capability_id set) fails closed", %{cap: cap} do
      delegated = %{cap | parent_capability_id: "cap_some_parent_#{unique()}"}
      {:ok, resigned} = SystemAuthority.sign_capability(delegated)
      {:ok, :stored} = CapabilityStore.put(resigned)

      assert {:error, :disclosure_capability_delegated} =
               DisclosureCapability.fetch_and_validate(resigned.id, fetch_opts(cap))
    end

    @tag spec: "VP-05D2A0"
    test "delegated (non-empty delegation_chain) fails closed", %{cap: cap} do
      # The store's shared candidate check also cryptographically verifies any
      # delegation_chain (delegation_chain_valid?/1, reused from the ordinary
      # path) — a garbage/unverifiable record would already be rejected there
      # with the generic :disclosure_capability_rejected. Disable that
      # verification here so this test isolates DisclosureCapability's OWN
      # shape rule: a disclosure capability must have no chain at all,
      # verifiable or not.
      original = Application.get_env(:arbor_security, :delegation_chain_verification_enabled)
      Application.put_env(:arbor_security, :delegation_chain_verification_enabled, false)
      on_exit(fn -> restore_config(:delegation_chain_verification_enabled, original) end)

      chain_record = %{
        delegator_id: "agent_delegator",
        delegator_signature: <<0, 1, 2, 3>>,
        constraints: %{},
        delegated_at: DateTime.utc_now()
      }

      delegated = %{cap | delegation_chain: [chain_record]}
      {:ok, resigned} = SystemAuthority.sign_capability(delegated)
      {:ok, :stored} = CapabilityStore.put(resigned)

      assert {:error, :disclosure_capability_delegated} =
               DisclosureCapability.fetch_and_validate(resigned.id, fetch_opts(cap))
    end

    @tag spec: "VP-05D2A0"
    test "nonzero delegation_depth fails closed", %{cap: cap} do
      deep = %{cap | delegation_depth: 1}
      {:ok, resigned} = SystemAuthority.sign_capability(deep)
      {:ok, :stored} = CapabilityStore.put(resigned)

      assert {:error, :disclosure_capability_nonzero_depth} =
               DisclosureCapability.fetch_and_validate(resigned.id, fetch_opts(cap))
    end

    @tag spec: "VP-05D2A0"
    test "any max_uses (including 1) fails closed", %{cap: cap} do
      for max_uses <- [1, 50] do
        capped = %{cap | max_uses: max_uses}
        {:ok, resigned} = SystemAuthority.sign_capability(capped)
        {:ok, :stored} = CapabilityStore.put(resigned)

        assert {:error, :disclosure_capability_max_uses_forbidden} =
                 DisclosureCapability.fetch_and_validate(resigned.id, fetch_opts(cap))
      end
    end

    @tag spec: "VP-05D2A0"
    test "dual-purpose constraints (top-level egress + disclosure) fails closed", %{cap: cap} do
      dual = %{
        cap
        | constraints: Map.put(cap.constraints, :egress, %{max_tier: :external_provider})
      }

      {:ok, resigned} = SystemAuthority.sign_capability(dual)
      {:ok, :stored} = CapabilityStore.put(resigned)

      assert {:error, :disclosure_capability_dual_purpose} =
               DisclosureCapability.fetch_and_validate(resigned.id, fetch_opts(cap))
    end

    @tag spec: "VP-05D2A0"
    test "unknown/duplicate-spelled nested field fails closed", %{cap: cap} do
      bad_disclosure = Map.put(cap.constraints.disclosure, :extra, "smuggled")
      bad = %{cap | constraints: %{disclosure: bad_disclosure}}
      {:ok, resigned} = SystemAuthority.sign_capability(bad)
      {:ok, :stored} = CapabilityStore.put(resigned)

      assert {:error, :disclosure_capability_unknown_field} =
               DisclosureCapability.fetch_and_validate(resigned.id, fetch_opts(cap))
    end

    @tag spec: "VP-05D2A0"
    test "missing route field fails closed", %{cap: cap} do
      bad_disclosure = Map.delete(cap.constraints.disclosure, :destination)
      bad = %{cap | constraints: %{disclosure: bad_disclosure}}
      {:ok, resigned} = SystemAuthority.sign_capability(bad)
      {:ok, :stored} = CapabilityStore.put(resigned)

      assert {:error, :disclosure_capability_missing_route_field} =
               DisclosureCapability.fetch_and_validate(resigned.id, fetch_opts(cap))
    end

    @tag spec: "VP-05D2A0"
    test "wrong kind fails closed", %{cap: cap} do
      bad_disclosure = Map.put(cap.constraints.disclosure, :kind, :something_else)
      bad = %{cap | constraints: %{disclosure: bad_disclosure}}
      {:ok, resigned} = SystemAuthority.sign_capability(bad)
      {:ok, :stored} = CapabilityStore.put(resigned)

      assert {:error, :disclosure_capability_wrong_kind} =
               DisclosureCapability.fetch_and_validate(resigned.id, fetch_opts(cap))
    end
  end

  describe "Arbor.Security.validate_disclosure_capability/3" do
    setup do
      {:ok, cap} = Arbor.Security.issue_disclosure_capability(valid_issue_opts())
      %{cap: cap}
    end

    @tag spec: "VP-05D2A0"
    test "security regression: exact active authority validates while the egress gate is dark",
         %{cap: cap} do
      original = Application.get_env(:arbor_security, :egress_gate_enforcing)
      Application.put_env(:arbor_security, :egress_gate_enforcing, false)
      on_exit(fn -> restore_config(:egress_gate_enforcing, original) end)

      opts = Keyword.delete(fetch_opts(cap), :principal_id)

      assert :ok =
               Arbor.Security.validate_disclosure_capability(cap.principal_id, cap.id, opts)
    end

    @tag spec: "VP-05D2A0"
    test "security regression: revoked exact authority fails closed while the egress gate is dark",
         %{cap: cap} do
      original = Application.get_env(:arbor_security, :egress_gate_enforcing)
      Application.put_env(:arbor_security, :egress_gate_enforcing, false)
      on_exit(fn -> restore_config(:egress_gate_enforcing, original) end)

      :ok = CapabilityStore.revoke(cap.id)
      opts = Keyword.delete(fetch_opts(cap), :principal_id)

      assert {:error, _reason} =
               Arbor.Security.validate_disclosure_capability(cap.principal_id, cap.id, opts)
    end

    @tag spec: "VP-05D2A0"
    test "security regression: positional principal and exact route cannot be overridden", %{
      cap: cap
    } do
      opts =
        cap
        |> fetch_opts(
          principal_id: Arbor.Identifiers.generate_agent_id(),
          egress_provider: "openai"
        )

      assert {:error, :disclosure_capability_wrong_route} =
               Arbor.Security.validate_disclosure_capability(cap.principal_id, cap.id, opts)

      assert {:error, :disclosure_capability_wrong_principal} =
               Arbor.Security.validate_disclosure_capability(
                 Arbor.Identifiers.generate_agent_id(),
                 cap.id,
                 Keyword.put(opts, :egress_provider, "anthropic")
               )
    end

    @tag spec: "VP-05D2A0"
    test "malformed facade inputs fail closed without raising", %{cap: cap} do
      assert {:error, :invalid_fetch_opts} =
               Arbor.Security.validate_disclosure_capability(cap.principal_id, cap.id, %{})

      assert {:error, _reason} =
               Arbor.Security.validate_disclosure_capability(
                 cap.principal_id,
                 "not-a-capability-id",
                 Keyword.delete(fetch_opts(cap), :principal_id)
               )
    end
  end

  defp restore_config(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_config(key, value), do: Application.put_env(:arbor_security, key, value)

  defp capability_id do
    "cap_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end
end
