defmodule Arbor.Actions.AcpCliArgvInjectionSecurityRegressionTest do
  @moduledoc """
  Security regression for CVE-2026-96620 / GHSA-h4mw-j7qp-8mwm.

  `Arbor.Actions.Acp.StartSession` accepts a caller `session_id` that later
  becomes Claude `--resume`. A value beginning with `-` must be rejected
  before any managed session (and therefore any provider CLI) is started.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Actions.Acp.StartSession

  @claude_uuid "a226df5e-bc82-412c-9870-1fc52d036763"
  @injected_mcp_config "--mcp-config=/tmp/x.json"

  defmodule RecordingAI do
    def acp_providers, do: Arbor.AI.acp_providers()

    def acp_managed_start_session(provider, opts) do
      send(self(), {:unsafe_session_start, provider, opts})

      {:ok,
       %{
         worker_session_id: "acp_worker_test",
         session_id: Keyword.get(opts, :session_id) || "session_test",
         provider: provider,
         model: Keyword.get(opts, :model) || "default",
         status: "ready",
         pooled: false
       }}
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

    Application.put_env(:arbor_actions, :ai_module, RecordingAI)
    :ok
  end

  test "security regression: dash-leading session_id is refused before any managed session starts" do
    for session_id <- [@injected_mcp_config, "-x", " -x"] do
      assert {:error, message} =
               StartSession.run(
                 %{provider: "claude", session_id: session_id},
                 %{agent_id: "agent_test"}
               )

      assert message =~ "invalid_provider_session_id"
      refute_received {:unsafe_session_start, _, _}
    end
  end

  test "security regression: a Claude UUID still resumes through StartSession" do
    assert {:ok, result} =
             StartSession.run(
               %{provider: "claude", session_id: @claude_uuid, use_pool: false},
               %{agent_id: "agent_test"}
             )

    assert_receive {:unsafe_session_start, :claude, opts}
    assert Keyword.get(opts, :session_id) == @claude_uuid
    assert result.session_id == @claude_uuid
    assert result.continuity == "resumed"
  end

  test "security regression: dash-leading model and cwd are refused before managed start" do
    for params <- [
          %{provider: "claude", model: @injected_mcp_config},
          %{provider: "claude", cwd: @injected_mcp_config},
          %{provider: "gemini", cwd: " -x"}
        ] do
      assert {:error, message} = StartSession.run(params, %{agent_id: "agent_test"})
      assert message =~ "invalid_cli_argv_value" or message =~ "leading_dash"
      refute_received {:unsafe_session_start, _, _}
    end
  end
end
