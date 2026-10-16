defmodule Arbor.Actions.AcpPermissionModeSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  alias Arbor.Actions.Acp.StartSession

  defmodule RecordingAI do
    def acp_providers, do: Arbor.AI.acp_providers()

    def acp_managed_start_session(provider, opts) do
      send(self(), {:unsafe_session_start, provider, opts})
      {:ok, %{worker_session_id: "worker_test", session_id: "session_test", provider: provider}}
    end
  end

  setup do
    old = Application.fetch_env(:arbor_actions, :ai_module)

    on_exit(fn ->
      case old do
        {:ok, module} -> Application.put_env(:arbor_actions, :ai_module, module)
        :error -> Application.delete_env(:arbor_actions, :ai_module)
      end
    end)

    :ok
  end

  test "security regression: caller bypass aliases are refused before any managed session starts" do
    Application.put_env(:arbor_actions, :ai_module, RecordingAI)

    for mode <- [
          "bypass",
          :bypass,
          "bypass_permissions",
          :bypass_permissions,
          "auto",
          :auto,
          "bypassPermissions"
        ] do
      assert {:error, message} =
               StartSession.run(%{provider: "claude", permission_mode: mode}, %{
                 agent_id: "agent_test"
               })

      assert message =~ "acp_permission_mode_refused"
      refute_received {:unsafe_session_start, _, _}
    end
  end

  test "security regression: real AI facade path refuses string-keyed bypass before provider resolution" do
    Application.put_env(:arbor_actions, :ai_module, Arbor.AI)
    # An invalid provider prevents any CLI launch on the vulnerable predecessor.
    assert {:error, message} =
             StartSession.run(
               %{"provider" => "unknown_provider", "permission_mode" => "bypass"},
               %{}
             )

    assert message =~ "acp_permission_mode_refused"
  end
end
