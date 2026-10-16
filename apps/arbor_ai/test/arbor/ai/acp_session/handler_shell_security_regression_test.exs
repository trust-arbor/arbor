defmodule Arbor.AI.AcpSession.HandlerShellSecurityRegressionTest do
  @moduledoc """
  A real signed ACP wildcard grant must not confer shell authority. These
  permission callbacks use the real Security store and the configured public
  Shell authorization boundary; no command is executed.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.AI.AcpSession.Handler
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security

  defmodule AutoPolicy do
    def confirmation_mode(_principal, _uri), do: :auto
  end

  setup do
    :ok = Security.TestBootstrap.start!()
    authorizer = Application.fetch_env!(:arbor_shell, :agent_authorizer)
    assert Code.ensure_loaded?(authorizer)

    case Supervisor.start_child(Arbor.Shell.Supervisor, Arbor.Shell.ExecutablePolicy) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    previous =
      for {app, key, value} <- [
            {:arbor_ai, :security_module, Security},
            {:arbor_ai, :trust_policy_module, AutoPolicy},
            {:arbor_trust, :policy_module, AutoPolicy},
            {:arbor_trust, :approval_guard_enabled, true}
          ] do
        old = Application.fetch_env(app, key)
        Application.put_env(app, key, value)
        {app, key, old}
      end

    {:ok, identity} = Security.generate_identity()
    :ok = Security.register_identity_fixture(Identity.public_only(identity))

    {:ok, _} =
      Security.grant_fixture(principal: identity.agent_id, resource: "arbor://acp/tool/**")

    on_exit(fn ->
      Security.revoke_all_fixture(identity.agent_id)
      Security.deregister_identity_fixture(identity.agent_id)

      for {app, key, old} <- previous do
        case old do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    {:ok, state} =
      Handler.init(agent_id: identity.agent_id, cwd: File.cwd!(), permission_timeout_ms: 1)

    %{state: state, agent_id: identity.agent_id}
  end

  test "security regression: ACP wildcard cannot authorize provider shell aliases", %{
    state: state
  } do
    for name <-
          ~w(Bash bash execute shell terminal run_terminal_cmd run_terminal_command exec_command run_shell_command shell_command local_shell) do
      assert {:ok, %{"outcome" => "denied"}, ^state} =
               Handler.handle_permission_request(
                 "s1",
                 %{"name" => name, "rawInput" => %{"command" => "ls"}},
                 [],
                 state
               ),
             "ACP wildcard authorized #{name} without shell authority"
    end
  end

  test "security regression: execute kind cannot be hidden behind a read tool name", %{
    state: state
  } do
    assert {:ok, %{"outcome" => "denied"}, ^state} =
             Handler.handle_permission_request(
               "s1",
               %{"name" => "Read", "kind" => "execute", "rawInput" => %{"command" => "ls"}},
               [],
               state
             )
  end

  test "security regression: opaque Kiro tools cannot evade the shell floor", %{state: state} do
    state = %{state | provider: :kiro}

    assert {:ok, %{"outcome" => "denied"}, ^state} =
             Handler.handle_permission_request(
               "s1",
               %{"toolCallId" => "tooluse_abc123"},
               [],
               state
             )
  end

  test "security regression: even a shell grant and auto policy must pass the always-locked floor",
       %{state: state, agent_id: agent_id} do
    {:ok, _} = Security.grant_fixture(principal: agent_id, resource: "arbor://shell/exec/ls")
    refute Arbor.Shell.authorize(agent_id, "ls", cwd: state.workspace_root) == {:ok, :authorized}

    assert {:ok, %{"outcome" => "denied"}, ^state} =
             Handler.handle_permission_request(
               "s1",
               %{"name" => "Bash", "rawInput" => %{"command" => "ls"}},
               [],
               state
             )
  end

  test "read tools retain their ACP authorization", %{state: state} do
    assert {:ok, %{"outcome" => "approved"}, ^state} =
             Handler.handle_permission_request(
               "s1",
               %{"name" => "Read", "kind" => "read"},
               [],
               state
             )
  end
end
