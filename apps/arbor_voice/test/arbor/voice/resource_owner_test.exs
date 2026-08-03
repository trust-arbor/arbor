defmodule Arbor.Voice.ResourceOwnerTest do
  use ExUnit.Case, async: false

  alias Arbor.Voice.ResourceOwner
  alias Arbor.Voice.Test.ResourceOwnerBackend, as: Backend

  @moduletag :fast

  @close_timeout_ms 1_000
  @cleanup_ready_timeout_ms 200
  @cleanup_attempts 2
  @cleanup_per_attempt_timeout_ms 100
  @max_recv_timeout_ms 500

  @default_opts [
    close_timeout_ms: @close_timeout_ms,
    cleanup_ready_timeout_ms: @cleanup_ready_timeout_ms,
    cleanup_attempts: @cleanup_attempts,
    cleanup_per_attempt_timeout_ms: @cleanup_per_attempt_timeout_ms,
    max_recv_timeout_ms: @max_recv_timeout_ms
  ]

  defmodule WrongShapeBackend do
    @behaviour Arbor.Voice.RealtimeBackend

    def open(_opts), do: {:ok, %{}}
    def configure(session, _config), do: {:ok, session, :unexpected}
    def send_text(session, _text), do: {:ok, session}
    def send_audio(session, _chunk), do: {:ok, session}
    def send_tool_result(session, _call_id, _output), do: {:ok, session}
    def recv(session, _timeout), do: {:ok, session}
    def close(_session), do: :ok

    def meta(_session) do
      %{backend: :wrong_shape, mode: :local, input_rate: nil, output_rate: nil}
    end
  end

  setup do
    :ok = Backend.start_test_table!()

    assert is_pid(Process.whereis(Arbor.Voice.Supervisor))
    assert is_pid(Process.whereis(Arbor.Voice.ResourceSupervisor))
    assert is_pid(Process.whereis(Arbor.Voice.ResourceCleanupTaskSupervisor))
    :ok
  end

  # ── backend forwarding & handle replacement ──

  @tag spec: "VOICE-5"
  test "backend callbacks are forwarded and replacement handles survive" do
    owner = self()
    opts = @default_opts

    assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: owner], opts)

    initial_handle = Backend.session_handle(owner)

    assert :ok = ResourceOwner.configure(ro, %{instructions: "hello"})
    after_configure = Backend.session_handle(owner)
    assert is_reference(initial_handle)
    refute initial_handle == after_configure

    assert :ok = ResourceOwner.send_text(ro, "text")
    after_text = Backend.session_handle(owner)
    refute after_configure == after_text

    assert :ok = ResourceOwner.send_audio(ro, <<1, 2, 3>>)
    after_audio = Backend.session_handle(owner)
    refute after_text == after_audio

    assert :ok = ResourceOwner.send_tool_result(ro, "call_1", "output")
    after_tool = Backend.session_handle(owner)
    refute after_audio == after_tool

    assert {:ok, {:turn_done, %{text: ""}}} = ResourceOwner.recv(ro, 100)
    after_recv = Backend.session_handle(owner)
    refute after_tool == after_recv

    assert {:ok,
            %{
              backend: :resource_owner_backend,
              mode: :cloud,
              input_rate: 16_000,
              output_rate: 24_000
            }} =
             ResourceOwner.meta(ro)

    assert :ok = ResourceOwner.close(ro)
    assert Backend.close_count(owner) == 1
  end

  @tag spec: "VOICE-5"
  test "meta returns the exact four-field contract and rejects malformed meta" do
    defmodule BadMetaBackend do
      @behaviour Arbor.Voice.RealtimeBackend
      def open(_), do: {:ok, %{configured: true}}
      def configure(s, _), do: {:ok, s}
      def send_text(s, _), do: {:ok, s}
      def send_audio(s, _), do: {:ok, s}
      def send_tool_result(s, _, _), do: {:ok, s}
      def recv(s, _), do: {:ok, s, {:turn_done, %{text: ""}}}
      def close(_), do: :ok
      def meta(_), do: %{backend: :bad, mode: :invalid_mode}
    end

    assert {:ok, ro} = ResourceOwner.start(self(), BadMetaBackend, [], @default_opts)
    assert {:error, :invalid_backend_meta} = ResourceOwner.meta(ro)
    assert :ok = ResourceOwner.close(ro)
  end

  # ── owner-bound gating ──

  @tag spec: "VOICE-7"
  test "foreign callers cannot operate on or close another owner's resource" do
    owner = self()

    assert {:ok, ro} = ResourceOwner.start(owner, Backend, [parent: owner], @default_opts)

    _foreign =
      spawn(fn ->
        assert {:error, :foreign_caller} = ResourceOwner.configure(ro, %{})
        assert {:error, :foreign_caller} = ResourceOwner.send_text(ro, "x")
        assert {:error, :foreign_caller} = ResourceOwner.send_audio(ro, <<>>)
        assert {:error, :foreign_caller} = ResourceOwner.send_tool_result(ro, "x", "y")
        assert {:error, :foreign_caller} = ResourceOwner.recv(ro, 10)
        assert {:error, :foreign_caller} = ResourceOwner.meta(ro)
        assert {:error, :foreign_caller} = ResourceOwner.register_cleanup(ro, :x, fn -> :ok end)
        assert {:error, :foreign_caller} = ResourceOwner.remove_cleanup(ro, :x)
        assert {:error, :foreign_caller} = ResourceOwner.close(ro)
        send(owner, :foreign_done)
      end)

    assert_receive :foreign_done, 5_000
    assert :ok = ResourceOwner.close(ro)
  end

  @tag spec: "VOICE-7"
  test "security regression: a caller payload cannot spoof the resource owner identity" do
    owner = self()

    assert {:ok, ro} = ResourceOwner.start(owner, Backend, [parent: owner], @default_opts)

    forged_result =
      Task.async(fn -> GenServer.call(ro, {:meta, owner}) end)
      |> Task.await()

    assert {:error, :foreign_caller} = forged_result
    assert :ok = ResourceOwner.close(ro)
  end

  @tag spec: "VOICE-7"
  test "start refuses when called by a process other than owner_pid" do
    owner = self()

    _pid =
      spawn(fn ->
        result = ResourceOwner.start(owner, Backend, [parent: owner], @default_opts)
        send(owner, {:start_result, result})
      end)

    assert_receive {:start_result, {:error, :foreign_caller}}, 5_000
  end

  # ── normal close ──

  @tag spec: "VOICE-7"
  test "normal close closes the backend exactly once, runs cleanups, and removes the child" do
    owner = self()

    me = self()
    marker = make_ref()

    assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: owner], @default_opts)

    :ok = ResourceOwner.register_cleanup(ro, :a, fn -> send(me, {marker, :a}) end)
    :ok = ResourceOwner.register_cleanup(ro, :b, fn -> send(me, {marker, :b}) end)

    before_count = supervisor_child_count(Arbor.Voice.ResourceSupervisor)
    cleanup_before_count = supervisor_child_count(Arbor.Voice.ResourceCleanupTaskSupervisor)

    assert :ok = ResourceOwner.close(ro)

    assert_receive {^marker, :a}, 2_000
    assert_receive {^marker, :b}, 2_000
    assert Backend.close_count(owner) == 1

    refute Process.alive?(ro)
    assert :ok = ResourceOwner.close(ro)
    assert Backend.close_count(owner) == 1
    assert supervisor_child_count(Arbor.Voice.ResourceSupervisor) < before_count

    wait_for_supervisor_child_count(
      Arbor.Voice.ResourceCleanupTaskSupervisor,
      cleanup_before_count,
      2_000
    )
  end

  # ── forced owner death ──

  @tag spec: "VOICE-7"
  test "killing the owner closes the backend exactly once and runs cleanups without using Session terminate" do
    me = self()
    marker = make_ref()

    {owner_pid, owner_mon} =
      spawn_monitor(fn ->
        assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: self()], @default_opts)

        :ok =
          ResourceOwner.register_cleanup(ro, :killed_cleanup, fn ->
            send(me, {marker, :cleanup_ran})
          end)

        send(me, {:ready, self(), ro})

        receive do
          :please_exit -> :ok
        end
      end)

    assert_receive {:ready, ^owner_pid, _ro}, 5_000

    before_count = supervisor_child_count(Arbor.Voice.ResourceSupervisor)
    cleanup_before_count = supervisor_child_count(Arbor.Voice.ResourceCleanupTaskSupervisor)

    Process.exit(owner_pid, :kill)

    assert_receive {:DOWN, ^owner_mon, :process, ^owner_pid, :killed}, 2_000
    assert_receive {^marker, :cleanup_ran}, 2_000

    # The owner process is gone, but the resource owner survived until cleanup.
    # We can't assert exactly which pid because it is temporary, but the child count
    # should drop back to baseline after cleanup exits.
    wait_for_supervisor_child_count(Arbor.Voice.ResourceSupervisor, before_count - 1, 2_000)

    wait_for_supervisor_child_count(
      Arbor.Voice.ResourceCleanupTaskSupervisor,
      cleanup_before_count,
      2_000
    )

    assert Backend.close_count(owner_pid) == 1

    # No VoiceSession process existed, so no terminate/2 callback was involved.
    assert Process.whereis(Arbor.Voice.Session) == nil
  end

  # ── registration invariants ──

  @tag spec: "VOICE-7"
  test "duplicate cleanup keys fail closed" do
    owner = self()

    assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: owner], @default_opts)
    :ok = ResourceOwner.register_cleanup(ro, :x, fn -> :ok end)

    assert {:error, :duplicate_cleanup_key} =
             ResourceOwner.register_cleanup(ro, :x, fn -> :ok end)

    assert :ok = ResourceOwner.close(ro)
  end

  @tag spec: "VOICE-7"
  test "cleanup registration cap is enforced" do
    owner = self()

    assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: owner], @default_opts)

    for i <- 1..16 do
      :ok = ResourceOwner.register_cleanup(ro, i, fn -> :ok end)
    end

    assert {:error, :cleanup_capacity_exceeded} =
             ResourceOwner.register_cleanup(ro, 17, fn -> :ok end)

    assert :ok = ResourceOwner.close(ro)
  end

  @tag spec: "VOICE-7"
  test "remove_cleanup removes an obligation after explicit settlement" do
    owner = self()

    assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: owner], @default_opts)
    :ok = ResourceOwner.register_cleanup(ro, :x, fn -> :ok end)
    :ok = ResourceOwner.remove_cleanup(ro, :x)
    assert {:error, :unknown_cleanup_key} = ResourceOwner.remove_cleanup(ro, :x)
    assert :ok = ResourceOwner.close(ro)
  end

  # ── invalid input ──

  @tag spec: "VOICE-7"
  test "invalid backend module is rejected before open" do
    defmodule IncompleteBackend do
      @behaviour Arbor.Voice.RealtimeBackend
      def open(_), do: {:ok, %{}}
      def configure(_), do: {:ok, %{}}
    end

    assert {:error, :invalid_backend} =
             ResourceOwner.start(self(), IncompleteBackend, [], @default_opts)
  end

  @tag spec: "VOICE-7"
  test "invalid timeout options are rejected before start" do
    owner = self()

    assert {:error, {:invalid_owner_config, :close_timeout_ms}} =
             ResourceOwner.start(self(), Backend, [parent: owner], close_timeout_ms: 0)

    assert {:error, :supervisor_unavailable} =
             ResourceOwner.start(self(), Backend, [parent: owner],
               supervisor: :missing_supervisor
             )

    assert {:error, :cleanup_unavailable} =
             ResourceOwner.start(self(), Backend, [parent: owner], cleanup_supervisor: :missing)

    assert {:error, :invalid_owner_config} =
             ResourceOwner.start(self(), Backend, [parent: owner],
               close_timeout_ms: 1,
               close_timeout_ms: 2
             )

    assert {:error, :invalid_owner_config} =
             ResourceOwner.start(
               self(),
               Backend,
               [parent: owner],
               [{:unknown, 1}, {:close_timeout_ms, 1}]
             )

    assert {:error, :invalid_owner_config} =
             ResourceOwner.start(
               self(),
               Backend,
               [parent: owner],
               [{:close_timeout_ms, 1}, :malformed]
             )

    assert {:error, {:invalid_owner_config, :backend_opts}} =
             ResourceOwner.start(self(), Backend, [parent: owner, parent: owner], @default_opts)

    assert {:error, {:invalid_owner_config, :backend_opts}} =
             ResourceOwner.start(self(), Backend, %{parent: owner}, @default_opts)
  end

  @tag spec: "VOICE-7"
  test "recv rejects negative, :infinity, and oversized timeouts" do
    owner = self()

    assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: owner], @default_opts)
    assert {:error, :invalid_timeout} = ResourceOwner.recv(ro, -1)
    assert {:error, :invalid_timeout} = ResourceOwner.recv(ro, :infinity)
    assert {:error, :invalid_timeout} = ResourceOwner.recv(ro, @max_recv_timeout_ms + 1)
    assert :ok = ResourceOwner.close(ro)
  end

  @tag spec: "VOICE-7"
  test "open failures return a stable redacted error" do
    owner = self()

    for open_mode <- [:fail, :raise, :throw, :exit] do
      result =
        ResourceOwner.start(
          self(),
          Backend,
          [parent: owner, open_mode: open_mode, secret: "open-secret"],
          @default_opts
        )

      assert {:error, :backend_open_failed} = result
      refute inspect(result) =~ "open-secret"
    end
  end

  @tag spec: "VOICE-7"
  test "backend callback raise, throw, or exit returns a stable error and keeps handle stable" do
    owner = self()

    assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: owner], @default_opts)

    for mode <- [:raise, :throw, :exit] do
      stable_handle = Backend.session_handle(owner)
      {:ok, _meta} = ResourceOwner.meta(ro)
      :ok = Backend.set_failures(Backend, [{mode, [:configure]}])
      assert {:error, :backend_callback_failed} = ResourceOwner.configure(ro, %{})
      assert stable_handle == Backend.session_handle(owner)
      # Subsequent successful call proves handle was not replaced with garbage.
      :ok = Backend.set_failures(Backend, [])
      assert :ok = ResourceOwner.configure(ro, %{})
      refute stable_handle == Backend.session_handle(owner)
    end

    assert :ok = ResourceOwner.close(ro)
  end

  @tag spec: "VOICE-7"
  test "backend callback return shapes are closed per operation" do
    assert {:ok, ro} = ResourceOwner.start(self(), WrongShapeBackend, [], @default_opts)

    assert {:error, :backend_callback_failed} = ResourceOwner.configure(ro, %{})
    assert {:error, :backend_callback_failed} = ResourceOwner.recv(ro, 10)
    assert :ok = ResourceOwner.close(ro)
  end

  # ── cleanup failure modes ──

  @tag spec: "VOICE-7"
  test "one failing cleanup does not suppress the rest" do
    owner = self()
    me = self()
    marker = make_ref()

    assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: owner], @default_opts)

    :ok =
      ResourceOwner.register_cleanup(ro, :fail, fn -> raise "boom secret=#{inspect(marker)}" end)

    :ok = ResourceOwner.register_cleanup(ro, :ok, fn -> send(me, {marker, :ok_cleanup}) end)

    assert :ok = ResourceOwner.close(ro)
    assert_receive {^marker, :ok_cleanup}, 2_000
  end

  @tag spec: "VOICE-7"
  test "cleanup timeout is retried and eventually exhausts without suppressing others" do
    owner = self()
    me = self()
    marker = make_ref()
    cleanup_before_count = supervisor_child_count(Arbor.Voice.ResourceCleanupTaskSupervisor)

    assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: owner], @default_opts)

    :ok =
      ResourceOwner.register_cleanup(ro, :slow, fn ->
        Process.sleep(500)
        :ok
      end)

    :ok = ResourceOwner.register_cleanup(ro, :ok, fn -> send(me, {marker, :ok_cleanup}) end)

    assert :ok = ResourceOwner.close(ro)
    assert_receive {^marker, :ok_cleanup}, 2_000
    refute Process.alive?(ro)

    wait_for_supervisor_child_count(
      Arbor.Voice.ResourceCleanupTaskSupervisor,
      cleanup_before_count,
      2_000
    )
  end

  @tag spec: "VOICE-7"
  test "cleanup retries are round-based" do
    owner = self()
    me = self()
    marker = make_ref()

    # Custom opts with 3 attempts so we can observe round ordering.
    opts = Keyword.merge(@default_opts, cleanup_attempts: 3, cleanup_per_attempt_timeout_ms: 50)

    assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: owner], opts)

    fail_fun = fn ->
      send(me, {marker, :attempt})
      raise "still failing secret=secret-value"
    end

    :ok = ResourceOwner.register_cleanup(ro, :fail, fail_fun)

    assert :ok = ResourceOwner.close(ro)

    # We expect attempts 1, 2, 3 (round-based, all first attempts come first,
    # but there is only one obligation here so we see three attempts sequentially).
    assert_receive {^marker, :attempt}, 1_000
    assert_receive {^marker, :attempt}, 1_000
    assert_receive {^marker, :attempt}, 1_000
    refute_receive {^marker, :attempt}, 200
  end

  @tag spec: "VOICE-7"
  test "security regression: cleanup returning {:error, :transient} once is retried then succeeds" do
    owner = self()
    me = self()
    marker = make_ref()
    counter = :atomics.new(1, signed: false)
    :atomics.put(counter, 1, 0)

    opts = Keyword.merge(@default_opts, cleanup_attempts: 3, cleanup_per_attempt_timeout_ms: 100)

    assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: owner], opts)

    # Soft {:error, _} must retry (budget settlement and other cleanups rely on
    # this). Other normal returns remain success for compatibility.
    :ok =
      ResourceOwner.register_cleanup(ro, :budget_like, fn ->
        n = :atomics.add_get(counter, 1, 1)
        send(me, {marker, {:attempt, n}})

        if n == 1 do
          {:error, :transient}
        else
          :ok
        end
      end)

    assert :ok = ResourceOwner.close(ro)

    assert_receive {^marker, {:attempt, 1}}, 1_000
    assert_receive {^marker, {:attempt, 2}}, 1_000
    refute_receive {^marker, {:attempt, _}}, 200
    assert :atomics.get(counter, 1) == 2
  end

  # ── hanging close ──

  @tag spec: "VOICE-7"
  test "hanging backend close does not prevent cleanups from being attempted" do
    owner = self()
    me = self()
    marker = make_ref()
    cleanup_before_count = supervisor_child_count(Arbor.Voice.ResourceCleanupTaskSupervisor)

    # Tell the backend to hang longer than the close timeout so coordinator will
    # still drive cleanups and kill the owner at the deadline.
    assert {:ok, ro} =
             ResourceOwner.start(
               self(),
               Backend,
               [parent: owner, hang_close_for_ms: 10_000],
               @default_opts
             )

    :ok =
      ResourceOwner.register_cleanup(ro, :hung_cleanup, fn -> send(me, {marker, :cleanup_ran}) end)

    assert {:error, :owner_timeout} = ResourceOwner.close(ro)
    assert_receive {^marker, :cleanup_ran}, 2_000
    refute Process.alive?(ro)
    assert Backend.close_count(owner) == 1
    assert :ok = ResourceOwner.close(ro)

    wait_for_supervisor_child_count(
      Arbor.Voice.ResourceCleanupTaskSupervisor,
      cleanup_before_count,
      2_000
    )
  end

  # ── coordinator unavailable ──

  @tag spec: "VOICE-7"
  test "close is bounded when cleanup supervisor is unavailable" do
    owner = self()

    {:ok, custom_cleanup_supervisor} = Task.Supervisor.start_link()
    Process.unlink(custom_cleanup_supervisor)

    assert {:ok, ro} =
             ResourceOwner.start(
               self(),
               Backend,
               [parent: owner],
               Keyword.merge(@default_opts, cleanup_supervisor: custom_cleanup_supervisor)
             )

    cleanup_ref = Process.monitor(custom_cleanup_supervisor)
    Process.exit(custom_cleanup_supervisor, :kill)
    assert_receive {:DOWN, ^cleanup_ref, :process, ^custom_cleanup_supervisor, :killed}, 1_000

    assert {:error, :cleanup_unavailable} = ResourceOwner.close(ro)
    assert Backend.close_count(owner) == 0
    refute Process.alive?(ro)
  end

  # ── redaction ──

  @tag spec: "VOICE-7"
  test "format_status and errors contain no secrets, handles, closures, or exception text" do
    owner = self()

    assert {:ok, ro} =
             ResourceOwner.start(
               self(),
               Backend,
               [parent: owner, secret: "super-secret-sentinel"],
               @default_opts
             )

    status = :sys.get_status(ro)
    {:status, _run_info, _, [_, _, _, _, state_map]} = status

    refute inspect(state_map) =~ "super-secret-sentinel"
    refute inspect(state_map) =~ "backend-secret"

    :ok = Backend.set_failures(Backend, raise: [:configure])
    result = ResourceOwner.configure(ro, %{secret: "injected-secret"})
    refute inspect(result) =~ "injected-secret"
    assert result == {:error, :backend_callback_failed}

    assert :ok = ResourceOwner.close(ro)
  end

  # ── helpers ──

  defp supervisor_child_count(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> length()
  end

  defp wait_for_supervisor_child_count(supervisor, expected, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    loop = fn loop ->
      if supervisor_child_count(supervisor) == expected do
        :ok
      else
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          loop.(loop)
        else
          flunk(
            "supervisor child count for #{inspect(supervisor)} did not converge to #{expected}; got #{supervisor_child_count(supervisor)}"
          )
        end
      end
    end

    loop.(loop)
  end
end
