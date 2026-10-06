defmodule Arbor.Voice.DeskLateCleanupTest do
  use ExUnit.Case, async: false

  alias Arbor.Voice
  alias Arbor.Voice.ClosureReceipt
  alias Arbor.Voice.Test.ConversationSecurityFixture

  alias Arbor.Voice.Test.SessionFakes.{
    FakeCommsSession,
    FakeEngagementStore,
    FakeLedger,
    FakeSignals
  }

  @moduletag :fast
  @moduletag :integration
  @moduletag spec: "VOICE-13,VOICE-24"

  @supervisors [
    Arbor.Voice.DeskSupervisor,
    Arbor.Voice.SessionSupervisor,
    Arbor.Voice.ResourceSupervisor,
    Arbor.Voice.CleanupLeaseSupervisor,
    Arbor.Voice.BackendWorkerSupervisor,
    Arbor.Voice.DeskWorkerSupervisor
  ]

  defmodule Media do
    def capture_pcm(opts) do
      {:ok,
       %{
         audio: %{
           pcm: :binary.copy(<<0, 0>>, opts[:duration_ms] * 16),
           sample_rate: 16_000,
           channels: 1,
           sample_format: :s16le
         },
         utterance_ended_at: ~U[2026-09-29 12:00:00Z]
       }}
    end

    def play_pcm(_, _), do: :ok
    def device_status, do: :idle
  end

  defmodule Backend do
    @behaviour Arbor.Voice.RealtimeBackend
    def egress_route, do: :none
    def open(opts), do: {:ok, Map.new(opts) |> Map.put(:events, [])}
    def configure(%{mode: :startup_failure}, _), do: {:error, :refused}

    def configure(%{mode: :startup_timeout} = state, _) do
      {:ok, deadline} = Arbor.Voice.BackendWorker.operation_deadline()
      send(state.parent, {:startup_timeout_configuring, self()})
      delay = max(deadline - System.monotonic_time(:millisecond), 0) + 25
      Process.send_after(self(), :finish_startup_configuration, delay)

      receive do
        :finish_startup_configuration ->
          {:error, :timeout, Map.put(state, :generation, 1)}
      end
    end

    def configure(state, _), do: {:ok, state}
    def send_text(state, _), do: {:ok, state}
    def send_tool_result(state, _, _), do: {:ok, state}

    def send_audio(state, _) do
      send(state.parent, :audio_received)
      events = [{:input_transcript, "Fixture request"}, {:turn_done, %{text: "Fixture response"}}]
      {:ok, %{state | events: events}}
    end

    def recv(%{mode: :success, events: [event | rest]} = state, _),
      do: {:ok, %{state | events: rest}, event}

    def recv(%{mode: :hold, parent: parent}, _) do
      send(parent, :audio_receiving)
      Process.sleep(5)
      {:error, :timeout}
    end

    def recv(_, _), do: {:error, :fixture_failure}

    def close(state) do
      send(state.parent, {:backend_close, state.mode})

      if state.mode == :startup_timeout,
        do: send(state.parent, {:startup_timeout_closed, state.generation, self()})

      if state.mode == :unknown_close, do: {:error, :unknown}, else: :ok
    end

    def meta(_),
      do: %{
        backend: :late_cleanup_fixture,
        mode: :local,
        input_format: Arbor.Voice.PcmFormat.mono_s16le(16_000),
        output_format: Arbor.Voice.PcmFormat.mono_s16le(24_000)
      }
  end

  defmodule Speakable do
    def render(text, _), do: {:screen_only, text}
    def tts_guard!({_, text}), do: text
  end

  # Observe the actual owner identity without replacing any ownership behavior.
  defmodule TrackingOwner do
    alias Arbor.Voice.ResourceOwner

    def start(session, backend, backend_opts, handoff, opts) do
      case ResourceOwner.start(session, backend, backend_opts, handoff, opts) do
        {:ok, owner} = result ->
          send(backend_opts[:parent], {:resource_owner, session, owner})
          result

        other ->
          other
      end
    end

    defdelegate configure(owner, config), to: ResourceOwner
    defdelegate meta(owner), to: ResourceOwner
    defdelegate close(owner), to: ResourceOwner
    defdelegate reserve_audio_turn(owner, format, bytes, timeout), to: ResourceOwner
    defdelegate reserve_audio(owner, format, bytes, timeout), to: ResourceOwner
    defdelegate handoff_audio(owner, ticket, pcm), to: ResourceOwner
    defdelegate recv_audio_request(owner, ticket, timeout), to: ResourceOwner
    defdelegate send_text(owner, text), to: ResourceOwner
    defdelegate send_audio(owner, pcm), to: ResourceOwner
    defdelegate send_tool_result(owner, id, result), to: ResourceOwner
    defdelegate send_tool_result_request(owner, id, result), to: ResourceOwner
    defdelegate recv(owner, timeout), to: ResourceOwner
    defdelegate register_cleanup(owner, key, fun), to: ResourceOwner
    defdelegate adopt_provisional_cleanup(owner, key, fun), to: ResourceOwner
    defdelegate remove_cleanup(owner, key), to: ResourceOwner
    defdelegate activate_turn(owner, lease), to: ResourceOwner
    defdelegate fence_and_drain(owner, scope), to: ResourceOwner
  end

  setup do
    ConversationSecurityFixture.install()
    {:ok, _} = FakeEngagementStore.start()
    {:ok, _} = FakeCommsSession.start_recorder()
    {:ok, _} = FakeSignals.start()
    {:ok, ledger} = FakeLedger.start()
    prior_children = Map.new(@supervisors, &{&1, children(&1)})

    opts = [
      backend: Backend,
      backend_opts: [parent: self(), mode: :turn_failure],
      comms: FakeCommsSession,
      engagement_store: FakeEngagementStore,
      ledger: FakeLedger,
      resource_owner: TrackingOwner,
      signals: FakeSignals,
      speakable: Speakable,
      session_budget_ms: 5_000,
      daily_budget_ms: 60_000,
      resource_owner_opts: [
        close_timeout_ms: 300,
        cleanup_ready_timeout_ms: 100,
        cleanup_per_attempt_timeout_ms: 50
      ]
    ]

    settings = [
      desk_voice_module: Voice,
      desk_multimedia_module: Media,
      desk_comms_module: FakeCommsSession,
      desk_session_options: opts
    ]

    previous = for {key, _} <- settings, do: {key, Application.fetch_env(:arbor_voice, key)}
    for {key, value} <- settings, do: Application.put_env(:arbor_voice, key, value)

    on_exit(fn ->
      try do
        for supervisor <- @supervisors,
            pid <- MapSet.difference(children(supervisor), prior_children[supervisor]) do
          DynamicSupervisor.terminate_child(supervisor, pid)
        end
      after
        for {key, value} <- previous do
          case value do
            {:ok, original} -> Application.put_env(:arbor_voice, key, original)
            :error -> Application.delete_env(:arbor_voice, key)
          end
        end
      end
    end)

    {:ok, ledger: ledger, user: "late-cleanup-#{System.unique_integer([:positive])}"}
  end

  test "security regression: real late lease settlement releases Desk after Session and owner exit",
       %{ledger: ledger, user: user} do
    FakeLedger.set_consume_mode(ledger, :error)
    assert {:ok, id} = record(user)
    assert_receive {:resource_owner, session, owner}, 1_000
    session_ref = Process.monitor(session)
    owner_ref = Process.monitor(owner)
    assert_receive {:backend_close, :turn_failure}, 1_000

    assert %{terminal: false, state: :cleanup_pending} =
             await(id, &(&1.state == :cleanup_pending))

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, _}, 1_000
    assert_receive {:DOWN, ^session_ref, :process, ^session, _}, 1_000
    assert {:error, :not_found} = Voice.session_status({user, "fixture-agent"})
    assert {:error, :device_busy} = record(user)
    assert Enum.any?(FakeLedger.calls(ledger), &match?({:consume, _, _, _}, &1))

    FakeLedger.set_consume_mode(ledger, :ok)
    assert %{terminal: true, state: :cancelled} = await(id, & &1.terminal)
    assert {:ok, next} = record(user)
    assert %{terminal: true} = await(next, & &1.terminal)
  end

  test "security regression: accepted startup handoff converges after late exact release",
       %{ledger: ledger, user: user} do
    mode(:startup_failure)
    FakeLedger.set_release_mode(ledger, :error)
    assert {:ok, id} = record(user)
    assert %{terminal: false} = await(id, &(&1.state == :cleanup_pending))
    assert {:error, :device_busy} = record(user)
    assert Enum.any?(FakeLedger.calls(ledger), &match?({:release, _, _}, &1))
    FakeLedger.set_release_mode(ledger, :ok)
    assert %{terminal: true} = await(id, & &1.terminal)
    assert {:ok, next} = record(user)
    assert %{terminal: true} = await(next, & &1.terminal)
  end

  test "security regression: timed-out startup closes exact backend before late lease settlement",
       %{ledger: ledger, user: user} do
    mode(:startup_timeout)
    FakeLedger.set_release_mode(ledger, :error)
    assert {:ok, id} = record(user)
    assert_receive {:startup_timeout_configuring, worker}, 1_000
    worker_ref = Process.monitor(worker)
    assert_receive {:startup_timeout_closed, 1, ^worker}, 1_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 1_000
    refute_receive :audio_received, 25

    assert %{terminal: false, state: :cleanup_pending} =
             await(id, &(&1.state == :cleanup_pending))

    assert {:error, :device_busy} = record(user)
    assert Enum.any?(FakeLedger.calls(ledger), &match?({:release, _, _}, &1))

    FakeLedger.set_release_mode(ledger, :ok)
    assert %{terminal: true, state: :cancelled} = await(id, & &1.terminal)
    assert {:error, :not_found} = Voice.session_status({user, "fixture-agent"})
    mode(:success)
    assert {:ok, next} = record(user)
    assert %{terminal: true, state: :complete} = await(next, & &1.terminal)
  end

  test "security regression: unknown backend close remains blocked after successful settlement",
       %{ledger: ledger, user: user} do
    mode(:unknown_close)
    assert {:ok, id} = record(user)
    assert_receive {:backend_close, :unknown_close}, 1_000
    assert %{terminal: false} = await(id, &(&1.state == :cleanup_pending))
    assert Enum.any?(FakeLedger.calls(ledger), &match?({:consume, _, _, _}, &1))
    assert {:error, :cleanup_pending} = Voice.cancel_desk_turn(id)
    assert {:error, :device_busy} = record(user)
  end

  test "security regression: exact Session death with transferred custody still converges",
       %{ledger: ledger, user: user} do
    mode(:hold)
    FakeLedger.set_consume_mode(ledger, :error)
    assert {:ok, id} = record(user)
    assert_receive :audio_received, 1_000
    assert_receive :audio_receiving, 1_000
    [{session, _}] = Registry.lookup(Arbor.Voice.Registry, {user, "fixture-agent"})
    Process.exit(session, :kill)
    assert %{terminal: false} = await(id, &(&1.state == :cleanup_pending))
    assert {:error, :device_busy} = record(user)
    FakeLedger.set_consume_mode(ledger, :ok)
    assert %{terminal: true} = await(id, & &1.terminal)
  end

  test "security regression: successful close publishes its receipt before returning a completed turn",
       %{user: user} do
    mode(:success)

    for _ <- 1..3 do
      assert {:ok, id} = record(user)
      assert %{terminal: true, state: :complete, error: nil} = await(id, & &1.terminal)
    end
  end

  test "security regression: receipt writers are role-bound and distinct across operations" do
    first = ClosureReceipt.new(:atomics.new(1, []))
    other = ClosureReceipt.new(:atomics.new(1, []))
    assert {:error, :custody_pending} = ClosureReceipt.session_closing(first)
    assert {:error, :foreign_writer} = ClosureReceipt.backend_closed(first)
    assert {:error, :foreign_writer} = ClosureReceipt.lease_drained(first)
    parent = self()

    spawn(fn ->
      send(parent, {:foreign_receipt, ClosureReceipt.custody_owned(first)})
    end)

    assert_receive {:foreign_receipt, {:error, :foreign_writer}}
    owner = ClosureReceipt.for_owner(first, self())
    lease = ClosureReceipt.for_lease(owner, self())
    assert :ok = ClosureReceipt.custody_owned(first)
    assert :ok = ClosureReceipt.begin_provisional(first)
    assert :ok = ClosureReceipt.backend_closed(owner)
    assert :ok = ClosureReceipt.lease_drained(lease)
    assert {:error, :custody_pending} = ClosureReceipt.session_closing(first)
    refute ClosureReceipt.closed?(first)
    refute ClosureReceipt.closed?(other)

    assert :ok = ClosureReceipt.custody_owned(first)
    assert :ok = ClosureReceipt.session_closing(first)
    assert ClosureReceipt.closed?(first)
    refute ClosureReceipt.closed?(other)
  end

  defp record(user),
    do: Voice.start_desk_turn(user, "fixture-agent", session_token: "fixture", duration_ms: 100)

  defp mode(value) do
    opts = Application.fetch_env!(:arbor_voice, :desk_session_options)

    Application.put_env(
      :arbor_voice,
      :desk_session_options,
      Keyword.put(opts, :backend_opts, parent: self(), mode: value)
    )
  end

  defp await(id, predicate, remaining \\ 400)
  defp await(_, _, 0), do: flunk("Desk did not reach the required cleanup state")

  defp await(id, predicate, remaining) do
    assert {:ok, status} = Voice.desk_turn_status(id)

    if predicate.(status) do
      status
    else
      Process.sleep(10)
      await(id, predicate, remaining - 1)
    end
  end

  defp children(supervisor) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_, pid, _, _} -> if is_pid(pid), do: [pid], else: [] end)
    |> MapSet.new()
  end
end
