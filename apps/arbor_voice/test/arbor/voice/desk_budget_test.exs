defmodule Arbor.Voice.DeskBudgetTest do
  use ExUnit.Case, async: false
  alias Arbor.Voice
  alias Arbor.Voice.BudgetLedger
  alias Arbor.Voice.Test.BudgetLedgerFakeBackend, as: Store
  alias Arbor.Voice.Test.SessionFakes.{FakeCommsSession, FakeEngagementStore, FakeSignals}

  @moduletag :fast
  @moduletag :integration
  @moduletag spec: "VOICE-13,VOICE-24"

  defmodule Media do
    def capture_pcm(opts) do
      if observer = Application.get_env(:arbor_voice, :desk_budget_capture_observer),
        do: send(observer, :capture_started)

      {:ok,
       %{
         audio: %{
           pcm: :binary.copy(<<1, 0>>, opts[:duration_ms] * 16),
           sample_rate: 16_000,
           channels: 1,
           sample_format: :s16le
         },
         utterance_ended_at: ~U[2026-09-28 12:00:00Z]
       }}
    end

    def play_pcm(_, _), do: :ok
    def device_status, do: :idle
  end

  defmodule Backend do
    @behaviour Arbor.Voice.RealtimeBackend
    def egress_route, do: :none
    def open(opts), do: {:ok, %{parent: opts[:parent], events: []}}
    def configure(state, _), do: {:ok, state}
    def send_text(state, _), do: {:ok, state}
    def send_tool_result(state, _, _), do: {:ok, state}

    def send_audio(state, _) do
      send(state.parent, :provider_received_audio)

      {:ok,
       %{
         state
         | events: [
             {:input_transcript, "Budget test request"},
             {:turn_done, %{text: "Budget test response"}}
           ]
       }}
    end

    def recv(%{events: [event | rest]} = state, _) do
      Process.sleep(5)
      {:ok, %{state | events: rest}, event}
    end

    def recv(_, _), do: {:error, :timeout}

    def close(state) do
      send(state.parent, :provider_closed)
      :ok
    end

    def meta(_),
      do: %{
        backend: :desk_budget_fixture,
        mode: :local,
        input_format: Arbor.Voice.PcmFormat.mono_s16le(16_000),
        output_format: Arbor.Voice.PcmFormat.mono_s16le(24_000)
      }
  end

  defmodule Speakable do
    def render(text, _), do: {:screen_only, text}
    def tts_guard!({_, text}), do: text
  end

  setup do
    Arbor.Voice.Test.ConversationSecurityFixture.install()
    {:ok, _} = FakeEngagementStore.start()
    {:ok, _} = FakeSignals.start()
    {:ok, _} = FakeCommsSession.start_recorder()
    store = :"desk_budget_store_#{System.unique_integer([:positive])}"
    {:ok, _} = Store.start_link(agent_name: store)

    ledger_opts = [
      backend: Store,
      backend_opts: [agent_name: store],
      now_unix_ms: DateTime.to_unix(~U[2026-09-28 12:00:00Z], :millisecond)
    ]

    settings = [
      desk_multimedia_module: Media,
      desk_voice_module: Voice,
      desk_comms_module: FakeCommsSession,
      daily_budget_ms: 3_600_000,
      session_budget_ms: 3_600_000,
      tool_router_timeout_ms: 60_000,
      audio_turn_timeout_ms: 90_000,
      desk_timeout_ms: 120_000,
      desk_session_options: [
        backend: Backend,
        backend_opts: [parent: self()],
        comms: FakeCommsSession,
        engagement_store: FakeEngagementStore,
        ledger: BudgetLedger,
        ledger_opts: ledger_opts,
        signals: FakeSignals,
        speakable: Speakable,
        wall_clock: fn -> ~U[2026-09-28 12:00:00Z] end
      ]
    ]

    previous = for {key, _} <- settings, do: {key, Application.fetch_env(:arbor_voice, key)}
    for {key, value} <- settings, do: Application.put_env(:arbor_voice, key, value)

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Arbor.Voice.DeskSupervisor),
          is_pid(pid),
          do: DynamicSupervisor.terminate_child(Arbor.Voice.DeskSupervisor, pid)

      for {key, value} <- previous do
        case value do
          {:ok, old} -> Application.put_env(:arbor_voice, key, old)
          :error -> Application.delete_env(:arbor_voice, key)
        end
      end

      Store.stop(store)
    end)

    %{store: store, ledger_opts: ledger_opts}
  end

  test "regression: two completed Desk turns reserve only their bounded permit, not the daily allowance",
       context do
    user = "desk-budget-repeat-#{System.unique_integer([:positive])}"

    for _ <- 1..2 do
      assert {:ok, operation} =
               Voice.start_desk_turn(user, "budget-agent",
                 session_token: "fixture",
                 duration_ms: 100
               )

      assert %{terminal: true, state: :complete, error: nil} = await_terminal(operation)
      assert_receive :provider_received_audio
      assert_receive :provider_closed
    end

    assert {:ok, remaining} =
             BudgetLedger.remaining(user, "2026-09-28", 3_600_000, context.ledger_opts)

    assert remaining < 3_600_000
    assert remaining > 3_480_000

    requested =
      Store.history(context.store)
      |> Enum.flat_map(fn
        %{record: %{data: %{"active_reservations" => entries}}} ->
          Enum.map(entries, & &1["requested_ms"])

        _ ->
          []
      end)

    assert requested != []
    assert Enum.all?(requested, &(&1 > 0 and &1 <= 120_000))
  end

  test "owned Desk startup honors lower configured ceilings and the remaining permit" do
    opts = Application.fetch_env!(:arbor_voice, :desk_session_options)

    for {session_budget, daily_budget, lifetime, ceiling} <- [
          {3_600_000, 3_600_000, 300_000, 120_000},
          {5_000, 10_000, 60_000, 5_000},
          {3_600_000, 3_600_000, 10_000, 10_000}
        ] do
      custody = %{
        pid: self(),
        revoked: :atomics.new(1, []),
        deadline: System.monotonic_time(:millisecond) + lifetime
      }

      user = "desk-cap-#{System.unique_integer([:positive])}"

      assert {:ok, handle} =
               Voice.start_owned_desk_session(
                 user,
                 "budget-agent",
                 opts ++
                   [
                     session_token: "fixture",
                     audio_mode: :pcm16,
                     session_budget_ms: session_budget,
                     daily_budget_ms: daily_budget
                   ],
                 custody
               )

      on_exit(fn -> Voice.stop_owned_desk_session(handle) end)
      assert {:ok, %{reserved_ms: reserved}} = Voice.session_status({user, "budget-agent"})
      assert reserved > 0 and reserved <= ceiling
      assert :ok = Voice.stop_owned_desk_session(handle)
    end
  end

  test "security regression: caller options cannot raise operator Desk budget ceilings",
       context do
    Application.put_env(:arbor_voice, :session_budget_ms, 5_000)
    Application.put_env(:arbor_voice, :daily_budget_ms, 10_000)
    opts = Application.fetch_env!(:arbor_voice, :desk_session_options)
    user = "desk-operator-cap-#{System.unique_integer([:positive])}"

    custody = %{
      pid: self(),
      revoked: :atomics.new(1, []),
      deadline: System.monotonic_time(:millisecond) + 60_000
    }

    assert {:ok, handle} =
             Voice.start_owned_desk_session(
               user,
               "budget-agent",
               opts ++
                 [
                   session_token: "fixture",
                   audio_mode: :pcm16,
                   session_budget_ms: 3_600_000,
                   daily_budget_ms: 3_600_000
                 ],
               custody
             )

    on_exit(fn -> Voice.stop_owned_desk_session(handle) end)
    assert {:ok, %{reserved_ms: 5_000}} = Voice.session_status({user, "budget-agent"})
    assert {:ok, 5_000} = BudgetLedger.remaining(user, "2026-09-28", 10_000, context.ledger_opts)
    assert :ok = Voice.stop_owned_desk_session(handle)
  end

  test "malformed operation configuration fails before capture or provider startup" do
    previous = Application.fetch_env(:arbor_voice, :desk_budget_capture_observer)
    Application.put_env(:arbor_voice, :desk_budget_capture_observer, self())

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_voice, :desk_budget_capture_observer, value)
        :error -> Application.delete_env(:arbor_voice, :desk_budget_capture_observer)
      end
    end)

    for {key, normal} <- [
          tool_router_timeout_ms: 60_000,
          audio_turn_timeout_ms: 90_000,
          desk_timeout_ms: 120_000
        ] do
      Application.put_env(:arbor_voice, key, :invalid)

      assert {:error, :invalid_config} =
               Voice.start_desk_turn("bad-config", "agent",
                 session_token: "fixture",
                 duration_ms: 100
               )

      Application.put_env(:arbor_voice, key, normal)
    end

    refute_receive :capture_started
    refute_receive :provider_received_audio
  end

  test "a shorter operator Desk allowance becomes the unchanged permit and reservation" do
    Application.put_env(:arbor_voice, :desk_timeout_ms, 2_000)

    assert {:ok, operation} =
             Voice.start_desk_turn("short-desk", "agent",
               session_token: "fixture",
               duration_ms: 100
             )

    assert [{pid, _}] = Registry.lookup(Arbor.Voice.Registry, {:desk, operation})
    state = :sys.get_state(pid)
    assert state.permit.deadline == state.started_at + 2_000
    assert %{terminal: true, state: :complete} = await_terminal(operation)
    assert_receive :provider_received_audio
    assert_receive :provider_closed
  end

  defp await_terminal(operation, remaining \\ 250)
  defp await_terminal(_, 0), do: flunk("Desk did not reach a terminal outcome")

  defp await_terminal(operation, remaining) do
    assert {:ok, status} = Voice.desk_turn_status(operation)

    if status.terminal do
      status
    else
      Process.sleep(10)
      await_terminal(operation, remaining - 1)
    end
  end
end
