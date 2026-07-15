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
  alias Arbor.Shell.AppleContainerUnitDrainCoordinator, as: DrainCoordinator
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
  @max_secondary_notification_bytes 512

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

    # Suite-stable ownership: unlinked start so a per-test ExUnit process exit
    # cannot take down the named fake mid-suite (start_link raced reset -> :noproc).
    def ensure_started do
      case GenServer.start(__MODULE__, %{}, name: __MODULE__) do
        {:ok, pid} ->
          pid

        {:error, {:already_started, pid}} ->
          pid
      end
    end

    def reset(script) when is_list(script) do
      ensure_started()
      GenServer.call(__MODULE__, {:reset, script, self()})
    end

    def calls do
      GenServer.call(__MODULE__, :calls)
    end

    def monotonic_ms do
      ensure_started()
      GenServer.call(__MODULE__, :monotonic_ms)
    end

    def advance_mono(ms) when is_integer(ms) and ms >= 0 do
      ensure_started()
      GenServer.call(__MODULE__, {:advance_mono, ms})
    end

    def release_held do
      ensure_started()
      GenServer.call(__MODULE__, :release_held)
    end

    def held_count do
      ensure_started()
      GenServer.call(__MODULE__, :held_count)
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
      {:ok, %{script: [], calls: [], owner: nil, counter: 0, mono: 1_000_000, held: []}}
    end

    @impl true
    def handle_call({:reset, script, owner}, _from, state) do
      for session <- state.held, is_pid(session), Process.alive?(session) do
        Process.exit(session, :kill)
      end

      {:reply, :ok,
       %{state | script: script, calls: [], owner: owner, counter: 0, mono: 1_000_000, held: []}}
    end

    def handle_call(:calls, _from, state) do
      {:reply, Enum.reverse(state.calls), state}
    end

    def handle_call(:monotonic_ms, _from, state) do
      {:reply, state.mono, state}
    end

    def handle_call({:advance_mono, ms}, _from, state) do
      {:reply, :ok, %{state | mono: state.mono + ms}}
    end

    def handle_call(:held_count, _from, state) do
      alive = Enum.count(state.held, &(is_pid(&1) and Process.alive?(&1)))
      {:reply, alive, state}
    end

    def handle_call(:release_held, _from, state) do
      for session <- Enum.reverse(state.held), is_pid(session), Process.alive?(session) do
        send(session, :release_hold)
      end

      {:reply, :ok, %{state | held: []}}
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

        [{:hold, result} | rest] ->
          stream_to = Keyword.get(opts, :stream_to)
          {:ok, session} = start_hold_session(id, result, stream_to)
          {:reply, {:ok, session}, %{state | script: rest, held: [session | state.held]}}

        [{:advance_after, ms, result} | rest] when is_integer(ms) and ms >= 0 ->
          # Advance during this phase so the *next* phase sees an exhausted
          # operation deadline (create still launched with positive remaining).
          stream_to = Keyword.get(opts, :stream_to)
          state = %{state | mono: state.mono + ms, script: rest}
          {:ok, session} = start_session_gs(id, normalize_result(result), stream_to, 0)
          {:reply, {:ok, session}, state}

        [result | rest] when is_map(result) ->
          stream_to = Keyword.get(opts, :stream_to)
          {:ok, session} = start_session_gs(id, normalize_result(result), stream_to, 0)
          {:reply, {:ok, session}, %{state | script: rest}}

        [] ->
          {:reply, {:error, :script_exhausted}, state}
      end
    end

    @impl true
    def handle_info(_, state), do: {:noreply, state}

    defp start_delay_session(id, result, stream_to, ms) do
      start_session_gs(id, normalize_result(result), stream_to, ms)
    end

    defp start_hang_session(id, result, stream_to) do
      start_session_gs(id, normalize_result(result), stream_to, :hang)
    end

    defp start_hold_session(id, result, stream_to) do
      start_session_gs(id, normalize_result(result), stream_to, :hold)
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
      state = %{id: id, result: result, stream_to: stream_to, done: false, mode: delay}

      case delay do
        :hang ->
          {:ok, state}

        :hold ->
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

    def handle_info(:release_hold, %{mode: :hold, done: false} = state) do
      # Deliver the exact held response — ignore any prior cancel/kill intent.
      notify_exit(state)
      Process.send_after(self(), :stop, 50)
      {:noreply, %{state | done: true}}
    end

    def handle_info(:release_hold, state), do: {:noreply, state}

    def handle_info(:fake_kill, %{mode: :hold} = state) do
      # Held sessions ignore kill/cancel until release — gate owns exact response.
      {:noreply, state}
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
    assert :ok = Worker.begin(worker, start_ref)
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

  defp nonterminal_registry?(execution_id) do
    case ExecutionRegistry.get(execution_id) do
      {:ok, %{status: status}} when status in [:completed, :failed, :timed_out, :killed] ->
        false

      {:ok, %{status: status}} when status in [:running, :cancelling, :pending] ->
        true

      _ ->
        false
    end
  end

  defp restore_unit_supervisor! do
    case Process.whereis(Arbor.Shell.AppleContainerUnitSupervisor) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        _ =
          Supervisor.terminate_child(
            Arbor.Shell.Supervisor,
            Arbor.Shell.AppleContainerUnitSupervisor
          )

        _ =
          Supervisor.delete_child(
            Arbor.Shell.Supervisor,
            Arbor.Shell.AppleContainerUnitSupervisor
          )

        {:ok, _} =
          Supervisor.start_child(
            Arbor.Shell.Supervisor,
            Worker.supervisor_child_spec()
          )

        :ok
    end
  end

  defp restore_drain_coordinator! do
    case Process.whereis(DrainCoordinator) do
      pid when is_pid(pid) ->
        :ok

      _missing ->
        case Supervisor.restart_child(Arbor.Shell.Supervisor, DrainCoordinator) do
          {:ok, _pid} ->
            :ok

          {:ok, _pid, _info} ->
            :ok

          {:error, :running} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, :not_found} ->
            {:ok, _} =
              Supervisor.start_child(Arbor.Shell.Supervisor, DrainCoordinator)

            :ok

          {:error, _reason} ->
            _ = Supervisor.terminate_child(Arbor.Shell.Supervisor, DrainCoordinator)
            _ = Supervisor.delete_child(Arbor.Shell.Supervisor, DrainCoordinator)

            {:ok, _} =
              Supervisor.start_child(Arbor.Shell.Supervisor, DrainCoordinator)

            :ok
        end
    end
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

      start_call = Enum.at(calls, 2)
      assert Keyword.get(start_call.opts, :max_output_bytes) == 8_192

      assert Keyword.get(Enum.at(calls, 0).opts, :max_output_bytes) ==
               UnitCore.phase_output_limit(:verify_absent)

      assert Keyword.get(Enum.at(calls, 1).opts, :max_output_bytes) ==
               UnitCore.phase_output_limit(:create)

      refute Process.alive?(worker)
    end
  end

  describe "start protocol" do
    test "wrong ref runs nothing and begin is GenServer.call", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeRuntime.reset([success_list([])])
      start_ref = make_ref()

      {:ok, execution_id} =
        ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

      assert {:ok, worker} =
               Worker.start_for_test(spec, executable, execution_id, start_ref,
                 runtime: FakeRuntime
               )

      assert :ok = ExecutionRegistry.adopt(execution_id, worker)
      assert {:error, :invalid_begin_ref} = Worker.begin(worker, make_ref())
      assert FakeRuntime.calls() == []
      assert Process.alive?(worker)
      assert {:ok, %{status: :running, result: nil}} = ExecutionRegistry.get(execution_id)

      assert {:error, :invalid_begin_ref} = Worker.begin(worker, make_ref())
      assert FakeRuntime.calls() == []

      send(worker, {:cancel_shell_execution, execution_id})
      assert {:error, :preflight_cancelled} = await_terminal(execution_id)
    end

    test "replayed begin after start returns bounded error", %{
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

      :ok = FakeRuntime.reset(script)
      start_ref = make_ref()

      {:ok, execution_id} =
        ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

      assert {:ok, worker} =
               Worker.start_for_test(spec, executable, execution_id, start_ref,
                 runtime: FakeRuntime
               )

      assert :ok = ExecutionRegistry.adopt(execution_id, worker)
      assert :ok = Worker.begin(worker, start_ref)
      assert {:error, :invalid_begin_ref} = Worker.begin(worker, start_ref)
      assert {:ok, _} = await_terminal(execution_id)
    end

    test "invalid runtime atom fails before worker start", %{
      spec: spec,
      executable: executable
    } do
      start_ref = make_ref()

      {:ok, execution_id} =
        ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

      assert {:error, :invalid_runtime_module} =
               Worker.start_for_test(spec, executable, execution_id, start_ref,
                 runtime: :not_a_runtime_module
               )

      assert {:error, :invalid_runtime_module} =
               Worker.start_for_test(spec, executable, execution_id, start_ref, runtime: String)
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

    test "launch failure during preflight reduces to list_containment_failure", %{
      spec: spec,
      executable: executable
    } do
      script = [{:error, :runtime_unavailable}]
      {execution_id, _worker, _} = start_and_begin(spec, executable, script)
      assert {:error, :list_containment_failure} = await_terminal(execution_id)
      exec = await_registry_terminal(execution_id)
      assert exec.status == :failed
      assert exec.result.error == :list_containment_failure
    end
  end

  describe "timeouts and cleanup retry" do
    test "operation deadline after create yields timed_out candidate and cleanup absence", %{
      executable: executable,
      plan: plan
    } do
      spec = %{
        plan: plan,
        timeout_ms: 100,
        max_output_bytes: 1024
      }

      # Preflight + create succeed; after create the fake clock advances past the
      # operation deadline so start is never launched.
      script = [
        success_list([]),
        {:advance_after, 200, success(%{exit_code: 0})},
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([])
      ]

      {execution_id, _worker, _} = start_and_begin(spec, executable, script)
      assert {:ok, result} = await_terminal(execution_id, 10_000)
      assert result.timed_out == true
      assert result.killed == true
      assert result.exit_code == 137

      exec = await_registry_terminal(execution_id, 10_000)
      assert exec.status == :timed_out
      assert exec.result.timed_out == true

      calls = FakeRuntime.calls()
      # preflight list, create, force_stop, delete, final list — no start
      assert length(calls) == 5
      assert Enum.at(calls, 0).args == tl(plan.argv.verify_absent)
      assert Enum.at(calls, 1).args == tl(plan.argv.create)
      assert Enum.at(calls, 2).args == tl(plan.argv.force_stop)
      assert Enum.at(calls, 3).args == tl(plan.argv.delete)
      assert Enum.at(calls, 4).args == tl(plan.argv.verify_absent)
    end

    test "cleanup retry honors delay then absence", %{spec: spec, executable: executable} do
      script = [
        success_list([]),
        success(%{exit_code: 0}),
        success(%{exit_code: 0, stdout: "ok"}),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([%{"configuration" => %{"id" => @name}}]),
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

      eventually!(fn -> length(FakeRuntime.calls()) >= 3 end)

      assert :ok = ExecutionRegistry.request_cancel(execution_id)
      assert {:ok, result} = await_terminal(execution_id, 10_000)
      assert result.cancelled == true
      assert result.killed == true

      exec = await_registry_terminal(execution_id, 10_000)
      assert exec.status == :killed
      assert exec.result.cancelled == true
      assert length(FakeRuntime.calls()) >= 5
      refute Process.alive?(worker)
    end

    test "security regression: no terminal before exact positive absence", %{
      spec: spec,
      executable: executable
    } do
      script = [
        success_list([]),
        success(%{exit_code: 0}),
        success(%{exit_code: 0, stdout: "cand"}),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([%{"configuration" => %{"id" => @name}}]),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        {:hold, success_list([])}
      ]

      {execution_id, worker, _} = start_and_begin(spec, executable, script)

      eventually!(fn -> FakeRuntime.held_count() >= 1 end, 10_000)

      refute_receive {:apple_container_unit_terminal, ^execution_id, _}, 100
      assert nonterminal_registry?(execution_id)
      assert Process.alive?(worker)

      assert :ok = FakeRuntime.release_held()
      assert {:ok, result} = await_terminal(execution_id, 10_000)
      assert result.stdout == "cand"

      exec = await_registry_terminal(execution_id)
      assert exec.status == :completed
      assert exec.result.stdout == "cand"
      last_list = Enum.at(FakeRuntime.calls(), -1)
      assert last_list.args == ["list", "--all", "--format", "json"]
      refute Process.alive?(worker)
    end

    test "security regression: request_drain waits for exact absence before receipt", %{
      spec: spec,
      executable: executable
    } do
      script = [
        success_list([]),
        success(%{exit_code: 0}),
        {:hang, success(%{exit_code: 0, stdout: "partial"})},
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([%{"configuration" => %{"id" => @name}}]),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        {:hold, success_list([])}
      ]

      {execution_id, worker, _} = start_and_begin(spec, executable, script)
      eventually!(fn -> length(FakeRuntime.calls()) >= 3 end)
      worker_ref = Process.monitor(worker)
      receipt_ref = make_ref()
      parent = self()

      drain_caller =
        spawn(fn ->
          reply = Worker.request_drain(worker, receipt_ref, 15_000)
          send(parent, {:drain_reply, reply})

          receive do
            {:apple_container_unit_drained, _, _, _} = msg ->
              send(parent, {:drain_receipt, msg})
          after
            30_000 ->
              send(parent, {:drain_receipt, :timeout})
          end
        end)

      assert_receive {:drain_reply, :ok}, 5_000

      # A different request (other process or other ref) is rejected while the
      # accepted drain is outstanding. Same caller+ref replay is covered by the
      # public API accepting only one stored receipt pair.
      assert {:error, :drain_already_requested} =
               Task.async(fn -> Worker.request_drain(worker, make_ref()) end)
               |> Task.await(5_000)

      assert {:error, :drain_already_requested} =
               Worker.request_drain(worker, make_ref())

      eventually!(fn -> FakeRuntime.held_count() >= 1 end, 15_000)

      refute_receive {:apple_container_unit_terminal, ^execution_id, _}, 100
      refute_receive {:drain_receipt, _}, 50
      assert Process.alive?(worker)
      assert Process.alive?(drain_caller)
      assert nonterminal_registry?(execution_id)

      assert :ok = FakeRuntime.release_held()

      assert_receive {:drain_receipt,
                      {:apple_container_unit_drained, ^worker, ^execution_id, ^receipt_ref}},
                     15_000

      assert_receive {:apple_container_unit_terminal, ^execution_id, {:ok, result}}, 5_000
      assert result.cancelled == true

      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 10_000
      refute Process.alive?(worker)

      exec = await_registry_terminal(execution_id, 5_000)
      assert exec.status == :killed
      assert exec.result.cancelled == true
    end

    test "security regression: supervised drain coordinator waits for exact absence", %{
      spec: spec,
      executable: executable
    } do
      # Active start cancelled by coordinator drain; one present cleanup round;
      # final successful absence is held so terminate_child must block.
      script = [
        success_list([]),
        success(%{exit_code: 0}),
        {:hang, success(%{exit_code: 0, stdout: "partial"})},
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([%{"configuration" => %{"id" => @name}}]),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        {:hold, success_list([])}
      ]

      {execution_id, worker, _} = start_and_begin(spec, executable, script)
      eventually!(fn -> length(FakeRuntime.calls()) >= 3 end)

      worker_ref = Process.monitor(worker)
      coordinator = Process.whereis(DrainCoordinator)
      unit_sup = Process.whereis(Arbor.Shell.AppleContainerUnitSupervisor)
      port_sup = Process.whereis(Arbor.Shell.PortSessionSupervisor)

      assert is_pid(coordinator)
      assert is_pid(unit_sup)
      assert is_pid(port_sup)
      assert Process.alive?(coordinator)
      assert Process.alive?(unit_sup)
      assert Process.alive?(port_sup)

      task =
        Task.async(fn ->
          Supervisor.terminate_child(Arbor.Shell.Supervisor, DrainCoordinator)
        end)

      try do
        eventually!(fn -> FakeRuntime.held_count() >= 1 end, 30_000)

        # terminate_child remains blocked while final absence is held.
        assert is_nil(Task.yield(task, 300))
        assert Process.alive?(task.pid)
        assert Process.alive?(coordinator)
        assert Process.alive?(worker)
        assert Process.alive?(unit_sup)
        assert Process.alive?(port_sup)
        assert nonterminal_registry?(execution_id)
        refute_receive {:apple_container_unit_terminal, ^execution_id, _}, 100

        # Still no controller terminal and supervisors stay up while held.
        Process.sleep(100)
        assert is_nil(Task.yield(task, 50))
        assert Process.alive?(coordinator)
        assert Process.alive?(worker)
        assert Process.alive?(unit_sup)
        assert Process.alive?(port_sup)
        assert nonterminal_registry?(execution_id)
        refute_receive {:apple_container_unit_terminal, ^execution_id, _}, 50

        assert :ok = FakeRuntime.release_held()

        assert :ok = Task.await(task, 30_000)
        assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 15_000
        refute Process.alive?(worker)
        refute Process.alive?(coordinator)

        exec = await_registry_terminal(execution_id, 10_000)
        assert exec.status == :killed
        assert exec.result.cancelled == true
      after
        # Release held sessions before waiting so a failed assertion cannot
        # poison later tests by leaving the coordinator stuck in terminate/2.
        _ = FakeRuntime.release_held()

        if Process.alive?(task.pid) do
          _ = Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill)
        end

        restore_drain_coordinator!()
      end
    end

    test "security regression: controller death holds absence before terminal", %{
      spec: spec,
      executable: executable
    } do
      parent = self()

      controller =
        spawn(fn ->
          :ok =
            FakeRuntime.reset([
              success_list([]),
              success(%{exit_code: 0}),
              success(%{exit_code: 0, stdout: "x"}),
              success(%{exit_code: 0}),
              success(%{exit_code: 0}),
              success_list([%{"configuration" => %{"id" => @name}}]),
              success(%{exit_code: 0}),
              success(%{exit_code: 0}),
              {:hold, success_list([])}
            ])

          start_ref = make_ref()

          {:ok, execution_id} =
            ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

          {:ok, worker} =
            Worker.start_for_test(spec, executable, execution_id, start_ref, runtime: FakeRuntime)

          :ok = ExecutionRegistry.adopt(execution_id, worker)
          assert :ok = Worker.begin(worker, start_ref)
          send(parent, {:started, execution_id, worker})

          receive do
            :die -> :ok
          end
        end)

      assert_receive {:started, execution_id, worker}, 2_000
      eventually!(fn -> FakeRuntime.held_count() >= 1 end, 15_000)

      Process.exit(controller, :kill)

      Process.sleep(50)
      assert Process.alive?(worker)
      assert nonterminal_registry?(execution_id)

      assert :ok = FakeRuntime.release_held()
      exec = await_registry_terminal(execution_id, 10_000)
      assert exec.status == :completed
      assert exec.result.stdout == "x"
      eventually!(fn -> not Process.alive?(worker) end, 10_000)
      assert length(FakeRuntime.calls()) >= 6
    after
      restore_unit_supervisor!()
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
      assert :ok = Worker.begin(worker, start_ref)
      eventually!(fn -> length(FakeRuntime.calls()) >= 1 end)

      status = :sys.get_status(worker)
      text = inspect(status, limit: :infinity, printable_limit: :infinity)

      refute text =~ @runtime_path
      refute text =~ @projections.worktree
      refute text =~ @image
      refute text =~ inspect(start_ref)

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

    test "secondary notification is bounded; registry keeps full candidate stdout", %{
      executable: executable,
      plan: plan
    } do
      large = String.duplicate("Z", @max_secondary_notification_bytes + 200)

      spec = %{
        plan: plan,
        timeout_ms: 30_000,
        max_output_bytes: 8_192
      }

      script = [
        success_list([]),
        success(%{exit_code: 0}),
        success(%{exit_code: 0, stdout: large}),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([])
      ]

      {execution_id, _, _} = start_and_begin(spec, executable, script)
      assert {:ok, notified} = await_terminal(execution_id)
      assert byte_size(notified.stdout) == @max_secondary_notification_bytes

      exec = await_registry_terminal(execution_id)
      assert exec.status == :completed
      assert exec.result.stdout == large
      assert byte_size(exec.result.stdout) > @max_secondary_notification_bytes
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
      coord_idx = Enum.find_index(modules, &(&1 == DrainCoordinator))
      assert is_integer(port_idx)
      assert is_integer(unit_idx)
      assert is_integer(coord_idx)
      assert unit_idx == port_idx + 1
      assert coord_idx == unit_idx + 1
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
