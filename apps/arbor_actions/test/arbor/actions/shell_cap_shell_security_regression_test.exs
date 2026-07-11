defmodule Arbor.Actions.ShellCapShellSecurityRegressionTest do
  @moduledoc """
  Security regression: Actions.Shell.Execute compound path with config true.

  With `compound_shell_enabled: true` and broad shell capability, the agent
  action path must return a stable compound-shell unavailable failure and must
  not produce delayed filesystem side effects. Fails on parent `dab2d315`
  (opt-in CapShell still executes); passes on the fail-closed candidate.

  Intentional security API break for the retired CapShell prototype.
  """
  use Arbor.Actions.ActionCase, async: false
  @moduletag :fast

  alias Arbor.Actions.Shell

  @side_effect_wait_ms 1_500

  setup_all do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil ->
        {:ok, _} = Application.ensure_all_started(:arbor_shell)

      _pid ->
        :ok
    end

    :ok
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_trust)

    if Process.whereis(Arbor.Trust.Store) == nil do
      start_supervised!(Arbor.Trust.Store)
    end

    prev = %{
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      identity: Application.get_env(:arbor_security, :strict_identity_mode),
      uri_registry: Application.get_env(:arbor_security, :uri_registry_enforcement),
      escalation: Application.get_env(:arbor_security, :consensus_escalation_enabled),
      trust_guard: Application.get_env(:arbor_trust, :approval_guard_enabled),
      trust_enforcer: Application.get_env(:arbor_trust, :policy_enforcer_enabled),
      compound: Application.get_env(:arbor_shell, :compound_shell_enabled)
    }

    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, false)
    Application.put_env(:arbor_trust, :approval_guard_enabled, true)
    Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
    Application.put_env(:arbor_shell, :compound_shell_enabled, true)

    on_exit(fn ->
      restore(:arbor_security, :reflex_checking_enabled, prev.reflex)
      restore(:arbor_security, :capability_signing_required, prev.signing)
      restore(:arbor_security, :strict_identity_mode, prev.identity)
      restore(:arbor_security, :uri_registry_enforcement, prev.uri_registry)
      restore(:arbor_security, :consensus_escalation_enabled, prev.escalation)
      restore(:arbor_trust, :approval_guard_enabled, prev.trust_guard)
      restore(:arbor_trust, :policy_enforcer_enabled, prev.trust_enforcer)

      if is_nil(prev.compound),
        do: Application.delete_env(:arbor_shell, :compound_shell_enabled),
        else: Application.put_env(:arbor_shell, :compound_shell_enabled, prev.compound)
    end)

    agent_id = "agent_actions_capshell_sec_#{System.unique_integer([:positive])}"

    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(agent_id)

    :ok =
      Arbor.Trust.Store.store_profile(%{
        profile
        | rules:
            profile.rules
            |> Map.put("arbor://shell/exec/sleep", :auto)
            |> Map.put("arbor://shell/exec/touch", :auto)
            |> Map.put("arbor://shell/exec/**", :auto)
      })

    {:ok, _cap} = Arbor.Security.grant(principal: agent_id, resource: "arbor://shell/exec/**")

    {:ok, agent_id: agent_id}
  end

  test "security regression: Execute with config true returns unavailable and no delayed side effect",
       %{agent_id: agent_id} do
    assert Arbor.Shell.compound_shell_enabled?()

    marker =
      Path.join(
        System.tmp_dir!(),
        "actions_capshell_sec_#{System.unique_integer([:positive])}"
      )

    File.rm(marker)

    try do
      result =
        Shell.Execute.run(
          %{command: "sleep 1; touch #{marker}", sandbox: :basic},
          %{
            agent_id: agent_id,
            approved_invocation: %{
              request_id: "irq_capshell_sec_regression",
              principal_id: agent_id,
              resource_uri: "arbor://shell/exec/sleep",
              decision: :approved
            }
          }
        )

      assert {:error, message} = result
      assert is_binary(message)

      assert message =~ "unavailable" or message =~ "security_boundary_incomplete" or
               message =~ "Compound shell",
             "expected stable compound-shell unavailable message, got: #{inspect(message)}"

      Process.sleep(@side_effect_wait_ms)

      refute File.exists?(marker),
             "action path must not execute delayed compound side effect when CapShell is fail-closed"
    after
      File.rm(marker)
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
