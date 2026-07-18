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
    init_git_repo!(worktree)

    on_exit(fn ->
      File.rm_rf!(worktree)
      restore_env(:cross_app_mix_runner, previous_runner)
      restore_env(:cross_app_monotonic_ms, previous_clock)
    end)

    %{worktree: worktree}
  end

  test "two affected app files form one multi-file batch mix test invocation", %{
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

    # Two exact files pack into one argv-safe multi-file child under the runtime cap.
    expected_batch = [
      "test",
      "--",
      "apps/alpha/test/alpha_test.exs",
      "apps/beta/test/beta_test.exs"
    ]

    assert_receive {:mix_invocation, ^worktree, ^expected_batch, opts1}
    assert Keyword.get(opts1, :timeout) == 30_000

    # Never a raw directory; only exact admitted file paths.
    refute_received {:mix_invocation, _, ["test", "--", "apps/alpha/test"], _}
    refute_received {:mix_invocation, _, ["test", "--", "apps/alpha/test/alpha_test.exs"], _}
    refute_received {:mix_invocation, _, ["test", "--", "apps/beta/test/beta_test.exs"], _}
    refute_received {:mix_invocation, _, _}
  end

  test "stops after first failed batch and preserves earlier batch evidence", %{
    worktree: worktree
  } do
    parent = self()
    # Force two batches via file count so fail-fast can stop before the second.
    paths = write_numbered_tests!(worktree, "alpha", Core.max_test_batch_files() + 1)
    assert length(paths) == Core.max_test_batch_files() + 1

    assert {:ok, [batch1, batch2]} = Core.partition_test_batches(paths)

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      send(parent, {:mix_invocation, args})

      case args do
        ["test", "--" | batch_paths] when batch_paths == batch1.paths ->
          {:ok, %{exit_code: 0, stdout: "batch1 ok", stderr: "", timed_out: false}}

        ["test", "--" | batch_paths] when batch_paths == batch2.paths ->
          {:ok, %{exit_code: 1, stdout: "batch2 fail", stderr: "", timed_out: false}}

        other ->
          flunk("unexpected mix invocation: #{inspect(other)}")
      end
    end)

    check =
      Shell.run_app_tests(
        worktree,
        ["apps/alpha/test"],
        60_000
      )

    refute check["passed"]
    assert check["reason"] == "tests_failed"
    assert check["exit_code"] == 1
    assert String.contains?(check["stdout_excerpt"], "[#{batch1.label}]")
    assert String.contains?(check["stdout_excerpt"], "batch1 ok")
    assert String.contains?(check["stdout_excerpt"], "[#{batch2.label}]")
    assert String.contains?(check["stdout_excerpt"], "batch2 fail")
    assert {:ok, _} = Jason.encode(check)

    assert_receive {:mix_invocation, ["test", "--" | received1]}
    assert received1 == batch1.paths
    assert_receive {:mix_invocation, ["test", "--" | received2]}
    assert received2 == batch2.paths
    refute_received {:mix_invocation, _}
  end

  test "child that consumes remaining budget is timed out; later batches never launch", %{
    worktree: worktree
  } do
    parent = self()
    paths = write_numbered_tests!(worktree, "alpha", Core.max_test_batch_files() + 1)
    assert {:ok, [batch1, batch2]} = Core.partition_test_batches(paths)

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

      {:ok, %{exit_code: 0, stdout: "batch1 ok", stderr: "", timed_out: false}}
    end)

    check =
      Shell.run_app_tests(
        worktree,
        ["apps/alpha/test"],
        5_000
      )

    refute check["passed"]
    assert check["reason"] == "tests_timed_out"
    assert String.contains?(check["stdout_excerpt"], "[#{batch1.label}]")
    # First batch itself overran the shared budget — classified as timeout, not pass.
    refute String.contains?(
             check["stdout_excerpt"],
             "budget exhausted before #{batch2.label}"
           )

    assert byte_size(check["stdout_excerpt"]) <= Core.max_aggregate_excerpt()

    assert {:ok, _} = Jason.encode(check)

    assert_receive {:mix_invocation, ["test", "--" | received], opts}
    assert received == batch1.paths
    assert Keyword.get(opts, :timeout) == 5_000
    refute_received {:mix_invocation, _, _}
  end

  test "final batch overrun after success-shaped runner result is still timed out", %{
    worktree: worktree
  } do
    parent = self()
    paths = write_numbered_tests!(worktree, "alpha", Core.max_test_batch_files() + 1)
    assert {:ok, [batch1, batch2]} = Core.partition_test_batches(paths)

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
        ["test", "--" | batch_paths] when batch_paths == batch1.paths ->
          # Small advance; remaining budget stays positive.
          Agent.update(clock_agent, fn t -> t + 1_000 end)
          {:ok, %{exit_code: 0, stdout: "batch1 ok", stderr: "", timed_out: false}}

        ["test", "--" | batch_paths] when batch_paths == batch2.paths ->
          # Final batch returns success shape but consumes the shared deadline.
          Agent.update(clock_agent, fn _ -> 20_000 end)
          {:ok, %{exit_code: 0, stdout: "batch2 ok", stderr: "", timed_out: false}}

        other ->
          flunk("unexpected mix invocation: #{inspect(other)}")
      end
    end)

    check =
      Shell.run_app_tests(
        worktree,
        ["apps/alpha/test"],
        5_000
      )

    refute check["passed"]
    assert check["reason"] == "tests_timed_out"
    # Earlier success evidence preserved.
    assert String.contains?(check["stdout_excerpt"], "[#{batch1.label}]")
    assert String.contains?(check["stdout_excerpt"], "batch1 ok")
    assert String.contains?(check["stdout_excerpt"], "[#{batch2.label}]")
    assert {:ok, _} = Jason.encode(check)

    assert_receive {:mix_invocation, ["test", "--" | r1], opts1}
    assert r1 == batch1.paths
    assert Keyword.get(opts1, :timeout) == 5_000
    assert_receive {:mix_invocation, ["test", "--" | r2], opts2}
    assert r2 == batch2.paths
    assert Keyword.get(opts2, :timeout) == 4_000
    refute_received {:mix_invocation, _, _}
  end

  test "exact runner timed_out flag times out; text-only timeout string does not", %{
    worktree: worktree
  } do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha"])

    assert {:ok, [batch]} =
             Core.partition_test_batches([
               "apps/alpha/test/alpha_test.exs"
             ])

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      send(parent, {:mix_invocation, args})

      case args do
        ["test", "--" | paths] when paths == batch.paths ->
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
        ["apps/alpha/test"],
        10_000
      )

    refute text_fail["passed"]
    assert text_fail["reason"] == "tests_failed"
    refute text_fail["reason"] == "tests_timed_out"
    assert String.contains?(text_fail["stdout_excerpt"], "timeout waiting")
    assert_receive {:mix_invocation, ["test", "--" | received]}
    assert received == batch.paths
    refute_received {:mix_invocation, _}

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
        ["apps/alpha/test"],
        10_000
      )

    refute exact["passed"]
    assert exact["reason"] == "tests_timed_out"
    assert_receive {:mix_invocation, {:exact, ["test", "--" | exact_paths]}}
    assert exact_paths == batch.paths
    refute_received {:mix_invocation, _}
  end

  test "invalid UTF-8 process output is JSON-safe and hashed as raw bytes", %{worktree: worktree} do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha"])
    raw = "line1\n" <> <<0xFF, 0xFE>> <> "\nline2"
    raw_hash = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    stderr_raw = <<0x80, "bad">>
    stderr_hash = :crypto.hash(:sha256, stderr_raw) |> Base.encode16(case: :lower)

    assert {:ok, [batch]} = Core.partition_test_batches(["apps/alpha/test/alpha_test.exs"])

    expected_aggregate =
      :crypto.hash(
        :sha256,
        batch.label <> "\n" <> raw_hash
      )
      |> Base.encode16(case: :lower)

    expected_stderr_aggregate =
      :crypto.hash(
        :sha256,
        batch.label <> "\n" <> stderr_hash
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
    # Aggregate digests are batch label + raw-byte stream digests (not the sanitized text).
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
    assert_receive {:mix_invocation, ["test", "--", "apps/alpha/test/alpha_test.exs"]}
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
    assert_receive {:mix_invocation, ["test", "--", "apps/alpha/test/alpha_test.exs"]}
  end

  test "no launch after deadline is already exhausted", %{worktree: worktree} do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha", "beta"])

    assert {:ok, [batch]} =
             Core.partition_test_batches([
               "apps/alpha/test/alpha_test.exs",
               "apps/beta/test/beta_test.exs"
             ])

    assert batch.count == 2

    assert batch.paths == [
             "apps/alpha/test/alpha_test.exs",
             "apps/beta/test/beta_test.exs"
           ]

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

    assert String.contains?(
             check["stdout_excerpt"],
             "budget exhausted before #{batch.label}"
           )

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
    assert check["reason"] == "no_existing_test_files"
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

  test "process timeout on first batch stops and reports tests_timed_out", %{worktree: worktree} do
    parent = self()
    paths = write_numbered_tests!(worktree, "alpha", Core.max_test_batch_files() + 1)
    assert {:ok, [batch1, batch2]} = Core.partition_test_batches(paths)

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
        ["apps/alpha/test"],
        10_000
      )

    refute check["passed"]
    assert check["reason"] == "tests_timed_out"
    assert check["exit_code"] == 137
    assert String.contains?(check["stdout_excerpt"], "[#{batch1.label}]")

    assert_receive {:mix_invocation, ["test", "--" | received]}
    assert received == batch1.paths
    # Fail-fast: second batch never launches after first times out.
    refute_received {:mix_invocation, _}
    assert batch2.index == 2
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
    assert Keyword.get(dev_opts, :resource_profile) == :intensive
    refute match?(%{"MIX_ENV" => "test"}, Keyword.get(dev_opts, :env))

    assert_receive {:mix_invocation, ^worktree, ["xref", "graph"], xref_opts}
    assert Keyword.get(xref_opts, :validation_resource) == resource
    assert Keyword.get(xref_opts, :timeout) == 30_000
    assert Keyword.get(xref_opts, :resource_profile) == :intensive

    assert_receive {:mix_invocation, ^worktree, ["compile", "--warnings-as-errors"], test_opts}
    assert Keyword.get(test_opts, :validation_resource) == resource
    assert Keyword.get(test_opts, :timeout) == 30_000
    assert Keyword.get(test_opts, :resource_profile) == :intensive
    assert Keyword.get(test_opts, :env) == %{"MIX_ENV" => "test"}

    assert_receive {:mix_invocation, ^worktree, ["test", "--", "apps/alpha/test/alpha_test.exs"],
                    test_run_opts}

    assert Keyword.get(test_run_opts, :validation_resource) == resource
    assert Keyword.get(test_run_opts, :timeout) == 30_000
    assert Keyword.get(test_run_opts, :resource_profile) == :intensive

    refute_received {:mix_invocation, _, _, _}
  end

  test "operation timeout above 600000 reaches Mix execution with resource_profile intensive", %{
    worktree: worktree
  } do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha"])
    resource = %{id: "validation-resource-intensive-timeout"}
    standard_ceiling = Arbor.Shell.spawn_capable_max_timeout_ms()
    assert standard_ceiling == 600_000
    assert {:ok, intensive_ceiling} = Arbor.Shell.spawn_capable_max_timeout_ms(:intensive)
    assert intensive_ceiling == 1_200_000
    # Above standard Shell ceiling, within intensive cross_app action ceiling.
    operation_timeout = standard_ceiling + 1
    assert operation_timeout == 600_001
    assert operation_timeout <= Core.maximum_timeout()

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
               operation_timeout,
               intensive_ceiling,
               resource
             )

    assert checks.compile["passed"]
    assert checks.xref["passed"]
    assert checks.test_compile["passed"]
    assert checks.test["passed"]

    # Last-mile: every contained Mix stage carries the above-standard timeout
    # and the system-owned intensive resource profile (not caller-selectable).
    assert_receive {:mix_invocation, ^worktree, ["compile", "--warnings-as-errors"], dev_opts}
    assert Keyword.get(dev_opts, :timeout) == operation_timeout
    assert Keyword.get(dev_opts, :resource_profile) == :intensive

    assert_receive {:mix_invocation, ^worktree, ["xref", "graph"], xref_opts}
    assert Keyword.get(xref_opts, :timeout) == operation_timeout
    assert Keyword.get(xref_opts, :resource_profile) == :intensive

    assert_receive {:mix_invocation, ^worktree, ["compile", "--warnings-as-errors"], test_opts}
    assert Keyword.get(test_opts, :timeout) == operation_timeout
    assert Keyword.get(test_opts, :resource_profile) == :intensive
    assert Keyword.get(test_opts, :env) == %{"MIX_ENV" => "test"}

    assert_receive {:mix_invocation, ^worktree, ["test", "--", "apps/alpha/test/alpha_test.exs"],
                    test_run_opts}

    assert Keyword.get(test_run_opts, :timeout) == operation_timeout
    assert Keyword.get(test_run_opts, :resource_profile) == :intensive

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

        ["test", "--", "apps/alpha/test/alpha_test.exs"] ->
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

    assert_receive {:mix_invocation, ["test", "--", "apps/alpha/test/alpha_test.exs"], test_opts,
                    60_000}

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

  test "test execution errors identify the deterministic batch label, not path lists", %{
    worktree: worktree
  } do
    parent = self()
    paths = write_numbered_tests!(worktree, "alpha", Core.max_test_batch_files() + 1)
    assert {:ok, [batch1, batch2]} = Core.partition_test_batches(paths)

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})

      case args do
        ["compile", "--warnings-as-errors"] ->
          {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}

        ["xref", "graph"] ->
          {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}

        ["test", "--" | batch_paths] when batch_paths == batch1.paths ->
          {:ok, %{exit_code: 0, stdout: "batch1 ok", stderr: "", timed_out: false}}

        ["test", "--" | batch_paths] when batch_paths == batch2.paths ->
          {:error, :operation_deadline_exceeded}

        other ->
          flunk("unexpected mix invocation: #{inspect(other)}")
      end
    end)

    assert {:error, {:test_execution_failed, label, :operation_deadline_exceeded}} =
             Shell.run_validation_checks(
               worktree,
               ["apps/alpha/test"],
               30_000,
               %{id: "res"}
             )

    assert label == batch2.label
    refute String.contains?(label, "apps/alpha/test/f")
    assert String.starts_with?(label, "batch-")

    assert_receive {:mix_invocation, ["compile", "--warnings-as-errors"], _}
    assert_receive {:mix_invocation, ["xref", "graph"], _}
    assert_receive {:mix_invocation, ["compile", "--warnings-as-errors"], test_compile_opts}
    assert Keyword.get(test_compile_opts, :env) == %{"MIX_ENV" => "test"}
    assert_receive {:mix_invocation, ["test", "--" | r1], _}
    assert r1 == batch1.paths
    assert_receive {:mix_invocation, ["test", "--" | r2], _}
    assert r2 == batch2.paths
    refute_received {:mix_invocation, _, _}
  end

  test "expands app test dirs into multi-file batch mix invocations under closed limits", %{
    worktree: worktree
  } do
    parent = self()
    dir = Path.join(worktree, "apps/alpha/test")
    File.mkdir_p!(Path.join(dir, "nested"))
    File.write!(Path.join(dir, "z_test.exs"), "defmodule ZTest do\nend\n")
    File.write!(Path.join(dir, "a_test.exs"), "defmodule ATest do\nend\n")
    File.write!(Path.join([dir, "nested", "m_test.exs"]), "defmodule MTest do\nend\n")
    File.write!(Path.join(dir, "helper.exs"), "defmodule Helper do\nend\n")

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})
      {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}
    end)

    check = Shell.run_app_tests(worktree, ["apps/alpha/test"], 30_000, 60_000)
    assert check["passed"]

    # Runtime batch cap admits up to 20 exact files; three-file inventory is one child.
    assert Core.max_test_batch_files() == 20
    assert Core.max_test_batch_runtime_files() == 20

    expected_batch = [
      "test",
      "--",
      "apps/alpha/test/a_test.exs",
      "apps/alpha/test/nested/m_test.exs",
      "apps/alpha/test/z_test.exs"
    ]

    assert_receive {:mix_invocation, ^expected_batch, opts1}
    assert Keyword.get(opts1, :timeout) == 30_000
    refute_received {:mix_invocation, ["test", "--", "apps/alpha/test/helper.exs"], _}
    refute_received {:mix_invocation, _, _}
  end

  test "verified files above the runtime batch cap split into within-limit invocations", %{
    worktree: worktree
  } do
    parent = self()
    count = Core.max_test_batch_files() + 5
    paths = write_numbered_tests!(worktree, "alpha", count)
    assert {:ok, batches} = Core.partition_test_batches(paths)
    assert length(batches) == 2
    assert Enum.at(batches, 0).count == Core.max_test_batch_files()
    assert Enum.at(batches, 1).count == 5
    assert Enum.flat_map(batches, & &1.paths) == paths

    assert Core.max_test_batch_runtime_files() == 20

    assert Core.max_test_batch_files() ==
             min(Core.max_test_batch_runtime_files(), Core.max_test_batch_argv_files())

    assert Core.max_test_batch_argv_files() ==
             Arbor.Shell.spawn_capable_max_command_args() - 2

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})
      {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}
    end)

    check = Shell.run_app_tests(worktree, ["apps/alpha/test"], 10_000, 100_000)
    assert check["passed"]

    for batch <- batches do
      assert_receive {:mix_invocation, ["test", "--" | received], opts}
      assert received == batch.paths
      assert length(received) == batch.count
      assert length(received) <= Core.max_test_batch_files()
      assert length(received) <= Core.max_test_batch_runtime_files()
      # Full argv remains inside Shell's closed admission ceiling.
      assert length(["test", "--" | received]) <=
               Arbor.Shell.spawn_capable_max_command_args()

      arg_bytes = Enum.reduce(received, 0, fn p, acc -> acc + byte_size(p) + 1 end)
      assert arg_bytes <= Core.max_test_batch_arg_bytes()
      assert Keyword.get(opts, :timeout) == 10_000
    end

    refute_received {:mix_invocation, _, _}
  end

  test "operation timeout caps each batch below remaining aggregate stage budget", %{
    worktree: worktree
  } do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha", "beta"])

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})
      {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}
    end)

    check = Shell.run_app_tests(worktree, ["apps/alpha/test", "apps/beta/test"], 10_000, 100_000)
    assert check["passed"]

    expected_batch = [
      "test",
      "--",
      "apps/alpha/test/alpha_test.exs",
      "apps/beta/test/beta_test.exs"
    ]

    assert_receive {:mix_invocation, ^expected_batch, opts1}
    assert Keyword.get(opts1, :timeout) == 10_000
    refute_received {:mix_invocation, _, _}
  end

  test "gitignored test files are excluded from expansion inventory", %{worktree: worktree} do
    parent = self()
    dir = Path.join(worktree, "apps/alpha/test")
    File.mkdir_p!(dir)
    File.write!(Path.join(worktree, ".gitignore"), "_generated_test.exs\n")
    File.write!(Path.join(dir, "kept_test.exs"), "defmodule KeptTest do\nend\n")
    File.write!(Path.join(dir, "_generated_test.exs"), "defmodule GeneratedTest do\nend\n")

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})
      {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}
    end)

    check = Shell.run_app_tests(worktree, ["apps/alpha/test"], 10_000, 20_000)
    assert check["passed"]

    assert_receive {:mix_invocation, ["test", "--", "apps/alpha/test/kept_test.exs"], _}
    refute_received {:mix_invocation, ["test", "--", "apps/alpha/test/_generated_test.exs"], _}
    refute_received {:mix_invocation, _, _}
  end

  test "malformed next_test_step input becomes an execution error, not silent success", %{
    worktree: worktree
  } do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha"])

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      send(parent, {:mix_invocation, args})
      flunk("must not run mix with malformed step: #{inspect(args)}")
    end)

    # operation_timeout 0 is malformed for next_test_step; Shell must not complete
    # the stage as a silent pass after expansion finds real files.
    thrown = catch_throw(Shell.run_app_tests(worktree, ["apps/alpha/test"], 0, 10_000))

    assert match?(
             {:execution_error, {:invalid_test_step, {:invalid_test_step_input, _}}},
             thrown
           )

    refute_received {:mix_invocation, _}

    # Public validation checks surface converts the throw into {:error, reason}.
    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      case args do
        ["compile", "--warnings-as-errors"] ->
          {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}

        ["xref", "graph"] ->
          {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}

        other ->
          flunk("must not run tests with malformed step: #{inspect(other)}")
      end
    end)

    assert {:error, {:invalid_test_step, {:invalid_test_step_input, _}}} =
             Shell.run_validation_checks(worktree, ["apps/alpha/test"], 0, 10_000, %{id: "r"})
  end

  test "symlink test files fail closed without launching mix tests", %{worktree: worktree} do
    parent = self()
    dir = Path.join(worktree, "apps/alpha/test")
    File.mkdir_p!(dir)
    real = Path.join(worktree, "outside_test.exs")
    File.write!(real, "defmodule Outside do\nend\n")
    link = Path.join(dir, "linked_test.exs")
    File.ln_s!(real, link)

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})

      case args do
        ["compile", "--warnings-as-errors"] ->
          {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}

        ["xref", "graph"] ->
          {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}

        other ->
          flunk("must not run tests after symlink enumeration: #{inspect(other)}")
      end
    end)

    assert {:error, {:test_file_enumeration_failed, {:symlink_rejected, :path_component, rel}}} =
             Shell.run_validation_checks(worktree, ["apps/alpha/test"], 10_000, 20_000, %{id: "r"})

    assert rel == "apps/alpha/test/linked_test.exs"
    refute_received {:mix_invocation, ["test" | _], _}
  end

  test "aggregate stage budget is independent of pre-test compile wall time", %{
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
          Agent.update(clock_agent, fn t -> t + 50_000 end)
          {:ok, %{exit_code: 0, stdout: "compile ok", stderr: "", timed_out: false}}

        ["xref", "graph"] ->
          Agent.update(clock_agent, fn t -> t + 50_000 end)
          {:ok, %{exit_code: 0, stdout: "xref ok", stderr: "", timed_out: false}}

        ["test", "--", "apps/alpha/test/alpha_test.exs"] ->
          {:ok, %{exit_code: 0, stdout: "test ok", stderr: "", timed_out: false}}

        other ->
          flunk("unexpected mix invocation: #{inspect(other)}")
      end
    end)

    # Per-op 5s, aggregate stage 8s — pre-test stages burn 150s of wall clock
    # but must not reduce the aggregate stage budget started after test compile.
    assert {:ok, checks} =
             Shell.run_validation_checks(worktree, ["apps/alpha/test"], 5_000, 8_000, %{id: "res"})

    assert checks.test["passed"]

    assert_receive {:mix_invocation, ["test", "--", "apps/alpha/test/alpha_test.exs"], test_opts,
                    _}

    assert Keyword.get(test_opts, :timeout) == 5_000
  end

  defp mkdir_app_tests!(worktree, apps) do
    for app <- apps do
      dir = Path.join(worktree, "apps/#{app}/test")
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "#{app}_test.exs"),
        "defmodule #{Macro.camelize(app)}Test do\nend\n"
      )
    end
  end

  defp write_numbered_tests!(worktree, app, count)
       when is_binary(app) and is_integer(count) and count > 0 do
    dir = Path.join(worktree, "apps/#{app}/test")
    File.mkdir_p!(dir)

    for i <- 1..count do
      name = "f#{String.pad_leading(Integer.to_string(i), 4, "0")}_test.exs"
      File.write!(Path.join(dir, name), "defmodule F#{i}Test do\nend\n")
      "apps/#{app}/test/#{name}"
    end
  end

  defp init_git_repo!(worktree) do
    {_, 0} = System.cmd("git", ["init"], cd: worktree, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@arbor.local"], cd: worktree)
    {_, 0} = System.cmd("git", ["config", "user.name", "CrossApp Test"], cd: worktree)
    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_actions, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_actions, key, value)
end
