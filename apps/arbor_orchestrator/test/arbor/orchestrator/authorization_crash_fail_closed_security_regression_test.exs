defmodule Arbor.Orchestrator.AuthorizationCrashFailClosedSecurityRegressionTest do
  @moduledoc """
  Security regression: a crash *during* the legacy orchestrator access check
  must deny, regardless of `security_required`.

  `Authorization.check_orchestrator_access/2` (legacy signer path) used to
  return `if Config.security_required?(), do: {:error, :security_unavailable},
  else: :ok` from its `rescue` and `catch :exit` clauses while logging
  "failing closed". With `security_required: false` a raise or exit inside the
  check (a signer whose key store is down, CapabilityStore exiting mid-call)
  therefore granted access. An exception is not "security not configured".

  The explicit escape hatch is deliberately kept: security reported
  unavailable + `security_required: false` still returns `:ok` for standalone
  deployments without arbor_security.
  """

  # async: false — mutates :arbor_orchestrator app env
  # (:security_required, :security_available_override).
  use ExUnit.Case, async: false

  @moduletag :security_regression
  @moduletag :fast

  alias Arbor.Orchestrator.Authorization

  @app :arbor_orchestrator
  @agent_id "agent_authz_crash_fail_closed"

  setup do
    prev_required = Application.get_env(@app, :security_required)
    prev_override = Application.get_env(@app, :security_available_override)

    on_exit(fn ->
      restore(:security_required, prev_required)
      restore(:security_available_override, prev_override)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(@app, key)
  defp restore(key, value), do: Application.put_env(@app, key, value)

  # Forces the legacy check onto its authorize branch, where the signer runs.
  defp security_available_but_not_required do
    Application.put_env(@app, :security_available_override, true)
    Application.put_env(@app, :security_required, false)
  end

  describe "security regression: crash during the legacy access check fails closed" do
    test "a raise inside the check denies even when security_required is false" do
      security_available_but_not_required()

      raising_signer = fn _resource -> raise "signing key store crashed" end

      assert {:error, :security_unavailable} =
               Authorization.check_orchestrator_access(@agent_id, raising_signer)
    end

    test "an exit inside the check denies even when security_required is false" do
      security_available_but_not_required()

      exiting_signer = fn _resource -> exit({:noproc, {GenServer, :call, [:key_store]}}) end

      assert {:error, :security_unavailable} =
               Authorization.check_orchestrator_access(@agent_id, exiting_signer)
    end

    test "a raise inside the check denies when security_required is true" do
      Application.put_env(@app, :security_available_override, true)
      Application.put_env(@app, :security_required, true)

      raising_signer = fn _resource -> raise "signing key store crashed" end

      assert {:error, :security_unavailable} =
               Authorization.check_orchestrator_access(@agent_id, raising_signer)
    end
  end

  describe "explicit standalone escape hatch is unchanged" do
    test "security unavailable + security_required false still permits" do
      Application.put_env(@app, :security_available_override, false)
      Application.put_env(@app, :security_required, false)

      assert :ok = Authorization.check_orchestrator_access(@agent_id, nil)
    end

    test "security unavailable + security_required true denies" do
      Application.put_env(@app, :security_available_override, false)
      Application.put_env(@app, :security_required, true)

      assert {:error, :security_unavailable} =
               Authorization.check_orchestrator_access(@agent_id, nil)
    end
  end
end
