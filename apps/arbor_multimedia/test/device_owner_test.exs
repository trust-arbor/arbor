defmodule Arbor.Multimedia.DeviceOwnerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  @moduletag :fast
  alias Arbor.Multimedia
  alias Arbor.Multimedia.{DeviceOwner, Fence}

  setup do
    # This private application is never started with the production driver in tests.
    Application.put_env(:arbor_multimedia, :driver, Arbor.Multimedia.FakeDriver)
    Application.put_env(:arbor_multimedia, :fake_test, self())
    Application.put_env(:arbor_multimedia, :fake_open, :ok)
    Application.put_env(:arbor_multimedia, :fake_finish_supported, true)
    Application.put_env(:arbor_multimedia, :operation_grace_ms, 200)
    Fence.release(Fence.current())

    start_supervised!(
      {DynamicSupervisor, strategy: :one_for_one, name: Arbor.Multimedia.DriverSupervisor}
    )

    owner = start_supervised!({DeviceOwner, []})

    on_exit(fn ->
      Fence.release(Fence.current())

      for key <- [:fake_test, :fake_open, :fake_finish_supported, :operation_grace_ms],
          do: Application.delete_env(:arbor_multimedia, key)
    end)

    %{owner: owner}
  end

  test "capture returns exact bytes and completion timestamp only after positive close" do
    task = Task.async(fn -> Multimedia.capture_pcm(duration_ms: 100, sample_rate: 8_000) end)
    assert_receive {:opened, worker, %{frames: 800}}
    pcm = :binary.copy(<<12, 34>>, 800)
    emit(worker, {:complete, 800})
    emit(worker, {:pcm, pcm})
    assert_receive {:close_attempt, ^worker}
    assert Task.yield(task, 0) == nil
    send(worker, {:close_result, :ok})
    assert {:ok, %{audio: %{pcm: ^pcm}, utterance_ended_at: %DateTime{}}} = Task.await(task)
    assert Fence.current() == nil
  end

  test "public finish returns exact partial audio only after checked close" do
    {task, control, worker} = manual_capture()
    assert :ok = Multimedia.finish_capture(control)
    assert_receive {:finish_attempt, ^worker}
    pcm = :binary.copy(<<12, 34>>, 1_600)
    emit(worker, {:partial, 1_600})
    assert Task.yield(task, 0) == nil
    emit(worker, {:pcm, pcm})
    assert_receive {:close_attempt, ^worker}
    assert Task.yield(task, 0) == nil
    assert Multimedia.device_status() == :busy
    send(worker, {:close_result, :ok})
    assert {:ok, %{audio: %{pcm: ^pcm}}} = Task.await(task)
    assert Multimedia.device_status() == :idle
    assert {:error, :invalid_control} = Multimedia.finish_capture(control)
  end

  test "security regression: finish requires both private control and designated controller" do
    {task, control, worker} = manual_capture()
    assert {:error, :invalid_control} = Multimedia.finish_capture(:crypto.strong_rand_bytes(32))

    assert {:error, :invalid_control} =
             Task.async(fn -> Multimedia.finish_capture(control) end) |> Task.await()

    refute_receive {:finish_attempt, _}, 20
    assert :ok = Multimedia.finish_capture(control)
    assert :ok = Multimedia.finish_capture(control)
    assert_receive {:finish_attempt, ^worker}
    refute_receive {:finish_attempt, _}, 20
    emit(worker, {:partial, 0})
    finish_close(worker)
    assert {:error, :recording_too_short} = Task.await(task)
  end

  test "manual finish cannot upgrade discarded audio after capture caller loss" do
    {task, control, worker} = manual_capture()
    Process.unlink(task.pid)
    Process.exit(task.pid, :kill)
    assert_receive {:close_attempt, ^worker}
    assert {:error, :finish_unavailable} = Multimedia.finish_capture(control)
    emit(worker, {:partial, 800})
    emit(worker, {:pcm, :binary.copy(<<12, 34>>, 800)})
    assert Fence.current() != nil
    send(worker, {:close_result, :ok})
    eventually(fn -> assert Fence.current() == nil end)
  end

  test "controller loss discards recording while caller waits for positive close" do
    parent = self()

    controller =
      spawn(fn ->
        receive do
          {:multimedia_capture_control, _, control} ->
            send(parent, {:control_received, control})

            receive do
              :stop -> :ok
            end
        end
      end)

    task =
      Task.async(fn ->
        Multimedia.capture_pcm([duration_ms: 1_000, sample_rate: 8_000],
          controller: {controller, make_ref()}
        )
      end)

    assert_receive {:opened, worker, _}
    assert_receive {:control_received, _}
    send(controller, :stop)
    assert_receive {:close_attempt, ^worker}
    assert Task.yield(task, 0) == nil
    send(worker, {:close_result, :ok})
    assert {:error, :caller_down} = Task.await(task)
    assert Multimedia.device_status() == :idle
  end

  test "unsupported manual driver is rejected before any device effect while timed capture remains available" do
    Application.put_env(:arbor_multimedia, :fake_finish_supported, false)
    refute Multimedia.manual_capture_finish_supported?()

    assert {:error, :finish_unavailable} =
             Multimedia.capture_pcm([duration_ms: 100, sample_rate: 8_000],
               controller: {self(), make_ref()}
             )

    refute_receive {:opened, _, _}, 20
    task = Task.async(fn -> Multimedia.capture_pcm(duration_ms: 100, sample_rate: 8_000) end)
    assert_receive {:opened, worker, _}
    emit(worker, {:pcm, :binary.copy(<<1, 0>>, 800)})
    emit(worker, {:complete, 800})
    finish_close(worker)
    assert {:ok, _} = Task.await(task)
  end

  test "capture readiness receipt follows the first valid PCM chunk exactly once" do
    {task, control, worker, tag} = readiness_capture()
    refute_receive {:multimedia_capture_started, _, _}, 20

    emit(worker, {:pcm, <<1, 0>>})
    assert_receive {:multimedia_capture_started, ^tag, ^control}
    emit(worker, {:pcm, <<2, 0>>})
    refute_receive {:multimedia_capture_started, _, _}, 20

    emit(worker, {:pcm, :binary.copy(<<3, 0>>, 7_998)})
    emit(worker, {:complete, 8_000})
    finish_close(worker)
    assert {:ok, %{audio: %{pcm: pcm}}} = Task.await(task)
    assert byte_size(pcm) == 16_000
    refute_receive {:multimedia_capture_started, _, _}, 20
  end

  test "completed capture cannot announce readiness from buffered PCM arriving later" do
    {task, _control, worker, _tag} = readiness_capture()
    emit(worker, {:complete, 8_000})
    emit(worker, {:pcm, :binary.copy(<<1, 0>>, 8_000)})
    finish_close(worker)
    assert {:ok, %{audio: %{pcm: pcm}}} = Task.await(task)
    assert byte_size(pcm) == 16_000
    refute_receive {:multimedia_capture_started, _, _}, 20
  end

  test "stale and invalid PCM cannot announce capture readiness", %{owner: owner} do
    {task, _control, worker, _tag} = readiness_capture()
    send(owner, {:driver, make_ref(), Arbor.Multimedia.Redacted.new({:pcm, <<1, 0>>})})
    refute_receive {:multimedia_capture_started, _, _}, 20

    emit(worker, {:pcm, <<1>>})
    finish_close(worker)
    assert {:error, :invalid_media} = Task.await(task)
    refute_receive {:multimedia_capture_started, _, _}, 20
  end

  test "capture caller cancellation suppresses a late readiness receipt" do
    {task, _control, worker, _tag} = readiness_capture()
    Process.unlink(task.pid)
    Process.exit(task.pid, :kill)
    assert_receive {:close_attempt, ^worker}

    emit(worker, {:pcm, <<1, 0>>})
    send(worker, {:close_result, :ok})
    eventually(fn -> assert Multimedia.device_status() == :idle end)
    refute_receive {:multimedia_capture_started, _, _}, 20
  end

  test "expired capture cannot announce readiness from late PCM" do
    Application.put_env(:arbor_multimedia, :operation_grace_ms, 1)
    {task, _control, worker, _tag} = readiness_capture(100)
    assert {:error, :cleanup_pending} = Task.await(task, 1_000)
    assert_receive {:close_attempt, ^worker}

    emit(worker, {:pcm, <<1, 0>>})
    send(worker, {:close_result, :ok})
    eventually(fn -> assert Multimedia.device_status() == :idle end)
    refute_receive {:multimedia_capture_started, _, _}, 20
  end

  defp readiness_capture(duration_ms \\ 1_000) do
    controller = self()
    tag = make_ref()

    task =
      Task.async(fn ->
        Multimedia.capture_pcm([duration_ms: duration_ms, sample_rate: 8_000],
          controller: {controller, tag},
          minimum_duration_ms: 100
        )
      end)

    assert_receive {:multimedia_capture_control, ^tag, control}
    assert_receive {:opened, worker, _}
    {task, control, worker, tag}
  end

  defp manual_capture do
    controller = self()
    tag = make_ref()

    task =
      Task.async(fn ->
        Multimedia.capture_pcm([duration_ms: 1_000, sample_rate: 8_000],
          controller: {controller, tag},
          minimum_duration_ms: 100
        )
      end)

    assert_receive {:multimedia_capture_control, ^tag, control}
    assert_receive {:opened, worker, _}
    {task, control, worker}
  end

  test "playback exact completion cannot succeed on pipeline start or DOWN" do
    task = Task.async(fn -> Multimedia.play_pcm(audio()) end)
    assert_receive {:opened, worker, %{frames: 800, pcm: pcm}}
    assert pcm == audio().pcm
    assert Task.yield(task, 0) == nil
    emit(worker, {:complete, 800})
    finish_close(worker)
    assert :ok = Task.await(task)
  end

  test "stale events and unrelated messages do not complete or corrupt an operation", %{
    owner: owner
  } do
    task = Task.async(fn -> Multimedia.play_pcm(audio()) end)
    assert_receive {:opened, worker, _}
    send(owner, {:driver, make_ref(), Arbor.Multimedia.Redacted.new({:closed, :ok})})
    send(owner, {:unexpected, "PRIVATE_PCM_SENTINEL"})
    emit(worker, {:complete, 800})
    finish_close(worker)
    assert :ok = Task.await(task)
  end

  test "an uncertain close expires boundedly and retains occupancy until confirmed" do
    task = Task.async(fn -> Multimedia.play_pcm(audio()) end)
    assert_receive {:opened, worker, _}
    emit(worker, {:complete, 800})
    assert {:error, :cleanup_pending} = Task.await(task, 1000)
    assert {:error, :device_busy} = Multimedia.devices()
    assert Fence.current() != nil
    finish_close(worker)
    eventually(fn -> assert Fence.current() == nil end)
    assert Process.alive?(Process.whereis(DeviceOwner))
  end

  test "caller loss requests cleanup and never frees the device before close" do
    caller = spawn(fn -> Multimedia.play_pcm(audio()) end)
    assert_receive {:opened, worker, _}
    Process.exit(caller, :kill)
    assert_receive {:close_attempt, ^worker}
    assert {:error, :device_busy} = Multimedia.devices()
    send(worker, {:close_result, :ok})
    eventually(fn -> assert Fence.current() == nil end)
  end

  test "blocking startup cannot defeat operation deadline and late opening remains fenced" do
    Application.put_env(:arbor_multimedia, :fake_open, :wait)
    task = Task.async(fn -> Multimedia.play_pcm(audio()) end)
    assert_receive {:opened, worker, _}
    assert {:error, :cleanup_pending} = Task.await(task, 1000)
    assert {:error, :device_busy} = Multimedia.devices()
    send(worker, :continue_open)
    finish_close(worker)
    eventually(fn -> assert Fence.current() == nil end)
  end

  test "owner death retains the supervised resource worker which continues close", %{owner: owner} do
    caller = spawn(fn -> Multimedia.play_pcm(audio()) end)
    assert_receive {:opened, worker, _}
    Process.exit(owner, :kill)
    assert_receive {:close_attempt, ^worker}
    assert Process.alive?(worker)
    eventually(fn -> assert Process.whereis(DeviceOwner) not in [nil, owner] end)
    assert {:error, :device_busy} = Multimedia.devices()
    send(worker, {:close_result, :ok})
    eventually(fn -> assert Fence.current() == nil end)
    refute Process.alive?(caller)
  end

  test "positive close releases custody even if coordinator dies before consuming its acknowledgement",
       %{owner: owner} do
    caller = spawn(fn -> Multimedia.play_pcm(audio()) end)
    assert_receive {:opened, worker, _}
    monitor = Process.monitor(worker)
    emit(worker, {:complete, 800})
    assert_receive {:close_attempt, ^worker}
    :sys.suspend(owner)
    send(worker, {:close_result, :ok})
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    assert Fence.current() == nil
    Process.exit(owner, :kill)
    eventually(fn -> assert Process.whereis(DeviceOwner) not in [nil, owner] end)
    refute Process.alive?(caller)
  end

  test "stream close notification cannot forge checked resource exhaustion" do
    task = Task.async(fn -> Multimedia.play_pcm(audio()) end)
    assert_receive {:opened, worker, _}
    emit(worker, {:closed, :ok})
    assert_receive {:close_attempt, ^worker}
    assert Fence.current() != nil
    send(worker, {:close_result, :ok})
    assert {:error, :invalid_media} = Task.await(task)
    assert Fence.current() == nil
  end

  test "a media failure with proven close releases the device without reporting success" do
    task = Task.async(fn -> Multimedia.play_pcm(audio()) end)
    assert_receive {:opened, worker, _}
    emit(worker, {:complete, 800})
    assert_receive {:close_attempt, ^worker}
    send(worker, {:close_result, {:error, :playback_failed, :closed}})
    assert {:error, :playback_failed} = Task.await(task)
    assert Fence.current() == nil
  end

  test "worker death cannot serve as close evidence and owner restart preserves the fence", %{
    owner: owner
  } do
    task = Task.async(fn -> Multimedia.play_pcm(audio()) end)
    assert_receive {:opened, worker, _}
    Process.exit(worker, :kill)
    assert {:error, :cleanup_pending} = Task.await(task)
    Process.exit(owner, :kill)
    eventually(fn -> assert Process.whereis(DeviceOwner) not in [nil, owner] end)
    assert {:error, :device_busy} = Multimedia.devices()
    assert Fence.current() != nil
  end

  test "ordinary status and callback failure redact state, current message and reason", %{
    owner: owner
  } do
    sentinel = "PRIVATE_PCM_SENTINEL"
    pcm = :binary.copy(sentinel, 80)
    pcm = if rem(byte_size(pcm), 2) == 0, do: pcm, else: pcm <> <<0>>
    task = Task.async(fn -> Multimedia.play_pcm(%{audio() | pcm: pcm}) end)
    assert_receive {:opened, worker, _}
    refute inspect(:sys.get_status(owner)) =~ sentinel
    refute inspect(:sys.get_status(worker)) =~ sentinel

    for module <- [DeviceOwner, Arbor.Multimedia.DriverWorker] do
      refute inspect(
               module.format_status(%{
                 state: %{pcm: pcm},
                 message: {:pcm, pcm},
                 reason: pcm,
                 log: [pcm]
               })
             ) =~ sentinel
    end

    emit(worker, {:error, sentinel})
    finish_close(worker)
    assert {:error, :driver_failed} = Task.await(task)

    Application.put_env(:arbor_multimedia, :fake_open, :raise)

    logs =
      capture_log(fn ->
        assert {:error, :cleanup_pending} = Multimedia.play_pcm(audio())
      end)

    refute logs =~ sentinel
  end

  test "device enumeration is bounded and closed with no stream opened on errors" do
    task = Task.async(fn -> Multimedia.devices() end)
    assert_receive {:opened, worker, %{kind: :devices}}
    emit(worker, {:devices, []})
    finish_close(worker)
    assert {:ok, []} = Task.await(task)
    Application.put_env(:arbor_multimedia, :fake_open, :unavailable)
    assert {:error, :device_unavailable} = Multimedia.devices()
    assert Fence.current() == nil
  end

  test "requests already expired in the owner mailbox cannot later enter the driver", %{
    owner: owner
  } do
    :sys.suspend(owner)
    task = Task.async(fn -> Multimedia.devices() end)
    assert {:error, :cleanup_pending} = Task.await(task, 1000)
    :sys.resume(owner)
    refute_receive {:opened, _, _}
    assert Fence.current() == nil
  end

  test "effect permit is revoked at deadline while cleanup custody remains" do
    task = Task.async(fn -> Multimedia.play_pcm(audio()) end)
    assert_receive {:opened, worker, _}
    assert_receive {:permit, permit}
    assert Arbor.Multimedia.Driver.admitted?(permit)
    assert {:error, :cleanup_pending} = Task.await(task, 1000)
    refute Arbor.Multimedia.Driver.admitted?(permit)
    assert Fence.current() != nil
    finish_close(worker)
    eventually(fn -> assert Fence.current() == nil end)
  end

  test "security regression: actual owner crash reports redact PCM state, message and reason", %{
    owner: owner
  } do
    sentinel = "PRIVATE_OWNER_CRASH_PCM"
    caller = spawn(fn -> Multimedia.play_pcm(audio()) end)
    assert_receive {:opened, worker, _}
    token = make_ref()
    monitor = Process.monitor(owner)

    logs =
      capture_log(fn ->
        :sys.replace_state(owner, fn state ->
          %{state | operation: %{token: token, pcm: sentinel}}
        end)

        send(owner, {:driver, token, Arbor.Multimedia.Redacted.new({:pcm, sentinel})})
        assert_receive {:DOWN, ^monitor, :process, ^owner, _}
      end)

    refute logs =~ sentinel
    finish_close(worker)
    eventually(fn -> assert Fence.current() == nil end)
    refute Process.alive?(caller)
  end

  test "security regression: actual worker crash current message is redacted" do
    # This proves crash diagnostics, not deadline cleanup. A short operation
    # deadline can put the fake into its blocking close receive before the fault
    # message executes, especially while other isolated BEAMs are compiling.
    Application.put_env(:arbor_multimedia, :operation_grace_ms, 2_000)
    task = Task.async(fn -> Multimedia.play_pcm(audio()) end)
    assert_receive {:opened, worker, _}
    monitor = Process.monitor(worker)
    sentinel = "PRIVATE_WORKER_CRASH_PCM"

    logs =
      capture_log(fn ->
        :sys.replace_state(worker, fn state -> Map.delete(state, :owner) end)
        emit(worker, {:pcm, sentinel})
        assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
      end)

    refute logs =~ sentinel
    assert {:error, :cleanup_pending} = Task.await(task)
    assert Fence.current() != nil
  end

  test "explicitly pending close retries while retaining custody" do
    task = Task.async(fn -> Multimedia.play_pcm(audio()) end)
    assert_receive {:opened, worker, _}
    emit(worker, {:complete, 800})
    assert_receive {:close_attempt, ^worker}
    send(worker, {:close_result, {:error, :cleanup_pending}})
    assert Fence.current() != nil
    assert_receive {:close_attempt, ^worker}, 500
    send(worker, {:close_result, :ok})
    assert :ok = Task.await(task)
    assert Fence.current() == nil
  end

  test "concurrent device admissions use one atomic fence and stale release cannot erase its successor" do
    token = System.unique_integer([:positive, :monotonic])
    assert :ok = Fence.acquire(token)
    parent = self()

    stale =
      for _ <- 1..16 do
        spawn(fn ->
          send(parent, {:ready, self()})

          receive do
            :release -> Fence.release(token)
          end

          send(parent, {:released, self()})
        end)
      end

    for pid <- stale, do: assert_receive({:ready, ^pid})
    Fence.release(token)
    successor = System.unique_integer([:positive, :monotonic])
    assert :ok = Fence.acquire(successor)
    for pid <- stale, do: send(pid, :release)
    for pid <- stale, do: assert_receive({:released, ^pid})
    assert Fence.current() == successor
    assert {:error, :device_busy} = Fence.acquire(System.unique_integer([:positive, :monotonic]))
    Fence.release(successor)

    outcomes =
      for _ <- 1..16 do
        Task.async(fn ->
          candidate = System.unique_integer([:positive, :monotonic])
          {candidate, Fence.acquire(candidate)}
        end)
      end
      |> Enum.map(&Task.await/1)

    assert [{winner, :ok}] = Enum.filter(outcomes, fn {_, result} -> result == :ok end)
    assert Fence.current() == winner
    Fence.release(winner)
  end

  test "missing coordinator remains cleanup_pending while the resource worker holds custody" do
    task = Task.async(fn -> Multimedia.play_pcm(audio()) end)
    assert_receive {:opened, worker, _}
    stop_supervised!(DeviceOwner)
    assert {:error, :cleanup_pending} = Task.await(task)
    assert {:error, :cleanup_pending} = Multimedia.devices()
    assert Fence.current() != nil
    finish_close(worker)
    eventually(fn -> assert Fence.current() == nil end)
    assert {:error, :device_unavailable} = Multimedia.devices()
  end

  test "security regression: copied occupancy identity cannot attest checked close", %{
    owner: owner
  } do
    task = Task.async(fn -> Multimedia.play_pcm(audio()) end)
    assert_receive {:opened, worker, _}
    emit(worker, {:complete, 800})
    assert_receive {:close_attempt, ^worker}
    occupancy = Fence.current()
    assert is_integer(occupancy)
    send(owner, {:driver, occupancy, Arbor.Multimedia.Redacted.new({:closed, :ok})})
    assert Task.yield(task, 50) == nil
    assert Fence.current() == occupancy
    assert Process.alive?(worker)
    send(worker, {:close_result, :ok})
    assert :ok = Task.await(task)
    assert Fence.current() == nil
  end

  test "security regression: a worker PID alone cannot attest media completion" do
    task = Task.async(fn -> Multimedia.play_pcm(audio()) end)
    assert_receive {:opened, worker, _}
    send(worker, {:multimedia_driver, {:complete, 800}})
    refute_receive {:close_attempt, ^worker}, 50
    assert Task.yield(task, 0) == nil
    assert Fence.current() != nil
    emit(worker, {:complete, 800})
    finish_close(worker)
    assert :ok = Task.await(task)
  end

  test "coordinator death before open handoff proves no effects and releases custody" do
    dormant_owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    fence_id = System.unique_integer([:positive, :monotonic])
    token = make_ref()
    revoked = :atomics.new(1, [])

    permit = %{
      revoked: revoked,
      owner: dormant_owner,
      caller: self(),
      deadline: System.monotonic_time(:millisecond) + 1_000
    }

    assert :ok = Fence.acquire(fence_id)

    bootstrap =
      Arbor.Multimedia.Redacted.new(
        {Arbor.Multimedia.FakeDriver, dormant_owner, token, fence_id, permit}
      )

    {:ok, worker} =
      DynamicSupervisor.start_child(
        Arbor.Multimedia.DriverSupervisor,
        {Arbor.Multimedia.DriverWorker, bootstrap}
      )

    monitor = Process.monitor(worker)
    Process.exit(dormant_owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    assert Fence.current() == nil
    refute_receive {:opened, ^worker, _}
    task = Task.async(fn -> Multimedia.devices() end)
    assert_receive {:opened, next, _}
    emit(next, {:devices, []})
    finish_close(next)
    assert {:ok, []} = Task.await(task)
  end

  test "validation rejects unsafe public inputs before the fake or any native entry" do
    assert {:error, :invalid_options} =
             Multimedia.capture_pcm(duration_ms: 100, sample_rate: 8_000, module: SomeModule)

    assert {:error, :invalid_audio} = Multimedia.play_pcm(audio(), device_id: self())
    refute_receive {:opened, _, _}
  end

  defp finish_close(worker) do
    assert_receive {:close_attempt, ^worker}, 500
    send(worker, {:close_result, :ok})
  end

  defp emit(worker, event) do
    permit =
      Process.get({:driver_permit, worker}) ||
        receive do
          {:permit, permit} ->
            Process.put({:driver_permit, worker}, permit)
            permit
        after
          500 -> flunk("missing fake driver permit")
        end

    # Predecessor witness support only: the original candidate had raw driver
    # events. Both branches remain the explicit fake, never native passthrough.
    if function_exported?(Arbor.Multimedia.Driver, :notify, 2) do
      Arbor.Multimedia.Driver.notify(permit, event)
    else
      send(worker, {:multimedia_driver, event})
    end
  end

  defp audio,
    do: %{
      pcm: :binary.copy(<<1, 2>>, 800),
      sample_rate: 8_000,
      channels: 1,
      sample_format: :s16le
    }

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      eventually(fun, attempts - 1)
  end
end
