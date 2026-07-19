defmodule Arbor.Shell.ReviewerSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Shell
  alias Arbor.Shell.ExecutablePolicy
  alias Arbor.Shell.ExecutionRegistry

  @moduletag :fast
  @moduletag :security_regression

  test "security regression: runtime PATH cannot substitute an executable identity" do
    root = fixture_root("path")
    fake_echo = Path.join(root, "echo")
    marker = Path.join(root, "fake-echo-ran")
    original_path = System.get_env("PATH", "")
    File.mkdir_p!(root)
    File.write!(fake_echo, "#!/bin/sh\ntouch '#{marker}'\necho forged\n")
    File.chmod!(fake_echo, 0o755)

    try do
      System.put_env("PATH", root <> ":" <> original_path)
      assert {:ok, result} = Shell.execute_direct("echo", ["pinned"], sandbox: :none)
      assert String.trim(result.stdout) == "pinned"
      refute File.exists?(marker)
    after
      System.put_env("PATH", original_path)
      File.rm_rf!(root)
    end
  end

  test "security regression: native childless mode denies forking commands" do
    root = fixture_root("tree")
    marker = Path.join(root, "delayed-child")
    File.mkdir_p!(root)

    try do
      script = "(sleep 0.4; touch '#{marker}') & sleep 5"

      assert {:ok, result} =
               Shell.execute_direct("sh", ["-c", script], sandbox: :none, timeout: 100)

      refute result.timed_out
      refute result.killed
      assert result.exit_code != 0

      Process.sleep(700)
      refute File.exists?(marker)
    after
      File.rm_rf!(root)
    end
  end

  test "security regression: double-fork setsid descendant cannot escape containment" do
    root = fixture_root("double-fork")
    marker = Path.join(root, "escaped")
    File.mkdir_p!(root)

    script = """
    import os
    import time

    if os.fork() == 0:
        os.setsid()
        if os.fork() == 0:
            time.sleep(0.4)
            open(#{inspect(marker)}, "w").close()
            os._exit(0)
        os._exit(0)
    os._exit(0)
    """

    try do
      assert {:ok, result} =
               Shell.execute_direct("python3", ["-c", script],
                 sandbox: :none,
                 timeout: 2_000
               )

      Process.sleep(700)
      refute File.exists?(marker)
      assert result.exit_code != 0 or result.killed
    after
      File.rm_rf!(root)
    end
  end

  test "security regression: writable startup search directory cannot supply an executable" do
    root = fixture_root("writable-path")
    command = "arbor-attacker-tool"
    executable = Path.join(root, command)
    marker = Path.join(root, "executed")
    startup_path = System.get_env("PATH", "")
    File.mkdir_p!(root)
    File.write!(executable, "#!/bin/sh\ntouch '#{marker}'\n")
    File.chmod!(executable, 0o755)

    replace_executable_policy!(root <> ":/usr/bin:/bin")

    try do
      assert {:error, {:executable_not_found, ^command}} =
               Shell.execute_direct(command, [], sandbox: :none)

      refute File.exists?(marker)
    after
      replace_executable_policy!(startup_path)
      File.rm_rf!(root)
    end
  end

  test "security regression: direct agent facade requires an injected policy authorizer" do
    previous = Application.get_env(:arbor_shell, :agent_authorizer)
    Application.delete_env(:arbor_shell, :agent_authorizer)

    try do
      assert {:error, :agent_authorizer_unavailable} =
               Shell.authorize("agent_direct_facade", "echo denied", sandbox: :none)

      assert {:error, :agent_authorizer_unavailable} =
               Shell.authorize_and_execute(
                 "agent_direct_facade",
                 "echo denied",
                 sandbox: :none
               )
    after
      restore(:arbor_shell, :agent_authorizer, previous)
    end
  end

  test "security regression: async work is cancelled when its initiating caller dies" do
    parent = self()
    duration = "21.#{100 + rem(System.unique_integer([:positive]), 900)}"

    caller =
      spawn(fn ->
        result = Shell.execute_async("sleep #{duration}", sandbox: :none, timeout: 30_000)
        send(parent, {:async_started, result})
        receive do: (:release_authority -> :ok)
      end)

    ref = Process.monitor(caller)
    assert_receive {:async_started, {:ok, execution_id}}, 2_000

    on_exit(fn -> _ = Shell.kill(execution_id) end)

    assert eventually?(fn ->
             Enum.any?(os_processes(), &String.contains?(&1.command, "sleep #{duration}"))
           end)

    send(caller, :release_authority)
    assert_receive {:DOWN, ^ref, :process, ^caller, _reason}, 2_000

    assert eventually?(fn ->
             match?(
               {:ok, status} when status in [:killed, :failed],
               Shell.get_status(execution_id)
             )
           end)

    refute Enum.any?(os_processes(), &String.contains?(&1.command, "sleep #{duration}"))
  end

  test "security regression: streaming work is cancelled when every consumer dies" do
    consumer = spawn(fn -> Process.sleep(:infinity) end)

    assert {:ok, session_id} =
             Shell.execute_streaming("sleep 5",
               stream_to: consumer,
               sandbox: :none,
               timeout: 5_000
             )

    on_exit(fn -> _ = Shell.stop_session(session_id) end)
    Process.exit(consumer, :kill)

    assert eventually?(fn ->
             match?({:ok, status} when status in [:killed, :failed], Shell.get_status(session_id))
           end)
  end

  test "security regression: launcher SIGKILL exhausts its owned containment group" do
    duration = "29.731"

    assert {:ok, session_id} =
             Shell.execute_streaming("sleep #{duration}",
               stream_to: self(),
               sandbox: :none,
               timeout: 30_000
             )

    on_exit(fn -> _ = Shell.stop_session(session_id) end)

    assert %{pid: launcher_pid} =
             eventually_value(fn ->
               Enum.find(os_processes(), fn process ->
                 String.contains?(process.command, "arbor_shell_launcher exec") and
                   String.contains?(process.command, duration)
               end)
             end)

    assert %{pid: target_pid, pgid: target_pgid} =
             eventually_value(fn ->
               Enum.find(os_processes(), fn process ->
                 process.ppid == launcher_pid and process.pgid == process.pid and
                   String.contains?(process.command, duration)
               end)
             end)

    assert {_output, 0} = System.cmd("/bin/kill", ["-KILL", Integer.to_string(launcher_pid)])

    assert eventually?(
             fn ->
               terminal? =
                 match?(
                   {:ok, status} when status in [:killed, :failed],
                   Shell.get_status(session_id)
                 )

               terminal? and not os_process_alive?(target_pid) and
                 Enum.all?(os_processes(), &(&1.pgid != target_pgid))
             end,
             6_000
           )
  end

  test "security regression: malformed stdin fails without leaving the opened target alive" do
    duration = "23.#{100 + rem(System.unique_integer([:positive]), 900)}"

    assert {:error, :invalid_shell_input} =
             Shell.execute_direct("sleep", [duration],
               stdin: {:not, duration},
               sandbox: :none,
               timeout: 5_000
             )

    refute Enum.any?(os_processes(), &String.contains?(&1.command, "sleep #{duration}"))
  end

  test "security regression: public execute_direct survives abnormal port epipe from fast descendant-spawning command" do
    # On Linux, git daemon is a real /usr/bin/git executable that can close the
    # control pipe while still having spawned work. Base ProcessGroup linked the
    # native port to the arbitrary one-shot caller, so an asynchronous :epipe EXIT
    # killed the caller. The public facade must return a bounded fail-closed
    # result and leave the caller alive.
    parent = self()

    base_dir =
      Path.join(
        System.tmp_dir!(),
        "arbor_shell_git_daemon_base_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base_dir)
    base_flag = "--base-path=#{base_dir}"
    on_exit(fn -> File.rm_rf(base_dir) end)

    {caller, ref} =
      spawn_monitor(fn ->
        assert Process.info(self(), :trap_exit) == {:trap_exit, false}

        result =
          Shell.execute_direct(
            "git",
            [
              "daemon",
              "--reuseaddr",
              "--listen=127.0.0.1",
              "--port=0",
              base_flag,
              base_dir
            ],
            sandbox: :none,
            timeout: 50,
            clear_env: true,
            cwd: base_dir
          )

        send(parent, {:shell_result, self(), result})
        # Stay alive until the parent observes survival after the shell return.
        receive do
          :release -> :ok
        after
          5_000 -> :ok
        end
      end)

    receive do
      {:shell_result, ^caller, result} ->
        assert Process.alive?(caller)
        send(caller, :release)
        assert_receive {:DOWN, ^ref, :process, ^caller, :normal}, 2_000

        # Must reach shell execution and fail closed — not pass on setup misses
        # such as {:executable_not_found, _} or policy unavailability.
        assert {:ok, map} = result
        assert is_map(map)
        assert is_integer(map.exit_code)

        assert map.exit_code != 0 or map.timed_out or Map.get(map, :killed) == true or
                 Map.get(map, :containment_failure) == true

        # Match only a real git target with this unique base-path; never count
        # arbor_shell_launcher whose argv embeds the same flag during teardown.
        assert eventually?(fn ->
                 not Enum.any?(os_processes(), &leftover_target_git_daemon?(&1, base_flag))
               end)

      {:DOWN, ^ref, :process, ^caller, reason} ->
        flunk(
          "one-shot shell caller exited with #{inspect(reason)} instead of a controlled public result"
        )
    after
      10_000 ->
        flunk("timed out waiting for public execute_direct result or caller exit")
    end
  end

  test "security regression: public execute_direct does not return until process-group kill is proven" do
    # Force abnormal launcher death by SIGKILL, then inject two kill-helper
    # failures before the real kill. exit_status and {:EXIT, port, _} may arrive
    # in either order; both must prove exhaustion then return containment_failure.
    parent = self()
    duration = "31.#{100 + rem(System.unique_integer([:positive]), 900)}"
    attempts = :atomics.new(1, signed: false)
    :atomics.put(attempts, 1, 0)
    previous = Application.get_env(:arbor_shell, :process_group_kill_group_interceptor)

    Application.put_env(
      :arbor_shell,
      :process_group_kill_group_interceptor,
      fn group_id, real_kill ->
        n = :atomics.add_get(attempts, 1, 1)
        send(parent, {:kill_attempt, n, group_id})

        if n < 3 do
          {:error, {:kill_helper_failed, 1, "injected-containment-failure"}}
        else
          real_kill.(group_id)
        end
      end
    )

    try do
      task =
        Task.async(fn ->
          Shell.execute_direct("sleep", [duration], sandbox: :none, timeout: 15_000)
        end)

      launcher =
        eventually_value(fn ->
          Enum.find(os_processes(), fn process ->
            String.contains?(process.command, "arbor_shell_launcher exec") and
              String.contains?(process.command, duration)
          end)
        end)

      assert launcher
      assert {_out, 0} = System.cmd("/bin/kill", ["-KILL", Integer.to_string(launcher.pid)])

      started_wait = System.monotonic_time(:millisecond)
      assert {:ok, result} = Task.await(task, 15_000)
      elapsed = System.monotonic_time(:millisecond) - started_wait

      # Fail-closed containment terminal after proven kill — not a raw launcher error.
      assert result.exit_code == 137
      assert result.killed == true
      assert Map.get(result, :containment_failure) == true
      assert elapsed >= 150

      assert_receive {:kill_attempt, 1, group_id}, 2_000
      assert is_integer(group_id) and group_id > 0
      assert_receive {:kill_attempt, 2, ^group_id}, 2_000
      assert_receive {:kill_attempt, 3, ^group_id}, 2_000

      refute Enum.any?(os_processes(), &String.contains?(&1.command, "sleep #{duration}"))
    after
      restore(:arbor_shell, :process_group_kill_group_interceptor, previous)
    end
  end

  test "security regression: public execute_direct preserves caller trap_exit flag" do
    previous = Process.flag(:trap_exit, false)

    try do
      assert Process.info(self(), :trap_exit) == {:trap_exit, false}

      assert {:ok, _result} =
               Shell.execute_direct("echo", ["trap-exit-false"], sandbox: :none, timeout: 2_000)

      assert Process.info(self(), :trap_exit) == {:trap_exit, false}

      Process.flag(:trap_exit, true)

      assert {:ok, _result} =
               Shell.execute_direct("echo", ["trap-exit-true"], sandbox: :none, timeout: 2_000)

      assert Process.info(self(), :trap_exit) == {:trap_exit, true}
    after
      flush_exit_messages()
      Process.flag(:trap_exit, previous)
    end
  end

  test "security regression: raw legacy status mutation cannot forge terminal success" do
    assert {:ok, execution_id} =
             Shell.execute_async("sleep 2", sandbox: :none, timeout: 3_000)

    registry = Process.whereis(ExecutionRegistry)

    forged_reply =
      Task.async(fn ->
        raw_call(
          registry,
          {:transition_status, execution_id, [:pending, :running], :completed,
           %{result: %{exit_code: 0}}}
        )
      end)
      |> Task.await()

    refute forged_reply == :ok
    assert {:ok, :running} = Shell.get_status(execution_id)
    assert :ok = Shell.kill(execution_id)
  end

  defp fixture_root(tag) do
    Path.join(
      System.tmp_dir!(),
      "arbor_shell_reviewer_#{tag}_#{System.unique_integer([:positive])}"
    )
  end

  defp raw_call(registry, request) do
    ref = make_ref()
    send(registry, {:"$gen_call", {self(), ref}, request})

    receive do
      {^ref, reply} -> reply
    after
      1_000 -> :no_reply
    end
  end

  defp replace_executable_policy!(startup_path) do
    supervisor = Arbor.Shell.Supervisor

    case Supervisor.terminate_child(supervisor, ExecutablePolicy) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    case Supervisor.delete_child(supervisor, ExecutablePolicy) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    case Supervisor.start_child(
           supervisor,
           {ExecutablePolicy, startup_path: startup_path}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp eventually?(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp eventually_value(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually_value(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        do_eventually(fun, deadline)
    end
  end

  defp do_eventually_value(fun, deadline) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _other ->
        if System.monotonic_time(:millisecond) >= deadline do
          nil
        else
          Process.sleep(20)
          do_eventually_value(fun, deadline)
        end
    end
  end

  defp os_processes do
    {output, 0} = System.cmd("ps", ["-axo", "pid=,ppid=,pgid=,command="])

    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/, line) do
        [_, pid, ppid, pgid, command] ->
          [
            %{
              pid: String.to_integer(pid),
              ppid: String.to_integer(ppid),
              pgid: String.to_integer(pgid),
              command: command
            }
          ]

        _other ->
          []
      end
    end)
  end

  defp os_process_alive?(pid), do: Enum.any?(os_processes(), &(&1.pid == pid))

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp flush_exit_messages do
    receive do
      {:EXIT, _from, _reason} -> flush_exit_messages()
    after
      0 -> :ok
    end
  end

  # Live *target* git only: lead executable is git and argv contains this test's
  # unique absolute --base-path=... flag. Never treat arbor_shell_launcher as a
  # leaked target (its argv embeds the same flag during teardown).
  defp leftover_target_git_daemon?(%{command: command}, base_flag)
       when is_binary(command) and is_binary(base_flag) and base_flag != "" do
    not String.contains?(command, "arbor_shell_launcher") and
      Path.basename(lead_executable(command) || "") == "git" and
      String.contains?(command, base_flag)
  end

  defp leftover_target_git_daemon?(_other, _base_flag), do: false

  defp lead_executable(command) when is_binary(command) do
    command
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
  end
end
