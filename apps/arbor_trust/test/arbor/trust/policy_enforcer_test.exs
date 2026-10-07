defmodule Arbor.Trust.PolicyEnforcerTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Trust.PolicyEnforcer
  import Arbor.Trust.TestHelpers, only: [actor_authority!: 0]

  defmodule ActionProfileProvider do
    alias Arbor.Contracts.Security.CapabilityProfile

    def action_namespace_capability_profiles do
      [
        CapabilityProfile.new!(%{
          uri_prefix: "arbor://action/browser/navigate",
          owner: :arbor_actions,
          blast_radius: :medium,
          reversibility: :read_only,
          effect_class: :read,
          data_class: :internal,
          arg_dependent: true,
          default_approval: :require_human,
          delegable: false,
          cost_class: :cheap,
          graduation_eligible: true
        })
      ]
    end
  end

  defmodule AutoPolicy do
    def effective_mode(_principal, _uri, _opts), do: :auto
  end

  defmodule AskPolicy do
    def effective_mode(_principal, _uri, _opts), do: :ask
  end

  defmodule BlockPolicy do
    def effective_mode(_principal, _uri, _opts), do: :block
  end

  setup do
    ensure_started(Arbor.Security.Identity.Registry)
    ensure_started(Arbor.Security.SystemAuthority)

    prev_trust_enforcer = Application.get_env(:arbor_trust, :policy_enforcer_enabled)
    prev_security_enforcer = Application.get_env(:arbor_security, :policy_enforcer_enabled)
    prev_policy = Application.get_env(:arbor_trust, :policy_module)
    prev_profile_overrides = Application.get_env(:arbor_trust, :capability_profile_overrides)
    prev_action_profile_provider = Application.get_env(:arbor_trust, :action_profile_provider)

    on_exit(fn ->
      restore(:arbor_trust, :policy_enforcer_enabled, prev_trust_enforcer)
      restore(:arbor_security, :policy_enforcer_enabled, prev_security_enforcer)
      restore(:arbor_trust, :policy_module, prev_policy)
      restore(:arbor_trust, :capability_profile_overrides, prev_profile_overrides)
      restore(:arbor_trust, :action_profile_provider, prev_action_profile_provider)
      rebind_trust!()
    end)

    {_identity, actor_authority} = actor_authority!()
    {:ok, actor_authority: actor_authority}
  end

  describe "enabled?/0" do
    test "uses compatibility fallback from security config" do
      Application.delete_env(:arbor_trust, :policy_enforcer_enabled)
      Application.put_env(:arbor_security, :policy_enforcer_enabled, false)
      refute PolicyEnforcer.enabled?()

      Application.put_env(:arbor_security, :policy_enforcer_enabled, true)
      assert PolicyEnforcer.enabled?()
    end

    test "trust config overrides compatibility fallback" do
      Application.put_env(:arbor_security, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_enforcer_enabled, false)

      refute PolicyEnforcer.enabled?()
    end
  end

  describe "ensure_capability/3" do
    test "returns an existing capability without minting", %{
      actor_authority: actor_authority
    } do
      agent_id = unique_agent()
      uri = "arbor://fs/read/policy-existing"

      {:ok, cap} =
        Arbor.Security.grant(
          principal: agent_id,
          resource: uri,
          actor_authority: actor_authority
        )

      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, BlockPolicy)

      assert {:ok, ^cap} = PolicyEnforcer.ensure_capability(agent_id, uri)
    end

    test "security regression: caller-owned mutation authority cannot self-mint", %{
      actor_authority: actor_authority
    } do
      agent_id = unique_agent()
      uri = "arbor://fs/read/policy-auto"

      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AutoPolicy)

      assert {:error, :unauthorized} =
               PolicyEnforcer.ensure_capability(agent_id, uri, actor_authority: actor_authority)

      refute capability_authorizing?(agent_id, uri)
    end

    test "resolves profile default constraints when a capability profile matches" do
      agent_id = unique_agent()
      uri = "arbor://fs/read/policy-default-constraints"

      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AutoPolicy)

      Application.put_env(:arbor_trust, :capability_profile_overrides, %{
        "arbor://fs/read" => %{default_constraints: %{rate_limit: 7}}
      })

      rebind_trust!()

      assert {:ok, spec} = PolicyEnforcer.grant_spec(agent_id, uri)
      assert spec.constraints == %{rate_limit: 7}
      assert spec.profile.uri_prefix == "arbor://fs/read"
      assert spec.profile.effect_class == :read
    end

    test "B6 security regression: high-risk auto standing does not mint a missing capability" do
      agent_id = unique_agent()
      uri = "arbor://fs/write/policy-high-risk-auto"

      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AutoPolicy)

      assert {:error, :unauthorized} = PolicyEnforcer.ensure_capability(agent_id, uri)
      refute capability_authorizing?(agent_id, uri)
    end

    test "B6 security regression: unprofiled auto standing does not mint baseline-only capability" do
      agent_id = unique_agent()
      uri = "arbor://unprofiled/policy-auto"

      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AutoPolicy)

      assert {:error, :unauthorized} = PolicyEnforcer.ensure_capability(agent_id, uri)
      refute capability_authorizing?(agent_id, uri)
    end

    test "B2 regression: action namespace profiles feed policy grant specs" do
      agent_id = unique_agent()
      uri = "arbor://action/browser/navigate"
      previous_provider = Application.get_env(:arbor_trust, :action_profile_provider)

      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AskPolicy)
      Application.put_env(:arbor_trust, :action_profile_provider, ActionProfileProvider)
      rebind_trust!()

      try do
        assert {:ok, spec} = PolicyEnforcer.grant_spec(agent_id, uri)
        assert spec.profile.uri_prefix == "arbor://action/browser/navigate"
        assert spec.profile.effect_class == :read
        assert spec.mode == :ask
      after
        restore(:arbor_trust, :action_profile_provider, previous_provider)
        rebind_trust!()
      end
    end

    test "resolves an ask-mode grant spec without minting" do
      agent_id = unique_agent()
      uri = "arbor://fs/read/policy-ask"

      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AskPolicy)

      assert {:ok, spec} = PolicyEnforcer.grant_spec(agent_id, uri)
      assert spec.mode == :ask
      refute spec.constraints[:requires_approval]
      refute capability_authorizing?(agent_id, uri)
    end

    test "denies when policy mode is :block" do
      agent_id = unique_agent()
      uri = "arbor://fs/read/policy-block"

      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, BlockPolicy)

      assert {:error, :unauthorized} = PolicyEnforcer.ensure_capability(agent_id, uri)
    end

    test "denies when disabled" do
      Application.put_env(:arbor_trust, :policy_enforcer_enabled, false)

      assert {:error, :unauthorized} =
               PolicyEnforcer.ensure_capability(unique_agent(), "arbor://fs/read/disabled")
    end
  end

  describe "sync_capabilities/2" do
    test "keeps mode-stamped ask grants while policy still asks", %{
      actor_authority: actor_authority
    } do
      agent_id = unique_agent()
      uri = "arbor://fs/read/policy-sync-ask"

      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AskPolicy)

      assert {:ok, cap} =
               Arbor.Security.grant(
                 principal: agent_id,
                 resource: uri,
                 metadata: %{source: :trust_policy_enforcer, mode: :ask},
                 actor_authority: actor_authority
               )

      assert :ok =
               PolicyEnforcer.sync_capabilities(agent_id,
                 actor_authority: actor_authority
               )

      assert capability_present?(agent_id, cap.id)
    end

    test "revokes legacy no-approval trust grants when policy now asks", %{
      actor_authority: actor_authority
    } do
      agent_id = unique_agent()
      uri = "arbor://fs/read/policy-sync-legacy-auto"

      {:ok, cap} =
        Arbor.Security.grant(
          principal: agent_id,
          resource: uri,
          metadata: %{source: :policy_enforcer},
          actor_authority: actor_authority
        )

      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AskPolicy)

      assert :ok =
               PolicyEnforcer.sync_capabilities(agent_id,
                 actor_authority: actor_authority
               )

      refute capability_present?(agent_id, cap.id)
    end

    test "security regression: revocation failures are returned and not counted as synced", %{
      actor_authority: actor_authority
    } do
      agent_id = unique_agent()
      uri = "arbor://fs/read/policy-sync-revoke-failure"

      {:ok, cap} =
        Arbor.Security.grant(
          principal: agent_id,
          resource: uri,
          metadata: %{source: :policy_enforcer},
          actor_authority: actor_authority
        )

      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AskPolicy)

      assert {:error, {:capability_revocation_failed, cap_id, _reason}} =
               PolicyEnforcer.sync_capabilities(agent_id, actor_authority: %{})

      assert cap_id == cap.id
      assert capability_present?(agent_id, cap.id)
    end
  end

  defp capability_present?(agent_id, capability_id) do
    {:ok, capabilities} = Arbor.Security.list_capabilities(agent_id)
    Enum.any?(capabilities, &(&1.id == capability_id))
  end

  defp capability_authorizing?(agent_id, resource_uri) do
    {:ok, capabilities} = Arbor.Security.list_capabilities(agent_id)

    Enum.any?(capabilities, fn capability ->
      Arbor.Security.capability_authorizes?(capability, resource_uri)
    end)
  end

  defp unique_agent, do: "agent_policy_enforcer_#{System.unique_integer([:positive])}"

  defp ensure_started(module) do
    if Process.whereis(module), do: :ok, else: start_supervised!({module, []})
  end

  defp rebind_trust! do
    _ = Application.stop(:arbor_trust)

    if function_exported?(Arbor.Trust.PolicyHost, :release_claim, 0) do
      Arbor.Trust.PolicyHost.release_claim()
    end

    {:ok, _} = Application.ensure_all_started(:arbor_trust)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
