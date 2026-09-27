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
    Application.put_env(:arbor_multimedia, :operation_grace_ms, 200)
    Fence.release(Fence.current())

    start_supervised!(
      {DynamicSupervisor, strategy: :one_for_one, name: Arbor.Multimedia.DriverSupervisor}
    )

    owner = start_supervised!({DeviceOwner, []})

    on_exit(fn ->
      Fence.release(Fence.current())

      for key <- [:fake_test, :fake_open, :operation_grace_ms],
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
    task = Task.async(fn -> Multimedia.play_pcm(audio()) end)
    assert_receive {:opened, worker, _}
    monitor = Process.monitor(worker)
    sentinel = "PRIVATE_WORKER_CRASH_PCM"

    logs =
      capture_log(fn ->
        :sys.replace_state(worker, fn state -> Map.delete(state, :owner) end)
        emit(worker, {:pcm, sentinel})
        assert_receive {:DOWN, ^monitor, :process, ^worker, _}
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
    active = :atomics.new(1, [])
    :atomics.put(active, 1, 1)

    permit = %{
      active: active,
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
