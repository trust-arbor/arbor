defmodule Arbor.AI.AcpSensitivitySecurityRegressionTest do
  @moduledoc """
  Exercises the real ACP session through Arbor.AI's public facade. Only the
  final ACP protocol client is injected; session ownership, model confirmation,
  prompt admission and the production sensitivity policy remain real.
  """

  use ExUnit.Case, async: false

  alias Arbor.AI.AcpSession
  alias Arbor.Contracts.Security.Taint

  @moduletag :fast

  defmodule CapturingClient do
    @moduledoc false

    def start_link(opts), do: Agent.start_link(fn -> opts end)

    def new_session(_client, _cwd, _opts),
      do: {:ok, %{"sessionId" => "sensitivity-regression-session"}}

    def load_session(_client, session_id, _cwd, _opts),
      do: {:ok, %{"sessionId" => session_id}}

    def set_config_option(_client, _session_id, "model", value),
      do: {:ok, %{"configOptions" => [%{"id" => "model", "currentValue" => value}]}}

    def prompt(client, _session_id, content, opts) do
      observer = Agent.get(client, &Keyword.fetch!(&1, :test_pid))
      send(observer, {:acp_sensitivity_prompt, content, opts})
      {:ok, %{"text" => "accepted"}}
    end

    def cancel(_client, _session_id), do: :ok

    def disconnect(client) do
      Agent.stop(client, :normal)
      :ok
    end
  end

  setup do
    previous = Application.fetch_env(:arbor_ai, :acp_client_module)
    Application.put_env(:arbor_ai, :acp_client_module, CapturingClient)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_ai, :acp_client_module, value)
        :error -> Application.delete_env(:arbor_ai, :acp_client_module)
      end
    end)

    session =
      start_supervised!(
        {AcpSession,
         provider: :claude,
         model: "sonnet",
         client_opts: [test_pid: self(), command: ["injected-acp-client"]]}
      )

    assert :ok = AcpSession.await_ready(session, timeout: 5_000)

    assert {:ok, %{"sessionId" => "sensitivity-regression-session"}} =
             Arbor.AI.acp_create_session(session, timeout: 5_000)

    {:ok, session: session}
  end

  test "security regression: restricted ordinary prose is refused before an ACP prompt", %{
    session: session
  } do
    content = "The launch plan describes the next product release."

    assert {:error, {:sensitivity_blocked, _reason}} =
             Arbor.AI.acp_send_message(session, content,
               sensitivity: :restricted,
               timeout: 5_000
             )

    refute_receive {:acp_sensitivity_prompt, _, _}, 100
  end

  test "security regression: a public label cannot lower recorded restricted taint for ACP", %{
    session: session
  } do
    {:ok, taint} =
      Taint.new(
        level: :derived,
        sensitivity: :restricted,
        sanitizations: 0,
        confidence: :unverified,
        source: nil,
        chain: []
      )

    assert {:error, {:sensitivity_blocked, _reason}} =
             Arbor.AI.acp_send_message(session, "The planning notes are ready.",
               sensitivity: :public,
               taint: taint,
               timeout: 5_000
             )

    refute_receive {:acp_sensitivity_prompt, _, _}, 100
  end

  test "security regression: ordinary public content still reaches the real ACP session", %{
    session: session
  } do
    content = "Explain how a rainbow forms."

    assert {:ok, %{"text" => "accepted"}} =
             Arbor.AI.acp_send_message(session, content,
               sensitivity: :public,
               timeout: 5_000
             )

    assert_receive {:acp_sensitivity_prompt, ^content, _provider_opts}, 1_000
  end
end
