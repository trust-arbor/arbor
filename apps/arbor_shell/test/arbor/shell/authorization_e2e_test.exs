defmodule Arbor.Shell.AuthorizationE2ETest do
  @moduledoc """
  End-to-end tests for shell authorization flow.

  Tests the full pipeline: agent -> authorize_and_execute/authorize_and_dispatch
  -> Security.authorize -> CapabilityStore lookup -> shell execution.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.CapabilityStore

  setup do
    # Ensure Security processes are running
    ensure_security_started()

    # Disable features that interfere with minimal authorization tests
    prev_reflex = Application.get_env(:arbor_security, :reflex_checking_enabled)
    prev_signing = Application.get_env(:arbor_security, :capability_signing_required)
    prev_identity = Application.get_env(:arbor_security, :strict_identity_mode)
    prev_approval = Application.get_env(:arbor_security, :approval_guard_enabled)
    prev_receipts = Application.get_env(:arbor_security, :invocation_receipts_enabled)

    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :approval_guard_enabled, false)
    Application.put_env(:arbor_security, :invocation_receipts_enabled, false)

    agent_id = "agent_shell_e2e_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      restore_config(:reflex_checking_enabled, prev_reflex)
      restore_config(:capability_signing_required, prev_signing)
      restore_config(:strict_identity_mode, prev_identity)
      restore_config(:approval_guard_enabled, prev_approval)
      restore_config(:invocation_receipts_enabled, prev_receipts)
    end)

    {:ok, agent_id: agent_id}
  end

  # ===========================================================================
  # 1. Authorized execution
  # ===========================================================================

  describe "authorized execution" do
    test "agent with shell capability can execute commands", %{agent_id: agent_id} do
      grant_shell_capability(agent_id, "arbor://shell/exec/echo")

      result = Arbor.Shell.authorize_and_execute(agent_id, "echo hello", sandbox: :none)

      assert {:ok, %{exit_code: 0, stdout: stdout}} = result
      assert String.trim(stdout) == "hello"
    end

    test "agent with wildcard shell capability can execute any command", %{agent_id: agent_id} do
      grant_shell_capability(agent_id, "arbor://shell/exec")

      result = Arbor.Shell.authorize_and_execute(agent_id, "echo wildcard", sandbox: :none)

      assert {:ok, %{exit_code: 0, stdout: stdout}} = result
      assert String.trim(stdout) == "wildcard"
    end
  end

  # ===========================================================================
  # 2. Unauthorized execution
  # ===========================================================================

  describe "unauthorized execution" do
    test "agent without capability gets authorization error", %{agent_id: agent_id} do
      # No capability granted — should be blocked at authorization, not execution
      result = Arbor.Shell.authorize_and_execute(agent_id, "echo blocked", sandbox: :none)

      assert {:error, :unauthorized} = result
    end

    test "authorization error is returned before command runs", %{agent_id: agent_id} do
      # Use a command that would create a side effect if it ran
      marker = "/tmp/arbor_shell_auth_test_#{:erlang.unique_integer([:positive])}"

      result =
        Arbor.Shell.authorize_and_execute(agent_id, "touch #{marker}", sandbox: :none)

      assert {:error, :unauthorized} = result
      # Verify the command never ran
      refute File.exists?(marker)
    end
  end

  # ===========================================================================
  # 3. Specific command authorization
  # ===========================================================================

  describe "specific command authorization" do
    test "echo capability allows echo but blocks other commands", %{agent_id: agent_id} do
      grant_shell_capability(agent_id, "arbor://shell/exec/echo")

      # echo should work
      assert {:ok, %{exit_code: 0}} =
               Arbor.Shell.authorize_and_execute(agent_id, "echo hello", sandbox: :none)

      # rm should be blocked at authorization
      assert {:error, :unauthorized} =
               Arbor.Shell.authorize_and_execute(agent_id, "rm -rf /", sandbox: :none)
    end

    test "ls capability allows ls but blocks echo", %{agent_id: agent_id} do
      grant_shell_capability(agent_id, "arbor://shell/exec/ls")

      assert {:ok, %{exit_code: _}} =
               Arbor.Shell.authorize_and_execute(agent_id, "ls /tmp", sandbox: :none)

      assert {:error, :unauthorized} =
               Arbor.Shell.authorize_and_execute(agent_id, "echo denied", sandbox: :none)
    end

    test "path-prefixed commands are stripped to base name", %{agent_id: agent_id} do
      # Granting "echo" capability should work even when command uses /bin/echo
      grant_shell_capability(agent_id, "arbor://shell/exec/echo")

      assert {:ok, %{exit_code: 0, stdout: stdout}} =
               Arbor.Shell.authorize_and_execute(agent_id, "/bin/echo path_test", sandbox: :none)

      assert String.trim(stdout) == "path_test"
    end
  end

  # ===========================================================================
  # 4. Dispatch authorization
  # ===========================================================================

  describe "authorize_and_dispatch via authorize_and_execute_async" do
    test "authorized agent can execute async commands", %{agent_id: agent_id} do
      grant_shell_capability(agent_id, "arbor://shell/exec/echo")

      result = Arbor.Shell.authorize_and_execute_async(agent_id, "echo async", sandbox: :none)

      assert {:ok, exec_id} = result
      assert is_binary(exec_id)
      assert String.starts_with?(exec_id, "exec_")

      # Wait for result
      {:ok, async_result} = Arbor.Shell.get_result(exec_id, wait: true, timeout: 5000)
      assert async_result.exit_code == 0
      assert String.contains?(async_result.stdout, "async")
    end

    test "unauthorized agent is blocked from async execution", %{agent_id: agent_id} do
      result = Arbor.Shell.authorize_and_execute_async(agent_id, "echo blocked", sandbox: :none)

      assert {:error, :unauthorized} = result
    end
  end

  describe "authorize_and_dispatch via authorize_and_execute_streaming" do
    test "authorized agent can execute streaming commands", %{agent_id: agent_id} do
      grant_shell_capability(agent_id, "arbor://shell/exec/echo")

      result =
        Arbor.Shell.authorize_and_execute_streaming(
          agent_id,
          "echo streaming",
          stream_to: self(),
          sandbox: :none
        )

      assert {:ok, session_id} = result
      assert is_binary(session_id)

      assert_receive {:port_exit, ^session_id, 0, output}, 5_000
      assert String.contains?(output, "streaming")
    end

    test "unauthorized agent is blocked from streaming execution", %{agent_id: agent_id} do
      result =
        Arbor.Shell.authorize_and_execute_streaming(
          agent_id,
          "echo blocked",
          stream_to: self(),
          sandbox: :none
        )

      assert {:error, :unauthorized} = result
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp grant_shell_capability(agent_id, resource_uri) do
    cap = %Capability{
      id: "cap_shell_e2e_#{:erlang.unique_integer([:positive])}",
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

  defp restore_config(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_config(key, value), do: Application.put_env(:arbor_security, key, value)
end
