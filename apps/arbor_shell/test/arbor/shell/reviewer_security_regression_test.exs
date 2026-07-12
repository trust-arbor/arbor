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
end
