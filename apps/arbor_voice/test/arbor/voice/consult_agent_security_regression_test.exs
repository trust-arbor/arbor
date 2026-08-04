defmodule Arbor.Voice.ConsultAgentSecurityRegressionTest do
  @moduledoc """
  Scripted xAI public-turn proof for production FrontDesk consult_agent
  (VP-05B / VOICE-9, partial VOICE-17) including session_token security
  regression. VOICE-17 remains normatively planned.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.Voice
  alias Arbor.Voice.Backend.XaiRealtime
  alias Arbor.Voice.Test.EgressAuthorityFakes
  alias Arbor.Voice.Test.EgressAuthorityFakes.{AI, Security, Trust}
  alias Arbor.Voice.ToolRouter.FrontDesk

  alias Arbor.Voice.Test.SessionFakes.{
    ControllableTurnBackend,
    FakeCommsSession,
    FakeEngagementStore,
    FakeLedger,
    FakeSignals
  }

  @distinctive_token "vp05b-security-regression-token-7f3a9c2e"

  defmodule SharedTransport do
    @moduledoc false
    @table :arbor_voice_xai_consult_e2e_transport

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

  defmodule FakeAgentFacade do
    @moduledoc false
    @table :arbor_voice_fake_agent_facade

    def ensure! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ok
    end

    def reset do
      ensure!()
      :ets.insert(@table, {:calls, []})
      :ok
    end

    def calls do
      ensure!()

      case :ets.lookup(@table, :calls) do
        [{:calls, list}] -> list
        _ -> []
      end
    end

    def send_message(caller_id, target_agent_id, message, opts \\ []) do
      ensure!()

      entry = %{
        caller_id: caller_id,
        target_agent_id: target_agent_id,
        message: message,
        opts: opts
      }

      case :ets.lookup(@table, :calls) do
        [{:calls, list}] -> :ets.insert(@table, {:calls, list ++ [entry]})
        _ -> :ets.insert(@table, {:calls, [entry]})
      end

      {:ok, "agent grounded reply"}
    end

    # Required by Config.validate_agent_module/1 after VP-05C (dual export).
    def dispatch_task(_caller_id, _target_agent_id, _task, _opts \\ []) do
      {:error, :dispatch_failed}
    end
  end

  # Same catalog and consult path as FrontDesk; captures the exact router
  # context map so the security regression can prove the closed six-key set.
  defmodule ContextCapturingFrontDesk do
    @moduledoc false
    @table :arbor_voice_consult_router_context

    def ensure! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ok
    end

    def reset do
      ensure!()
      :ets.insert(@table, {:contexts, []})
      :ok
    end

    def contexts do
      ensure!()

      case :ets.lookup(@table, :contexts) do
        [{:contexts, list}] -> list
        _ -> []
      end
    end

    def tools, do: FrontDesk.tools()

    def invoke(context, authority) do
      ensure!()

      case :ets.lookup(@table, :contexts) do
        [{:contexts, list}] -> :ets.insert(@table, {:contexts, list ++ [context]})
        _ -> :ets.insert(@table, {:contexts, [context]})
      end

      FrontDesk.invoke(context, authority)
    end
  end

  defp unique_ids do
    n = System.unique_integer([:positive])
    {"user_consult_#{n}", "agent_consult_#{n}"}
  end

  setup do
    EgressAuthorityFakes.reset()
    SharedTransport.ensure!()
    FakeAgentFacade.ensure!()
    FakeAgentFacade.reset()
    ContextCapturingFrontDesk.reset()

    previous_modules =
      for key <- [:agent_module, :ai_module, :security_module, :trust_module], into: %{} do
        {key, Application.fetch_env(:arbor_voice, key)}
      end

    on_exit(fn ->
      Enum.each(previous_modules, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_voice, key, value)
        {key, :error} -> Application.delete_env(:arbor_voice, key)
      end)
    end)

    Application.put_env(:arbor_voice, :agent_module, FakeAgentFacade)
    Application.put_env(:arbor_voice, :ai_module, AI)
    Application.put_env(:arbor_voice, :security_module, Security)
    Application.put_env(:arbor_voice, :trust_module, Trust)

    frames = [
      %{
        "type" => "response.function_call_arguments.done",
        "call_id" => "call_consult",
        "name" => "consult_agent",
        "arguments" => Jason.encode!(%{"message" => "what is status?"})
      },
      %{"type" => "response.done"},
      %{"type" => "response.output_text.delta", "delta" => "Front desk "},
      %{"type" => "response.output_text.delta", "delta" => "final"},
      %{"type" => "response.done"}
    ]

    SharedTransport.reset(frames)

    {:ok, eng} =
      FakeEngagementStore.start(result: {:ok, %{id: "eng_consult_e2e", agent_id: "agent_x"}})

    {:ok, _ledger} = FakeLedger.start()
    {:ok, signals} = FakeSignals.start()
    {:ok, recorder} = FakeCommsSession.start_recorder()

    opts = [
      comms: FakeCommsSession,
      engagement_store: FakeEngagementStore,
      ledger: FakeLedger,
      signals: FakeSignals,
      backend: XaiRealtime,
      backend_opts: [
        transport: SharedTransport,
        oauth_resolver: fn :xai -> {:ok, "test-token-not-real"} end
      ],
      # Capture context while preserving FrontDesk catalog + consult path.
      tool_router: ContextCapturingFrontDesk,
      tool_router_timeout_ms: 5_000,
      progress_threshold_ms: 2_000,
      session_token: @distinctive_token,
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

    %{opts: opts, eng: eng, signals: signals, recorder: recorder}
  end

  @tag spec: "VOICE-9,VOICE-17"
  @tag :security_regression
  test "security regression: public turn consult_agent schema, grounded reply, token isolation",
       %{
         opts: opts,
         signals: signals,
         recorder: recorder
       } do
    {user_id, agent_id} = unique_ids()
    assert {:ok, key} = Voice.start_session(user_id, agent_id, opts)

    assert {:ok, "Front desk final"} = Voice.text_turn(user_id, agent_id, "please consult")

    sent = SharedTransport.sent()

    # session.update carries exactly the FrontDesk catalog
    updates =
      Enum.filter(sent, fn
        %{"type" => "session.update"} -> true
        _ -> false
      end)

    assert length(updates) >= 1
    [%{"session" => session_payload} | _] = updates
    assert session_payload["tools"] == FrontDesk.catalog()

    # Router context is exactly the six credential-free keys — not merely that
    # provider frames lack the token.
    assert [router_context] = ContextCapturingFrontDesk.contexts()

    assert Map.keys(router_context) |> Enum.sort() ==
             [:agent_id, :arguments, :call_id, :engagement_id, :name, :user_id]

    assert router_context.call_id == "call_consult"
    assert router_context.name == "consult_agent"
    assert router_context.arguments == %{"message" => "what is status?"}
    assert router_context.user_id == user_id
    assert router_context.agent_id == agent_id
    assert router_context.engagement_id == "eng_consult_e2e"
    refute Map.has_key?(router_context, :session_token)
    refute Map.has_key?(router_context, :authority)
    refute inspect(router_context) =~ @distinctive_token
    refute Enum.any?(Map.values(router_context), &is_function/1)
    refute Enum.any?(Map.values(router_context), &is_pid/1)
    refute Enum.any?(Map.values(router_context), &is_reference/1)

    # Agent facade received one exact voice UserMessage
    assert [call] = FakeAgentFacade.calls()
    assert call.caller_id == user_id
    assert call.target_agent_id == agent_id
    assert %UserMessage{} = call.message
    assert call.message.content == "what is status?"
    assert call.message.transport == :voice
    assert call.message.sender_id == user_id
    assert call.message.engagement_id == nil
    assert Keyword.get(call.opts, :timeout) == 5_000
    assert Keyword.get(call.opts, :session_token) == @distinctive_token

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
          "call_id" => "call_consult",
          "output" => output
        }
      }
    ] = outputs

    assert Jason.decode!(output) == %{
             "success" => true,
             "result" => %{"reply" => "agent grounded reply"}
           }

    refute output =~ @distinctive_token
    assert {:ok, status} = Voice.session_status(key)
    refute inspect(status) =~ @distinctive_token

    # Security regression: distinctive token absent from provider frames,
    # signals, status, public result, and inspected retained surfaces.
    encoded_sent = inspect(sent)
    refute encoded_sent =~ @distinctive_token

    emissions = FakeSignals.emissions(signals)
    refute inspect(emissions) =~ @distinctive_token

    [{session_pid, _}] = Registry.lookup(Arbor.Voice.Registry, key)
    sys_status = :sys.get_status(session_pid)
    refute inspect(sys_status) =~ @distinctive_token
    # Proof is closed over inside tool_authority only — not a Session field
    # and never visible via Inspect of retained state.
    state = :sys.get_state(session_pid)
    refute Map.has_key?(state, :session_token)
    refute inspect(state) =~ @distinctive_token
    refute inspect(session_pid) =~ @distinctive_token

    # Transcript path only has front-desk user/final assistant pair
    records = FakeCommsSession.record_calls(recorder)
    refute inspect(records) =~ @distinctive_token

    assert :ok = Voice.stop_session(key)
  end

  @tag spec: "VOICE-9"
  @tag :security_regression
  test "security regression: unauthenticated local backend preserves consult engagement without proof",
       %{opts: opts, recorder: recorder} do
    FakeAgentFacade.reset()
    ControllableTurnBackend.ensure_table!()
    ControllableTurnBackend.reset()

    ControllableTurnBackend.enqueue([
      {:tool_call,
       %{
         id: "call_local_consult",
         name: "consult_agent",
         arguments: %{"message" => "local status"}
       }},
      {:turn_done, %{text: ""}},
      {:turn_done, %{text: "Local consult final"}}
    ])

    local_opts =
      opts
      |> Keyword.delete(:session_token)
      |> Keyword.put(:backend, ControllableTurnBackend)
      |> Keyword.put(:backend_opts, [])
      |> Keyword.put(:tool_router, FrontDesk)

    refute Keyword.has_key?(local_opts, :session_token)
    assert ControllableTurnBackend.egress_route() == :none

    {user_id, agent_id} = unique_ids()
    assert {:ok, key} = Voice.start_session(user_id, agent_id, local_opts)
    on_exit(fn -> _ = Voice.stop_session(key) end)

    assert {:ok, "Local consult final"} =
             Voice.text_turn(user_id, agent_id, "consult over local backend")

    assert [call] = FakeAgentFacade.calls()
    assert call.caller_id == user_id
    assert call.target_agent_id == agent_id
    assert %UserMessage{} = call.message
    assert call.message.content == "local status"
    assert call.message.transport == :voice
    assert call.message.sender_id == user_id
    assert call.message.engagement_id == "eng_consult_e2e"
    assert call.opts == [timeout: 5_000]
    refute Keyword.has_key?(call.opts, :session_token)
    refute inspect(call) =~ "session_token"

    assert [{"call_local_consult", output}] = ControllableTurnBackend.tool_results()

    assert Jason.decode!(output) == %{
             "success" => true,
             "result" => %{"reply" => "agent grounded reply"}
           }

    assert [{^agent_id, "eng_consult_e2e", _user_entry, assistant_entry, _record_opts}] =
             FakeCommsSession.record_calls(recorder)

    assert assistant_entry.content == "Local consult final"

    [{session_pid, _}] = Registry.lookup(Arbor.Voice.Registry, key)
    session_ref = Process.monitor(session_pid)
    assert :ok = Voice.stop_session(key)
    assert_receive {:DOWN, ^session_ref, :process, ^session_pid, _reason}, 1_000
    assert ControllableTurnBackend.close_count() == 1
  end

  @tag spec: "VOICE-9,VOICE-17"
  @tag :security_regression
  test "security regression: missing proof fails before consult and provider effects", %{
    opts: opts
  } do
    FakeAgentFacade.reset()

    SharedTransport.reset([
      %{
        "type" => "response.function_call_arguments.done",
        "call_id" => "call_consult2",
        "name" => "consult_agent",
        "arguments" => Jason.encode!(%{"message" => "no proof"})
      },
      %{"type" => "response.done"},
      %{"type" => "response.output_text.delta", "delta" => "ok"},
      %{"type" => "response.done"}
    ])

    opts = Keyword.delete(opts, :session_token)
    {user_id, agent_id} = unique_ids()
    assert {:error, :start_failed} = Voice.start_session(user_id, agent_id, opts)
    assert FakeAgentFacade.calls() == []
    assert SharedTransport.sent() == []
    assert EgressAuthorityFakes.active_capabilities() == []
  end
end
