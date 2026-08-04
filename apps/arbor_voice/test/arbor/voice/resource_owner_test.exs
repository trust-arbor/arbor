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

    def egress_route, do: :none
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

  defmodule ConfigureLatestBackend do
    @behaviour Arbor.Voice.RealtimeBackend

    def egress_route, do: :none
    def open(opts), do: {:ok, %{parent: Keyword.fetch!(opts, :parent), generation: 0}}

    def configure(session, _config) do
      {:error, :distinctive_configure_failure, %{session | generation: 1}}
    end

    def send_text(session, _text), do: {:ok, session}
    def send_audio(session, _chunk), do: {:ok, session}
    def send_tool_result(session, _call_id, _output), do: {:ok, session}
    def recv(_session, _timeout), do: {:error, :timeout}

    def close(session) do
      send(session.parent, {:configure_latest_closed, session.generation})
      :ok
    end

    def meta(_session),
      do: %{backend: :configure_latest, mode: :local, input_rate: nil, output_rate: nil}
  end

  defmodule DelayedCleanupSupervisor do
    use GenServer

    def start_link(test_pid, marker), do: GenServer.start_link(__MODULE__, {test_pid, marker})

    @impl true
    def init({test_pid, marker}), do: {:ok, %{test_pid: test_pid, marker: marker, starts: 0}}

    @impl true
    def handle_call(
          {:start_task, [_owner, _callers, {:erlang, :apply, [fun, []]}], _restart, _shutdown},
          _from,
          state
        )
        when is_function(fun, 0) do
      attempt = state.starts + 1
      test_pid = state.test_pid
      marker = state.marker

      pid =
        spawn(fn ->
          send(test_pid, {marker, :coordinator_spawned, attempt, self()})

          if attempt == 1 do
            receive do
              :run_delayed_coordinator -> fun.()
            end
          else
            fun.()
          end
        end)

      {:reply, {:ok, pid}, %{state | starts: attempt}}
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

    # Nonblocking request seam (Session cancel path); await the asynchronous reply.
    assert {:ok, req} =
             ResourceOwner.send_tool_result_request(ro, "call_async", "async-out")

    assert {:reply, :ok} = :gen_server.wait_response(req, :infinity)
    after_async = Backend.session_handle(owner)
    refute after_tool == after_async

    assert {:ok, {:turn_done, %{text: ""}}} = ResourceOwner.recv(ro, 100)
    after_recv = Backend.session_handle(owner)
    refute after_async == after_recv

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

  @tag :security_regression
  @tag spec: "VOICE-17"
  test "configure failure retains and closes the backend's latest opaque handle" do
    assert {:ok, ro} =
             ResourceOwner.start(self(), ConfigureLatestBackend, [parent: self()], @default_opts)

    assert {:error, :backend_callback_failed} = ResourceOwner.configure(ro, %{})
    assert :ok = ResourceOwner.close(ro)
    assert_receive {:configure_latest_closed, 1}, 1_000
    refute_receive {:configure_latest_closed, 0}, 100
  end

  @tag spec: "VOICE-5"
  test "compiled backend is loaded before callback validation" do
    backend = Arbor.Voice.Test.FakeBackend

    # Test support BEAMs are already compiled but may not be loaded in a fresh,
    # focused test VM. Recreate that first-use production state explicitly.
    _ = :code.purge(backend)
    _ = :code.delete(backend)
    _ = :code.purge(backend)
    assert :code.is_loaded(backend) == false

    assert {:ok, ro} = ResourceOwner.start(self(), backend, [], @default_opts)
    assert match?({:file, _path}, :code.is_loaded(backend))
    assert :ok = ResourceOwner.close(ro)
  end

  @tag spec: "VOICE-5"
  test "meta returns the exact four-field contract and rejects malformed meta" do
    defmodule BadMetaBackend do
      @behaviour Arbor.Voice.RealtimeBackend
      def egress_route, do: :none
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

        assert {:error, :foreign_caller} =
                 ResourceOwner.adopt_provisional_cleanup(ro, :x, fn -> :ok end)

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
  test "normal close serializes multiple cleanup children in one generation and removes the owner" do
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

  @tag spec: "VOICE-17"
  test "planned ResourceSupervisor child shutdown runs the bounded terminate backstop" do
    marker = make_ref()
    test_pid = self()

    assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: self()], @default_opts)
    ro_ref = Process.monitor(ro)

    :ok =
      ResourceOwner.register_cleanup(ro, :planned_shutdown_cleanup, fn ->
        send(test_pid, {marker, :cleanup_ran})
        :ok
      end)

    assert :ok = DynamicSupervisor.terminate_child(Arbor.Voice.ResourceSupervisor, ro)
    assert_receive {^marker, :cleanup_ran}, 500
    assert_receive {:DOWN, ^ro_ref, :process, ^ro, :shutdown}, 500
    assert Backend.close_count(self()) == 1
  end

  @tag spec: "VOICE-17"
  test "killing a coordinator kills its in-flight child and stale completion cannot skip replay" do
    marker = make_ref()
    gate = :atomics.new(1, signed: false)
    attempts = :atomics.new(1, signed: false)

    opts =
      Keyword.merge(@default_opts,
        close_timeout_ms: 750,
        cleanup_attempts: 1,
        cleanup_per_attempt_timeout_ms: 500
      )

    assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: self()], opts)
    ro_ref = Process.monitor(ro)

    on_exit(fn ->
      :atomics.put(gate, 1, 1)
      await_process_exit(ro, 2_000)
    end)

    test_pid = self()

    :ok =
      ResourceOwner.register_cleanup(ro, :guarded_cleanup, fn ->
        attempt = :atomics.add_get(attempts, 1, 1)
        send(test_pid, {marker, :worker_started, attempt, self()})
        send(test_pid, {marker, :pre_ack_effect, attempt})

        wait = fn wait ->
          if :atomics.get(gate, 1) == 1 do
            send(test_pid, {marker, :post_gate_effect, attempt})
            :ok
          else
            receive do
            after
              10 -> wait.(wait)
            end
          end
        end

        wait.(wait)
      end)

    request = :gen_server.send_request(ro, :close)
    assert_receive {^marker, :worker_started, 1, first_worker}, 500
    assert_receive {^marker, :pre_ack_effect, 1}, 500

    %{generation: old_generation, pid: old_coordinator, child: %{pid: ^first_worker}} =
      cleanup_attempt_snapshot(ro)

    coordinator_ref = Process.monitor(old_coordinator)
    worker_ref = Process.monitor(first_worker)
    Process.exit(old_coordinator, :kill)

    assert_receive {:DOWN, ^coordinator_ref, :process, ^old_coordinator, :killed}, 500
    assert_receive {:DOWN, ^worker_ref, :process, ^first_worker, :killed}, 500

    assert_receive {^marker, :worker_started, replay_attempt, replay_worker}, 1_000
    assert replay_attempt >= 2
    refute replay_worker == first_worker
    assert_receive {^marker, :pre_ack_effect, ^replay_attempt}, 500

    send(ro, {:cleanup_result, old_generation, old_coordinator, [:guarded_cleanup]})
    refute_receive {^marker, :post_gate_effect, 1}, 50

    :atomics.put(gate, 1, 1)
    assert_receive {^marker, :post_gate_effect, ^replay_attempt}, 500
    refute_receive {^marker, :post_gate_effect, 1}, 100

    assert {:reply, :ok} = :gen_server.wait_response(request, 1_000)
    assert_receive {:DOWN, ^ro_ref, :process, ^ro, :normal}, 500
  end

  @tag spec: "VOICE-17"
  test "ready timeout retires one exact generation before a replacement can run" do
    marker = make_ref()
    test_pid = self()
    {:ok, cleanup_supervisor} = DelayedCleanupSupervisor.start_link(self(), marker)

    opts =
      Keyword.merge(@default_opts,
        close_timeout_ms: 750,
        cleanup_ready_timeout_ms: 50,
        cleanup_supervisor: cleanup_supervisor
      )

    assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: self()], opts)
    ro_ref = Process.monitor(ro)

    :ok =
      ResourceOwner.register_cleanup(ro, :ready_race_cleanup, fn ->
        send(test_pid, {marker, :cleanup_ran})
        :ok
      end)

    request = :gen_server.send_request(ro, :close)
    assert_receive {^marker, :coordinator_spawned, 1, first_coordinator}, 500

    %{generation: first_generation, pid: ^first_coordinator} = cleanup_attempt_snapshot(ro)
    first_ref = Process.monitor(first_coordinator)
    assert_receive {:DOWN, ^first_ref, :process, ^first_coordinator, :killed}, 500

    assert_receive {^marker, :coordinator_spawned, 2, second_coordinator}, 500
    refute second_coordinator == first_coordinator

    send(ro, {:cleanup_ready, first_generation, first_coordinator})

    assert_receive {^marker, :cleanup_ran}, 500
    refute_receive {^marker, :coordinator_spawned, 3, _pid}, 100
    refute_receive {^marker, :cleanup_ran}, 100
    assert {:reply, :ok} = :gen_server.wait_response(request, 1_000)
    assert_receive {:DOWN, ^ro_ref, :process, ^ro, :normal}, 500
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

  @tag spec: "VOICE-17"
  test "cleanup supervisor death before Session owner death retains cleanup in ResourceOwner" do
    test_pid = self()
    marker = make_ref()
    gate = :atomics.new(1, signed: false)
    {:ok, cleanup_supervisor} = Task.Supervisor.start_link()
    Process.unlink(cleanup_supervisor)

    owner_pid =
      spawn(fn ->
        opts = Keyword.merge(@default_opts, cleanup_supervisor: cleanup_supervisor)
        {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: self()], opts)

        :ok =
          ResourceOwner.register_cleanup(ro, :retained_after_both_deaths, fn ->
            if :atomics.get(gate, 1) == 1 do
              send(test_pid, {marker, :cleanup_ran})
              :ok
            else
              {:error, :blocked}
            end
          end)

        send(test_pid, {marker, :ready, self(), ro})
        Process.sleep(:infinity)
      end)

    assert_receive {^marker, :ready, ^owner_pid, ro}, 1_000
    ro_ref = Process.monitor(ro)

    on_exit(fn ->
      :atomics.put(gate, 1, 1)
      if Process.alive?(owner_pid), do: Process.exit(owner_pid, :kill)
      if Process.alive?(cleanup_supervisor), do: Process.exit(cleanup_supervisor, :kill)
      await_process_exit(ro, 2_000)
    end)

    cleanup_ref = Process.monitor(cleanup_supervisor)
    Process.exit(cleanup_supervisor, :kill)
    assert_receive {:DOWN, ^cleanup_ref, :process, ^cleanup_supervisor, :killed}, 500

    owner_ref = Process.monitor(owner_pid)
    Process.exit(owner_pid, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :killed}, 500
    assert Process.alive?(ro)

    :atomics.put(gate, 1, 1)
    assert_receive {^marker, :cleanup_ran}, 1_000
    assert_receive {:DOWN, ^ro_ref, :process, ^ro, :normal}, 1_000
  end

  @tag spec: "VOICE-17"
  test "Session owner death before cleanup supervisor death kills stale child and replays cleanup" do
    test_pid = self()
    marker = make_ref()
    gate = :atomics.new(1, signed: false)
    attempts = :atomics.new(1, signed: false)
    {:ok, cleanup_supervisor} = Task.Supervisor.start_link()
    Process.unlink(cleanup_supervisor)

    owner_pid =
      spawn(fn ->
        opts =
          Keyword.merge(@default_opts,
            cleanup_supervisor: cleanup_supervisor,
            cleanup_per_attempt_timeout_ms: 500
          )

        {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: self()], opts)

        :ok =
          ResourceOwner.register_cleanup(ro, :retained_after_coordinator_loss, fn ->
            attempt = :atomics.add_get(attempts, 1, 1)
            send(test_pid, {marker, :cleanup_worker, attempt, self()})

            wait = fn wait ->
              if :atomics.get(gate, 1) == 1 do
                send(test_pid, {marker, :cleanup_ran, attempt})
                :ok
              else
                receive do
                after
                  10 -> wait.(wait)
                end
              end
            end

            wait.(wait)
          end)

        send(test_pid, {marker, :ready, self(), ro})
        Process.sleep(:infinity)
      end)

    assert_receive {^marker, :ready, ^owner_pid, ro}, 1_000
    ro_ref = Process.monitor(ro)

    on_exit(fn ->
      :atomics.put(gate, 1, 1)
      if Process.alive?(owner_pid), do: Process.exit(owner_pid, :kill)
      if Process.alive?(cleanup_supervisor), do: Process.exit(cleanup_supervisor, :kill)
      await_process_exit(ro, 2_000)
    end)

    owner_ref = Process.monitor(owner_pid)
    Process.exit(owner_pid, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :killed}, 500
    assert_receive {^marker, :cleanup_worker, 1, stale_worker}, 500
    stale_worker_ref = Process.monitor(stale_worker)

    cleanup_ref = Process.monitor(cleanup_supervisor)
    Process.exit(cleanup_supervisor, :kill)
    assert_receive {:DOWN, ^cleanup_ref, :process, ^cleanup_supervisor, :killed}, 500
    assert_receive {:DOWN, ^stale_worker_ref, :process, ^stale_worker, :killed}, 500
    assert Process.alive?(ro)

    assert_receive {^marker, :cleanup_worker, replay_attempt, _replay_worker}, 1_000
    assert replay_attempt >= 2
    :atomics.put(gate, 1, 1)
    assert_receive {^marker, :cleanup_ran, ^replay_attempt}, 1_000
    refute_receive {^marker, :cleanup_ran, 1}, 100
    assert_receive {:DOWN, ^ro_ref, :process, ^ro, :normal}, 1_000
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

  @tag spec: "VOICE-17"
  test "one provisional cleanup can be adopted beyond the ordinary cleanup cap" do
    marker = make_ref()
    test_pid = self()

    assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: self()], @default_opts)

    for i <- 1..16 do
      :ok = ResourceOwner.register_cleanup(ro, i, fn -> :ok end)
    end

    cleanup = fn -> send(test_pid, {marker, :provisional_cleanup}) end

    assert :ok = ResourceOwner.adopt_provisional_cleanup(ro, :turn, cleanup)
    assert :ok = ResourceOwner.adopt_provisional_cleanup(ro, :turn, cleanup)

    assert {:error, :provisional_cleanup_occupied} =
             ResourceOwner.adopt_provisional_cleanup(ro, :other_turn, fn -> :ok end)

    assert :ok = ResourceOwner.close(ro)
    assert_receive {^marker, :provisional_cleanup}, 1_000
  end

  @tag spec: "VOICE-17"
  test "provisional adoption coalesces an exact ordinary cleanup without duplicate execution" do
    calls = :atomics.new(1, signed: false)

    assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: self()], @default_opts)

    cleanup = fn ->
      _ = :atomics.add_get(calls, 1, 1)
      :ok
    end

    :ok = ResourceOwner.register_cleanup(ro, :turn, cleanup)
    :ok = ResourceOwner.adopt_provisional_cleanup(ro, :turn, cleanup)

    assert {:error, :provisional_cleanup_conflict} =
             ResourceOwner.adopt_provisional_cleanup(ro, :turn, fn -> :ok end)

    owner_state = :sys.get_state(ro)
    assert %{turn: ^cleanup} = Arbor.Voice.Redacted.value(owner_state.cleanups)
    assert map_size(Arbor.Voice.Redacted.value(owner_state.cleanups)) == 1

    assert :ok = ResourceOwner.close(ro)
    assert :atomics.get(calls, 1) == 1
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
      def egress_route, do: :none
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

  @tag spec: "VOICE-5"
  test "recv timeout is preserved while arbitrary backend errors remain redacted" do
    defmodule TimeoutAwareBackend do
      @behaviour Arbor.Voice.RealtimeBackend
      @table :arbor_voice_timeout_aware_backend

      def egress_route, do: :none

      def ensure! do
        case :ets.whereis(@table) do
          :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
          _ -> :ok
        end

        :ok
      end

      def set_mode(mode) do
        ensure!()
        :ets.insert(@table, {:mode, mode})
        :ok
      end

      defp mode do
        ensure!()

        case :ets.lookup(@table, :mode) do
          [{:mode, m}] -> m
          [] -> :event
        end
      end

      def open(_), do: ensure!() && {:ok, %{}}
      def configure(s, _), do: {:ok, s}
      def send_text(s, _), do: {:ok, s}
      def send_audio(s, _), do: {:ok, s}
      def send_tool_result(s, _, _), do: {:ok, s}

      def recv(s, _timeout) do
        case mode() do
          :timeout -> {:error, :timeout}
          :secret_error -> {:error, {:transport_secret, "leaked-credential-xyz"}}
          :event -> {:ok, s, {:turn_done, %{text: "ok"}}}
        end
      end

      def close(_), do: :ok

      def meta(_) do
        %{backend: :timeout_aware, mode: :local, input_rate: nil, output_rate: nil}
      end
    end

    TimeoutAwareBackend.ensure!()
    TimeoutAwareBackend.set_mode(:timeout)

    assert {:ok, ro} = ResourceOwner.start(self(), TimeoutAwareBackend, [], @default_opts)
    assert {:error, :timeout} = ResourceOwner.recv(ro, 50)

    TimeoutAwareBackend.set_mode(:secret_error)
    result = ResourceOwner.recv(ro, 50)
    assert result == {:error, :backend_callback_failed}
    refute inspect(result) =~ "leaked-credential"
    refute inspect(result) =~ "transport_secret"

    TimeoutAwareBackend.set_mode(:event)
    assert {:ok, {:turn_done, %{text: "ok"}}} = ResourceOwner.recv(ro, 50)
    assert :ok = ResourceOwner.close(ro)
  end

  # ── cleanup failure modes ──

  @tag spec: "VOICE-7"
  test "one failing cleanup remains owned without suppressing the rest and later recovers" do
    owner = self()
    me = self()
    marker = make_ref()
    gate = :atomics.new(1, signed: false)

    opts = Keyword.merge(@default_opts, close_timeout_ms: 200)
    assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: owner], opts)
    ro_ref = Process.monitor(ro)

    on_exit(fn ->
      :atomics.put(gate, 1, 1)
      await_process_exit(ro, 2_000)
    end)

    :ok =
      ResourceOwner.register_cleanup(ro, :fail, fn ->
        send(me, {marker, :failing_cleanup_attempt})

        if :atomics.get(gate, 1) == 1 do
          :ok
        else
          raise "boom secret=#{inspect(marker)}"
        end
      end)

    :ok = ResourceOwner.register_cleanup(ro, :ok, fn -> send(me, {marker, :ok_cleanup}) end)

    assert {:error, :owner_timeout} = ResourceOwner.close(ro)
    assert_receive {^marker, :ok_cleanup}, 2_000
    assert_receive {^marker, :failing_cleanup_attempt}, 2_000
    assert Process.alive?(ro)

    :atomics.put(gate, 1, 1)
    assert_receive {:DOWN, ^ro_ref, :process, ^ro, :normal}, 2_000
  end

  @tag spec: "VOICE-7"
  test "cleanup timeout remains pending after the caller deadline and later recovers" do
    owner = self()
    me = self()
    marker = make_ref()
    gate = :atomics.new(1, signed: false)
    cleanup_before_count = supervisor_child_count(Arbor.Voice.ResourceCleanupTaskSupervisor)

    opts =
      Keyword.merge(@default_opts,
        close_timeout_ms: 250,
        cleanup_per_attempt_timeout_ms: 75
      )

    assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: owner], opts)
    ro_ref = Process.monitor(ro)

    on_exit(fn ->
      :atomics.put(gate, 1, 1)
      await_process_exit(ro, 2_000)
    end)

    :ok =
      ResourceOwner.register_cleanup(ro, :slow, fn ->
        send(me, {marker, {:slow_worker, self()}})

        if :atomics.get(gate, 1) == 1 do
          :ok
        else
          Process.sleep(10_000)
        end
      end)

    :ok = ResourceOwner.register_cleanup(ro, :ok, fn -> send(me, {marker, :ok_cleanup}) end)

    assert {:error, :owner_timeout} = ResourceOwner.close(ro)
    assert_receive {^marker, :ok_cleanup}, 2_000
    assert_receive {^marker, {:slow_worker, _worker}}, 2_000
    assert Process.alive?(ro)

    :atomics.put(gate, 1, 1)
    assert_receive {:DOWN, ^ro_ref, :process, ^ro, :normal}, 2_000

    wait_for_supervisor_child_count(
      Arbor.Voice.ResourceCleanupTaskSupervisor,
      cleanup_before_count,
      2_000
    )
  end

  @tag spec: "VOICE-7"
  test "round-based raise exhaustion remains pending and later recovers" do
    owner = self()
    me = self()
    marker = make_ref()
    gate = :atomics.new(1, signed: false)

    # Custom opts with 3 attempts so we can observe round ordering.
    opts =
      Keyword.merge(@default_opts,
        close_timeout_ms: 200,
        cleanup_attempts: 3,
        cleanup_per_attempt_timeout_ms: 50
      )

    assert {:ok, ro} = ResourceOwner.start(self(), Backend, [parent: owner], opts)
    ro_ref = Process.monitor(ro)

    on_exit(fn ->
      :atomics.put(gate, 1, 1)
      await_process_exit(ro, 2_000)
    end)

    fail_fun = fn ->
      send(me, {marker, :attempt})

      if :atomics.get(gate, 1) == 1 do
        :ok
      else
        raise "still failing secret=secret-value"
      end
    end

    :ok = ResourceOwner.register_cleanup(ro, :fail, fail_fun)

    assert {:error, :owner_timeout} = ResourceOwner.close(ro)
    assert Process.alive?(ro)

    # At least one complete configured batch ran; later generations may already
    # have begun because retained cleanup retries continue after exhaustion.
    assert_receive {^marker, :attempt}, 1_000
    assert_receive {^marker, :attempt}, 1_000
    assert_receive {^marker, :attempt}, 1_000

    :atomics.put(gate, 1, 1)
    assert_receive {:DOWN, ^ro_ref, :process, ^ro, :normal}, 2_000
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
  test "hanging backend close kills only its worker while owner retains cleanup and later recovers" do
    owner = self()
    me = self()
    marker = make_ref()
    cleanup_before_count = supervisor_child_count(Arbor.Voice.ResourceCleanupTaskSupervisor)
    opts = Keyword.merge(@default_opts, close_timeout_ms: 300)

    assert {:ok, ro} =
             ResourceOwner.start(
               self(),
               Backend,
               [parent: owner, hang_close_for_ms: 10_000],
               opts
             )

    ro_ref = Process.monitor(ro)

    on_exit(fn ->
      await_process_exit(ro, 2_000)
    end)

    :ok =
      ResourceOwner.register_cleanup(ro, :hung_cleanup, fn -> send(me, {marker, :cleanup_ran}) end)

    request = :gen_server.send_request(ro, :close)

    assert :ok = wait_until(fn -> backend_close_attempt_pid(ro) != nil end, 200)
    close_worker = backend_close_attempt_pid(ro)
    close_worker_ref = Process.monitor(close_worker)

    assert {:reply, {:error, :owner_timeout}} = :gen_server.wait_response(request, 1_000)
    assert_receive {^marker, :cleanup_ran}, 2_000
    assert_receive {:DOWN, ^close_worker_ref, :process, ^close_worker, :killed}, 1_000
    assert Process.alive?(ro)
    assert Backend.close_count(owner) == 1

    started_ms = System.monotonic_time(:millisecond)
    assert {:error, :owner_timeout} = ResourceOwner.close(ro)
    assert System.monotonic_time(:millisecond) - started_ms < 100

    assert :ok = Backend.set_hang_close(owner, nil)
    assert_receive {:DOWN, ^ro_ref, :process, ^ro, :normal}, 2_000
    assert Backend.close_count(owner) >= 2

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
    marker = make_ref()

    {:ok, custom_cleanup_supervisor} = Task.Supervisor.start_link()
    Process.unlink(custom_cleanup_supervisor)

    assert {:ok, ro} =
             ResourceOwner.start(
               self(),
               Backend,
               [parent: owner],
               Keyword.merge(@default_opts, cleanup_supervisor: custom_cleanup_supervisor)
             )

    :ok =
      ResourceOwner.register_cleanup(ro, :supervisor_independent, fn ->
        send(owner, {marker, :cleanup_ran})
      end)

    cleanup_ref = Process.monitor(custom_cleanup_supervisor)
    Process.exit(custom_cleanup_supervisor, :kill)
    assert_receive {:DOWN, ^cleanup_ref, :process, ^custom_cleanup_supervisor, :killed}, 1_000

    assert :ok = ResourceOwner.close(ro)
    assert_receive {^marker, :cleanup_ran}, 1_000
    assert Backend.close_count(owner) == 1
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

  defp await_process_exit(pid, timeout_ms) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} ->
          :ok
      after
        timeout_ms ->
          Process.demonitor(ref, [:flush])
          _ = DynamicSupervisor.terminate_child(Arbor.Voice.ResourceSupervisor, pid)
          :ok
      end
    else
      :ok
    end
  end

  defp backend_close_attempt_pid(owner) do
    case :sys.get_state(owner) do
      %{backend_close_attempt: %{pid: pid}} when is_pid(pid) -> pid
      _state -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp cleanup_attempt_snapshot(owner) do
    %{cleanup_attempt: attempt} = :sys.get_state(owner)
    attempt
  end

  defp wait_until(fun, timeout_ms) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    loop = fn loop ->
      if fun.() do
        :ok
      else
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(5)
          loop.(loop)
        else
          {:error, :timeout}
        end
      end
    end

    loop.(loop)
  end

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
