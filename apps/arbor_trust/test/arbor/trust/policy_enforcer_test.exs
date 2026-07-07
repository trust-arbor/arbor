defmodule Arbor.Trust.PolicyEnforcerTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Security.CapabilityStore
  alias Arbor.Trust.PolicyEnforcer

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
    ensure_started(CapabilityStore)

    prev_trust_enforcer = Application.get_env(:arbor_trust, :policy_enforcer_enabled)
    prev_security_enforcer = Application.get_env(:arbor_security, :policy_enforcer_enabled)
    prev_policy = Application.get_env(:arbor_trust, :policy_module)
    prev_profile_overrides = Application.get_env(:arbor_trust, :capability_profile_overrides)

    on_exit(fn ->
      restore(:arbor_trust, :policy_enforcer_enabled, prev_trust_enforcer)
      restore(:arbor_security, :policy_enforcer_enabled, prev_security_enforcer)
      restore(:arbor_trust, :policy_module, prev_policy)
      restore(:arbor_trust, :capability_profile_overrides, prev_profile_overrides)
    end)

    :ok
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
    test "returns an existing capability without minting" do
      agent_id = unique_agent()
      uri = "arbor://fs/read/policy-existing"
      {:ok, cap} = Arbor.Security.grant(principal: agent_id, resource: uri)

      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, BlockPolicy)

      assert {:ok, ^cap} = PolicyEnforcer.ensure_capability(agent_id, uri)
    end

    test "mints an explicit capability when policy mode is :auto" do
      agent_id = unique_agent()
      uri = "arbor://fs/read/policy-auto"

      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AutoPolicy)

      assert {:ok, cap} = PolicyEnforcer.ensure_capability(agent_id, uri)
      assert cap.principal_id == agent_id
      assert cap.resource_uri == uri
      assert cap.metadata[:source] == :trust_policy_enforcer
      refute cap.constraints[:requires_approval]
    end

    test "mints profile default constraints when a capability profile matches" do
      agent_id = unique_agent()
      uri = "arbor://fs/read/policy-default-constraints"

      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AutoPolicy)

      Application.put_env(:arbor_trust, :capability_profile_overrides, %{
        "arbor://fs/read" => %{default_constraints: %{rate_limit: 7}}
      })

      assert {:ok, cap} = PolicyEnforcer.ensure_capability(agent_id, uri)
      assert cap.constraints == %{rate_limit: 7}
      assert cap.metadata[:profile_uri] == "arbor://fs/read"
      assert cap.metadata[:profile_effect_class] == :read
    end

    test "B6 security regression: high-risk auto standing does not mint a missing capability" do
      agent_id = unique_agent()
      uri = "arbor://fs/write/policy-high-risk-auto"

      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AutoPolicy)

      assert {:error, :unauthorized} = PolicyEnforcer.ensure_capability(agent_id, uri)
      assert {:error, :not_found} = CapabilityStore.find_authorizing(agent_id, uri)
    end

    test "B6 security regression: unprofiled auto standing does not mint baseline-only capability" do
      agent_id = unique_agent()
      uri = "arbor://unprofiled/policy-auto"

      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AutoPolicy)

      assert {:error, :unauthorized} = PolicyEnforcer.ensure_capability(agent_id, uri)
      assert {:error, :not_found} = CapabilityStore.find_authorizing(agent_id, uri)
    end

    test "mints an explicit trust-stamped capability when policy mode is :ask" do
      agent_id = unique_agent()
      uri = "arbor://fs/read/policy-ask"

      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AskPolicy)

      assert {:ok, cap} = PolicyEnforcer.ensure_capability(agent_id, uri)
      assert cap.metadata[:source] == :trust_policy_enforcer
      assert cap.metadata[:mode] == :ask
      refute cap.constraints[:requires_approval]
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

  describe "sync_capabilities/1" do
    test "keeps mode-stamped ask grants while policy still asks" do
      agent_id = unique_agent()
      uri = "arbor://fs/read/policy-sync-ask"

      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AskPolicy)

      assert {:ok, cap} = PolicyEnforcer.ensure_capability(agent_id, uri)
      assert :ok = PolicyEnforcer.sync_capabilities(agent_id)
      assert {:ok, ^cap} = CapabilityStore.get(cap.id)
    end

    test "revokes legacy no-approval trust grants when policy now asks" do
      agent_id = unique_agent()
      uri = "arbor://fs/read/policy-sync-legacy-auto"

      {:ok, cap} =
        Arbor.Security.grant(
          principal: agent_id,
          resource: uri,
          metadata: %{source: :policy_enforcer}
        )

      Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AskPolicy)

      assert :ok = PolicyEnforcer.sync_capabilities(agent_id)
      assert {:error, :not_found} = CapabilityStore.get(cap.id)
    end
  end

  defp unique_agent, do: "agent_policy_enforcer_#{System.unique_integer([:positive])}"

  defp ensure_started(module) do
    if Process.whereis(module), do: :ok, else: start_supervised!({module, []})
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
