defmodule Arbor.Actions.Coding.CrossApp.ShellTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.Coding.CrossApp.Core
  alias Arbor.Actions.Coding.CrossApp.Shell

  @moduletag :fast

  setup do
    previous_runner = Application.get_env(:arbor_actions, :cross_app_mix_runner)
    previous_clock = Application.get_env(:arbor_actions, :cross_app_monotonic_ms)

    worktree =
      Path.join(
        System.tmp_dir!(),
        "cross_app_shell_#{System.unique_integer([:positive])}_#{:erlang.phash2(self())}"
      )

    File.rm_rf!(worktree)
    File.mkdir_p!(worktree)

    on_exit(fn ->
      File.rm_rf!(worktree)
      restore_env(:cross_app_mix_runner, previous_runner)
      restore_env(:cross_app_monotonic_ms, previous_clock)
    end)

    %{worktree: worktree}
  end

  test "two affected app paths cause two separate single-path mix test invocations", %{
    worktree: worktree
  } do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha", "beta"])

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
    assert {:ok, _} = Jason.encode(check)

    assert_receive {:mix_invocation, ^worktree, ["test", "--", "apps/alpha/test"], opts1}
    assert Keyword.get(opts1, :timeout) == 30_000

    assert_receive {:mix_invocation, ^worktree, ["test", "--", "apps/beta/test"], opts2}
    assert is_integer(Keyword.get(opts2, :timeout))
    assert Keyword.get(opts2, :timeout) > 0
    assert Keyword.get(opts2, :timeout) <= 30_000

    # Never a single combined multi-root command.
    refute_received {:mix_invocation, _, ["test", "--", "apps/alpha/test", "apps/beta/test"], _}
    refute_received {:mix_invocation, _, _}
  end

  test "stops after second-app failure and preserves earlier evidence", %{worktree: worktree} do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha", "beta", "gamma"])

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      send(parent, {:mix_invocation, args})

      case args do
        ["test", "--", "apps/alpha/test"] ->
          {:ok, %{exit_code: 0, stdout: "alpha ok", stderr: "", timed_out: false}}

        ["test", "--", "apps/beta/test"] ->
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
    assert String.contains?(check["stdout_excerpt"], "alpha ok")
    assert String.contains?(check["stdout_excerpt"], "[apps/beta/test]")
    refute String.contains?(check["stdout_excerpt"], "[apps/gamma/test]")
    assert {:ok, _} = Jason.encode(check)

    assert_receive {:mix_invocation, ["test", "--", "apps/alpha/test"]}
    assert_receive {:mix_invocation, ["test", "--", "apps/beta/test"]}
    refute_received {:mix_invocation, ["test", "--", "apps/gamma/test"]}
  end

  test "child that consumes remaining budget is timed out; later children never launch", %{
    worktree: worktree
  } do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha", "beta"])

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
      # Consume the entire remaining budget so post-child deadline check fails.
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
    # Alpha itself overran the shared budget — classified as timeout, not pass.
    refute String.contains?(check["stdout_excerpt"], "budget exhausted before apps/beta")

    assert byte_size(check["stdout_excerpt"]) <= Core.max_aggregate_excerpt()

    assert {:ok, _} = Jason.encode(check)

    assert_receive {:mix_invocation, ["test", "--", "apps/alpha/test"], opts}
    assert Keyword.get(opts, :timeout) == 5_000
    refute_received {:mix_invocation, ["test", "--", "apps/beta/test"], _}
  end

  test "final child overrun after success-shaped runner result is still timed out", %{
    worktree: worktree
  } do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha", "omega"])

    {:ok, clock_agent} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(clock_agent), do: Agent.stop(clock_agent)
    end)

    Application.put_env(:arbor_actions, :cross_app_monotonic_ms, fn ->
      Agent.get(clock_agent, & &1)
    end)

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})

      case args do
        ["test", "--", "apps/alpha/test"] ->
          # Small advance; remaining budget stays positive.
          Agent.update(clock_agent, fn t -> t + 1_000 end)
          {:ok, %{exit_code: 0, stdout: "alpha ok", stderr: "", timed_out: false}}

        ["test", "--", "apps/omega/test"] ->
          # Final child returns success shape but consumes the shared deadline.
          Agent.update(clock_agent, fn _ -> 20_000 end)
          {:ok, %{exit_code: 0, stdout: "omega ok", stderr: "", timed_out: false}}

        other ->
          flunk("unexpected mix invocation: #{inspect(other)}")
      end
    end)

    check =
      Shell.run_app_tests(
        worktree,
        ["apps/alpha/test", "apps/omega/test"],
        5_000
      )

    refute check["passed"]
    assert check["reason"] == "tests_timed_out"
    # Earlier success evidence preserved.
    assert String.contains?(check["stdout_excerpt"], "[apps/alpha/test]")
    assert String.contains?(check["stdout_excerpt"], "alpha ok")
    assert String.contains?(check["stdout_excerpt"], "[apps/omega/test]")
    assert {:ok, _} = Jason.encode(check)

    assert_receive {:mix_invocation, ["test", "--", "apps/alpha/test"], opts1}
    assert Keyword.get(opts1, :timeout) == 5_000
    assert_receive {:mix_invocation, ["test", "--", "apps/omega/test"], opts2}
    assert Keyword.get(opts2, :timeout) == 4_000
    refute_received {:mix_invocation, _, _}
  end

  test "exact runner timed_out flag times out; text-only timeout string does not", %{
    worktree: worktree
  } do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha", "beta"])

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      send(parent, {:mix_invocation, args})

      case args do
        ["test", "--", "apps/alpha/test"] ->
          {:ok,
           %{
             exit_code: 1,
             stdout: "assertion failed after timeout waiting for process",
             stderr: "timeout in helper",
             timed_out: false
           }}

        other ->
          flunk("unexpected mix invocation: #{inspect(other)}")
      end
    end)

    text_fail =
      Shell.run_app_tests(
        worktree,
        ["apps/alpha/test", "apps/beta/test"],
        10_000
      )

    refute text_fail["passed"]
    assert text_fail["reason"] == "tests_failed"
    refute text_fail["reason"] == "tests_timed_out"
    assert String.contains?(text_fail["stdout_excerpt"], "timeout waiting")
    assert_receive {:mix_invocation, ["test", "--", "apps/alpha/test"]}
    refute_received {:mix_invocation, ["test", "--", "apps/beta/test"]}

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      send(parent, {:mix_invocation, {:exact, args}})

      {:ok,
       %{
         exit_code: 137,
         stdout: "killed",
         stderr: "",
         timed_out: true
       }}
    end)

    exact =
      Shell.run_app_tests(
        worktree,
        ["apps/alpha/test", "apps/beta/test"],
        10_000
      )

    refute exact["passed"]
    assert exact["reason"] == "tests_timed_out"
    assert_receive {:mix_invocation, {:exact, ["test", "--", "apps/alpha/test"]}}
    refute_received {:mix_invocation, {:exact, ["test", "--", "apps/beta/test"]}}
  end

  test "invalid UTF-8 process output is JSON-safe and hashed as raw bytes", %{worktree: worktree} do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha"])
    raw = "line1\n" <> <<0xFF, 0xFE>> <> "\nline2"
    raw_hash = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    stderr_raw = <<0x80, "bad">>
    stderr_hash = :crypto.hash(:sha256, stderr_raw) |> Base.encode16(case: :lower)

    expected_aggregate =
      :crypto.hash(
        :sha256,
        "apps/alpha/test\n" <> raw_hash
      )
      |> Base.encode16(case: :lower)

    expected_stderr_aggregate =
      :crypto.hash(
        :sha256,
        "apps/alpha/test\n" <> stderr_hash
      )
      |> Base.encode16(case: :lower)

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      send(parent, {:mix_invocation, args})
      {:ok, %{exit_code: 1, stdout: raw, stderr: stderr_raw, timed_out: false}}
    end)

    check =
      Shell.run_app_tests(
        worktree,
        ["apps/alpha/test"],
        10_000
      )

    refute check["passed"]
    assert check["reason"] == "tests_failed"
    # Aggregate digests are path + raw-byte stream digests (not the sanitized text).
    assert check["stdout_sha256"] == expected_aggregate
    assert check["stderr_sha256"] == expected_stderr_aggregate
    assert String.valid?(check["stdout_excerpt"])
    assert String.valid?(check["stderr_excerpt"])
    assert {:ok, encoded} = Jason.encode(check)
    assert is_binary(encoded)
    # Direct feedback path also preserves raw-byte hashing.
    feedback = Core.feedback_from_result(%{exit_code: 1, stdout: raw, stderr: stderr_raw})
    assert feedback["stdout_sha256"] == raw_hash
    assert feedback["stderr_sha256"] == stderr_hash
    assert_receive {:mix_invocation, ["test", "--", "apps/alpha/test"]}
  end

  test "multibyte excerpt bounds never split UTF-8 codepoints", %{worktree: worktree} do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha"])
    # 3000 bytes of 2-byte codepoints — forces truncation past the 2000-byte cap.
    huge = String.duplicate("é", 1_500)

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      send(parent, {:mix_invocation, args})
      {:ok, %{exit_code: 1, stdout: huge, stderr: "", timed_out: false}}
    end)

    check =
      Shell.run_app_tests(
        worktree,
        ["apps/alpha/test"],
        10_000
      )

    refute check["passed"]
    assert check["stdout_truncated"]
    assert byte_size(check["stdout_excerpt"]) <= Core.max_aggregate_excerpt()
    assert String.valid?(check["stdout_excerpt"])
    assert String.contains?(check["stdout_excerpt"], "...[omitted]...")
    assert {:ok, _} = Jason.encode(check)
    assert_receive {:mix_invocation, ["test", "--", "apps/alpha/test"]}
  end

  test "no launch after deadline is already exhausted", %{worktree: worktree} do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha", "beta"])

    # First clock read establishes deadline; subsequent reads are past it.
    {:ok, clock_agent} = Agent.start_link(fn -> {:init, 0} end)

    on_exit(fn ->
      if Process.alive?(clock_agent), do: Agent.stop(clock_agent)
    end)

    Application.put_env(:arbor_actions, :cross_app_monotonic_ms, fn ->
      Agent.get_and_update(clock_agent, fn
        {:init, t} -> {t, {:armed, t}}
        {:armed, t} -> {t + 10_000, {:armed, t}}
      end)
    end)

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      send(parent, {:mix_invocation, args})
      flunk("must not launch mix after deadline exhausted: #{inspect(args)}")
    end)

    check =
      Shell.run_app_tests(
        worktree,
        ["apps/alpha/test", "apps/beta/test"],
        5_000
      )

    refute check["passed"]
    assert check["reason"] == "tests_timed_out"
    assert String.contains?(check["stdout_excerpt"], "budget exhausted before apps/alpha/test")
    refute_received {:mix_invocation, _}
    assert {:ok, _} = Jason.encode(check)
  end

  test "missing test directories yield empty pass without mix invocations", %{worktree: worktree} do
    parent = self()

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

  test "no affected paths yield no_affected_app_tests without mix", %{worktree: worktree} do
    parent = self()

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      send(parent, {:mix_invocation, args})
      {:ok, %{exit_code: 0, stdout: "", stderr: "", timed_out: false}}
    end)

    check = Shell.run_app_tests(worktree, [], 10_000)
    assert check["passed"]
    assert check["reason"] == "no_affected_app_tests"
    refute_received {:mix_invocation, _}
  end

  test "process timeout on first app stops and reports tests_timed_out", %{worktree: worktree} do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha", "beta"])

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

    assert_receive {:mix_invocation, ["test", "--", "apps/alpha/test"]}
    refute_received {:mix_invocation, ["test", "--", "apps/beta/test"]}
  end

  defp mkdir_app_tests!(worktree, apps) do
    for app <- apps do
      File.mkdir_p!(Path.join(worktree, "apps/#{app}/test"))
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_actions, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_actions, key, value)
end
