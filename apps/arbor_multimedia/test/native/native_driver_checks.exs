defmodule Arbor.Multimedia.NativeDriverChecks do
  use ExUnit.Case, async: false
  alias Arbor.Multimedia
  alias Arbor.Multimedia.{DeviceOwner, Fence}
  alias Membrane.PortAudio.SyncExecutor

  setup do
    ArborNativeFake.configure(self())
    Application.put_env(:arbor_multimedia, :driver, Arbor.Multimedia.Driver.Native)
    Application.put_env(:arbor_multimedia, :operation_grace_ms, 2_000)
    Fence.release(Fence.current())
    executor = start_supervised!({SyncExecutor, []})
    start_supervised!({Task.Supervisor, name: Arbor.Multimedia.NativeTaskSupervisor})

    start_supervised!(
      {DynamicSupervisor, name: Arbor.Multimedia.NativeSupervisor, strategy: :one_for_one},
      id: :native_supervisor
    )

    start_supervised!(
      {DynamicSupervisor, name: Arbor.Multimedia.DriverSupervisor, strategy: :one_for_one},
      id: :driver_supervisor
    )

    owner = start_supervised!({DeviceOwner, []})

    on_exit(fn ->
      Fence.release(Fence.current())
      Application.delete_env(:arbor_multimedia, :driver)
      Application.delete_env(:arbor_multimedia, :operation_grace_ms)
    end)

    %{owner: owner, executor: executor}
  end

  test "boot is dormant and permission request is explicit and fixed" do
    assert Multimedia.device_status() == :idle
    refute_receive {:effect, _}, 50

    if :os.type() == {:unix, :darwin} do
      assert Multimedia.microphone_permission() == :authorized
      assert_receive {:effect, :permission_status}
      refute_receive {:effect, :permission_request}, 20
      ArborNativeFake.set(:permission, :not_determined)
      assert Multimedia.request_microphone_permission() == :not_determined
      assert_receive {:effect, :permission_request}
      assert_receive {:effect, :permission_status}
      ArborNativeFake.set(:permission, {:unsafe, "private"})
      assert Multimedia.microphone_permission() == :unavailable
    else
      assert Multimedia.microphone_permission() == :unavailable
      assert Multimedia.request_microphone_permission() == :unavailable
    end
  end

  test "enumeration joins public native barrier and returns only bounded facade fields" do
    assert {:ok, [device]} = Multimedia.devices()

    assert device == %{
             id: 1,
             name: "Fake device",
             max_input_channels: 1,
             max_output_channels: 1,
             default_sample_rate: 16_000
           }

    assert_receive {:effect, :enumerate}
    assert Multimedia.device_status() == :idle
  end

  test "actual Core capture drains exact PCM before checked close and tree exit" do
    assert {:ok, %{audio: audio, utterance_ended_at: %DateTime{}}} =
             Multimedia.capture_pcm(duration_ms: 100, sample_rate: 8_000)

    assert audio.pcm == :binary.copy(<<12, 34>>, 800)
    assert_receive {:effect, {:create, :source, element, resource}}
    assert_receive {:effect, {:start, :source, ^resource}}
    assert_receive {:effect, {:destroy, ^resource}}
    refute Process.alive?(element)
    assert Multimedia.device_status() == :idle
  end

  test "public manual finish joins queued native PCM and checked cleanup through the actual pipeline" do
    assert Multimedia.manual_capture_finish_supported?()
    ArborNativeFake.set(:completion, false)
    ArborNativeFake.set(:finish_frames, 1_600)
    {task, control} = manual_capture()
    assert_receive {:effect, {:create, :source, element, resource}}
    assert_receive {:effect, {:start, :source, ^resource}}
    assert :ok = Multimedia.finish_capture(control)
    assert_receive {:effect, {:finish, ^resource, ^element, stream}}
    assert Task.yield(task, 0) == nil
    refute_receive {:effect, {:destroy, ^resource}}, 20
    pcm = :binary.copy(<<29, 0>>, 1_600)
    send(element, {:portaudio_correlated_payload, stream, pcm})
    assert {:ok, %{audio: %{pcm: ^pcm}, utterance_ended_at: %DateTime{}}} = Task.await(task)
    assert_receive {:effect, {:destroy, ^resource}}
    refute Process.alive?(element)
    assert Multimedia.device_status() == :idle
  end

  test "native empty and short manual captures cannot reach successful media results" do
    ArborNativeFake.set(:completion, false)

    for frames <- [0, 799] do
      ArborNativeFake.set(:finish_frames, frames)
      {task, control} = manual_capture()
      assert_receive {:effect, {:create, :source, element, resource}}
      assert_receive {:effect, {:start, :source, ^resource}}
      assert :ok = Multimedia.finish_capture(control)
      assert_receive {:effect, {:finish, ^resource, ^element, stream}}

      if frames > 0,
        do: send(element, {:portaudio_correlated_payload, stream, :binary.copy(<<1, 0>>, frames)})

      assert {:error, :recording_too_short} = Task.await(task)
      assert_receive {:effect, {:destroy, ^resource}}
      refute Process.alive?(element)
      assert Multimedia.device_status() == :idle
    end
  end

  test "security regression: cancellation during a partial frame join discards audio and closes native custody" do
    ArborNativeFake.set(:completion, false)
    ArborNativeFake.set(:finish_frames, 1_600)
    {task, control} = manual_capture()
    assert_receive {:effect, {:create, :source, element, resource}}
    assert_receive {:effect, {:start, :source, ^resource}}
    assert :ok = Multimedia.finish_capture(control)
    assert_receive {:effect, {:finish, ^resource, ^element, _}}
    Process.unlink(task.pid)
    Process.exit(task.pid, :kill)
    assert_receive {:effect, {:destroy, ^resource}}, 2_000
    eventually(fn -> assert Multimedia.device_status() == :idle end)
    refute Process.alive?(element)
    assert {:error, :invalid_control} = Multimedia.finish_capture(control)
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
    {task, control}
  end

  test "actual Core playback accepts an exact non-buffer tail and closes every process" do
    pcm = :binary.copy(<<12, 34>>, 513)

    assert :ok =
             Multimedia.play_pcm(%{
               pcm: pcm,
               sample_rate: 8_000,
               channels: 1,
               sample_format: :s16le
             })

    assert_receive {:effect, {:create, :sink, element, resource}}
    assert_receive {:effect, {:write, ^pcm, ^resource}}
    assert_receive {:effect, {:start, :sink, ^resource}}
    assert_receive {:effect, {:destroy, ^resource}}
    refute Process.alive?(element)
    assert Multimedia.device_status() == :idle
  end

  test "security regression: deadline while native create blocks rejects late start and recovers only after native close" do
    Application.put_env(:arbor_multimedia, :operation_grace_ms, 100)
    ArborNativeFake.set(:hold, true)
    task = Task.async(fn -> Multimedia.capture_pcm(duration_ms: 100, sample_rate: 8_000) end)
    assert_receive {:effect, {:create, :source, _element, resource}}
    assert_receive {:effect, {:held, executor}}
    assert {:error, :cleanup_pending} = Task.await(task, 1_000)
    assert Multimedia.device_status() == :cleanup_pending
    assert {:error, :device_busy} = Multimedia.devices()
    send(executor, :release_native)
    assert_receive {:effect, {:destroy, ^resource}}
    refute_receive {:effect, {:start, _, _}}, 50
    eventually(fn -> assert Multimedia.device_status() == :idle end)
  end

  test "security regression: DriverWorker death keeps native custody and authenticated recovery joins close" do
    ArborNativeFake.set(:hold, true)
    caller = spawn(fn -> Multimedia.capture_pcm(duration_ms: 100, sample_rate: 8_000) end)
    assert_receive {:effect, {:create, :source, _element, resource}}
    assert_receive {:effect, {:held, executor}}
    [{_, worker, _, _}] = DynamicSupervisor.which_children(Arbor.Multimedia.DriverSupervisor)
    Process.exit(worker, :kill)
    eventually(fn -> assert Multimedia.device_status() == :cleanup_pending end)
    assert Fence.current() != nil
    send(executor, :release_native)
    assert_receive {:effect, {:destroy, ^resource}}
    refute_receive {:effect, {:start, _, _}}, 50
    eventually(fn -> assert Multimedia.device_status() == :idle end)
    refute Process.alive?(caller)
  end

  test "security regression: forged cleanup cannot clear pending custody", %{owner: owner} do
    ArborNativeFake.set(:close, {:error, :cleanup_pending})
    task = Task.async(fn -> Multimedia.capture_pcm(duration_ms: 100, sample_rate: 8_000) end)
    assert_receive {:effect, {:create, :source, _, _}}
    assert {:error, :cleanup_pending} = Task.await(task, 3_000)
    fence = Fence.current()
    op = :sys.get_state(owner).operation
    {session, _secret} = op.custody

    send(
      owner,
      {:driver_custody_closed, op.token, op.worker, fence, session, :crypto.strong_rand_bytes(32)}
    )

    assert Multimedia.device_status() == :cleanup_pending
    assert Fence.current() == fence
    ArborNativeFake.set(:close, :ok)
    eventually(fn -> assert Multimedia.device_status() == :idle end)
  end

  test "security regression: native generation loss never reports idle", %{executor: executor} do
    ArborNativeFake.set(:completion, false)
    task = Task.async(fn -> Multimedia.capture_pcm(duration_ms: 100, sample_rate: 8_000) end)
    assert_receive {:effect, {:start, :source, _}}
    Process.exit(executor, :kill)
    assert {:error, :cleanup_pending} = Task.await(task, 3_000)
    assert Multimedia.device_status() == :cleanup_pending
    assert {:error, :device_busy} = Multimedia.devices()
    assert Fence.current() != nil
  end

  test "security regression: executor queue expiry cannot start new native work", %{
    executor: executor
  } do
    Application.put_env(:arbor_multimedia, :operation_grace_ms, 100)
    :sys.suspend(executor)
    task = Task.async(fn -> Multimedia.capture_pcm(duration_ms: 100, sample_rate: 8_000) end)
    assert {:error, :cleanup_pending} = Task.await(task, 1_000)
    assert Multimedia.device_status() == :cleanup_pending
    :sys.resume(executor)
    eventually(fn -> assert Multimedia.device_status() == :idle end)
    refute_receive {:effect, {:create, _, _, _}}, 50
    refute_receive {:effect, {:start, _, _}}, 50
  end

  test "security regression: positive cleanup barrier cannot upgrade an uncertain media close to success" do
    ArborNativeFake.set(:close, [{:error, :cleanup_pending}, {:error, :stop_failed_closed}])
    assert {:error, :driver_failed} = Multimedia.capture_pcm(duration_ms: 100, sample_rate: 8_000)
    assert Multimedia.device_status() == :idle
  end

  test "stop failure with positive native close is an error and releases custody" do
    ArborNativeFake.set(:close, {:error, :stop_failed_closed})
    assert {:error, :driver_failed} = Multimedia.capture_pcm(duration_ms: 100, sample_rate: 8_000)
    assert Multimedia.device_status() == :idle
  end

  test "playback sends bounded even chunks and an exact tail" do
    pcm = :binary.copy(<<12, 34>>, 2_501)

    assert :ok =
             Multimedia.play_pcm(%{
               pcm: pcm,
               sample_rate: 8_000,
               channels: 1,
               sample_format: :s16le
             })

    assert_receive {:effect, {:write, first, resource}}
    assert_receive {:effect, {:write, last, ^resource}}
    assert byte_size(first) == 4_096
    assert byte_size(last) == 906
    assert first <> last == pcm
    refute_receive {:effect, {:write, _, _}}, 30
  end

  test "security regression: PCM remains absent from ordinary native pipeline status and logs", %{
    owner: owner
  } do
    sentinel = "PRIVATE_PCM_SENTINEL_42"
    pcm = :binary.copy(sentinel, 200)
    ArborNativeFake.set(:hold, true)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        task =
          Task.async(fn ->
            Multimedia.play_pcm(%{
              pcm: pcm,
              sample_rate: 8_000,
              channels: 1,
              sample_format: :s16le
            })
          end)

        assert_receive {:effect, {:create, :sink, _, _}}
        assert_receive {:effect, {:held, executor}}
        [{_, session, _, _}] = DynamicSupervisor.which_children(Arbor.Multimedia.NativeSupervisor)
        state = :sys.get_state(session)
        op = :sys.get_state(owner).operation

        pids =
          [owner, op.worker, session, state.pipeline, state.supervisor] ++
            Enum.flat_map(state.children, fn {name, child} ->
              if name == :device, do: [], else: [child.pid]
            end)

        assert {:messages, []} = Process.info(state.children.device.pid, :messages)

        for pid <- pids do
          refute inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity) =~
                   sentinel
        end

        send(executor, :release_native)
        assert :ok = Task.await(task, 3_000)
      end)

    refute log =~ sentinel
  end

  defp eventually(fun, remaining \\ 150)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, remaining) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(20)
      eventually(fun, remaining - 1)
  end
end
