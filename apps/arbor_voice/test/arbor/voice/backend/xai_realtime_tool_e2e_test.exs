defmodule Arbor.Voice.Backend.XaiRealtimeToolE2ETest do
  @moduledoc """
  Scripted xAI public-turn proof: function_call wire frame through Voice.text_turn
  to one function_call_output and final assistant text (VP-04E3 / VOICE-8).
  No network or OAuth.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Voice
  alias Arbor.Voice.Backend.XaiRealtime
  alias Arbor.Voice.Session.TurnCore
  alias Arbor.Voice.Test.EgressAuthorityFakes

  alias Arbor.Voice.Test.EgressAuthorityFakes.{AI, Security, Trust}

  alias Arbor.Voice.Test.SessionFakes.{
    FakeCommsSession,
    FakeEngagementStore,
    FakeLedger,
    FakeSignals
  }

  defmodule SharedTransport do
    @moduledoc false
    @table :arbor_voice_xai_tool_e2e_transport

    def ensure! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ok
    end

    def reset(frames) when is_list(frames) do
      ensure!()
      :ets.insert(@table, {:frames, frames})
      :ets.insert(@table, {:sent, []})
      :ok
    end

    def sent do
      ensure!()

      case :ets.lookup(@table, :sent) do
        [{:sent, list}] -> list
        _ -> []
      end
    end

    def connect(opts) do
      ensure!()
      _ = Keyword.fetch!(opts, :token)
      {:ok, %{id: make_ref()}}
    end

    def send_frame(state, frame) do
      ensure!()

      case :ets.lookup(@table, :sent) do
        [{:sent, list}] -> :ets.insert(@table, {:sent, list ++ [frame]})
        _ -> :ets.insert(@table, {:sent, [frame]})
      end

      {:ok, state}
    end

    def recv_frame(state, _timeout) do
      ensure!()

      case :ets.lookup(@table, :frames) do
        [{:frames, [frame | rest]}] ->
          :ets.insert(@table, {:frames, rest})
          {:ok, state, frame}

        [{:frames, []}] ->
          {:error, :timeout}

        _ ->
          {:error, :timeout}
      end
    end

    def close(_state), do: :ok
  end

  defmodule OkRouter do
    @moduledoc false
    def tools, do: []
    def invoke(%{name: "lookup"}, _authority), do: {:ok, %{"value" => "ok"}}
    def invoke(_, _authority), do: {:error, :unknown_tool}
  end

  defp unique_ids do
    n = System.unique_integer([:positive])
    {"user_xai_#{n}", "agent_xai_#{n}"}
  end

  setup do
    EgressAuthorityFakes.reset()

    previous_modules =
      for key <- [:ai_module, :security_module, :trust_module], into: %{} do
        {key, Application.fetch_env(:arbor_voice, key)}
      end

    Application.put_env(:arbor_voice, :ai_module, AI)
    Application.put_env(:arbor_voice, :security_module, Security)
    Application.put_env(:arbor_voice, :trust_module, Trust)

    on_exit(fn ->
      Enum.each(previous_modules, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_voice, key, value)
        {key, :error} -> Application.delete_env(:arbor_voice, key)
      end)
    end)

    SharedTransport.ensure!()

    frames = [
      %{
        "type" => "response.function_call_arguments.done",
        "call_id" => "call_e2e",
        "name" => "lookup",
        "arguments" => Jason.encode!(%{"q" => "1"})
      },
      # Intermediate blank response.done after tool-bearing wave
      %{"type" => "response.done"},
      # Post-tool final assistant text
      %{"type" => "response.output_text.delta", "delta" => "Final "},
      %{"type" => "response.output_text.delta", "delta" => "answer"},
      %{"type" => "response.done"}
    ]

    SharedTransport.reset(frames)

    {:ok, eng} =
      FakeEngagementStore.start(result: {:ok, %{id: "eng_xai_e2e", agent_id: "agent_x"}})

    {:ok, _ledger} = FakeLedger.start()
    {:ok, _signals} = FakeSignals.start()
    {:ok, _recorder} = FakeCommsSession.start_recorder()

    opts = [
      comms: FakeCommsSession,
      engagement_store: FakeEngagementStore,
      ledger: FakeLedger,
      signals: FakeSignals,
      session_token: "test-human-session-proof",
      backend: XaiRealtime,
      backend_opts: [
        transport: SharedTransport,
        oauth_resolver: fn :xai -> {:ok, "test-token-not-real"} end
      ],
      tool_router: OkRouter,
      tool_router_timeout_ms: 2_000,
      progress_threshold_ms: 2_000,
      session_budget_ms: 60_000,
      daily_budget_ms: 3_600_000,
      resource_owner_opts: [
        close_timeout_ms: 1_000,
        cleanup_ready_timeout_ms: 200,
        cleanup_attempts: 2,
        cleanup_per_attempt_timeout_ms: 200,
        max_recv_timeout_ms: 100
      ]
    ]

    %{opts: opts, eng: eng}
  end

  @tag spec: "VOICE-8"
  test "public text_turn: function_call -> one function_call_output -> final text", %{opts: opts} do
    {user_id, agent_id} = unique_ids()
    assert {:ok, key} = Voice.start_session(user_id, agent_id, opts)

    assert {:ok, "Final answer"} = Voice.text_turn(user_id, agent_id, "please lookup")

    sent = SharedTransport.sent()

    outputs =
      Enum.filter(sent, fn
        %{
          "type" => "conversation.item.create",
          "item" => %{"type" => "function_call_output"}
        } ->
          true

        _ ->
          false
      end)

    assert length(outputs) == 1

    [
      %{
        "item" => %{
          "call_id" => "call_e2e",
          "output" => output
        }
      }
    ] = outputs

    assert Jason.decode!(output) == %{"success" => true, "result" => %{"value" => "ok"}}
    # Empty catalog default would be different; prove success path not no_tools.
    refute output == TurnCore.no_tools_installed_output()

    # response.create follows tool output (xAI sequencing)
    output_idx =
      Enum.find_index(sent, fn f ->
        match?(%{"item" => %{"type" => "function_call_output"}}, f)
      end)

    assert output_idx != nil
    assert Enum.at(sent, output_idx + 1) == %{"type" => "response.create"}

    assert :ok = Voice.stop_session(key)
  end
end
