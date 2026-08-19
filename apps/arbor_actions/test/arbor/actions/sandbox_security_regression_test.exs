defmodule Arbor.Actions.SandboxSecurityRegressionTest do
  @moduledoc """
  Security regression: sandbox actions are an agent/extension surface.

  Parent behavior (must fail on checkout of the exact parent):
  `Create.run/2` and `Destroy.run/2` treat a truthy `context[:agent_id]` as
  caller authority, so spoofing another principal id without the
  `authorized_principal` envelope can obtain that principal's sandbox
  grant.

  Fixed behavior: only `Arbor.Actions.authorized_principal/2` is caller
  authority. Direct `run/2` that only supplies `agent_id` fails closed and
  does not create or destroy. The authorized path is
  `Arbor.Actions.authorize_and_execute/4` then `authorize_create` /
  `authorize_destroy`.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Actions.Sandbox

  @create_resource "arbor://sandbox/create"
  @destroy_resource "arbor://sandbox/destroy"

  setup do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_trust)

    unless Process.whereis(Arbor.Trust.Store), do: start_supervised!(Arbor.Trust.Store)

    case Process.whereis(Arbor.Sandbox.Registry) do
      nil ->
        {:ok, _pid} = Arbor.Sandbox.Registry.start_link([])

      _pid ->
        :ok
    end

    previous = %{
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      identity: Application.get_env(:arbor_security, :identity_verification),
      strict: Application.get_env(:arbor_security, :strict_identity_mode),
      uri: Application.get_env(:arbor_security, :uri_registry_enforcement),
      escalation: Application.get_env(:arbor_security, :consensus_escalation_enabled),
      security_approval: Application.get_env(:arbor_security, :approval_guard_enabled),
      trust_approval: Application.get_env(:arbor_trust, :approval_guard_enabled),
      trust_enforcer: Application.get_env(:arbor_trust, :policy_enforcer_enabled)
    }

    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :identity_verification, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, false)
    Application.put_env(:arbor_security, :approval_guard_enabled, false)
    Application.put_env(:arbor_trust, :approval_guard_enabled, false)
    Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)

    unique = System.unique_integer([:positive])
    caller_id = "agent_p1b_sandbox_caller_#{unique}"
    target_id = "agent_p1b_sandbox_target_#{unique}"
    victim_id = "agent_p1b_sandbox_victim_#{unique}"

    base_path =
      Path.join(System.tmp_dir!(), "arbor_actions_sandbox_sec_#{unique}")

    File.mkdir_p!(base_path)

    on_exit(fn ->
      cleanup_sandbox(target_id)
      cleanup_sandbox(caller_id)
      cleanup_sandbox(victim_id)
      File.rm_rf(base_path)

      if Process.whereis(Arbor.Security.CapabilityStore) do
        Arbor.Security.CapabilityStore.revoke_all(caller_id)
        Arbor.Security.CapabilityStore.revoke_all(victim_id)
      end

      if Process.whereis(Arbor.Trust.Store) do
        Arbor.Trust.Store.delete_profile(caller_id)
        Arbor.Trust.Store.delete_profile(victim_id)
      end

      restore(:arbor_security, :reflex_checking_enabled, previous.reflex)
      restore(:arbor_security, :capability_signing_required, previous.signing)
      restore(:arbor_security, :identity_verification, previous.identity)
      restore(:arbor_security, :strict_identity_mode, previous.strict)
      restore(:arbor_security, :uri_registry_enforcement, previous.uri)
      restore(:arbor_security, :consensus_escalation_enabled, previous.escalation)
      restore(:arbor_security, :approval_guard_enabled, previous.security_approval)
      restore(:arbor_trust, :approval_guard_enabled, previous.trust_approval)
      restore(:arbor_trust, :policy_enforcer_enabled, previous.trust_enforcer)
    end)

    {:ok,
     caller_id: caller_id, target_id: target_id, victim_id: victim_id, base_path: base_path}
  end

  test "security regression: Create.run/2 with only context[:agent_id] is denied and does not create",
       %{target_id: target_id} do
    assert {:error, "Unauthorized: :action_principal_authority_required"} =
             Sandbox.Create.run(%{agent_id: target_id}, %{agent_id: target_id})

    assert {:error, :not_found} = Arbor.Sandbox.get(target_id)
  end

  test "security regression: Destroy.run/2 with only context[:agent_id] is denied and does not destroy",
       %{target_id: target_id, base_path: base_path} do
    {:ok, sandbox} = Arbor.Sandbox.create(target_id, base_path: base_path)

    assert {:error, "Unauthorized: :action_principal_authority_required"} =
             Sandbox.Destroy.run(%{sandbox_id: sandbox.id}, %{agent_id: target_id})

    assert {:ok, ^sandbox} = Arbor.Sandbox.get(sandbox.id)
  end

  test "security regression: spoofing another principal id without the envelope cannot obtain that principal's sandbox authority",
       %{victim_id: victim_id, target_id: target_id} do
    authorize_agent(victim_id, @create_resource)

    assert {:error, "Unauthorized: :action_principal_authority_required"} =
             Sandbox.Create.run(%{agent_id: target_id}, %{agent_id: victim_id})

    assert {:error, :not_found} = Arbor.Sandbox.get(target_id)
  end

  test "security regression: authorize_and_execute/4 without a grant is denied and does not create",
       %{caller_id: caller_id, target_id: target_id} do
    assert {:error, :unauthorized} =
             Arbor.Actions.authorize_and_execute(
               caller_id,
               Sandbox.Create,
               %{agent_id: target_id},
               %{agent_id: caller_id}
             )

    assert {:error, :not_found} = Arbor.Sandbox.get(target_id)
  end

  test "security regression: authorized authorize_and_execute/4 uses authorize_create and creates",
       %{caller_id: caller_id, target_id: target_id} do
    authorize_agent(caller_id, @create_resource)

    assert {:ok, result} =
             Arbor.Actions.authorize_and_execute(
               caller_id,
               Sandbox.Create,
               %{agent_id: target_id},
               %{agent_id: caller_id}
             )

    assert result.status == "created"
    assert result.agent_id == target_id
    assert {:ok, sandbox} = Arbor.Sandbox.get(result.sandbox_id)
    assert sandbox.agent_id == target_id
  end

  test "security regression: authorized authorize_and_execute/4 uses authorize_destroy",
       %{caller_id: caller_id, target_id: target_id, base_path: base_path} do
    {:ok, sandbox} = Arbor.Sandbox.create(target_id, base_path: base_path)

    assert {:error, :unauthorized} =
             Arbor.Actions.authorize_and_execute(
               caller_id,
               Sandbox.Destroy,
               %{sandbox_id: sandbox.id},
               %{agent_id: caller_id}
             )

    assert {:ok, ^sandbox} = Arbor.Sandbox.get(sandbox.id)

    authorize_agent(caller_id, @destroy_resource)

    assert {:ok, result} =
             Arbor.Actions.authorize_and_execute(
               caller_id,
               Sandbox.Destroy,
               %{sandbox_id: sandbox.id},
               %{agent_id: caller_id}
             )

    assert result.status == "destroyed"
    assert {:error, :not_found} = Arbor.Sandbox.get(sandbox.id)
  end

  defp authorize_agent(agent_id, resource) do
    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(agent_id)
    :ok = Arbor.Trust.Store.store_profile(%{profile | rules: %{resource => :auto}})
    assert {:ok, _capability} = Arbor.Security.grant(principal: agent_id, resource: resource)
  end

  defp cleanup_sandbox(id) do
    if Process.whereis(Arbor.Sandbox.Registry) do
      case Arbor.Sandbox.get(id) do
        {:ok, sandbox} -> Arbor.Sandbox.destroy(sandbox.id)
        {:error, :not_found} -> :ok
      end
    end

    File.rm_rf(Path.expand("~/.arbor/sandbox/agents/#{id}"))
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
