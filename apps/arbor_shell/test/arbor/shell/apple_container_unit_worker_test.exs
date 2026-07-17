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
  # Journal-valid unit name: arbor-v1- + 32 lowercase hex.
  @name "arbor-v1-" <> String.duplicate("a", 32)
  @journal_token String.duplicate("1", 64)
  @runtime_path "/usr/local/bin/container"
  @max_secondary_notification_bytes 512

  @projections %{
    worktree: "/private/tmp/arbor-val/worktree",
    home: "/private/tmp/arbor-val/home",
    build: "/private/tmp/arbor-val/build",
    deps: "/private/tmp/arbor-val/deps",
    mix_wrapper_dir: "/private/tmp/arbor-val/bin"
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
    command_args: ["test", "apps/arbor_shell/test/example_test.exs"],
    resource_profile: :standard
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

    def set_mono_step(ms) when is_integer(ms) and ms >= 0 do
      ensure_started()
      GenServer.call(__MODULE__, {:set_mono_step, ms})
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
      {:ok,
       %{
         script: [],
         calls: [],
         owner: nil,
         counter: 0,
         mono: 1_000_000,
         mono_step: 0,
         held: []
       }}
    end

    @impl true
    def handle_call({:reset, script, owner}, _from, state) do
      for session <- state.held, is_pid(session), Process.alive?(session) do
        Process.exit(session, :kill)
      end

      {:reply, :ok,
       %{
         state
         | script: script,
           calls: [],
           owner: owner,
           counter: 0,
           mono: 1_000_000,
           mono_step: 0,
           held: []
       }}
    end

    def handle_call(:calls, _from, state) do
      {:reply, Enum.reverse(state.calls), state}
    end

    def handle_call(:monotonic_ms, _from, state) do
      {:reply, state.mono, %{state | mono: state.mono + state.mono_step}}
    end

    def handle_call({:advance_mono, ms}, _from, state) do
      {:reply, :ok, %{state | mono: state.mono + ms}}
    end

    def handle_call({:set_mono_step, ms}, _from, state) do
      {:reply, :ok, %{state | mono_step: ms}}
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

  defmodule FakeJournal do
    @moduledoc false

    use GenServer

    def ensure_started do
      case GenServer.start(__MODULE__, %{}, name: __MODULE__) do
        {:ok, pid} ->
          pid

        {:error, {:already_started, pid}} ->
          pid
      end
    end

    def reset(opts \\ []) when is_list(opts) do
      ensure_started()
      GenServer.call(__MODULE__, {:reset, opts})
    end

    def complete_calls do
      ensure_started()
      GenServer.call(__MODULE__, :complete_calls)
    end

    def block do
      ensure_started()
      GenServer.call(__MODULE__, :block)
    end

    def release do
      ensure_started()
      GenServer.call(__MODULE__, :release)
    end

    def complete(unit_name, token, server \\ __MODULE__) do
      case GenServer.call(server, {:complete, unit_name, token}, 30_000) do
        {:do_raise, exception} -> raise exception
        {:do_exit, reason} -> exit(reason)
        {:do_throw, reason} -> throw(reason)
        other -> other
      end
    end

    @impl true
    def init(_) do
      {:ok,
       %{
         results: [],
         calls: [],
         blocked: false,
         expected_unit: nil,
         expected_token: nil
       }}
    end

    @impl true
    def handle_call({:reset, opts}, _from, _state) do
      {:reply, :ok,
       %{
         results: Keyword.get(opts, :results, []),
         calls: [],
         blocked: Keyword.get(opts, :blocked, false),
         expected_unit: Keyword.get(opts, :expected_unit),
         expected_token: Keyword.get(opts, :expected_token)
       }}
    end

    def handle_call(:complete_calls, _from, state) do
      {:reply, Enum.reverse(state.calls), state}
    end

    def handle_call(:block, _from, state) do
      {:reply, :ok, %{state | blocked: true}}
    end

    def handle_call(:release, _from, state) do
      {:reply, :ok, %{state | blocked: false}}
    end

    def handle_call({:complete, unit_name, token}, _from, state) do
      calls = [{unit_name, token} | state.calls]

      cond do
        is_binary(state.expected_unit) and unit_name != state.expected_unit ->
          {:reply, {:error, :unknown_unit_name}, %{state | calls: calls}}

        is_binary(state.expected_token) and token != state.expected_token ->
          {:reply, {:error, :token_mismatch}, %{state | calls: calls}}

        state.blocked ->
          {:reply, {:error, :journal_blocked}, %{state | calls: calls}}

        true ->
          case state.results do
            [{:raise, exception} | rest] ->
              {:reply, {:do_raise, exception}, %{state | results: rest, calls: calls}}

            [{:exit, reason} | rest] ->
              {:reply, {:do_exit, reason}, %{state | results: rest, calls: calls}}

            [{:throw, reason} | rest] ->
              {:reply, {:do_throw, reason}, %{state | results: rest, calls: calls}}

            [result | rest] ->
              {:reply, result, %{state | results: rest, calls: calls}}

            [] ->
              # Default success after script exhaustion — keeps existing worker
              # tests green while still recording exact complete calls.
              {:reply, :ok, %{state | calls: calls}}
          end
      end
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
    FakeJournal.ensure_started()
    :ok = FakeJournal.reset()
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

  defp journal_record_for(spec, execution_id, opts \\ []) do
    %{
      unit_name: Keyword.get(opts, :unit_name, spec.plan.unit_name),
      execution_id: Keyword.get(opts, :execution_id, execution_id),
      token: Keyword.get(opts, :token, @journal_token),
      reserved_at_ms: Keyword.get(opts, :reserved_at_ms, 1_700_000_000_000)
    }
  end

  defp admission_opts(spec, execution_id, extra \\ []) do
    now = FakeRuntime.monotonic_ms()
    timeout_ms = Map.fetch!(spec, :timeout_ms)

    base = [
      runtime: FakeRuntime,
      journal_module: FakeJournal,
      journal_record: journal_record_for(spec, execution_id),
      operation_deadline: now + timeout_ms,
      ownership_caller: self()
    ]

    Keyword.merge(base, extra)
  end

  defp start_and_begin(spec, executable, script) do
    :ok = FakeRuntime.reset(script)
    start_ref = make_ref()

    {:ok, execution_id} =
      ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

    assert {:ok, worker} =
             Worker.start_for_test(
               spec,
               executable,
               execution_id,
               start_ref,
               admission_opts(spec, execution_id)
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

  # After a drain-without-publication stop, the registry may still be running or
  # may only observe owner-down. It must not carry a journal-gated finish/fail.
  defp unpublished_registry_after_owner_stop?(execution_id) do
    case ExecutionRegistry.get(execution_id) do
      {:ok, %{status: status}} when status in [:running, :cancelling, :pending] ->
        true

      {:ok, %{status: status, result: result}}
      when status in [:failed, :killed] and is_map(result) ->
        if owner_down_registry_error?(Map.get(result, :error)) do
          true
        else
          flunk(
            "registry shows journal-gated publication after drain-without-publication: " <>
              "#{inspect(status)} #{inspect(result)}"
          )
        end

      {:ok, %{status: :completed, result: result}} ->
        flunk(
          "registry shows journal-gated success publication after drain-without-publication: " <>
            "#{inspect(result)}"
        )

      other ->
        flunk("unexpected registry state: #{inspect(other)}")
    end
  end

  defp owner_down_registry_error?({:execution_owner_down, _}), do: true
  defp owner_down_registry_error?([:execution_owner_down | _]), do: true
  defp owner_down_registry_error?(%{error: inner}), do: owner_down_registry_error?(inner)
  defp owner_down_registry_error?(_), do: false

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

  # prep_stop leaves the coordinator permanently closed while still registered.
  # Always terminate/restart so later tests receive a fresh ready coordinator.
  defp restore_drain_coordinator! do
    case Process.whereis(DrainCoordinator) do
      pid when is_pid(pid) ->
        _ = Supervisor.terminate_child(Arbor.Shell.Supervisor, DrainCoordinator)

      _missing ->
        :ok
    end

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

  defp restore_execution_registry! do
    case Process.whereis(ExecutionRegistry) do
      pid when is_pid(pid) ->
        :ok

      _missing ->
        case Supervisor.restart_child(Arbor.Shell.Supervisor, ExecutionRegistry) do
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
              Supervisor.start_child(Arbor.Shell.Supervisor, {ExecutionRegistry, []})

            :ok

          {:error, _reason} ->
            _ = Supervisor.terminate_child(Arbor.Shell.Supervisor, ExecutionRegistry)
            _ = Supervisor.delete_child(Arbor.Shell.Supervisor, ExecutionRegistry)

            {:ok, _} =
              Supervisor.start_child(Arbor.Shell.Supervisor, {ExecutionRegistry, []})

            :ok
        end
    end
  end

  defp unit_child_pids do
    Arbor.Shell.AppleContainerUnitSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_id, child, _type, _modules} when is_pid(child) -> [child]
      _other -> []
    end)
  end

  defp unit_child_count, do: length(unit_child_pids())

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
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 admission_opts(spec, execution_id)
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
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 admission_opts(spec, execution_id)
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
      :ok = FakeRuntime.reset([])
      start_ref = make_ref()

      {:ok, execution_id} =
        ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

      assert {:error, :invalid_runtime_module} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 admission_opts(spec, execution_id, runtime: :not_a_runtime_module)
               )

      assert {:error, :invalid_runtime_module} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 admission_opts(spec, execution_id, runtime: String)
               )
    end

    test "omitting durable admission opts fails closed before child start", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeRuntime.reset([])
      start_ref = make_ref()
      before = unit_child_count()

      {:ok, execution_id} =
        ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

      assert {:error, :durable_unit_admission_required} =
               Worker.start_for_test(spec, executable, execution_id, start_ref,
                 runtime: FakeRuntime
               )

      assert unit_child_count() == before
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

    test "security regression: registry absence does not drop drain receipt or terminal", %{
      spec: spec,
      executable: executable
    } do
      on_exit(fn -> restore_execution_registry!() end)

      # Full lifecycle to create-attempted success, then hold exact absence so we
      # can remove ExecutionRegistry before the worker publishes terminal.
      script = [
        success_list([]),
        success(%{exit_code: 0}),
        success(%{exit_code: 0, stdout: "candidate-out"}),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        {:hold, success_list([])}
      ]

      {execution_id, worker, _} = start_and_begin(spec, executable, script)
      worker_ref = Process.monitor(worker)

      # Reach create-attempted cleanup and hold the final exact-absence list.
      eventually!(fn -> FakeRuntime.held_count() >= 1 end, 15_000)

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

      # Positive absence not yet proven — no terminal and no drain receipt.
      refute_receive {:apple_container_unit_terminal, ^execution_id, _}, 100
      refute_receive {:drain_receipt, _}, 50
      assert Process.alive?(worker)
      assert Process.alive?(drain_caller)

      # Make the named ExecutionRegistry unavailable before absence is released.
      assert is_pid(Process.whereis(ExecutionRegistry))
      assert :ok = Supervisor.terminate_child(Arbor.Shell.Supervisor, ExecutionRegistry)
      assert Process.whereis(ExecutionRegistry) == nil

      assert :ok = FakeRuntime.release_held()

      assert_receive {:apple_container_unit_terminal, ^execution_id, {:ok, result}}, 10_000
      assert result.stdout == "candidate-out"

      assert_receive {:drain_receipt,
                      {:apple_container_unit_drained, ^worker, ^execution_id, ^receipt_ref}},
                     10_000

      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 10_000
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
      # final successful absence is held so Application.prep_stop must block.
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

      app_state = %{startup_epoch: make_ref(), children_started?: true}

      task =
        Task.async(fn ->
          Arbor.Shell.Application.prep_stop(app_state)
        end)

      try do
        eventually!(fn -> FakeRuntime.held_count() >= 1 end, 30_000)

        # prep_stop remains blocked while final absence is held.
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

        assert ^app_state = Task.await(task, 30_000)
        assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 15_000
        refute Process.alive?(worker)
        # prep_stop barrier completes without killing the coordinator; it stays
        # registered and permanently closed.
        assert Process.alive?(coordinator)
        assert Process.whereis(DrainCoordinator) == coordinator

        assert {:error, :unit_start_unavailable} =
                 Worker.start(spec, executable, "exec_after_prep_stop", make_ref())

        exec = await_registry_terminal(execution_id, 10_000)
        assert exec.status == :killed
        assert exec.result.cancelled == true
      after
        # Release held sessions before waiting so a failed assertion cannot
        # poison later tests by leaving prep_stop blocked on absence.
        _ = FakeRuntime.release_held()

        if Process.alive?(task.pid) do
          _ = Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill)
        end

        restore_drain_coordinator!()
      end
    end

    test "security regression: legacy coordinator start requires durable admission", %{
      spec: spec,
      executable: executable
    } do
      before = unit_child_count()
      start_ref = make_ref()

      assert {:error, :durable_unit_admission_required} =
               Worker.start_under_coordinator(
                 spec,
                 executable,
                 "exec_direct_bypass",
                 start_ref,
                 self()
               )

      assert unit_child_count() == before
      assert unit_child_pids() == []
    end

    test "profile-aware timeout: standard rejects above 600000; intensive admits 1200000 including JSON form",
         %{
           executable: executable
         } do
      before = unit_child_count()
      start_ref = make_ref()
      standard_ceiling = Arbor.Shell.spawn_capable_max_timeout_ms()
      assert standard_ceiling == 600_000
      assert {:ok, intensive_ceiling} = Arbor.Shell.spawn_capable_max_timeout_ms(:intensive)
      assert intensive_ceiling == 1_200_000

      # Standard atom profile rejects one above the historical 600_000 ceiling.
      standard_over = %{
        plan: %{unit_name: @name, resource_profile: :standard},
        timeout_ms: standard_ceiling + 1,
        max_output_bytes: 8_192
      }

      assert {:error, :invalid_execution_spec} =
               Worker.start_under_coordinator(
                 standard_over,
                 executable,
                 "exec_standard_oversize",
                 start_ref,
                 self()
               )

      # Standard ceiling still admits under :standard (then durable gate).
      standard_ok = %{standard_over | timeout_ms: standard_ceiling}

      assert {:error, :durable_unit_admission_required} =
               Worker.start_under_coordinator(
                 standard_ok,
                 executable,
                 "exec_standard_ok",
                 start_ref,
                 self()
               )

      # Intensive atom admits the intensive ceiling (1_200_000).
      intensive_ok = %{
        plan: %{unit_name: @name, resource_profile: :intensive},
        timeout_ms: intensive_ceiling,
        max_output_bytes: 8_192
      }

      assert {:error, :durable_unit_admission_required} =
               Worker.start_under_coordinator(
                 intensive_ok,
                 executable,
                 "exec_intensive_ok",
                 start_ref,
                 self()
               )

      # JSON-clean serialized profile re-admits the intensive ceiling safely.
      serialized_intensive = %{
        plan: %{"unit_name" => @name, "resource_profile" => "intensive"},
        timeout_ms: intensive_ceiling,
        max_output_bytes: 8_192
      }

      assert {:error, :durable_unit_admission_required} =
               Worker.start_under_coordinator(
                 serialized_intensive,
                 executable,
                 "exec_serialized_intensive",
                 start_ref,
                 self()
               )

      # JSON-clean standard still rejects above 600_000 (no silent upgrade).
      serialized_standard_over = %{
        plan: %{"unit_name" => @name, "resource_profile" => "standard"},
        timeout_ms: standard_ceiling + 1,
        max_output_bytes: 8_192
      }

      assert {:error, :invalid_execution_spec} =
               Worker.start_under_coordinator(
                 serialized_standard_over,
                 executable,
                 "exec_serialized_standard_oversize",
                 start_ref,
                 self()
               )

      # Intensive still rejects above its own ceiling.
      intensive_over = %{intensive_ok | timeout_ms: intensive_ceiling + 1}

      assert {:error, :invalid_execution_spec} =
               Worker.start_under_coordinator(
                 intensive_over,
                 executable,
                 "exec_intensive_oversize",
                 start_ref,
                 self()
               )

      assert unit_child_count() == before
      assert unit_child_pids() == []
    end

    test "security regression: durable coordinator start rejects non-coordinator callers", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeRuntime.reset([])
      before = unit_child_count()
      start_ref = make_ref()
      execution_id = "exec_durable_bypass"
      record = journal_record_for(spec, execution_id)
      deadline = FakeRuntime.monotonic_ms() + spec.timeout_ms

      assert {:error, :coordinator_start_required} =
               Worker.start_under_coordinator_durable(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 self(),
                 record,
                 deadline
               )

      assert unit_child_count() == before
      assert unit_child_pids() == []
    end

    test "security regression: production start unavailable while coordinator drain in progress",
         %{
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
      coordinator = Process.whereis(DrainCoordinator)
      unit_sup = Process.whereis(Arbor.Shell.AppleContainerUnitSupervisor)
      port_sup = Process.whereis(Arbor.Shell.PortSessionSupervisor)

      assert is_pid(coordinator)
      assert is_pid(unit_sup)
      assert is_pid(port_sup)
      assert unit_child_count() == 1

      app_state = %{startup_epoch: make_ref(), children_started?: true}

      drain_task =
        Task.async(fn ->
          Arbor.Shell.Application.prep_stop(app_state)
        end)

      try do
        eventually!(fn -> FakeRuntime.held_count() >= 1 end, 30_000)

        # prep_stop barrier is mid-absence wait; coordinator stays nonblocking.
        assert is_nil(Task.yield(drain_task, 200))
        assert Process.alive?(coordinator)
        assert unit_child_count() == 1

        assert {:error, :unit_start_unavailable} =
                 Task.async(fn ->
                   Worker.start(spec, executable, "exec_late_after_snapshot", make_ref())
                 end)
                 |> Task.await(15_000)

        assert unit_child_count() == 1
        assert unit_child_pids() == [worker]
        assert Process.alive?(unit_sup)
        assert Process.alive?(port_sup)
        assert Process.alive?(coordinator)
        assert Process.alive?(worker)
        assert nonterminal_registry?(execution_id)

        assert :ok = FakeRuntime.release_held()
        assert ^app_state = Task.await(drain_task, 30_000)

        assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 15_000
        refute Process.alive?(worker)
        assert Process.alive?(coordinator)
        assert Process.whereis(DrainCoordinator) == coordinator

        assert {:error, :unit_start_unavailable} =
                 Worker.start(spec, executable, "exec_after_prep_stop", make_ref())

        exec = await_registry_terminal(execution_id, 10_000)
        assert exec.status == :killed
        assert exec.result.cancelled == true
      after
        _ = FakeRuntime.release_held()

        if Process.alive?(drain_task.pid) do
          _ = Task.yield(drain_task, 30_000) || Task.shutdown(drain_task, :brutal_kill)
        end

        restore_drain_coordinator!()
      end
    end

    test "pre-begin expiry stops waiting worker without create or start commands", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeRuntime.reset([])
      start_ref = make_ref()

      {:ok, execution_id} =
        ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

      assert {:ok, worker} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 admission_opts(spec, execution_id, pre_begin_timeout_ms: 50)
               )

      assert :ok = ExecutionRegistry.adopt(execution_id, worker)
      worker_ref = Process.monitor(worker)

      assert {:error, :preflight_cancelled} = await_terminal(execution_id, 5_000)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 5_000
      refute Process.alive?(worker)
      assert FakeRuntime.calls() == []

      exec = await_registry_terminal(execution_id, 5_000)
      assert exec.status == :failed
      assert exec.result.error == :preflight_cancelled
    end

    test "security regression: suspended worker handshake timeout does not bypass drain", %{
      spec: spec,
      executable: executable
    } do
      # Active start is cancelled after resume; one present cleanup round then
      # held final absence so post-resume progress is observable.
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

      # Suspend before prep_stop so request_drain handshake times out.
      assert :ok = :sys.suspend(worker)

      app_state = %{startup_epoch: make_ref(), children_started?: true}

      task =
        Task.async(fn ->
          Arbor.Shell.Application.prep_stop(app_state)
        end)

      try do
        # Cross at least one bounded handshake timeout (5_000ms). A prior bug
        # dropped unresponsive workers and let the barrier return.
        assert is_nil(Task.yield(task, 5_500))
        assert Process.alive?(task.pid)
        assert Process.alive?(coordinator)
        assert Process.alive?(worker)
        assert Process.alive?(unit_sup)
        assert Process.alive?(port_sup)
        assert nonterminal_registry?(execution_id)
        refute_receive {:apple_container_unit_terminal, ^execution_id, _}, 50

        # Still blocked after the timeout window; supervisors remain up.
        assert is_nil(Task.yield(task, 500))
        assert Process.alive?(task.pid)
        assert Process.alive?(coordinator)
        assert Process.alive?(unit_sup)
        assert Process.alive?(port_sup)

        assert :ok = :sys.resume(worker)

        eventually!(fn -> FakeRuntime.held_count() >= 1 end, 30_000)

        assert is_nil(Task.yield(task, 200))
        assert Process.alive?(coordinator)
        assert Process.alive?(worker)
        assert nonterminal_registry?(execution_id)
        refute_receive {:apple_container_unit_terminal, ^execution_id, _}, 50

        assert :ok = FakeRuntime.release_held()

        assert ^app_state = Task.await(task, 30_000)
        assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 15_000
        refute Process.alive?(worker)
        assert Process.alive?(coordinator)
        assert Process.whereis(DrainCoordinator) == coordinator

        assert_receive {:apple_container_unit_terminal, ^execution_id, {:ok, result}}, 5_000
        assert result.cancelled == true

        exec = await_registry_terminal(execution_id, 10_000)
        assert exec.status == :killed
        assert exec.result.cancelled == true
      after
        # Resume/release before waiting so assertion failure cannot leave
        # prep_stop blocked mid-handshake or mid-absence wait.
        if is_pid(worker) and Process.alive?(worker) do
          try do
            :sys.resume(worker)
          catch
            :exit, _ -> :ok
          end
        end

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
            Worker.start_for_test(
              spec,
              executable,
              execution_id,
              start_ref,
              admission_opts(spec, execution_id)
            )

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

      record = journal_record_for(spec, execution_id)

      assert {:ok, worker} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 admission_opts(spec, execution_id, journal_record: record)
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
      # Token value must not appear; redacted map keys may name sensitive fields.
      refute text =~ @journal_token

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
      assert redacted.state.ownership_caller == :redacted
      assert redacted.state.journal_record == :redacted
      assert redacted.state.token == :redacted
      assert redacted.state.operation_deadline == :redacted
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

    test "relative tool is pure preflight before admission" do
      assert {:error, {:invalid_tool_name, :relative_path}} =
               Shell.execute_spawn_capable("mix", ["test"], [])
    end

    test "begin and request_drain reject non-positive and infinite timeouts", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeRuntime.reset([{:hang, success(%{exit_code: 0})}])
      start_ref = make_ref()

      {:ok, execution_id} =
        ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

      assert {:ok, worker} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 admission_opts(spec, execution_id)
               )

      assert :ok = ExecutionRegistry.adopt(execution_id, worker)

      assert {:error, :invalid_begin} = Worker.begin(worker, start_ref, 0)
      assert {:error, :invalid_begin} = Worker.begin(worker, start_ref, -1)
      assert {:error, :invalid_begin} = Worker.begin(worker, start_ref, :infinity)
      assert {:error, :invalid_begin} = Worker.begin(worker, start_ref, 60_001)

      assert {:error, :invalid_drain} = Worker.request_drain(worker, make_ref(), 0)
      assert {:error, :invalid_drain} = Worker.request_drain(worker, make_ref(), -1)
      assert {:error, :invalid_drain} = Worker.request_drain(worker, make_ref(), :infinity)
      assert {:error, :invalid_drain} = Worker.request_drain(worker, make_ref(), 60_001)

      send(worker, {:cancel_shell_execution, execution_id})
      _ = await_terminal(execution_id, 10_000)
    end

    test "durable worker boundary rejects non-container executable path", %{spec: spec} do
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

      before = unit_child_count()

      # Exact deterministic assertion at the durable Worker admission boundary
      # (validates executable before the durable-admission-required gate).
      assert {:error, :invalid_runtime_executable} =
               Worker.start_under_coordinator(
                 spec,
                 bad,
                 "exec_test",
                 make_ref(),
                 self()
               )

      assert unit_child_count() == before
    end
  end

  describe "durable admission boundary" do
    test "rejects missing malformed extra and mismatched journal records", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeRuntime.reset([])
      start_ref = make_ref()
      before = unit_child_count()

      {:ok, execution_id} =
        ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

      base = admission_opts(spec, execution_id)

      assert {:error, :durable_unit_admission_required} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 Keyword.delete(base, :journal_record)
               )

      assert {:error, reason_missing} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 Keyword.put(base, :journal_record, %{})
               )

      assert reason_missing in [
               :missing_unit_name,
               :missing_execution_id,
               :missing_token,
               :missing_reserved_at_ms,
               :invalid_journal_record,
               :invalid_record
             ]

      assert {:error, {:unsupported_keys, _scope}} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 Keyword.put(
                   base,
                   :journal_record,
                   Map.put(journal_record_for(spec, execution_id), :extra, true)
                 )
               )

      assert {:error, :journal_record_mismatch} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 Keyword.put(
                   base,
                   :journal_record,
                   journal_record_for(spec, execution_id, execution_id: "other-exec")
                 )
               )

      assert {:error, :journal_record_mismatch} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 Keyword.put(
                   base,
                   :journal_record,
                   journal_record_for(spec, execution_id,
                     unit_name: "arbor-v1-" <> String.duplicate("b", 32)
                   )
                 )
               )

      assert unit_child_count() == before
    end

    test "rejects expired and overlong operation deadlines before child start", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeRuntime.reset([])
      start_ref = make_ref()
      before = unit_child_count()

      {:ok, execution_id} =
        ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

      now = FakeRuntime.monotonic_ms()

      assert {:error, :invalid_operation_deadline} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 admission_opts(spec, execution_id, operation_deadline: now)
               )

      assert {:error, :invalid_operation_deadline} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 admission_opts(spec, execution_id, operation_deadline: now - 1)
               )

      assert {:error, :invalid_operation_deadline} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 admission_opts(spec, execution_id, operation_deadline: now + spec.timeout_ms + 1)
               )

      assert unit_child_count() == before
    end

    test "deadline expiring between admission checks fails before child start", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeRuntime.reset([])
      :ok = FakeRuntime.set_mono_step(2)
      start_ref = make_ref()
      before = unit_child_count()

      {:ok, execution_id} =
        ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

      opts = [
        runtime: FakeRuntime,
        journal_record: journal_record_for(spec, execution_id),
        operation_deadline: 1_000_001,
        ownership_caller: self()
      ]

      assert {:error, :invalid_operation_deadline} =
               Worker.start_for_test(spec, executable, execution_id, start_ref, opts)

      assert unit_child_count() == before
    end

    test "waiting does not reset the admission operation deadline", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeRuntime.reset([success_list([])])
      start_ref = make_ref()

      {:ok, execution_id} =
        ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

      now = FakeRuntime.monotonic_ms()
      # Short remaining budget after a wait; must stay absolute (not now+timeout).
      deadline = now + 250

      assert {:ok, worker} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 admission_opts(spec, execution_id, operation_deadline: deadline)
               )

      assert :ok = ExecutionRegistry.adopt(execution_id, worker)

      # Advance clock while waiting — begin must keep the original deadline.
      :ok = FakeRuntime.advance_mono(200)
      assert :ok = Worker.begin(worker, start_ref)

      eventually!(fn -> length(FakeRuntime.calls()) >= 1 end)
      [call] = FakeRuntime.calls()
      remaining = Keyword.get(call.opts, :timeout)
      assert is_integer(remaining)
      assert remaining > 0
      assert remaining <= 50

      send(worker, {:cancel_shell_execution, execution_id})
      _ = await_terminal(execution_id, 10_000)
    end

    test "pre-begin expiry from operation deadline runs zero runtime commands", %{
      executable: executable,
      plan: plan
    } do
      # Cap pre-begin by a tiny remaining operation budget.
      spec = %{plan: plan, timeout_ms: 30_000, max_output_bytes: 1024}
      :ok = FakeRuntime.reset([])
      start_ref = make_ref()

      {:ok, execution_id} =
        ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

      now = FakeRuntime.monotonic_ms()

      assert {:ok, worker} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 admission_opts(spec, execution_id,
                   operation_deadline: now + 40,
                   pre_begin_timeout_ms: 30_000
                 )
               )

      assert :ok = ExecutionRegistry.adopt(execution_id, worker)
      worker_ref = Process.monitor(worker)

      assert {:error, :preflight_cancelled} = await_terminal(execution_id, 5_000)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 5_000
      refute Process.alive?(worker)
      assert FakeRuntime.calls() == []
    end

    test "begin after deadline expiry runs zero runtime commands", %{
      executable: executable,
      plan: plan
    } do
      spec = %{plan: plan, timeout_ms: 30_000, max_output_bytes: 1024}
      :ok = FakeRuntime.reset([])
      start_ref = make_ref()

      {:ok, execution_id} =
        ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

      now = FakeRuntime.monotonic_ms()

      assert {:ok, worker} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 admission_opts(spec, execution_id, operation_deadline: now + 500)
               )

      assert :ok = ExecutionRegistry.adopt(execution_id, worker)
      :ok = FakeRuntime.advance_mono(600)

      assert :ok = Worker.begin(worker, start_ref)
      assert {:error, :preflight_cancelled} = await_terminal(execution_id, 5_000)
      assert FakeRuntime.calls() == []
    end

    test "ownership_info requires exact caller and full record match", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeRuntime.reset([{:hang, success(%{exit_code: 0})}])
      start_ref = make_ref()

      {:ok, execution_id} =
        ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

      record = journal_record_for(spec, execution_id)

      assert {:ok, worker} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 admission_opts(spec, execution_id, journal_record: record)
               )

      assert :ok = ExecutionRegistry.adopt(execution_id, worker)

      assert {:ok, info} = Worker.ownership_info(worker, record)
      assert info.journal_record == record
      assert info.controller_pid == self()
      assert info.execution_id == execution_id
      refute Map.has_key?(info, :ownership_caller)
      refute Map.has_key?(info, :operation_deadline)

      # Wrong caller PID alone is insufficient even with the exact record.
      wrong_caller =
        Task.async(fn -> Worker.ownership_info(worker, record) end)
        |> Task.await(5_000)

      assert wrong_caller == {:error, :ownership_denied}

      assert {:error, :ownership_denied} =
               Worker.ownership_info(
                 worker,
                 %{record | token: String.duplicate("2", 64)}
               )

      assert {:error, :ownership_denied} =
               Worker.ownership_info(
                 worker,
                 %{record | reserved_at_ms: record.reserved_at_ms + 1}
               )

      assert {:error, :ownership_denied} =
               Worker.ownership_info(worker, Map.put(record, :extra, true))

      assert {:error, :ownership_denied} = Worker.ownership_info(worker, %{})

      send(worker, {:cancel_shell_execution, execution_id})
      _ = await_terminal(execution_id, 10_000)
      assert {:error, :ownership_denied} = Worker.ownership_info(worker, record)
    end

    test "ownership_hint returns only execution_id to exact PID owner", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeRuntime.reset([{:hang, success(%{exit_code: 0})}])
      start_ref = make_ref()

      {:ok, execution_id} =
        ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

      record = journal_record_for(spec, execution_id)

      assert {:ok, worker} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 admission_opts(spec, execution_id, journal_record: record)
               )

      assert :ok = ExecutionRegistry.adopt(execution_id, worker)

      assert {:ok, hint} = Worker.ownership_hint(worker)
      assert hint == %{execution_id: execution_id}
      assert Map.keys(hint) == [:execution_id]
      refute Map.has_key?(hint, :journal_record)
      refute Map.has_key?(hint, :token)
      refute Map.has_key?(hint, :controller_pid)
      refute Map.has_key?(hint, :ownership_caller)
      refute Map.has_key?(hint, :unit_name)
      refute Map.has_key?(hint, :operation_deadline)

      # ownership_info still requires the full exact record — hint is not authority.
      assert {:error, :ownership_denied} = Worker.ownership_info(worker, %{})

      wrong_caller =
        Task.async(fn -> Worker.ownership_hint(worker) end)
        |> Task.await(5_000)

      assert wrong_caller == {:error, :ownership_denied}

      assert {:error, :invalid_ownership_hint} = Worker.ownership_hint(worker, 0)
      assert {:error, :invalid_ownership_hint} = Worker.ownership_hint(worker, :infinity)

      send(worker, {:cancel_shell_execution, execution_id})
      _ = await_terminal(execution_id, 10_000)
      assert {:error, :ownership_denied} = Worker.ownership_hint(worker)
    end

    test "ownership_hint follows registered-name replacement across coordinator restart", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeRuntime.reset([{:hang, success(%{exit_code: 0})}])
      start_ref = make_ref()
      ownership_name = __MODULE__.HintRestartableCoordinator
      parent = self()

      assert Process.whereis(ownership_name) == nil
      assert Process.register(self(), ownership_name)

      on_exit(fn ->
        case Process.whereis(ownership_name) do
          pid when is_pid(pid) -> Process.exit(pid, :kill)
          _ -> :ok
        end
      end)

      {:ok, execution_id} =
        ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

      record = journal_record_for(spec, execution_id)

      assert {:ok, worker} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 admission_opts(spec, execution_id,
                   journal_record: record,
                   ownership_caller: {:registered, ownership_name}
                 )
               )

      assert :ok = ExecutionRegistry.adopt(execution_id, worker)
      assert {:ok, %{execution_id: ^execution_id}} = Worker.ownership_hint(worker)
      assert Process.unregister(ownership_name)
      assert {:error, :ownership_denied} = Worker.ownership_hint(worker)

      replacement =
        spawn(fn ->
          true = Process.register(self(), ownership_name)
          send(parent, {:hint_replacement_registered, self()})

          receive do
            {:query_hint, ^worker} ->
              send(parent, {:hint_replacement_result, Worker.ownership_hint(worker)})
          end

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:hint_replacement_registered, ^replacement}, 1_000
      send(replacement, {:query_hint, worker})
      assert_receive {:hint_replacement_result, {:ok, %{execution_id: ^execution_id}}}, 5_000

      # Full-record gate is unchanged after restart: re-register as authority.
      ref = Process.monitor(replacement)
      send(replacement, :stop)
      assert_receive {:DOWN, ^ref, :process, ^replacement, _}, 5_000
      assert Process.whereis(ownership_name) == nil
      assert Process.register(self(), ownership_name)
      assert {:ok, info} = Worker.ownership_info(worker, record)
      assert info.journal_record == record
      assert info.execution_id == execution_id
      # Hint never grants full-record fields.
      assert {:ok, %{execution_id: ^execution_id} = hint} = Worker.ownership_hint(worker)
      assert map_size(hint) == 1

      send(worker, {:cancel_shell_execution, execution_id})
      _ = await_terminal(execution_id, 10_000)
    end

    test "registered coordinator ownership survives coordinator process restart", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeRuntime.reset([{:hang, success(%{exit_code: 0})}])
      start_ref = make_ref()
      ownership_name = __MODULE__.RestartableCoordinator
      parent = self()

      assert Process.whereis(ownership_name) == nil
      assert Process.register(self(), ownership_name)

      on_exit(fn ->
        case Process.whereis(ownership_name) do
          pid when is_pid(pid) -> Process.exit(pid, :kill)
          _ -> :ok
        end
      end)

      {:ok, execution_id} =
        ExecutionRegistry.register("container unit", sandbox: :basic, cwd: "/")

      record = journal_record_for(spec, execution_id)

      assert {:ok, worker} =
               Worker.start_for_test(
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 admission_opts(spec, execution_id,
                   journal_record: record,
                   ownership_caller: {:registered, ownership_name}
                 )
               )

      assert :ok = ExecutionRegistry.adopt(execution_id, worker)
      assert {:ok, _info} = Worker.ownership_info(worker, record)
      assert Process.unregister(ownership_name)
      assert {:error, :ownership_denied} = Worker.ownership_info(worker, record)

      replacement =
        spawn(fn ->
          true = Process.register(self(), ownership_name)
          send(parent, {:replacement_registered, self()})

          receive do
            {:query_ownership, ^worker, ^record} ->
              send(parent, {:replacement_result, Worker.ownership_info(worker, record)})
          end

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:replacement_registered, ^replacement}, 1_000
      send(replacement, {:query_ownership, worker, record})
      assert_receive {:replacement_result, {:ok, info}}, 5_000
      assert info.journal_record == record
      assert info.execution_id == execution_id

      send(worker, {:cancel_shell_execution, execution_id})
      _ = await_terminal(execution_id, 10_000)
      send(replacement, :stop)
    end
  end

  describe "durable terminal-publication gate" do
    test "blocked complete hides registry/controller terminal until release", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeJournal.reset(blocked: true)

      script = [
        success_list([]),
        success(%{exit_code: 0}),
        success(%{exit_code: 0, stdout: "gated"}),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([])
      ]

      {execution_id, worker, _} = start_and_begin(spec, executable, script)

      eventually!(fn -> length(FakeJournal.complete_calls()) >= 1 end, 10_000)

      refute_receive {:apple_container_unit_terminal, ^execution_id, _}, 150
      assert nonterminal_registry?(execution_id)
      assert Process.alive?(worker)

      assert :ok = FakeJournal.release()
      assert {:ok, result} = await_terminal(execution_id, 10_000)
      assert result.stdout == "gated"

      exec = await_registry_terminal(execution_id)
      assert exec.status == :completed
      assert exec.result.stdout == "gated"
      refute Process.alive?(worker)

      calls = FakeJournal.complete_calls()
      assert length(calls) >= 1
      assert Enum.all?(calls, fn {unit, token} -> unit == @name and token == @journal_token end)
      assert List.last(calls) == {@name, @journal_token}
    end

    test "completion uses exact unit_name+token and precedes publication", %{
      spec: spec,
      executable: executable
    } do
      :ok =
        FakeJournal.reset(
          expected_unit: @name,
          expected_token: @journal_token,
          results: [:ok]
        )

      script = [
        success_list([]),
        success(%{exit_code: 0}),
        success(%{exit_code: 0, stdout: "order"}),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([])
      ]

      {execution_id, _worker, _} = start_and_begin(spec, executable, script)
      assert {:ok, _} = await_terminal(execution_id)

      assert FakeJournal.complete_calls() == [{@name, @journal_token}]
      exec = await_registry_terminal(execution_id)
      assert exec.status == :completed
    end

    test "fail once then retry succeeds with exactly one publication", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeJournal.reset(results: [{:error, :temporary_unavailable}, :ok])

      script = [
        success_list([]),
        success(%{exit_code: 0}),
        success(%{exit_code: 0, stdout: "retry-once"}),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([])
      ]

      {execution_id, worker, _} = start_and_begin(spec, executable, script)
      assert {:ok, result} = await_terminal(execution_id, 10_000)
      assert result.stdout == "retry-once"

      exec = await_registry_terminal(execution_id)
      assert exec.status == :completed
      assert exec.result.stdout == "retry-once"
      refute Process.alive?(worker)

      calls = FakeJournal.complete_calls()
      assert length(calls) == 2
      assert Enum.uniq(calls) == [{@name, @journal_token}]
    end

    test "stale journal retry timer is ignored", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeJournal.reset(blocked: true)

      script = [
        success_list([]),
        success(%{exit_code: 0}),
        success(%{exit_code: 0, stdout: "stale"}),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([])
      ]

      {execution_id, worker, _} = start_and_begin(spec, executable, script)
      eventually!(fn -> length(FakeJournal.complete_calls()) >= 1 end, 10_000)

      # Forged timer ref/token pairs must be ignored. Real retries may still run
      # while blocked, but publication must wait for an exact matching timer
      # after release (or a successful complete).
      for _ <- 1..5 do
        send(worker, {:timeout, make_ref(), {:journal_complete_retry, make_ref()}})
        send(worker, {:timeout, make_ref(), {:journal_complete_retry, :forged}})
      end

      _ = :sys.get_state(worker)
      refute_receive {:apple_container_unit_terminal, ^execution_id, _}, 50
      assert nonterminal_registry?(execution_id)
      assert Process.alive?(worker)

      assert :ok = FakeJournal.release()
      assert {:ok, result} = await_terminal(execution_id, 10_000)
      assert result.stdout == "stale"
    end

    test "failure plus exact drain emits receipt/stop without publication", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeJournal.reset(blocked: true)

      script = [
        success_list([]),
        success(%{exit_code: 0}),
        success(%{exit_code: 0, stdout: "drain-no-pub"}),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([])
      ]

      {execution_id, worker, _} = start_and_begin(spec, executable, script)
      eventually!(fn -> length(FakeJournal.complete_calls()) >= 1 end, 10_000)

      worker_ref = Process.monitor(worker)
      receipt_ref = make_ref()
      parent = self()

      _drain_caller =
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

      assert_receive {:drain_receipt,
                      {:apple_container_unit_drained, ^worker, ^execution_id, ^receipt_ref}},
                     10_000

      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 10_000
      refute Process.alive?(worker)

      # No controller publication. Registry may only observe owner-down after
      # stop — never a journal-gated finish/fail payload.
      refute_receive {:apple_container_unit_terminal, ^execution_id, _}, 100
      assert unpublished_registry_after_owner_stop?(execution_id)
      assert length(FakeJournal.complete_calls()) >= 1
    end

    test "no complete before positive absence", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeJournal.reset()

      script = [
        success_list([]),
        success(%{exit_code: 0}),
        success(%{exit_code: 0, stdout: "cand"}),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        {:hold, success_list([])}
      ]

      {execution_id, worker, _} = start_and_begin(spec, executable, script)
      eventually!(fn -> FakeRuntime.held_count() >= 1 end, 10_000)

      assert FakeJournal.complete_calls() == []
      refute_receive {:apple_container_unit_terminal, ^execution_id, _}, 100
      assert nonterminal_registry?(execution_id)
      assert Process.alive?(worker)

      assert :ok = FakeRuntime.release_held()
      assert {:ok, result} = await_terminal(execution_id, 10_000)
      assert result.stdout == "cand"
      assert FakeJournal.complete_calls() == [{@name, @journal_token}]
    end

    test "create failure with absence completes and publishes error and can drain", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeJournal.reset()

      # Create fails after preflight empty; UnitCore cleanup until absence, then
      # terminal error — gate completes then publishes the error.
      script = [
        success_list([]),
        success(%{exit_code: 1, stdout: "create-failed"}),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([])
      ]

      {execution_id, worker, _} = start_and_begin(spec, executable, script)

      # Race: drain may arrive before or after journal complete succeeds.
      # For create-failure terminal error path, first wait for held absence path
      # completion via terminal, then prove journal complete + publish.
      terminal = await_terminal(execution_id, 10_000)
      assert match?({:error, _}, terminal)
      assert FakeJournal.complete_calls() == [{@name, @journal_token}]

      exec = await_registry_terminal(execution_id)
      assert exec.status == :failed
      refute Process.alive?(worker)
    end

    test "create failure absence terminal can drain without publication when complete fails", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeJournal.reset(blocked: true)

      script = [
        success_list([]),
        success(%{exit_code: 1, stdout: "create-failed"}),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([])
      ]

      {execution_id, worker, _} = start_and_begin(spec, executable, script)
      eventually!(fn -> length(FakeJournal.complete_calls()) >= 1 end, 10_000)

      worker_ref = Process.monitor(worker)
      receipt_ref = make_ref()
      parent = self()

      _drain_caller =
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

      # Blocked complete + drain + safe terminal error → receipt without publication.
      assert_receive {:drain_receipt,
                      {:apple_container_unit_drained, ^worker, ^execution_id, ^receipt_ref}},
                     10_000

      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 10_000
      refute_receive {:apple_container_unit_terminal, ^execution_id, _}, 50
      assert unpublished_registry_after_owner_stop?(execution_id)
      assert length(FakeJournal.complete_calls()) >= 1
    end

    test "pre-create terminal completes journal before publish", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeJournal.reset(blocked: true)

      script = [
        success_list([%{"configuration" => %{"id" => @name}}])
      ]

      {execution_id, worker, _} = start_and_begin(spec, executable, script)
      eventually!(fn -> length(FakeJournal.complete_calls()) >= 1 end, 5_000)

      refute_receive {:apple_container_unit_terminal, ^execution_id, _}, 100
      assert nonterminal_registry?(execution_id)
      assert Process.alive?(worker)
      assert hd(FakeJournal.complete_calls()) == {@name, @journal_token}

      assert :ok = FakeJournal.release()
      assert {:error, :unit_name_collision} = await_terminal(execution_id, 10_000)
      exec = await_registry_terminal(execution_id)
      assert exec.status == :failed
      assert exec.result.error == :unit_name_collision
      refute Process.alive?(worker)
    end

    test "held terminal and journal retry fields are redacted", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeJournal.reset(blocked: true)

      script = [
        success_list([]),
        success(%{exit_code: 0}),
        success(%{exit_code: 0, stdout: "redact-me"}),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([])
      ]

      {execution_id, worker, _} = start_and_begin(spec, executable, script)
      eventually!(fn -> length(FakeJournal.complete_calls()) >= 1 end, 10_000)

      redacted =
        Worker.format_status(%{
          state: :sys.get_state(worker),
          message: {:x},
          reason: :y,
          log: []
        })

      assert redacted.state.held_terminal == :redacted
      assert redacted.state.journal_retry_timer == :redacted
      assert redacted.state.journal_retry_token == :redacted
      assert redacted.state.journal_complete_status == :redacted
      assert redacted.state.journal_complete_reason == :redacted
      assert redacted.state.journal_module == :redacted
      assert redacted.state.journal_record == :redacted
      assert redacted.state.token == :redacted

      text = inspect(redacted, limit: :infinity, printable_limit: :infinity)
      refute text =~ @journal_token
      refute text =~ "redact-me"

      assert :ok = FakeJournal.release()
      _ = await_terminal(execution_id, 10_000)
    end

    test "later cancel does not overwrite held terminal", %{
      spec: spec,
      executable: executable
    } do
      :ok = FakeJournal.reset(blocked: true)

      script = [
        success_list([]),
        success(%{exit_code: 0}),
        success(%{exit_code: 0, stdout: "keep-me"}),
        success(%{exit_code: 0}),
        success(%{exit_code: 0}),
        success_list([])
      ]

      {execution_id, worker, _} = start_and_begin(spec, executable, script)
      eventually!(fn -> length(FakeJournal.complete_calls()) >= 1 end, 10_000)

      send(worker, {:cancel_shell_execution, execution_id})
      _ = :sys.get_state(worker)

      assert :ok = FakeJournal.release()
      assert {:ok, result} = await_terminal(execution_id, 10_000)
      assert result.stdout == "keep-me"
    end
  end

  describe "application order" do
    test "unit durable owners follow PortSession in rest_for_one order" do
      children = Arbor.Shell.Application.production_children([startup_path: "/bin"], make_ref())
      modules = Enum.map(children, &child_module/1)

      port_idx = Enum.find_index(modules, &(&1 == DynamicSupervisor))
      journal_idx = Enum.find_index(modules, &(&1 == Arbor.Shell.AppleContainerUnitJournal))

      recovery_idx =
        Enum.find_index(modules, &(&1 == Arbor.Shell.AppleContainerUnitRecoverySupervisor))

      unit_idx = Enum.find_index(modules, &(&1 == Arbor.Shell.AppleContainerUnitSupervisor))
      coord_idx = Enum.find_index(modules, &(&1 == DrainCoordinator))
      assert is_integer(port_idx)
      assert is_integer(journal_idx)
      assert is_integer(recovery_idx)
      assert is_integer(unit_idx)
      assert is_integer(coord_idx)
      assert journal_idx == port_idx + 1
      assert recovery_idx == journal_idx + 1
      assert unit_idx == recovery_idx + 1
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
