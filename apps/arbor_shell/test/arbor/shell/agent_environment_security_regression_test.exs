defmodule Arbor.Shell.AgentEnvironmentSecurityRegressionTest do
  @moduledoc """
  Security regression: agent shell children must not inherit ambient VM
  credentials.

  Parent behavior (must fail on checkout of parent):
  `ProcessGroup` only overrides PATH (and optional caller env). Unspecified
  variables remain inherited from the Arbor BEAM, so an authorized
  `printenv SECRET` returns host credentials even when `:env` is rejected.

  Fixed behavior: agent-facing prepared execution forces a deny-by-default
  child environment (sync, async, streaming). Callers cannot disable this via
  `sandbox: :none` or `clear_env: false`.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.CapabilityStore

  setup do
    ensure_security_started()
    ensure_shell_started()

    prev = %{
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      identity: Application.get_env(:arbor_security, :strict_identity_mode),
      approval: Application.get_env(:arbor_security, :approval_guard_enabled),
      receipts: Application.get_env(:arbor_security, :invocation_receipts_enabled)
    }

    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :approval_guard_enabled, false)
    Application.put_env(:arbor_security, :invocation_receipts_enabled, false)

    agent_id = "agent_env_sec_#{:erlang.unique_integer([:positive])}"
    grant_shell_capability(agent_id, "arbor://shell/exec/**")

    secret_name =
      "ARBOR_SHELL_AGENT_ENV_REGRESSION_#{:erlang.unique_integer([:positive])}"

    # Opaque marker — never interpolate into assertion messages.
    secret_value =
      "v#{System.unique_integer([:positive])}_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"

    previous_secret = System.get_env(secret_name)
    System.put_env(secret_name, secret_value)

    on_exit(fn ->
      restore_secret(secret_name, previous_secret)
      restore_security(:reflex_checking_enabled, prev.reflex)
      restore_security(:capability_signing_required, prev.signing)
      restore_security(:strict_identity_mode, prev.identity)
      restore_security(:approval_guard_enabled, prev.approval)
      restore_security(:invocation_receipts_enabled, prev.receipts)
    end)

    {:ok, agent_id: agent_id, secret_name: secret_name, secret_value: secret_value}
  end

  describe "security regression: agent child environment is deny-by-default" do
    test "security regression: authorize_and_execute printenv cannot read ambient secret",
         %{agent_id: agent_id, secret_name: secret_name, secret_value: secret_value} do
      command = "printenv #{secret_name}"

      # Attempt to keep ambient inheritance via sandbox:none + clear_env:false;
      # agent opts must force clearing after authorization.
      assert {:ok, result} =
               Arbor.Shell.authorize_and_execute(agent_id, command,
                 sandbox: :none,
                 clear_env: false
               )

      refute_secret_in_output(result.stdout, secret_value)
      refute_secret_in_output(result.stderr, secret_value)
      # Missing variable: printenv exits non-zero with empty stdout.
      assert result.exit_code != 0
    end

    test "security regression: async and streaming agent paths also clear ambient env",
         %{agent_id: agent_id, secret_name: secret_name, secret_value: secret_value} do
      command = "printenv #{secret_name}"

      assert {:ok, exec_id} =
               Arbor.Shell.authorize_and_execute_async(agent_id, command,
                 sandbox: :none,
                 clear_env: false
               )

      assert {:ok, async_result} =
               Arbor.Shell.get_result(exec_id, wait: true, timeout: 5_000)

      refute_secret_in_output(async_result.stdout, secret_value)
      refute_secret_in_output(async_result.stderr, secret_value)
      assert async_result.exit_code != 0

      assert {:ok, session_id} =
               Arbor.Shell.authorize_and_execute_streaming(agent_id, command,
                 sandbox: :none,
                 clear_env: false,
                 stream_to: self()
               )

      assert_receive {:port_exit, ^session_id, exit_code, output}, 5_000
      refute_secret_in_output(output, secret_value)
      assert exit_code != 0
    end

    test "security regression: trusted execute_direct still inherits ambient unless clear_env",
         %{secret_name: secret_name, secret_value: secret_value} do
      assert {:ok, inherited} =
               Arbor.Shell.execute_direct("printenv", [secret_name], sandbox: :none)

      assert String.trim(inherited.stdout) == secret_value
      assert inherited.exit_code == 0

      assert {:ok, cleared} =
               Arbor.Shell.execute_direct("printenv", [secret_name],
                 sandbox: :none,
                 clear_env: true
               )

      refute_secret_in_output(cleared.stdout, secret_value)
      assert cleared.exit_code != 0
    end
  end

  # Never put the secret value into the assertion message (ExUnit would print it).
  defp refute_secret_in_output(output, secret_value) when is_binary(output) do
    refute String.contains?(output, secret_value),
           "agent/child output contained the ambient secret marker"
  end

  defp refute_secret_in_output(output, _secret_value) when output in [nil, ""], do: :ok
  defp refute_secret_in_output(_output, _secret_value), do: :ok

  defp restore_secret(name, nil), do: System.delete_env(name)
  defp restore_secret(name, value), do: System.put_env(name, value)

  defp grant_shell_capability(agent_id, resource_uri) do
    cap = %Capability{
      id: "cap_env_sec_#{:erlang.unique_integer([:positive])}",
      resource_uri: resource_uri,
      principal_id: agent_id,
      granted_at: DateTime.utc_now(),
      expires_at: nil,
      constraints: %{},
      delegation_depth: 0,
      delegation_chain: [],
      metadata: %{test: true}
    }

    {:ok, :stored} = CapabilityStore.put(cap)
    cap
  end

  defp ensure_shell_started do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil ->
        _ = Application.ensure_all_started(:arbor_shell)

      _pid ->
        :ok
    end
  end

  defp ensure_security_started do
    security_children = [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []}
    ]

    if Process.whereis(Arbor.Security.Supervisor) do
      for child <- security_children do
        try do
          case Supervisor.start_child(Arbor.Security.Supervisor, child) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            {:error, :already_present} -> :ok
            _other -> :ok
          end
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  defp restore_security(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_security(key, value), do: Application.put_env(:arbor_security, key, value)
end
