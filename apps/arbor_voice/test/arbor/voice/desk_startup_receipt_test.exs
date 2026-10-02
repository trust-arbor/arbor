defmodule Arbor.Voice.DeskStartupReceiptTest do
  use ExUnit.Case, async: false
  alias Arbor.Voice
  alias Arbor.Voice.BudgetLedger
  alias Arbor.Voice.Redacted
  alias Arbor.Voice.Test.BudgetLedgerFakeBackend
  alias Arbor.Voice.Test.ConversationSecurityFixture

  alias Arbor.Voice.Test.SessionFakes.{
    FakeCommsSession,
    FakeEngagementStore,
    FakeLedger,
    FakeSignals
  }

  @moduletag :fast
  @moduletag spec: "VOICE-13"

  defmodule Backend do
    alias Arbor.Voice.PcmFormat

    @behaviour Arbor.Voice.RealtimeBackend
    def egress_route, do: :none

    def open(opts) do
      state = Map.new(opts)
      send(state.parent, {:opened, state.mode})

      case state.mode do
        :open_rejected ->
          {:error, :refused}

        :open_uncertain ->
          {:error, :refused, :cleanup_pending}

        :open_fault ->
          raise "private-open-fault"

        :open_hang ->
          receive do
            :never -> {:error, :refused}
          end

        _ ->
          {:ok, state}
      end
    end

    def configure(state, _) do
      case state.mode do
        mode when mode in [:configure_rejected, :close_unknown] ->
          {:error, :refused}

        :cancel_after_configure ->
          :atomics.put(state.revoked, 1, 1)
          {:ok, state}

        _ ->
          {:ok, state}
      end
    end

    def send_text(state, _), do: {:ok, state}
    def send_audio(state, _), do: {:ok, state}
    def send_tool_result(state, _, _), do: {:ok, state}
    def recv(_, _), do: {:error, :timeout}

    def close(state) do
      send(state.parent, {:backend_close, state.mode})
      if state.mode == :close_unknown, do: {:error, :unknown}, else: :ok
    end

    def meta(_),
      do: %{
        backend: :desk_receipt_test,
        mode: :local,
        input_format: PcmFormat.mono_s16le(16_000),
        output_format: PcmFormat.mono_s16le(24_000)
      }
  end

  defmodule Multimedia do
    import ExUnit.Assertions

    def capture_pcm(opts) do
      {:ok,
       %{
         audio: %{
           pcm: :binary.copy(<<0, 0>>, opts[:duration_ms] * 16),
           sample_rate: 16_000,
           channels: 1,
           sample_format: :s16le
         },
         utterance_ended_at: ~U[2026-09-28 12:00:00Z]
       }}
    end

    def device_status, do: :idle
    def play_pcm(_, _), do: flunk("startup failure must not present audio")
  end

  defmodule NormalExit do
    use GenServer
    def init(_), do: {:ok, nil}
    def handle_call(:stop, _from, state), do: {:stop, :normal, state}
  end

  setup do
    ConversationSecurityFixture.install()
    {:ok, _} = FakeEngagementStore.start()
    {:ok, ledger} = FakeLedger.start()
    {:ok, _} = FakeSignals.start()

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Arbor.Voice.DeskSupervisor),
          is_pid(pid),
          do: DynamicSupervisor.terminate_child(Arbor.Voice.DeskSupervisor, pid)
    end)

    {:ok, ledger: ledger}
  end

  defp start(mode, extra \\ []) do
    revoked = :atomics.new(1, [])

    custody = %{
      pid: self(),
      revoked: revoked,
      deadline: System.monotonic_time(:millisecond) + 5_000
    }

    opts = session_options(mode, revoked)

    Voice.start_owned_desk_session(
      "desk-receipt-user",
      "desk-receipt-agent",
      Keyword.merge(opts, extra),
      custody
    )
  end

  defp session_options(mode, revoked) do
    [
      session_token: "voice-fixture-proof",
      audio_mode: :pcm16,
      backend: Backend,
      backend_opts: [parent: self(), mode: mode, revoked: revoked],
      comms: FakeCommsSession,
      engagement_store: FakeEngagementStore,
      ledger: FakeLedger,
      signals: FakeSignals,
      resource_owner_opts: [
        close_timeout_ms: 150,
        cleanup_ready_timeout_ms: 100,
        cleanup_attempts: 2,
        cleanup_per_attempt_timeout_ms: 50
      ],
      session_budget_ms: 5_000,
      daily_budget_ms: 60_000
    ]
  end

  defp configure_desk(options) do
    values = [
      desk_voice_module: Voice,
      desk_multimedia_module: Multimedia,
      desk_comms_module: FakeCommsSession,
      desk_session_options: options
    ]

    previous = for {key, _} <- values, do: {key, Application.fetch_env(:arbor_voice, key)}
    for {key, value} <- values, do: Application.put_env(:arbor_voice, key, value)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, prior} -> Application.put_env(:arbor_voice, key, prior)
          :error -> Application.delete_env(:arbor_voice, key)
        end
      end
    end)
  end

  defp desk do
    Voice.start_desk_turn("desk-receipt-user", "desk-receipt-agent",
      session_token: "voice-fixture-proof",
      duration_ms: 100
    )
  end

  defp terminal(id, attempts \\ 100)
  defp terminal(_id, 0), do: flunk("owned startup did not settle")

  defp terminal(id, attempts) do
    assert {:ok, status} = Voice.desk_turn_status(id)

    if status.terminal do
      status
    else
      Process.sleep(10)
      terminal(id, attempts - 1)
    end
  end

  defp cleanup_pending(id, attempts \\ 100)
  defp cleanup_pending(_id, 0), do: flunk("owned startup never reported pending cleanup")

  defp cleanup_pending(id, attempts) do
    assert {:ok, status} = Voice.desk_turn_status(id)

    if status.state == :cleanup_pending do
      refute status.terminal
      status
    else
      Process.sleep(10)
      cleanup_pending(id, attempts - 1)
    end
  end

  test "security regression: normal Session exit cannot substitute for a positive close receipt" do
    {:ok, pid} = GenServer.start(NormalExit, nil)
    handle = Redacted.new(%{pid: pid, closed: :atomics.new(1, [])})
    assert {:error, :cleanup_pending} = Voice.stop_owned_desk_session(handle)
  end

  test "checked startup rejection closes resources and permits an immediate new Session" do
    for mode <- [:open_rejected, :configure_rejected, :cancel_after_configure] do
      assert {:error, :start_failed, :closed} = start(mode)
      assert {:ok, handle} = start(:ok)
      assert :ok = Voice.stop_owned_desk_session(handle)
    end
  end

  test "security regression: startup fault timeout or failed close retains uncertainty" do
    for mode <- [:open_fault, :open_hang, :open_uncertain, :close_unknown] do
      assert {:error, :start_failed, :cleanup_pending} = start(mode)
    end
  end

  test "security regression: actual disabled ledger is a closed pre-resource refusal" do
    assert {:error, :disabled} = BudgetLedger.readiness(backend: nil)

    assert {:error, :start_failed, :closed} =
             start(:ok, ledger: BudgetLedger, ledger_opts: [backend: nil])

    refute_receive {:opened, _}
    assert {:ok, handle} = start(:ok)
    assert :ok = Voice.stop_owned_desk_session(handle)
  end

  test "security regression: invalid wall clock has no reservation to keep startup pending" do
    assert {:error, :start_failed, :closed} = start(:ok, wall_clock: fn -> :invalid end)
    refute_receive {:opened, _}
  end

  test "security regression: successful exact reservation release closes failed startup" do
    assert {:error, :start_failed, :closed} = start(:ok, monotonic_clock: fn -> :invalid end)
    refute_receive {:opened, _}
  end

  test "security regression: failed exact reservation release keeps startup pending", %{
    ledger: ledger
  } do
    for failure <- [:error, :raise] do
      FakeLedger.set_release_mode(ledger, failure)

      assert {:error, :start_failed, :cleanup_pending} =
               start(:ok, monotonic_clock: fn -> :invalid end)

      refute_receive {:opened, _}
    end
  end

  test "security regression: ambiguous real ledger CAS never proves startup closed" do
    name = :desk_startup_cas_ambiguity
    {:ok, _} = BudgetLedgerFakeBackend.start_link(agent_name: name)
    on_exit(fn -> BudgetLedgerFakeBackend.stop(name) end)
    :ok = BudgetLedgerFakeBackend.set_cas_error(name, :ack_lost)

    result =
      start(:ok,
        ledger: BudgetLedger,
        ledger_opts: [backend: BudgetLedgerFakeBackend, backend_opts: [agent_name: name]]
      )

    assert {:error, :start_failed, :cleanup_pending} = result
    refute_receive {:opened, _}
  end

  test "security regression: actual disabled ledger retires Desk and permits the next Record" do
    options = session_options(:open_rejected, :atomics.new(1, []))
    configure_desk(Keyword.merge(options, ledger: BudgetLedger, ledger_opts: [backend: nil]))
    assert {:ok, first} = desk()
    assert %{terminal: true, state: :cancelled, error: :start_failed} = terminal(first)
    refute_receive {:opened, _}

    Application.put_env(:arbor_voice, :desk_session_options, options)
    assert {:ok, second} = desk()
    assert %{terminal: true, state: :cancelled, error: :start_failed} = terminal(second)
    assert_receive {:opened, :open_rejected}
  end

  test "security regression: ambiguous real ledger CAS keeps Desk and blocks another Record" do
    name = :desk_pending_cas_ambiguity
    {:ok, _} = BudgetLedgerFakeBackend.start_link(agent_name: name)
    on_exit(fn -> BudgetLedgerFakeBackend.stop(name) end)
    :ok = BudgetLedgerFakeBackend.set_cas_error(name, :ack_lost)

    options = session_options(:ok, :atomics.new(1, []))

    configure_desk(
      Keyword.merge(options,
        ledger: BudgetLedger,
        ledger_opts: [backend: BudgetLedgerFakeBackend, backend_opts: [agent_name: name]]
      )
    )

    assert {:ok, id} = desk()
    assert %{error: :start_failed} = cleanup_pending(id)
    assert {:error, :cleanup_pending} = Voice.cancel_desk_turn(id)
    assert {:error, :device_busy} = desk()
    refute_receive {:opened, _}
  end

  test "security regression: failed release keeps Desk and blocks another Record", %{
    ledger: ledger
  } do
    FakeLedger.set_release_mode(ledger, :error)

    configure_desk(
      session_options(:ok, :atomics.new(1, []))
      |> Keyword.put(:monotonic_clock, fn -> :invalid end)
    )

    assert {:ok, id} = desk()
    assert %{error: :start_failed} = cleanup_pending(id)
    assert {:error, :cleanup_pending} = Voice.cancel_desk_turn(id)
    assert {:error, :device_busy} = desk()
    refute_receive {:opened, _}
  end

  test "security regression: cancellation during startup clock read prevents reservation", %{
    ledger: ledger
  } do
    parent = self()

    clock = fn ->
      send(parent, {:wall_clock_waiting, self()})

      receive do
        :read_clock -> ~U[2026-09-28 12:00:00Z]
      after
        2_000 -> :invalid
      end
    end

    configure_desk(
      session_options(:ok, :atomics.new(1, []))
      |> Keyword.put(:wall_clock, clock)
    )

    assert {:ok, id} = desk()
    assert_receive {:wall_clock_waiting, starter}
    assert {:error, :cleanup_pending} = Voice.cancel_desk_turn(id)
    assert {:error, :device_busy} = desk()
    send(starter, :read_clock)
    assert %{terminal: true, state: :cancelled} = terminal(id)
    assert FakeLedger.calls(ledger) == []
    refute_receive {:opened, _}

    Application.put_env(
      :arbor_voice,
      :desk_session_options,
      session_options(:open_rejected, :atomics.new(1, []))
    )

    assert {:ok, next} = desk()
    assert %{terminal: true, state: :cancelled} = terminal(next)
    assert_receive {:opened, :open_rejected}
  end
end
