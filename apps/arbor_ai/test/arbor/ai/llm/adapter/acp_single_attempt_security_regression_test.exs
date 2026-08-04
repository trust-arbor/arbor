defmodule Arbor.AI.LLM.Adapter.AcpSingleAttemptSecurityRegressionTest do
  @moduledoc false
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression
  @moduletag voice_id: "VOICE-17"

  alias Arbor.AI.LLM.Adapter.Acp
  alias Arbor.LLM.{Message, Request}

  defmodule CountingPool do
    @moduledoc false
    def checkout(agent, opts) do
      parent = Application.fetch_env!(:arbor_ai, :_test_acp_count_parent)
      send(parent, {:checkout, agent, Keyword.keys(opts)})
      {:ok, :fake_session}
    end

    def checkin(session, _opts \\ []) do
      parent = Application.fetch_env!(:arbor_ai, :_test_acp_count_parent)
      send(parent, {:checkin, session})
      :ok
    end

    def close_session(session, _opts \\ []) do
      parent = Application.fetch_env!(:arbor_ai, :_test_acp_count_parent)
      send(parent, {:close_session, session})
      :ok
    end
  end

  defmodule CountingSession do
    @moduledoc false
    def send_message(session, prompt, opts) do
      parent = Application.fetch_env!(:arbor_ai, :_test_acp_count_parent)
      send(parent, {:send_message, session, prompt, Keyword.keys(opts)})
      {:ok, %{"text" => "ok", "stopReason" => "end_turn", "usage" => %{}}}
    end

    def status(_session), do: %{status: :ready}
  end

  setup do
    Application.put_env(:arbor_ai, :_test_acp_adapter_pool_mod, CountingPool)
    Application.put_env(:arbor_ai, :_test_acp_adapter_session_mod, CountingSession)
    Application.put_env(:arbor_ai, :_test_acp_count_parent, self())

    on_exit(fn ->
      Application.delete_env(:arbor_ai, :_test_acp_adapter_pool_mod)
      Application.delete_env(:arbor_ai, :_test_acp_adapter_session_mod)
      Application.delete_env(:arbor_ai, :_test_acp_count_parent)
    end)

    :ok
  end

  defp build_request do
    %Request{
      provider: "acp",
      model: "sonnet",
      messages: [Message.new(:user, "hello")],
      provider_options: %{"agent" => "claude"}
    }
  end

  test "security regression VOICE-17: ACP single-attempt performs one checkout and one send_message" do
    assert {:ok, response} = Acp.complete_single_attempt(build_request(), [])
    assert response.text == "ok"

    assert_receive {:checkout, :claude, _}
    assert_receive {:send_message, :fake_session, "hello", _}
    assert_receive {:checkin, :fake_session}

    refute_received {:checkout, _, _}
    refute_received {:send_message, _, _, _}
  end

  test "security regression VOICE-17: ordinary ACP complete retains linear one-checkout one-send path" do
    assert {:ok, response} = Acp.complete(build_request(), [])
    assert response.text == "ok"

    assert_receive {:checkout, :claude, _}
    assert_receive {:send_message, :fake_session, "hello", _}
    assert_receive {:checkin, :fake_session}

    refute_received {:checkout, _, _}
    refute_received {:send_message, _, _, _}
  end

  test "security regression VOICE-17: Runtime.Acp.cli_for_provider fails bounded for non-binary" do
    assert {:error, {:no_cli_for_provider, ""}} =
             Arbor.AI.Runtime.Acp.cli_for_provider(:anthropic)

    assert {:error, {:no_cli_for_provider, ""}} =
             Arbor.AI.Runtime.Acp.cli_for_provider(%{bad: true})

    assert {:ok, :claude} = Arbor.AI.Runtime.Acp.cli_for_provider("anthropic")
  end
end
