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

  test "validation checks run compile, xref, MIX_ENV=test compile, then tests in order", %{
    worktree: worktree
  } do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha"])
    resource = %{id: "validation-resource-fixture"}

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

    assert {:ok, checks} =
             Shell.run_validation_checks(
               worktree,
               ["apps/alpha/test"],
               30_000,
               resource
             )

    assert checks.compile["passed"]
    assert checks.xref["passed"]
    assert checks.test_compile["passed"]
    assert checks.test["passed"]

    assert_receive {:mix_invocation, ^worktree, ["compile", "--warnings-as-errors"], dev_opts}
    assert Keyword.get(dev_opts, :validation_resource) == resource
    assert Keyword.get(dev_opts, :timeout) == 30_000
    refute match?(%{"MIX_ENV" => "test"}, Keyword.get(dev_opts, :env))

    assert_receive {:mix_invocation, ^worktree, ["xref", "graph"], xref_opts}
    assert Keyword.get(xref_opts, :validation_resource) == resource
    assert Keyword.get(xref_opts, :timeout) == 30_000

    assert_receive {:mix_invocation, ^worktree, ["compile", "--warnings-as-errors"], test_opts}
    assert Keyword.get(test_opts, :validation_resource) == resource
    assert Keyword.get(test_opts, :timeout) == 30_000
    assert Keyword.get(test_opts, :env) == %{"MIX_ENV" => "test"}

    assert_receive {:mix_invocation, ^worktree, ["test", "--", "apps/alpha/test"], test_run_opts}
    assert Keyword.get(test_run_opts, :validation_resource) == resource
    assert Keyword.get(test_run_opts, :timeout) == 30_000

    refute_received {:mix_invocation, _, _, _}
  end

  test "test-stage deadline starts only after successful MIX_ENV=test compile", %{
    worktree: worktree
  } do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha"])

    {:ok, clock_agent} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(clock_agent), do: Agent.stop(clock_agent)
    end)

    Application.put_env(:arbor_actions, :cross_app_monotonic_ms, fn ->
      Agent.get(clock_agent, & &1)
    end)

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts, Agent.get(clock_agent, & &1)})

      case args do
        ["compile", "--warnings-as-errors"] ->
          # Consume wall time during pre-test stages; must not start the shared
          # app-test deadline until after MIX_ENV=test compile succeeds.
          Agent.update(clock_agent, fn t -> t + 20_000 end)
          {:ok, %{exit_code: 0, stdout: "compile ok", stderr: "", timed_out: false}}

        ["xref", "graph"] ->
          Agent.update(clock_agent, fn t -> t + 20_000 end)
          {:ok, %{exit_code: 0, stdout: "xref ok", stderr: "", timed_out: false}}

        ["test", "--", "apps/alpha/test"] ->
          {:ok, %{exit_code: 0, stdout: "test ok", stderr: "", timed_out: false}}

        other ->
          flunk("unexpected mix invocation: #{inspect(other)}")
      end
    end)

    assert {:ok, checks} =
             Shell.run_validation_checks(worktree, ["apps/alpha/test"], 5_000, %{id: "res"})

    assert checks.compile["passed"]
    assert checks.xref["passed"]
    assert checks.test_compile["passed"]
    assert checks.test["passed"]

    # Two compile invocations (dev + test env) and xref consume 60_000ms of wall
    # clock before tests; the test stage still receives the full 5_000 budget.
    assert_receive {:mix_invocation, ["compile", "--warnings-as-errors"], dev_opts, 0}
    refute match?(%{"MIX_ENV" => "test"}, Keyword.get(dev_opts, :env))

    assert_receive {:mix_invocation, ["xref", "graph"], _xref_opts, 20_000}

    assert_receive {:mix_invocation, ["compile", "--warnings-as-errors"], test_compile_opts,
                    40_000}

    assert Keyword.get(test_compile_opts, :env) == %{"MIX_ENV" => "test"}

    assert_receive {:mix_invocation, ["test", "--", "apps/alpha/test"], test_opts, 60_000}
    assert Keyword.get(test_opts, :timeout) == 5_000
  end

  test "fail-closed skips later stages after compile, xref, or test_compile failure", %{
    worktree: worktree
  } do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha"])

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      send(parent, {:mix_invocation, args})

      case args do
        ["compile", "--warnings-as-errors"] ->
          {:ok, %{exit_code: 1, stdout: "compile fail", stderr: "", timed_out: false}}

        other ->
          flunk("must not run after compile failure: #{inspect(other)}")
      end
    end)

    assert {:ok, compile_fail} =
             Shell.run_validation_checks(worktree, ["apps/alpha/test"], 10_000, %{id: "res"})

    refute compile_fail.compile["passed"]
    assert compile_fail.xref["status"] == "skipped"
    assert compile_fail.test_compile["status"] == "skipped"
    assert compile_fail.test["status"] == "skipped"
    assert compile_fail.xref["reason"] == "compile_failed"
    assert compile_fail.test_compile["reason"] == "compile_failed"
    assert_receive {:mix_invocation, ["compile", "--warnings-as-errors"]}
    refute_received {:mix_invocation, _}

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})

      case args do
        ["compile", "--warnings-as-errors"] ->
          if Keyword.get(opts, :env) == %{"MIX_ENV" => "test"} do
            flunk("must not run test compile after xref failure")
          else
            {:ok, %{exit_code: 0, stdout: "compile ok", stderr: "", timed_out: false}}
          end

        ["xref", "graph"] ->
          {:ok, %{exit_code: 1, stdout: "xref fail", stderr: "", timed_out: false}}

        other ->
          flunk("must not run after xref failure: #{inspect(other)}")
      end
    end)

    assert {:ok, xref_fail} =
             Shell.run_validation_checks(worktree, ["apps/alpha/test"], 10_000, %{id: "res"})

    assert xref_fail.compile["passed"]
    refute xref_fail.xref["passed"]
    assert xref_fail.test_compile["status"] == "skipped"
    assert xref_fail.test["status"] == "skipped"
    assert xref_fail.test_compile["reason"] == "xref_failed"
    assert_receive {:mix_invocation, ["compile", "--warnings-as-errors"], _}
    assert_receive {:mix_invocation, ["xref", "graph"], _}
    refute_received {:mix_invocation, _, _}

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})

      case args do
        ["compile", "--warnings-as-errors"] ->
          if Keyword.get(opts, :env) == %{"MIX_ENV" => "test"} do
            {:ok, %{exit_code: 1, stdout: "test compile fail", stderr: "", timed_out: false}}
          else
            {:ok, %{exit_code: 0, stdout: "compile ok", stderr: "", timed_out: false}}
          end

        ["xref", "graph"] ->
          {:ok, %{exit_code: 0, stdout: "xref ok", stderr: "", timed_out: false}}

        ["test" | _] ->
          flunk("must not run tests after test_compile failure")

        other ->
          flunk("unexpected mix invocation: #{inspect(other)}")
      end
    end)

    assert {:ok, test_compile_fail} =
             Shell.run_validation_checks(worktree, ["apps/alpha/test"], 10_000, %{id: "res"})

    assert test_compile_fail.compile["passed"]
    assert test_compile_fail.xref["passed"]
    refute test_compile_fail.test_compile["passed"]
    assert test_compile_fail.test_compile["reason"] == "test_compile_failed"
    assert test_compile_fail.test["status"] == "skipped"
    assert test_compile_fail.test["reason"] == "test_compile_failed"

    assert_receive {:mix_invocation, ["compile", "--warnings-as-errors"], dev_opts}
    refute match?(%{"MIX_ENV" => "test"}, Keyword.get(dev_opts, :env))
    assert_receive {:mix_invocation, ["xref", "graph"], _}
    assert_receive {:mix_invocation, ["compile", "--warnings-as-errors"], test_opts}
    assert Keyword.get(test_opts, :env) == %{"MIX_ENV" => "test"}
    refute_received {:mix_invocation, _, _}

    evidence =
      Core.show(%{
        selection: %{
          changed_files: [],
          changed_apps: [],
          affected_apps: ["alpha"],
          test_paths: ["apps/alpha/test"],
          root_wide: false
        },
        checks: test_compile_fail,
        base_commit: "deadbeef"
      })

    refute evidence.passed
    assert evidence.reason == "test_compile_failed"
  end

  test "test execution errors include the exact selected path", %{worktree: worktree} do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha", "beta"])

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})

      case args do
        ["compile", "--warnings-as-errors"] ->
          {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}

        ["xref", "graph"] ->
          {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}

        ["test", "--", "apps/alpha/test"] ->
          {:ok, %{exit_code: 0, stdout: "alpha ok", stderr: "", timed_out: false}}

        ["test", "--", "apps/beta/test"] ->
          {:error, :operation_deadline_exceeded}

        other ->
          flunk("unexpected mix invocation: #{inspect(other)}")
      end
    end)

    assert {:error, {:test_execution_failed, "apps/beta/test", :operation_deadline_exceeded}} =
             Shell.run_validation_checks(
               worktree,
               ["apps/alpha/test", "apps/beta/test"],
               30_000,
               %{id: "res"}
             )

    assert_receive {:mix_invocation, ["compile", "--warnings-as-errors"], _}
    assert_receive {:mix_invocation, ["xref", "graph"], _}
    assert_receive {:mix_invocation, ["compile", "--warnings-as-errors"], test_compile_opts}
    assert Keyword.get(test_compile_opts, :env) == %{"MIX_ENV" => "test"}
    assert_receive {:mix_invocation, ["test", "--", "apps/alpha/test"], _}
    assert_receive {:mix_invocation, ["test", "--", "apps/beta/test"], _}
    refute_received {:mix_invocation, _, _}
  end

  defp mkdir_app_tests!(worktree, apps) do
    for app <- apps do
      File.mkdir_p!(Path.join(worktree, "apps/#{app}/test"))
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_actions, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_actions, key, value)
end
