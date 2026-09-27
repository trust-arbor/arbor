defmodule Arbor.Voice.AudioOperationTest do
  use ExUnit.Case, async: false

  alias Arbor.Voice.{BackendWorker, PcmFormat, ResourceOwner, Session}

  alias Arbor.Voice.Test.SessionFakes.{
    FakeCommsSession,
    FakeEngagementStore,
    FakeLedger,
    FakeSignals
  }

  @moduletag :fast
  @moduletag spec: "VOICE-5"
  @pcm "private-pcm-sample!!"
  @owner_opts [
    close_timeout_ms: 1_000,
    cleanup_ready_timeout_ms: 200,
    cleanup_attempts: 2,
    cleanup_per_attempt_timeout_ms: 100
  ]

  defmodule BlockingBackend do
    @behaviour Arbor.Voice.RealtimeBackend
    def egress_route, do: :none
    def open(opts), do: {:ok, %{parent: Keyword.fetch!(opts, :parent), generation: 0}}
    def configure(session, _), do: {:ok, session}
    def send_text(session, _), do: {:ok, session}

    def send_audio(session, _pcm) do
      send(session.parent, {:audio_entered, self(), BackendWorker.operation_deadline()})

      receive do
        :finish_audio ->
          send(session.parent, :audio_callback_finished)
          {:ok, %{session | generation: session.generation + 1}}
      end
    end

    def send_tool_result(session, _, _), do: {:ok, session}
    def recv(_, _), do: {:error, :timeout}

    def close(session) do
      send(session.parent, {:audio_backend_closed, session.generation})
      :ok
    end

    def meta(_),
      do: %{
        backend: :blocking_pcm,
        mode: :local,
        input_format: PcmFormat.mono_s16le(16_000),
        output_format: PcmFormat.mono_s16le(24_000)
      }
  end

  defmodule CorruptConfiguredMetaBackend do
    @behaviour Arbor.Voice.RealtimeBackend
    defdelegate egress_route(), to: BlockingBackend
    defdelegate open(opts), to: BlockingBackend
    def configure(session, _config), do: {:ok, Map.put(session, :invalid_meta, true)}
    defdelegate send_text(session, text), to: BlockingBackend
    defdelegate send_audio(session, pcm), to: BlockingBackend
    defdelegate send_tool_result(session, id, output), to: BlockingBackend
    defdelegate recv(session, timeout), to: BlockingBackend
    defdelegate close(session), to: BlockingBackend
    def meta(%{invalid_meta: true}), do: %{backend: :corrupt, mode: :local}
    def meta(session), do: BlockingBackend.meta(session)
  end

  test "malformed metadata after configure poisons the owner and cannot be reused" do
    {:ok, owner} =
      ResourceOwner.start(self(), CorruptConfiguredMetaBackend, [parent: self()], @owner_opts)

    assert {:error, :invalid_backend_meta} = ResourceOwner.configure(owner, %{})
    assert_receive {:audio_backend_closed, 0}
    assert {:error, :owner_poisoned} = ResourceOwner.send_text(owner, "must not send")

    assert {:error, :invalid_audio_format} =
             ResourceOwner.reserve_audio(owner, format(), byte_size(@pcm), 1_000)

    assert :ok = ResourceOwner.close(owner)
    refute_receive {:audio_backend_closed, _}
  end

  test "reserved PCM handoff is asynchronous, single-use, and closes the latest handle on success" do
    {:ok, owner} = ResourceOwner.start(self(), BlockingBackend, [parent: self()], @owner_opts)
    ref = Process.monitor(owner)
    {:ok, ticket} = ResourceOwner.reserve_audio(owner, format(), byte_size(@pcm), 1_000)
    {:ok, request} = ResourceOwner.handoff_audio(owner, ticket, @pcm)
    assert {:reply, :ok} = :gen_server.receive_response(request, 1_000)
    assert_receive {:audio_entered, worker, {:ok, deadline}}
    assert deadline == ticket.deadline_ms
    refute inspect(:sys.get_state(owner), limit: :infinity) =~ @pcm

    assert {:error, :invalid_audio_operation} =
             ResourceOwner.cancel_audio(owner, %{ticket | id: make_ref()})

    assert {:error, :owner_busy} = ResourceOwner.send_audio(owner, @pcm)
    send(worker, :finish_audio)
    assert_receive {:audio_backend_closed, 1}
    assert_receive {:voice_audio_operation_result, ^ticket, :ok, :ok}
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}
    refute_receive {:voice_audio_operation_result, ^ticket, _, _}
    assert {:error, :no_operation} = BackendWorker.operation_deadline()
  end

  test "reservation binds the actual owner, exact format, generation, and secret token" do
    {:ok, owner} = ResourceOwner.start(self(), BlockingBackend, [parent: self()], @owner_opts)

    assert {:error, :invalid_audio_format} =
             ResourceOwner.reserve_audio(
               owner,
               PcmFormat.mono_s16le(24_000),
               byte_size(@pcm),
               1_000
             )

    assert Task.async(fn ->
             ResourceOwner.reserve_audio(owner, format(), byte_size(@pcm), 1_000)
           end)
           |> Task.await() == {:error, :foreign_caller}

    {:ok, ticket} = ResourceOwner.reserve_audio(owner, format(), byte_size(@pcm), 1_000)

    for altered <- [%{ticket | generation: make_ref()}, %{ticket | token: make_ref()}] do
      {:ok, request} = ResourceOwner.handoff_audio(owner, altered, @pcm)

      assert {:reply, {:error, :invalid_audio_operation}} =
               :gen_server.receive_response(request, 1_000)
    end

    refute_receive {:audio_entered, _, _}
    assert :ok = ResourceOwner.cancel_audio(owner, ticket)
    assert_receive {:voice_audio_operation_result, ^ticket, {:error, :audio_cancelled}, :ok}
  end

  test "explicit configured descriptors must match authoritative metadata before reuse" do
    {:ok, owner} = ResourceOwner.start(self(), BlockingBackend, [parent: self()], @owner_opts)
    mon = Process.monitor(owner)

    assert {:error, :invalid_audio_format} =
             ResourceOwner.configure(owner, %{
               audio: %{
                 input_format: PcmFormat.mono_s16le(48_000),
                 output_format: PcmFormat.mono_s16le(24_000)
               }
             })

    assert_receive {:audio_backend_closed, 0}
    assert_receive {:DOWN, ^mon, :process, ^owner, :normal}
    refute_receive {:audio_entered, _, _}
  end

  test "cancel before handoff retires the reserved owner exactly once" do
    {:ok, owner} = ResourceOwner.start(self(), BlockingBackend, [parent: self()], @owner_opts)
    {:ok, ticket} = ResourceOwner.reserve_audio(owner, format(), byte_size(@pcm), 1_000)
    assert :ok = ResourceOwner.cancel_audio(owner, ticket)
    assert_receive {:voice_audio_operation_result, ^ticket, {:error, :audio_cancelled}, :ok}
    assert_receive {:audio_backend_closed, 0}
    refute_receive {:audio_entered, _, _}
    refute_receive {:voice_audio_operation_result, ^ticket, _, _}
  end

  test "owner deadline kills a blocked callback before a late result can commit" do
    {:ok, owner} = ResourceOwner.start(self(), BlockingBackend, [parent: self()], @owner_opts)
    {:ok, ticket} = ResourceOwner.reserve_audio(owner, format(), byte_size(@pcm), 100)
    {:ok, request} = ResourceOwner.handoff_audio(owner, ticket, @pcm)
    assert {:reply, :ok} = :gen_server.receive_response(request, 1_000)
    assert_receive {:audio_entered, worker, _}
    mon = Process.monitor(worker)
    assert_receive {:DOWN, ^mon, :process, ^worker, :killed}, 1_000
    assert_receive {:voice_audio_operation_result, ^ticket, {:error, :owner_timeout}, :ok}, 1_000
    send(worker, :finish_audio)
    refute_receive :audio_callback_finished
  end

  test "Session owner death retires a blocked PCM worker without waiting for its result" do
    observer = self()

    session_owner =
      spawn(fn ->
        {:ok, owner} =
          ResourceOwner.start(self(), BlockingBackend, [parent: observer], @owner_opts)

        {:ok, ticket} = ResourceOwner.reserve_audio(owner, format(), byte_size(@pcm), 1_000)
        {:ok, request} = ResourceOwner.handoff_audio(owner, ticket, @pcm)
        {:reply, :ok} = :gen_server.receive_response(request, 1_000)
        send(observer, {:reserved_owner, owner})

        receive do
          :stay_alive -> :ok
        end
      end)

    assert_receive {:reserved_owner, owner}
    assert_receive {:audio_entered, worker, _}
    worker_ref = Process.monitor(worker)
    owner_ref = Process.monitor(owner)
    Process.exit(session_owner, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 500
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 500
    send(worker, :finish_audio)
    refute_receive :audio_callback_finished
  end

  test "Session stop remains serviceable while PCM callback is blocked" do
    {key, session, ledger} = start_session()
    caller = Task.async(fn -> Session.send_audio_once(session, format(), @pcm) end)
    assert_receive {:audio_entered, worker, _}
    mon = Process.monitor(worker)
    assert {:ok, _} = Session.status(session)
    refute inspect(:sys.get_state(session), limit: :infinity) =~ @pcm
    assert :ok = Arbor.Voice.stop_session(key)
    assert Task.await(caller) == {:error, :session_stopped}
    assert_receive {:DOWN, ^mon, :process, ^worker, :killed}
    assert Enum.count(FakeLedger.calls(ledger), &match?({:consume, _, _, _}, &1)) == 1
  end

  test "Session caller death fences an in-flight PCM operation and settles once" do
    {_key, session, ledger} = start_session()
    caller = spawn(fn -> Session.send_audio_once(session, format(), @pcm) end)
    assert_receive {:audio_entered, worker, _}
    worker_ref = Process.monitor(worker)
    session_ref = Process.monitor(session)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 1_000
    assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}, 1_000
    assert Enum.count(FakeLedger.calls(ledger), &match?({:consume, _, _, _}, &1)) == 1
  end

  test "Session hard timeout fences blocked audio before reporting exhaustion" do
    {_key, session, ledger} = start_session()
    caller = Task.async(fn -> Session.send_audio_once(session, format(), @pcm) end)
    assert_receive {:audio_entered, worker, _}
    worker_ref = Process.monitor(worker)
    send(session, :hard_timeout)
    assert Task.await(caller) == {:error, :budget_exhausted}
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
    assert Enum.count(FakeLedger.calls(ledger), &match?({:consume, _, _, _}, &1)) == 1
  end

  test "successful Session PCM handoff reports bytes accepted and retires without a text turn" do
    {_key, session, ledger} = start_session()
    caller = Task.async(fn -> Session.send_audio_once(session, format(), @pcm) end)
    assert_receive {:audio_entered, worker, _}
    mon = Process.monitor(session)
    send(worker, :finish_audio)
    assert Task.await(caller) == :ok
    assert_receive {:audio_backend_closed, 1}
    assert_receive {:DOWN, ^mon, :process, ^session, :normal}
    assert Enum.count(FakeLedger.calls(ledger), &match?({:consume, _, _, _}, &1)) == 1
  end

  defp format, do: PcmFormat.mono_s16le(16_000)

  defp start_session do
    {:ok, _} = FakeEngagementStore.start()
    {:ok, ledger} = FakeLedger.start()
    {:ok, _} = FakeSignals.start()
    suffix = System.unique_integer([:positive])

    opts = [
      comms: FakeCommsSession,
      engagement_store: FakeEngagementStore,
      ledger: FakeLedger,
      ledger_opts: [],
      signals: FakeSignals,
      resource_owner: ResourceOwner,
      resource_owner_opts: @owner_opts,
      backend: BlockingBackend,
      backend_opts: [parent: self()],
      session_budget_ms: 60_000,
      daily_budget_ms: 3_600_000,
      wall_clock: fn -> ~U[2026-09-27 12:00:00.000000Z] end,
      monotonic_clock: fn -> 5_000_000 end
    ]

    {:ok, key} = Arbor.Voice.start_session("user_pcm_#{suffix}", "agent_pcm_#{suffix}", opts)
    [{session, _}] = Registry.lookup(Arbor.Voice.Registry, key)
    {key, session, ledger}
  end
end
