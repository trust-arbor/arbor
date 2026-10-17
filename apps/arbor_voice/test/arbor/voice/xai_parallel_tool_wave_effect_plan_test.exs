defmodule Arbor.Voice.XaiParallelToolWaveEffectPlanTest do
  @moduledoc """
  Public text turn with a parallel xAI tool wave, through the production
  ResourceOwner external-effect plan (not a permissive effect authorizer).

  Two requirements meet here:
  - xAI wants exactly one `response.create` after every function_call_output
    of a response, not one per output (the PR #15 goal);
  - ResourceOwner admits only the effects declared for each backend
    operation, and `recv` declares none.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Voice
  alias Arbor.Voice.Backend.XaiRealtime
  alias Arbor.Voice.Test.EgressAuthorityFakes
  alias Arbor.Voice.Test.EgressAuthorityFakes.{AI, Security, Trust}
  alias Arbor.Voice.ToolRouter.FrontDesk

  alias Arbor.Voice.Test.SessionFakes.{
    FakeCommsSession,
    FakeEngagementStore,
    FakeLedger,
    FakeSignals
  }

  defmodule WaveTransport do
    @moduledoc """
    Scripted provider that, like xAI, starts the post-tool response only
    after it receives a `response.create` following tool outputs.
    """
    @table :arbor_voice_xai_parallel_wave_transport

    def reset(frames, after_tools) do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ets.insert(@table, {:frames, frames})
      :ets.insert(@table, {:after_tools, after_tools})
      :ets.insert(@table, {:sent, []})
      :ok
    end

    def sent do
      case :ets.lookup(@table, :sent) do
        [{:sent, list}] -> list
        _ -> []
      end
    end

    def connect(opts) do
      _ = Keyword.fetch!(opts, :token)
      {:ok, %{id: make_ref()}}
    end

    def send_frame(state, frame) do
      [{:sent, list}] = :ets.lookup(@table, :sent)
      :ets.insert(@table, {:sent, list ++ [frame]})
      maybe_release_after_tools(frame, list)
      {:ok, state}
    end

    defp maybe_release_after_tools(%{"type" => "response.create"}, sent_before) do
      outputs_sent? =
        Enum.any?(sent_before, &match?(%{"item" => %{"type" => "function_call_output"}}, &1))

      case :ets.lookup(@table, :after_tools) do
        [{:after_tools, [_ | _] = after_tools}] when outputs_sent? ->
          [{:frames, frames}] = :ets.lookup(@table, :frames)
          :ets.insert(@table, {:frames, frames ++ after_tools})
          :ets.insert(@table, {:after_tools, []})

        _ ->
          :ok
      end
    end

    defp maybe_release_after_tools(_frame, _sent_before), do: :ok

    def send_frame(state, frame, _deadline) do
      case frame do
        %{"type" => "session.update", "session" => session} ->
          [{:frames, frames}] = :ets.lookup(@table, :frames)

          :ets.insert(
            @table,
            {:frames, [%{"type" => "session.updated", "session" => session} | frames]}
          )

        _ ->
          :ok
      end

      send_frame(state, frame)
    end

    def recv_frame(state, _timeout) do
      case :ets.lookup(@table, :frames) do
        [{:frames, [frame | rest]}] ->
          :ets.insert(@table, {:frames, rest})
          {:ok, state, frame}

        _ ->
          {:error, :timeout}
      end
    end

    def close(_state), do: :ok
  end

  defmodule ConsultAgentFacade do
    @moduledoc false
    def send_message(_caller_id, _target_agent_id, _message, _opts \\ []),
      do: {:ok, "consult reply"}

    def dispatch_task(_caller_id, _target_agent_id, _task, _opts \\ []),
      do: {:error, :not_used}
  end

  defmodule NoRootsOrchestrator do
    @moduledoc false
    def coding_repo_roots, do: {:ok, ["/tmp/arbor-voice-parallel-wave-root"]}
  end

  setup do
    EgressAuthorityFakes.reset()

    previous =
      for key <- [
            :agent_module,
            :orchestrator_module,
            :ai_module,
            :security_module,
            :trust_module
          ],
          into: %{} do
        {key, Application.fetch_env(:arbor_voice, key)}
      end

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_voice, key, value)
        {key, :error} -> Application.delete_env(:arbor_voice, key)
      end)
    end)

    Application.put_env(:arbor_voice, :agent_module, ConsultAgentFacade)
    Application.put_env(:arbor_voice, :orchestrator_module, NoRootsOrchestrator)
    Application.put_env(:arbor_voice, :ai_module, AI)
    Application.put_env(:arbor_voice, :security_module, Security)
    Application.put_env(:arbor_voice, :trust_module, Trust)

    {:ok, _eng} =
      FakeEngagementStore.start(
        result: {:ok, %{id: "eng_5b1f0c2d4e6a8b0c1d2e3f4a5b6c7d8e", agent_id: "agent_x"}}
      )

    {:ok, _ledger} = FakeLedger.start()
    {:ok, _signals} = FakeSignals.start()
    {:ok, _recorder} = FakeCommsSession.start_recorder()

    opts = [
      comms: FakeCommsSession,
      engagement_store: FakeEngagementStore,
      ledger: FakeLedger,
      signals: FakeSignals,
      backend: XaiRealtime,
      backend_opts: [
        transport: WaveTransport,
        oauth_resolver: fn :xai -> {:ok, "test-token-not-real"} end
      ],
      tool_router: FrontDesk,
      tool_router_timeout_ms: 5_000,
      progress_threshold_ms: 2_000,
      session_token: "xai-parallel-wave-token-7d3e9b21",
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

    %{opts: opts}
  end

  @tag spec: "VOICE-8"
  test "parallel tool wave completes under the owner effect plan with one response.create after both outputs",
       %{opts: opts} do
    WaveTransport.reset(
      [
        consult_call("call_wave_a", "first question"),
        consult_call("call_wave_b", "second question"),
        %{"type" => "response.done"}
      ],
      [
        %{"type" => "response.output_text.delta", "delta" => "after tools"},
        %{"type" => "response.done"}
      ]
    )

    n = System.unique_integer([:positive])
    {user_id, agent_id} = {"user_wave_#{n}", "agent_wave_#{n}"}

    assert {:ok, key} = Voice.start_session(user_id, agent_id, opts)
    assert {:ok, "after tools"} = Voice.text_turn(user_id, agent_id, "ask two things")

    sent = WaveTransport.sent()

    outputs =
      for {%{"item" => %{"type" => "function_call_output", "call_id" => id}}, i} <-
            Enum.with_index(sent),
          do: {id, i}

    assert Enum.map(outputs, &elem(&1, 0)) |> Enum.sort() == ["call_wave_a", "call_wave_b"]
    first_output = outputs |> Enum.map(&elem(&1, 1)) |> Enum.min()
    last_output = outputs |> Enum.map(&elem(&1, 1)) |> Enum.max()

    creates_after_first_output =
      for {%{"type" => "response.create"}, i} <- Enum.with_index(sent), i > first_output, do: i

    assert [create_index] = creates_after_first_output
    assert create_index > last_output

    assert :ok = Voice.stop_session(key)
  end

  defp consult_call(call_id, message) do
    %{
      "type" => "response.function_call_arguments.done",
      "call_id" => call_id,
      "name" => "consult_agent",
      "arguments" => Jason.encode!(%{"message" => message})
    }
  end
end
