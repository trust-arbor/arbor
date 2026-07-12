defmodule Arbor.Agent.IntentDispatcherPrincipalSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.IntentDispatcher
  alias Arbor.Contracts.Memory.{Intent, Percept}

  @moduletag :fast
  @moduletag :security_regression

  setup do
    ensure_runtime_started()
    previous = security_config()
    configure_minimal_security()

    agent_id = "agent_intent_principal_#{System.unique_integer([:positive])}"
    marker = Path.join(System.tmp_dir!(), "#{agent_id}_forged")
    File.rm(marker)

    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(agent_id)

    rules =
      profile.rules
      |> Map.put("arbor://shell/exec/echo", :auto)
      |> Map.put("arbor://shell/exec/touch", :auto)

    :ok = Arbor.Trust.Store.store_profile(%{profile | rules: rules})

    for resource <- ["arbor://shell/exec/echo", "arbor://shell/exec/touch"] do
      assert {:ok, _capability} =
               Arbor.Security.grant(principal: agent_id, resource: resource)
    end

    on_exit(fn ->
      restore_security_config(previous)
      Arbor.Security.CapabilityStore.revoke_all(agent_id)
      File.rm(marker)
    end)

    {:ok, agent_id: agent_id, marker: marker}
  end

  test "security regression: trusted scope executes childless Shell and is removed after callback",
       %{agent_id: agent_id} do
    intent = shell_intent("echo intent-dispatch-authorized")

    assert {:ok, %Percept{outcome: :failure, error: :authenticated_principal_required}} =
             IntentDispatcher.dispatch(agent_id, intent)

    assert {:ok, %Percept{outcome: :success} = success} =
             Arbor.Actions.with_principal_authority(agent_id, fn authority ->
               send(self(), {:principal_authority, authority})
               IntentDispatcher.dispatch(agent_id, intent)
             end)

    assert success.data.result.stdout =~ "intent-dispatch-authorized"
    assert_receive {:principal_authority, stale_authority}

    assert {:error, :authenticated_principal_required} =
             Arbor.Actions.execute_with_principal_authority(
               stale_authority,
               Arbor.Actions.Shell.Execute,
               %{command: "echo stale-principal-authority", sandbox: :none},
               %{}
             )

    assert {:ok, %Percept{outcome: :failure, error: :authenticated_principal_required}} =
             IntentDispatcher.dispatch(agent_id, intent)
  end

  test "security regression: active principal rejects forged context identity", %{
    agent_id: agent_id,
    marker: marker
  } do
    intent = shell_intent("touch #{marker}")

    assert {:ok,
            %Percept{
              outcome: :failure,
              error: {:principal_context_mismatch, ^agent_id, ["agent_forged"]}
            }} =
             Arbor.Actions.with_principal_authority(agent_id, fn ->
               IntentDispatcher.dispatch(agent_id, intent, context: %{agent_id: "agent_forged"})
             end)

    refute File.exists?(marker)
  end

  defp shell_intent(command) do
    Intent.action(:shell_execute, %{command: command, sandbox: :none},
      capability: "arbor://shell"
    )
  end

  defp ensure_runtime_started do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_trust)
    {:ok, _} = Application.ensure_all_started(:arbor_shell)

    security_children = [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.Constraint.RateLimiter, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []}
    ]

    for {module, opts} <- security_children do
      unless Process.whereis(module) do
        case Supervisor.start_child(Arbor.Security.Supervisor, {module, opts}) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to start #{inspect(module)}: #{inspect(reason)}"
        end
      end
    end

    unless Process.whereis(Arbor.Trust.Store) do
      start_supervised!(Arbor.Trust.Store)
    end

    unless Process.whereis(Arbor.Shell.ExecutablePolicy) do
      start_supervised!({Arbor.Shell.ExecutablePolicy, startup_path: System.get_env("PATH", "")})
    end

    unless Process.whereis(Arbor.Shell.ExecutionRegistry) do
      start_supervised!(Arbor.Shell.ExecutionRegistry)
    end

    unless Process.whereis(Arbor.Shell.PortSessionSupervisor) do
      start_supervised!(
        {DynamicSupervisor, name: Arbor.Shell.PortSessionSupervisor, strategy: :one_for_one}
      )
    end
  end

  defp security_config do
    %{
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      identity_verification: Application.get_env(:arbor_security, :identity_verification),
      identity: Application.get_env(:arbor_security, :strict_identity_mode),
      uri_registry: Application.get_env(:arbor_security, :uri_registry_enforcement),
      escalation: Application.get_env(:arbor_security, :consensus_escalation_enabled),
      security_approval: Application.get_env(:arbor_security, :approval_guard_enabled),
      receipts: Application.get_env(:arbor_security, :invocation_receipts_enabled),
      trust_guard: Application.get_env(:arbor_trust, :approval_guard_enabled),
      trust_enforcer: Application.get_env(:arbor_trust, :policy_enforcer_enabled)
    }
  end

  defp configure_minimal_security do
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :identity_verification, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, false)
    Application.put_env(:arbor_security, :approval_guard_enabled, false)
    Application.put_env(:arbor_security, :invocation_receipts_enabled, false)
    Application.put_env(:arbor_trust, :approval_guard_enabled, false)
    Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
  end

  defp restore_security_config(previous) do
    restore(:arbor_security, :reflex_checking_enabled, previous.reflex)
    restore(:arbor_security, :capability_signing_required, previous.signing)
    restore(:arbor_security, :identity_verification, previous.identity_verification)
    restore(:arbor_security, :strict_identity_mode, previous.identity)
    restore(:arbor_security, :uri_registry_enforcement, previous.uri_registry)
    restore(:arbor_security, :consensus_escalation_enabled, previous.escalation)
    restore(:arbor_security, :approval_guard_enabled, previous.security_approval)
    restore(:arbor_security, :invocation_receipts_enabled, previous.receipts)
    restore(:arbor_trust, :approval_guard_enabled, previous.trust_guard)
    restore(:arbor_trust, :policy_enforcer_enabled, previous.trust_enforcer)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
