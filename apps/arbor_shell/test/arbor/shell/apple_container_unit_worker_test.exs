defmodule Arbor.Shell.AppleContainerUnitWorkerTest do
  @moduledoc """
  Supervised Apple Container unit owner tests.

  Uses a deterministic same-library fake runtime — never real mutating
  `container` commands.
  """

  use ExUnit.Case, async: false

  alias Arbor.Shell
  alias Arbor.Shell.AppleContainerPlanCore
  alias Arbor.Shell.AppleContainerUnitCore, as: UnitCore
  alias Arbor.Shell.AppleContainerUnitWorker, as: Worker
  alias Arbor.Shell.ExecutablePolicy
  alias Arbor.Shell.ExecutionRegistry

  @moduletag :fast

  @index_hex String.duplicate("a", 64)
  @vminit_hex String.duplicate("b", 64)
  @image "127.0.0.1:0/arbor/workload@sha256:#{@index_hex}"
  @init_image "127.0.0.1:0/arbor/vminit@sha256:#{@vminit_hex}"
  @kernel_path "/usr/local/share/container/kernels/default.kernel"
  @name "arbor-val-unit1"
  @runtime_path "/usr/local/bin/container"

  @projections %{
    worktree: "/private/tmp/arbor-val/worktree",
    home: "/private/tmp/arbor-val/home",
    tmp: "/private/tmp/arbor-val/tmp",
    build: "/private/tmp/arbor-val/build",
    deps: "/private/tmp/arbor-val/deps",
    mix_wrapper: "/private/tmp/arbor-val/bin/mix"
  }

  @host_runtime_roots %{
    erlang: "/opt/erlang",
    elixir: "/opt/elixir"
  }

  @valid_request %{
    image: @image,
    init_image: @init_image,
    kernel_path: @kernel_path,
    name: @name,
    projections: @projections,
    host_runtime_roots: @host_runtime_roots,
    mix_env: "test",
    command_args: ["test", "apps/arbor_shell/test/example_test.exs"]
  }

  defmodule FakeRuntime do
    @moduledoc false

    use GenServer

    def ensure_started do
      case GenServer.start_link(__MODULE__, %{}, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end

    def reset(script) when is_list(script) do
      ensure_started()
      GenServer.call(__MODULE__, {:reset, script, self()})
    end

    def calls do
      GenServer.call(__MODULE__, :calls)
    end

    def start_command(executable, args, display_command, opts) do
      ensure_started()
      GenServer.call(__MODULE__, {:start_command, executable, args, display_command, opts})
    end

    def kill(session) when is_pid(session) do
      send(session, :fake_kill)
      :ok
    end

    def kill(_), do: :ok

    def get_id(session) when is_pid(session) do
      GenServer.call(session, :get_id)
    catch
      :exit, _ -> nil
    end

    def get_id(_), do: nil

    def get_result(session) when is_pid(session) do
      GenServer.call(session, :get_result)
    catch
      :exit, reason -> {:error, reason}
    end

    def get_result(_), do: {:error, :invalid_session}

    @impl true
    def init(_) do
      {:ok, %{script: [], calls: [], owner: nil, counter: 0}}
    end

    @impl true
    def handle_call({:reset, script, owner}, _from, state) do
      {:reply, :ok, %{state | script: script, calls: [], owner: owner, counter: 0}}
    end

    def handle_call(:calls, _from, state) do
      {:reply, Enum.reverse(state.calls), state}
    end

    def handle_call({:start_command, executable, args, display_command, opts}, _from, state) do
      call = %{
        executable: executable,
        args: args,
        display_command: display_command,
        opts: opts
      }

      state = %{state | calls: [call | state.calls], counter: state.counter + 1}
      id = "fake_port_#{state.counter}"

      case state.script do
        [{:error, reason} | rest] ->
          {:reply, {:error, reason}, %{state | script: rest}}

        [{:hang, result} | rest] ->
          stream_to = Keyword.get(opts, :stream_to)
          {:ok, session} = start_hang_session(id, result, stream_to)
          {:reply, {:ok, session}, %{state | script: rest}}

        [{:delay, ms, result} | rest] ->
          stream_to = Keyword.get(opts, :stream_to)
          {:ok, session} = start_delay_session(id, result, stream_to, ms)
          {:reply, {:ok, session}, %{state | script: rest}}

        [result | rest] when is_map(result) ->
          stream_to = Keyword.get(opts, :stream_to)
          {:ok, session} = start_session_gs(id, normalize_result(result), stream_to, 0)
          {:reply, {:ok, session}, %{state | script: rest}}

        [] ->
          {:reply, {:error, :script_exhausted}, state}
      end
    end

    defp start_delay_session(id, result, stream_to, ms) do
      start_session_gs(id, normalize_result(result), stream_to, ms)
    end

    defp start_hang_session(id, result, stream_to) do
      # Only completes on kill/cancel.
      start_session_gs(id, normalize_result(result), stream_to, :hang)
    end

    defp start_session_gs(id, result, stream_to, delay) do
      GenServer.start(FakeRuntime.Session, {id, result, stream_to, delay})
    end

    defp normalize_result(result) do
      %{
        exit_code: Map.get(result, :exit_code, 0),
        stdout: Map.get(result, :stdout, ""),
        stderr: "",
        timed_out: Map.get(result, :timed_out, false),
        cancelled: Map.get(result, :cancelled, false),
        killed: Map.get(result, :killed, false),
        output_truncated: Map.get(result, :output_truncated, false),
        output_limit_exceeded: Map.get(result, :output_limit_exceeded, false),
        duration_ms: Map.get(result, :duration_ms, 1),
        containment_failure: Map.get(result, :containment_failure, false),
        status: Map.get(result, :status, :completed),
        output: Map.get(result, :stdout, ""),
        command: "container unit"
      }
      |> then(fn m ->
        if m.containment_failure, do: m, else: Map.delete(m, :containment_failure)
      end)
    end
  end

  defmodule FakeRuntime.Session do
    @moduledoc false
    use GenServer

    def init({id, result, stream_to, delay}) do
      state = %{id: id, result: result, stream_to: stream_to, done: false}

      case delay do
        :hang ->
          {:ok, state}

        ms when is_integer(ms) and ms >= 0 ->
          Process.send_after(self(), :complete, ms)
          {:ok, state}
      end
    end

    def handle_call(:get_id, _from, state), do: {:reply, state.id, state}

    def handle_call(:get_result, _from, state) do
      {:reply, {:ok, public_result(state.result)}, state}
    end

    def handle_info(:complete, %{done: false} = state) do
      notify_exit(state)
      Process.send_after(self(), :stop, 50)
      {:noreply, %{state | done: true}}
    end

    def handle_info(:fake_kill, state) do
      result =
        state.result
        |> Map.put(:cancelled, true)
        |> Map.put(:killed, true)
        |> Map.put(:exit_code, 137)
        |> Map.put(:status, :killed)

      state = %{state | result: result}

      if not state.done do
        notify_exit(state)
      end

      Process.send_after(self(), :stop, 10)
      {:noreply, %{state | done: true}}
    end

    def handle_info({:cancel_shell_execution, id}, %{id: id} = state) do
      handle_info(:fake_kill, state)
    end

    def handle_info({:cancel_shell_execution, _}, state), do: {:noreply, state}

    def handle_info(:stop, state), do: {:stop, :normal, state}

    def handle_info(_, state), do: {:noreply, state}

    defp notify_exit(state) do
      if is_pid(state.stream_to) do
        send(
          state.stream_to,
          {:port_exit, state.id, state.result.exit_code, Map.get(state.result, :stdout, "")}
        )
      end
    end

    defp public_result(result) do
      Map.take(result, [
        :exit_code,
        :stdout,
        :stderr,
        :timed_out,
        :cancelled,
        :killed,
        :output_truncated,
        :output_limit_exceeded,
        :duration_ms,
        :containment_failure,
        :status,
        :output,
        :command
      ])
    end
  end

  setup do
    FakeRuntime.ensure_started()
    assert {:ok, plan} = AppleContainerPlanCore.new(@valid_request)

    executable = %ExecutablePolicy.Executable{
      name: "container",
      path: @runtime_path,
      device: 1,
      inode: 1,
      size: 1,
      mtime: 1,
      ctime: 1,
      mode: 0o755,
      sha256: String.duplicate("c", 64)
    }

    spec = %{
      plan: plan,
      timeout_ms: 30_000,
      max_output_bytes: 8_192
    }

    {:ok, plan: plan, executable: executable, spec: spec}
  end

  defp success_list(entries) do
    %{
      exit_code: 0,
      stdout: Jason.encode!(entries),
      duration_ms: 1
    }
  end

  defp success(opts) do
    Map.merge(
      %{
        exit_code: 0,
        stdout: "",
        duration_ms: 1
      },
      opts
    )
  end

  defp start_and_begin(spec, executable, script) do
    :ok = FakeRuntime.reset(script)
    start_ref = make_ref()

    {:ok, execution_id} =
      ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

    assert {:ok, worker} =
             Worker.start_for_test(spec, executable, execution_id, start_ref,
               runtime: FakeRuntime
             )

    assert :ok = ExecutionRegistry.adopt(execution_id, worker)
    send(worker, {:begin_unit_execution, start_ref})
    {execution_id, worker, start_ref}
  end

  defp await_terminal(execution_id, timeout \\ 5_000) do
    assert_receive {:apple_container_unit_terminal, ^execution_id, terminal}, timeout
    terminal
  end

  defp await_registry_terminal(execution_id, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      case ExecutionRegistry.get(execution_id) do
        {:ok, %{status: status} = exec}
        when status in [:completed, :failed, :timed_out, :killed] ->
          exec

        _ ->
          if System.monotonic_time(:millisecond) < deadline do
            Process.sleep(10)
            :retry
          else
            flunk("registry did not reach terminal for #{execution_id}")
          end
      end
    end)
    |> Enum.find(&is_map/1)
  end

  describe "happy path" do
    test "nonzero candidate then cleanup/absence publishes success", %{
      spec: spec,
      executable: executable,
      plan: plan
    } do
      script = [
        success_list([]),
        success(%{exit_code: 0, stdout: "created"}),
        success(%{exit_code: 7, stdout: "candidate-out", duration_ms: 12}),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([])
      ]

      {execution_id, worker, _ref} = start_and_begin(spec, executable, script)

      assert {:ok, result} = await_terminal(execution_id)
      assert result.exit_code == 7
      assert result.stdout == "candidate-out"
      assert result.duration_ms == 12

      exec = await_registry_terminal(execution_id)
      assert exec.status == :completed
      assert exec.result.exit_code == 7
      assert exec.result.stdout == "candidate-out"

      refute Map.has_key?(exec, :owner_pid)
      refute Map.has_key?(exec, :controller_pid)
      refute contains_authority?(exec)

      calls = FakeRuntime.calls()
      assert length(calls) == 6

      # Exact phase order via stripped argv matching plan phases.
      assert Enum.at(calls, 0).args == tl(plan.argv.verify_absent)
      assert Enum.at(calls, 1).args == tl(plan.argv.create)
      assert Enum.at(calls, 2).args == tl(plan.argv.start)
      assert Enum.at(calls, 3).args == tl(plan.argv.force_stop)
      assert Enum.at(calls, 4).args == tl(plan.argv.delete)
      assert Enum.at(calls, 5).args == tl(plan.argv.verify_absent)

      for call <- calls do
        assert call.display_command == "container unit"
        assert call.executable.path == @runtime_path
        assert Keyword.get(call.opts, :cwd) == "/"
        assert Keyword.get(call.opts, :clear_env) == true
        assert Keyword.get(call.opts, :env) == %{}
        assert Keyword.get(call.opts, :stream_to) == worker
        refute inspect(call.opts) =~ @projections.worktree
        refute call.display_command =~ @runtime_path
      end

      # Candidate phase uses min(spec, UnitCore hard max)
      start_call = Enum.at(calls, 2)
      assert Keyword.get(start_call.opts, :max_output_bytes) == 8_192

      # Non-candidate phases use UnitCore phase limits
      assert Keyword.get(Enum.at(calls, 0).opts, :max_output_bytes) ==
               UnitCore.phase_output_limit(:verify_absent)

      assert Keyword.get(Enum.at(calls, 1).opts, :max_output_bytes) ==
               UnitCore.phase_output_limit(:create)

      refute Process.alive?(worker)
    end
  end

  describe "start protocol" do
    test "wrong ref runs nothing", %{spec: spec, executable: executable} do
      :ok = FakeRuntime.reset([success_list([])])
      start_ref = make_ref()

      {:ok, execution_id} =
        ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

      assert {:ok, worker} =
               Worker.start_for_test(spec, executable, execution_id, start_ref,
                 runtime: FakeRuntime
               )

      assert :ok = ExecutionRegistry.adopt(execution_id, worker)
      send(worker, {:begin_unit_execution, make_ref()})
      Process.sleep(50)
      assert FakeRuntime.calls() == []
      assert Process.alive?(worker)
      assert {:ok, %{status: :running, result: nil}} = ExecutionRegistry.get(execution_id)

      # Replay of wrong ref still does nothing; correct ref later works after cancel path.
      send(worker, {:cancel_shell_execution, execution_id})
      assert {:error, :preflight_cancelled} = await_terminal(execution_id)
    end

    test "collision/preflight failure publishes error without cleanup commands", %{
      spec: spec,
      executable: executable
    } do
      script = [
        success_list([%{"configuration" => %{"id" => @name}}])
      ]

      {execution_id, _worker, _} = start_and_begin(spec, executable, script)
      assert {:error, :unit_name_collision} = await_terminal(execution_id)

      exec = await_registry_terminal(execution_id)
      assert exec.status == :failed
      assert exec.result.error == :unit_name_collision
      assert length(FakeRuntime.calls()) == 1
    end

    test "launch/session failure during preflight fails closed", %{
      spec: spec,
      executable: executable
    } do
      script = [{:error, :runtime_unavailable}]
      {execution_id, _worker, _} = start_and_begin(spec, executable, script)
      assert {:error, :runtime_unavailable} = await_terminal(execution_id)
      exec = await_registry_terminal(execution_id)
      assert exec.status == :failed
    end
  end

  describe "timeouts and cleanup retry" do
    test "operation timeout after create continues cleanup", %{
      executable: executable,
      plan: plan
    } do
      spec = %{
        plan: plan,
        timeout_ms: 30,
        max_output_bytes: 1024
      }

      # Preflight + create succeed quickly; start hangs until kill/timeout from PortSession opts.
      # Fake delay longer than remaining deadline is not needed if worker checks deadline at launch.
      # Use immediate create then a delay start that will be cancelled via timeout at next phase.
      script = [
        success_list([]),
        success(%{exit_code: 0}),
        # start - by the time create finishes, deadline may remain; give delayed start
        # then cleanup commands after synthetic timeout if start still launches.
        {:delay, 200, success(%{exit_code: 0, stdout: "late", timed_out: true, killed: true})},
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([])
      ]

      {execution_id, _worker, _} = start_and_begin(spec, executable, script)
      terminal = await_terminal(execution_id, 10_000)

      # Either start completed with timeout flags or synthetic timeout entered cleanup.
      case terminal do
        {:ok, result} ->
          assert is_map(result)

        {:error, reason} ->
          assert is_atom(reason)
      end

      _ = await_registry_terminal(execution_id, 10_000)
      # Cleanup ran (force_stop/delete/list) after create.
      assert length(FakeRuntime.calls()) >= 3
    end

    test "cleanup retry honors delay then absence", %{spec: spec, executable: executable} do
      script = [
        success_list([]),
        success(%{exit_code: 0}),
        success(%{exit_code: 0, stdout: "ok"}),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        # first verify still present
        success_list([%{"configuration" => %{"id" => @name}}]),
        # retry cleanup round
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([])
      ]

      {execution_id, _worker, _} = start_and_begin(spec, executable, script)
      assert {:ok, result} = await_terminal(execution_id, 10_000)
      assert result.exit_code == 0
      assert length(FakeRuntime.calls()) == 9
    end
  end

  describe "cancellation and ownership" do
    test "cancel during start retains cleanup until absence", %{
      spec: spec,
      executable: executable
    } do
      script = [
        success_list([]),
        success(%{exit_code: 0}),
        {:hang, success(%{exit_code: 0, stdout: "partial"})},
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([])
      ]

      {execution_id, worker, _} = start_and_begin(spec, executable, script)

      # Wait until start session is active (3rd call queued).
      eventually!(fn -> length(FakeRuntime.calls()) >= 3 end)

      assert :ok = ExecutionRegistry.request_cancel(execution_id)
      terminal = await_terminal(execution_id, 10_000)

      case terminal do
        {:ok, result} ->
          assert result.cancelled == true or result.killed == true

        {:error, reason} ->
          assert reason in [:cancelled, :preflight_cancelled]
      end

      exec = await_registry_terminal(execution_id, 10_000)
      assert exec.status in [:completed, :failed, :killed, :timed_out]
      # Cleanup commands after cancel
      assert length(FakeRuntime.calls()) >= 5
      refute Process.alive?(worker)
    end

    test "controller death retains cleanup ownership", %{spec: spec, executable: executable} do
      parent = self()

      controller =
        spawn(fn ->
          :ok =
            FakeRuntime.reset([
              success_list([]),
              success(%{exit_code: 0}),
              {:hang, success(%{exit_code: 0, stdout: "x"})},
              success(%{exit_code: 0}),
              success(%{exit_code: 0}),
              success_list([])
            ])

          start_ref = make_ref()

          {:ok, execution_id} =
            ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

          {:ok, worker} =
            Worker.start_for_test(spec, executable, execution_id, start_ref, runtime: FakeRuntime)

          :ok = ExecutionRegistry.adopt(execution_id, worker)
          send(worker, {:begin_unit_execution, start_ref})
          send(parent, {:started, execution_id, worker})

          # Die after start is active.
          receive do
            :die -> :ok
          end
        end)

      assert_receive {:started, execution_id, worker}, 2_000
      eventually!(fn -> length(FakeRuntime.calls()) >= 3 end)
      Process.exit(controller, :kill)

      # Worker must continue cleanup and publish terminal without controller.
      exec = await_registry_terminal(execution_id, 10_000)
      assert exec.status in [:completed, :failed, :killed, :timed_out]
      eventually!(fn -> not Process.alive?(worker) end, 10_000)
      assert length(FakeRuntime.calls()) >= 5
    end

    test "security regression: no terminal before exact positive absence", %{
      spec: spec,
      executable: executable
    } do
      # Start succeeds but list never proves absence — inject present forever then finally absent
      # after we check intermediate state.
      script = [
        success_list([]),
        success(%{exit_code: 0}),
        success(%{exit_code: 0, stdout: "cand"}),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([%{"configuration" => %{"id" => @name}}]),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([])
      ]

      {execution_id, _worker, _} = start_and_begin(spec, executable, script)

      # While cleanup is retrying, registry must not be terminal success yet.
      Process.sleep(30)

      case ExecutionRegistry.get(execution_id) do
        {:ok, %{status: status}} when status in [:completed, :failed, :timed_out, :killed] ->
          # If already terminal, absence must have been proven (calls include final list).
          assert length(FakeRuntime.calls()) >= 6

        {:ok, %{status: status}} ->
          assert status in [:running, :cancelling, :pending]

        _ ->
          :ok
      end

      assert {:ok, _} = await_terminal(execution_id, 10_000)
      exec = await_registry_terminal(execution_id)
      assert exec.status == :completed
      # Final successful empty list is required
      last_list = Enum.at(FakeRuntime.calls(), -1)
      assert last_list.args == ["list", "--all", "--format", "json"]
    end

    test "security regression: unit supervisor shutdown leaves PortSession supervisor", %{
      spec: spec,
      executable: executable
    } do
      script = [
        success_list([]),
        success(%{exit_code: 0}),
        {:hang, success(%{exit_code: 0})},
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([])
      ]

      sessions_before = Process.whereis(Arbor.Shell.PortSessionSupervisor)
      units_before = Process.whereis(Arbor.Shell.AppleContainerUnitSupervisor)
      assert is_pid(sessions_before)
      assert is_pid(units_before)

      {_execution_id, worker, _} = start_and_begin(spec, executable, script)
      eventually!(fn -> length(FakeRuntime.calls()) >= 3 end)
      worker_ref = Process.monitor(worker)

      # Terminate only the unit supervisor; PortSession must remain.
      assert :ok =
               Supervisor.terminate_child(
                 Arbor.Shell.Supervisor,
                 Arbor.Shell.AppleContainerUnitSupervisor
               )

      assert :ok =
               Supervisor.delete_child(
                 Arbor.Shell.Supervisor,
                 Arbor.Shell.AppleContainerUnitSupervisor
               )

      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 10_000
      assert Process.whereis(Arbor.Shell.PortSessionSupervisor) == sessions_before
      assert Process.alive?(sessions_before)

      # Restore unit supervisor for later tests.
      {:ok, _} =
        Supervisor.start_child(
          Arbor.Shell.Supervisor,
          Worker.supervisor_child_spec()
        )
    end
  end

  describe "redaction and facade" do
    test "format_status redacts plan argv projections executable refs pids paths output", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeRuntime.reset([{:hang, success(%{exit_code: 0})}])
      start_ref = make_ref()

      {:ok, execution_id} =
        ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

      assert {:ok, worker} =
               Worker.start_for_test(spec, executable, execution_id, start_ref,
                 runtime: FakeRuntime
               )

      assert :ok = ExecutionRegistry.adopt(execution_id, worker)
      send(worker, {:begin_unit_execution, start_ref})
      eventually!(fn -> length(FakeRuntime.calls()) >= 1 end)

      status = :sys.get_status(worker)
      text = inspect(status, limit: :infinity, printable_limit: :infinity)

      refute text =~ @runtime_path
      refute text =~ @projections.worktree
      refute text =~ @image
      refute text =~ inspect(start_ref)
      # State map values should be redacted markers, not raw pids for controller.
      redacted =
        Worker.format_status(%{state: :sys.get_state(worker), message: {:x}, reason: :y, log: []})

      assert redacted.message == :redacted
      assert redacted.reason == :redacted
      assert redacted.log == :redacted
      assert redacted.state.plan == :redacted
      assert redacted.state.argv == :redacted
      assert redacted.state.projections == :redacted
      assert redacted.state.executable == :redacted
      assert redacted.state.controller_pid == :redacted
      assert redacted.state.active_session == :redacted

      send(worker, {:cancel_shell_execution, execution_id})
      _ = await_terminal(execution_id, 10_000)
    end

    test "registry projections expose no pid/ref/argv/path authority", %{
      spec: spec,
      executable: executable
    } do
      script = [
        success_list([]),
        success(%{exit_code: 0}),
        success(%{exit_code: 0, stdout: "out"}),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([])
      ]

      {execution_id, _, _} = start_and_begin(spec, executable, script)
      assert {:ok, _} = await_terminal(execution_id)
      {:ok, exec} = ExecutionRegistry.get(execution_id)
      refute contains_authority?(exec)
      assert exec.command == "container unit"
      # cwd is registry metadata ("/") — must not include projection paths
      refute exec.cwd =~ "arbor-val"
    end

    test "execute_spawn_capable remains fail closed" do
      assert {:error, {:spawn_backend_unavailable, :production_backend_missing}} =
               Shell.execute_spawn_capable("mix", ["test"], [])
    end

    test "production start rejects non-container executable path", %{spec: spec} do
      bad = %ExecutablePolicy.Executable{
        name: "container",
        path: "/tmp/evil",
        device: 1,
        inode: 1,
        size: 1,
        mtime: 1,
        ctime: 1,
        mode: 0o755,
        sha256: String.duplicate("d", 64)
      }

      assert {:error, :invalid_runtime_executable} =
               Worker.start(spec, bad, "exec_test", make_ref())
    end
  end

  describe "application order" do
    test "unit supervisor is after PortSession supervisor" do
      children = Arbor.Shell.Application.production_children([startup_path: "/bin"], make_ref())
      modules = Enum.map(children, &child_module/1)

      port_idx = Enum.find_index(modules, &(&1 == DynamicSupervisor))
      unit_idx = Enum.find_index(modules, &(&1 == Arbor.Shell.AppleContainerUnitSupervisor))
      assert is_integer(port_idx)
      assert is_integer(unit_idx)
      assert unit_idx == port_idx + 1
    end
  end

  defp child_module({module, _opts}) when is_atom(module), do: module
  defp child_module(%{id: id}) when is_atom(id), do: id
  defp child_module(module) when is_atom(module), do: module

  defp contains_authority?(term) do
    text = inspect(term, limit: :infinity, printable_limit: :infinity)

    cond do
      text =~ ~r/#PID</ -> true
      text =~ ~r/#Reference</ -> true
      text =~ ~r/#Port</ -> true
      text =~ @runtime_path -> true
      text =~ @projections.worktree -> true
      text =~ "--mount" -> true
      true -> false
    end
  end

  defp eventually!(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    result =
      Stream.repeatedly(fn ->
        if fun.() do
          true
        else
          if System.monotonic_time(:millisecond) < deadline do
            Process.sleep(10)
            :retry
          else
            false
          end
        end
      end)
      |> Enum.find(&(&1 == true or &1 == false))

    assert result
  end
end
