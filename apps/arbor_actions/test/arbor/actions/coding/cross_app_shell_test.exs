defmodule Arbor.Actions.Coding.CrossApp.ShellTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.Coding.CrossApp.Core
  alias Arbor.Actions.Coding.CrossApp.Shell

  @moduletag :fast

  setup do
    previous_runner = Application.get_env(:arbor_actions, :cross_app_mix_runner)
    previous_clock = Application.get_env(:arbor_actions, :cross_app_monotonic_ms)

    on_exit(fn ->
      restore_env(:cross_app_mix_runner, previous_runner)
      restore_env(:cross_app_monotonic_ms, previous_clock)
    end)

    :ok
  end

  test "two affected app paths cause two separate single-path mix test invocations" do
    parent = self()
    worktree = System.tmp_dir!()

    alpha = Path.join(worktree, "apps/alpha/test")
    beta = Path.join(worktree, "apps/beta/test")
    File.mkdir_p!(alpha)
    File.mkdir_p!(beta)

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn path, args, opts ->
      send(parent, {:mix_invocation, path, args, opts})

      {:ok,
       %{
         exit_code: 0,
         stdout: "ok #{Enum.join(args, " ")}",
         stderr: "",
         timed_out: false
       }}
    end)

    check =
      Shell.run_app_tests(
        worktree,
        ["apps/alpha/test", "apps/beta/test"],
        30_000
      )

    assert check["passed"]
    assert check["reason"] == nil
    assert check["exit_code"] == 0

    assert_receive {:mix_invocation, ^worktree, ["test", "apps/alpha/test"], opts1}
    assert Keyword.get(opts1, :timeout) == 30_000

    assert_receive {:mix_invocation, ^worktree, ["test", "apps/beta/test"], opts2}
    assert is_integer(Keyword.get(opts2, :timeout))
    assert Keyword.get(opts2, :timeout) > 0
    assert Keyword.get(opts2, :timeout) <= 30_000

    # Never a single combined multi-root command.
    refute_received {:mix_invocation, _, ["test", "apps/alpha/test", "apps/beta/test"], _}
    refute_received {:mix_invocation, _, _}
  end

  test "stops after second-app failure and does not invoke remaining apps" do
    parent = self()
    worktree = System.tmp_dir!()

    for app <- ["alpha", "beta", "gamma"] do
      File.mkdir_p!(Path.join(worktree, "apps/#{app}/test"))
    end

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      send(parent, {:mix_invocation, args})

      case args do
        ["test", "apps/alpha/test"] ->
          {:ok, %{exit_code: 0, stdout: "alpha ok", stderr: "", timed_out: false}}

        ["test", "apps/beta/test"] ->
          {:ok, %{exit_code: 1, stdout: "beta fail", stderr: "", timed_out: false}}

        other ->
          flunk("unexpected mix invocation: #{inspect(other)}")
      end
    end)

    check =
      Shell.run_app_tests(
        worktree,
        ["apps/alpha/test", "apps/beta/test", "apps/gamma/test"],
        60_000
      )

    refute check["passed"]
    assert check["reason"] == "tests_failed"
    assert check["exit_code"] == 1
    assert String.contains?(check["stdout_excerpt"], "[apps/alpha/test]")
    assert String.contains?(check["stdout_excerpt"], "[apps/beta/test]")
    refute String.contains?(check["stdout_excerpt"], "[apps/gamma/test]")

    assert_receive {:mix_invocation, ["test", "apps/alpha/test"]}
    assert_receive {:mix_invocation, ["test", "apps/beta/test"]}
    refute_received {:mix_invocation, ["test", "apps/gamma/test"]}
  end

  test "total test-stage deadline exhaustion returns bounded timeout evidence" do
    parent = self()
    worktree = System.tmp_dir!()

    for app <- ["alpha", "beta"] do
      File.mkdir_p!(Path.join(worktree, "apps/#{app}/test"))
    end

    # Shared clock: stays at 0 until a mix run consumes the whole budget.
    {:ok, clock_agent} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(clock_agent), do: Agent.stop(clock_agent)
    end)

    Application.put_env(:arbor_actions, :cross_app_monotonic_ms, fn ->
      Agent.get(clock_agent, & &1)
    end)

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})
      # Consume the entire remaining budget so the next step times out.
      Agent.update(clock_agent, fn _ -> 10_000 end)

      {:ok, %{exit_code: 0, stdout: "alpha ok", stderr: "", timed_out: false}}
    end)

    check =
      Shell.run_app_tests(
        worktree,
        ["apps/alpha/test", "apps/beta/test"],
        5_000
      )

    refute check["passed"]
    assert check["reason"] == "tests_timed_out"
    assert String.contains?(check["stdout_excerpt"], "[apps/alpha/test]")
    assert String.contains?(check["stdout_excerpt"], "[apps/beta/test]")
    assert String.contains?(check["stdout_excerpt"], "budget exhausted")
    assert String.length(check["stdout_excerpt"]) <= Core.max_aggregate_excerpt()

    assert_receive {:mix_invocation, ["test", "apps/alpha/test"], opts}
    assert Keyword.get(opts, :timeout) == 5_000
    refute_received {:mix_invocation, ["test", "apps/beta/test"], _}
  end

  test "missing test directories yield empty pass without mix invocations" do
    parent = self()
    worktree = System.tmp_dir!()

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      send(parent, {:mix_invocation, args})
      {:ok, %{exit_code: 0, stdout: "", stderr: "", timed_out: false}}
    end)

    check =
      Shell.run_app_tests(
        worktree,
        ["apps/ghost/test", "apps/missing/test"],
        10_000
      )

    assert check["passed"]
    assert check["reason"] == "no_existing_test_dirs"
    refute_received {:mix_invocation, _}
  end

  test "no affected paths yield no_affected_app_tests without mix" do
    parent = self()

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      send(parent, {:mix_invocation, args})
      {:ok, %{exit_code: 0, stdout: "", stderr: "", timed_out: false}}
    end)

    check = Shell.run_app_tests(System.tmp_dir!(), [], 10_000)
    assert check["passed"]
    assert check["reason"] == "no_affected_app_tests"
    refute_received {:mix_invocation, _}
  end

  test "process timeout on first app stops and reports tests_timed_out" do
    parent = self()
    worktree = System.tmp_dir!()
    File.mkdir_p!(Path.join(worktree, "apps/alpha/test"))
    File.mkdir_p!(Path.join(worktree, "apps/beta/test"))

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      send(parent, {:mix_invocation, args})

      {:ok,
       %{
         exit_code: 137,
         stdout: "killed",
         stderr: "",
         timed_out: true
       }}
    end)

    check =
      Shell.run_app_tests(
        worktree,
        ["apps/alpha/test", "apps/beta/test"],
        10_000
      )

    refute check["passed"]
    assert check["reason"] == "tests_timed_out"
    assert check["exit_code"] == 137
    assert String.contains?(check["stdout_excerpt"], "[apps/alpha/test]")

    assert_receive {:mix_invocation, ["test", "apps/alpha/test"]}
    refute_received {:mix_invocation, ["test", "apps/beta/test"]}
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_actions, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_actions, key, value)
end
