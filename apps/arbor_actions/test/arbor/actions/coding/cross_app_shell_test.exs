defmodule Arbor.Actions.Coding.CrossApp.ShellTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.Coding.CrossApp.Core
  alias Arbor.Actions.Coding.CrossApp.Shell

  @moduletag :fast

  setup do
    previous_runner = Application.get_env(:arbor_actions, :cross_app_mix_runner)
    previous_clock = Application.get_env(:arbor_actions, :cross_app_monotonic_ms)
    previous_after_freeze = Application.get_env(:arbor_actions, :cross_app_after_candidate_freeze)

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
      restore_env(:cross_app_after_candidate_freeze, previous_after_freeze)
    end)

    %{worktree: worktree}
  end

  test "two affected app files form separate per-app batch mix test invocations", %{
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
        60_000,
        120_000
      )

    assert check["passed"]
    assert check["reason"] == nil
    assert check["exit_code"] == 0
    assert {:ok, _} = Jason.encode(check)

    # App test root boundary forces separate per-app batches.
    assert_receive {:mix_invocation, ^worktree, alpha_batch, opts_a}
    assert alpha_batch == ["test", "--", "apps/alpha/test/alpha_test.exs"]
    assert Keyword.get(opts_a, :timeout) == 60_000

    assert_receive {:mix_invocation, ^worktree, beta_batch, opts_b}
    assert beta_batch == ["test", "--", "apps/beta/test/beta_test.exs"]
    assert Keyword.get(opts_b, :timeout) == 60_000

    # Never a raw directory; only exact admitted file paths.
    refute_received {:mix_invocation, _, ["test", "--", "apps/alpha/test"], _}
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
        60_000,
        120_000
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

  test "ceiling-sum exceeding stage budget still launches the first child", %{
    worktree: worktree
  } do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha", "beta"])

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})
      {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}
    end)

    # 2 app batches * 5_000 ceiling > 5_000 stage budget, but residual > 0.
    check =
      Shell.run_app_tests(
        worktree,
        ["apps/alpha/test", "apps/beta/test"],
        5_000,
        5_000
      )

    assert check["passed"] == true
    assert_receive {:mix_invocation, ["test", "--" | _paths], opts}
    assert Keyword.get(opts, :timeout) == 5_000
    assert_receive {:mix_invocation, ["test", "--" | _], _}
  end

  test "exhausted residual before first child hands off structurally without launch", %{
    worktree: worktree
  } do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha", "beta"])

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      send(parent, {:unexpected_mix_invocation, args})
      flunk("exhausted residual must not launch a child")
    end)

    # test_stage_timeout 0 => available residual 0 before first child.
    check =
      Shell.run_app_tests(
        worktree,
        ["apps/alpha/test", "apps/beta/test"],
        5_000,
        0
      )

    assert check["reason"] == "validation_capacity_exceeded"
    assert check["capacity_handoff"]["schema_version"] == 3
    assert check["capacity_handoff"]["phase"] == "structural"
    assert check["capacity_handoff"]["available_budget_ms"] == 0
    assert check["capacity_handoff"]["completed_batch_count"] == 0
    assert check["capacity_handoff"]["unstarted_file_count"] == 2
    assert check["capacity_handoff"]["interrupted_batch"] == nil
    refute Map.has_key?(check["capacity_handoff"], "required_budget_ms")
    assert {:ok, _} = Jason.encode(check)
    refute_received {:unexpected_mix_invocation, _}
  end

  test "runtime capacity exhaustion hands off after completed child", %{
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
      Shell.run_app_tests(worktree, ["apps/alpha/test"], 5_000, 10_000)

    refute check["passed"]
    assert check["reason"] == "validation_capacity_exceeded"
    assert check["capacity_handoff"]["schema_version"] == 3
    assert check["capacity_handoff"]["phase"] == "runtime"
    assert check["capacity_handoff"]["available_budget_ms"] == 0
    assert check["capacity_handoff"]["completed_batch_count"] == 1
    assert check["capacity_handoff"]["unstarted_batch_count"] == 1
    assert check["capacity_handoff"]["interrupted_batch"] == nil
    refute Map.has_key?(check["capacity_handoff"], "required_budget_ms")
    assert check["stdout_excerpt"] == ""

    assert check["capacity_handoff"]["unstarted_batches"] == [
             %{
               "index" => batch2.index,
               "total" => batch2.total,
               "count" => batch2.count,
               "label" => batch2.label,
               "inventory_sha256" => batch2.inventory_sha256
             }
           ]

    refute Map.has_key?(hd(check["capacity_handoff"]["unstarted_batches"]), "paths")

    assert byte_size(check["stdout_excerpt"]) <= Core.max_aggregate_excerpt()

    assert {:ok, _} = Jason.encode(check)

    assert_receive {:mix_invocation, ["test", "--" | received], opts}
    assert received == batch1.paths
    assert Keyword.get(opts, :timeout) == 5_000
    refute_received {:mix_invocation, _, _}
  end

  test "passing final batch that consumes aggregate budget remains success", %{
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
          # Final batch returns success and consumes the shared deadline.
          Agent.update(clock_agent, fn _ -> 20_000 end)
          {:ok, %{exit_code: 0, stdout: "batch2 ok", stderr: "", timed_out: false}}

        other ->
          flunk("unexpected mix invocation: #{inspect(other)}")
      end
    end)

    check =
      Shell.run_app_tests(worktree, ["apps/alpha/test"], 5_000, 10_000)

    # Design G: passing final child is completed success even at residual zero.
    assert check["passed"]
    refute check["reason"] == "tests_timed_out"
    refute Map.has_key?(check, "capacity_handoff")
    assert String.contains?(check["stdout_excerpt"], "[#{batch1.label}]")
    assert String.contains?(check["stdout_excerpt"], "batch1 ok")
    assert String.contains?(check["stdout_excerpt"], "[#{batch2.label}]")
    assert {:ok, _} = Jason.encode(check)

    assert_receive {:mix_invocation, ["test", "--" | r1], opts1}
    assert r1 == batch1.paths
    assert Keyword.get(opts1, :timeout) == 5_000
    assert_receive {:mix_invocation, ["test", "--" | r2], opts2}
    assert r2 == batch2.paths
    assert Keyword.get(opts2, :timeout) == 5_000
    refute_received {:mix_invocation, _, _}
  end

  test "aggregate-deadline interruption emits interrupted middle handoff", %{
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

    # operation_timeout 10_000, aggregate 5_000 => first child budget is 5_000 < op.
    # Runner times out with residual exhausted => aggregate interruption of batch1.
    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})
      Agent.update(clock_agent, fn _ -> 10_000 end)
      {:ok, %{exit_code: nil, stdout: "", stderr: "", timed_out: true}}
    end)

    check = Shell.run_app_tests(worktree, ["apps/alpha/test"], 10_000, 5_000)

    refute check["passed"]
    assert check["reason"] == "validation_capacity_exceeded"
    handoff = check["capacity_handoff"]
    assert handoff["schema_version"] == 3
    assert handoff["phase"] == "runtime"
    assert handoff["interrupted_batch"]["index"] == batch1.index

    assert handoff["unstarted_batches"] == [
             %{
               "index" => batch2.index,
               "total" => batch2.total,
               "count" => batch2.count,
               "label" => batch2.label,
               "inventory_sha256" => batch2.inventory_sha256
             }
           ]

    refute Map.has_key?(handoff["interrupted_batch"], "paths")
    assert_receive {:mix_invocation, ["test", "--" | received], opts}
    assert received == batch1.paths
    assert Keyword.get(opts, :timeout) == 5_000
    refute_received {:mix_invocation, _, _}
  end

  test "aggregate-deadline interruption of final batch emits empty suffix handoff", %{
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
          Agent.update(clock_agent, fn _ -> 1_000 end)
          {:ok, %{exit_code: 0, stdout: "batch1 ok", stderr: "", timed_out: false}}

        ["test", "--" | batch_paths] when batch_paths == batch2.paths ->
          Agent.update(clock_agent, fn _ -> 5_000 end)
          {:ok, %{exit_code: nil, stdout: "", stderr: "", timed_out: true}}

        other ->
          flunk("unexpected mix invocation: #{inspect(other)}")
      end
    end)

    check = Shell.run_app_tests(worktree, ["apps/alpha/test"], 10_000, 5_000)

    refute check["passed"]
    assert check["reason"] == "validation_capacity_exceeded"
    handoff = check["capacity_handoff"]
    assert handoff["phase"] == "runtime"
    assert handoff["completed_batch_count"] == 1
    assert handoff["interrupted_batch"]["index"] == batch2.index
    assert handoff["unstarted_batch_count"] == 0
    assert handoff["unstarted_file_count"] == 0
    assert handoff["unstarted_batches"] == []
    refute Map.has_key?(handoff["interrupted_batch"], "paths")

    assert_receive {:mix_invocation, ["test", "--" | received1], opts1}
    assert received1 == batch1.paths
    assert Keyword.get(opts1, :timeout) == 5_000

    assert_receive {:mix_invocation, ["test", "--" | received2], opts2}
    assert received2 == batch2.paths
    assert Keyword.get(opts2, :timeout) == 4_000
    refute_received {:mix_invocation, _, _}
  end

  test "equal-ceiling runner timeout remains ordinary tests_timed_out", %{
    worktree: worktree
  } do
    parent = self()
    paths = write_numbered_tests!(worktree, "alpha", Core.max_test_batch_files() + 1)
    assert {:ok, [batch1, _batch2]} = Core.partition_test_batches(paths)

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})
      {:ok, %{exit_code: nil, stdout: "", stderr: "", timed_out: true}}
    end)

    # Equal ceilings: budget_ms == operation_timeout => ordinary child timeout.
    check = Shell.run_app_tests(worktree, ["apps/alpha/test"], 5_000, 5_000)

    refute check["passed"]
    assert check["reason"] == "tests_timed_out"
    refute Map.has_key?(check, "capacity_handoff")
    assert_receive {:mix_invocation, ["test", "--" | received], opts}
    assert received == batch1.paths
    assert Keyword.get(opts, :timeout) == 5_000
  end

  test "security regression: prelaunch probe_timeout with exhausted aggregate budget hands off unstarted suffix",
       %{worktree: worktree} do
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
          Agent.update(clock_agent, fn _ -> 10_000 end)
          # Live Mix.invoke_spawn_capable/4 inspects spawn-capable errors.
          {:error, ":probe_timeout"}

        other ->
          flunk("must not retry or launch a later child: #{inspect(other)}")
      end
    end)

    check = Shell.run_app_tests(worktree, ["apps/alpha/test"], 10_000, 5_000)

    refute check["passed"]
    assert check["reason"] == "validation_capacity_exceeded"
    handoff = check["capacity_handoff"]
    assert Arbor.Contracts.Coding.ValidationCapacityHandoff.valid?(handoff)
    assert {:ok, _} = Jason.encode(check)
    assert handoff["schema_version"] == 3
    assert handoff["phase"] == "runtime"
    assert handoff["available_budget_ms"] == 0
    assert handoff["interrupted_batch"] == nil
    refute Map.has_key?(handoff, "required_budget_ms")
    assert handoff["completed_batch_count"] == 0
    assert handoff["completed_file_count"] == 0
    assert handoff["unstarted_batch_count"] == 2
    assert handoff["unstarted_file_count"] == length(paths)

    assert handoff["unstarted_batches"] == [
             compact_capacity_batch(batch1),
             compact_capacity_batch(batch2)
           ]

    refute Map.has_key?(hd(handoff["unstarted_batches"]), "paths")

    assert_receive {:mix_invocation, ["test", "--" | received], opts}
    assert received == batch1.paths
    assert Keyword.get(opts, :timeout) == 5_000
    refute_received {:mix_invocation, _, _}
  end

  test "prelaunch probe_timeout with remaining aggregate budget stays a test execution failure",
       %{
         worktree: worktree
       } do
    parent = self()
    paths = write_numbered_tests!(worktree, "alpha", Core.max_test_batch_files() + 1)
    assert {:ok, [batch1, _batch2]} = Core.partition_test_batches(paths)

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
          {:error, :probe_timeout}

        other ->
          flunk("must not retry or launch a later child: #{inspect(other)}")
      end
    end)

    assert {:execution_error, {:test_execution_failed, label, :probe_timeout}} =
             catch_throw(Shell.run_app_tests(worktree, ["apps/alpha/test"], 10_000, 5_000))

    assert label == batch1.label
    assert_receive {:mix_invocation, ["test", "--" | received], opts}
    assert received == batch1.paths
    assert Keyword.get(opts, :timeout) == 5_000
    refute_received {:mix_invocation, _, _}
  end

  test "later-batch prelaunch probe_timeout with exhausted budget hands off remaining unstarted suffix",
       %{worktree: worktree} do
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
          Agent.update(clock_agent, fn t -> t + 1_000 end)
          {:ok, %{exit_code: 0, stdout: "batch1 ok", stderr: "", timed_out: false}}

        ["test", "--" | batch_paths] when batch_paths == batch2.paths ->
          Agent.update(clock_agent, fn _ -> 10_000 end)
          {:error, :probe_timeout}

        other ->
          flunk("must not retry or launch a later child: #{inspect(other)}")
      end
    end)

    check = Shell.run_app_tests(worktree, ["apps/alpha/test"], 10_000, 5_000)

    refute check["passed"]
    assert check["reason"] == "validation_capacity_exceeded"
    handoff = check["capacity_handoff"]
    assert Arbor.Contracts.Coding.ValidationCapacityHandoff.valid?(handoff)
    assert handoff["phase"] == "runtime"
    assert handoff["completed_batch_count"] == 1
    assert handoff["interrupted_batch"] == nil
    assert handoff["unstarted_batches"] == [compact_capacity_batch(batch2)]
    refute Map.has_key?(hd(handoff["unstarted_batches"]), "paths")

    assert_receive {:mix_invocation, ["test", "--" | received1], opts1}
    assert received1 == batch1.paths
    assert Keyword.get(opts1, :timeout) == 5_000
    assert_receive {:mix_invocation, ["test", "--" | received2], opts2}
    assert received2 == batch2.paths
    assert Keyword.get(opts2, :timeout) == 4_000
    refute_received {:mix_invocation, _, _}
  end

  test "exhausted residual does not convert other probe or deadline errors into capacity", %{
    worktree: worktree
  } do
    parent = self()
    paths = write_numbered_tests!(worktree, "alpha", Core.max_test_batch_files() + 1)
    assert {:ok, [batch1, _batch2]} = Core.partition_test_batches(paths)

    {:ok, clock_agent} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(clock_agent), do: Agent.stop(clock_agent)
    end)

    Application.put_env(:arbor_actions, :cross_app_monotonic_ms, fn ->
      Agent.get(clock_agent, & &1)
    end)

    Enum.each([:probe_failed, :operation_deadline_exceeded], fn injected_reason ->
      Agent.update(clock_agent, fn _ -> 0 end)

      Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, opts ->
        send(parent, {:mix_invocation, args, opts, injected_reason})

        case args do
          ["test", "--" | batch_paths] when batch_paths == batch1.paths ->
            Agent.update(clock_agent, fn _ -> 10_000 end)
            {:error, injected_reason}

          other ->
            flunk("must not retry or launch a later child: #{inspect(other)}")
        end
      end)

      assert {:execution_error, {:test_execution_failed, label, ^injected_reason}} =
               catch_throw(Shell.run_app_tests(worktree, ["apps/alpha/test"], 10_000, 5_000))

      assert label == batch1.label
      assert_receive {:mix_invocation, ["test", "--" | received], opts, ^injected_reason}
      assert received == batch1.paths
      assert Keyword.get(opts, :timeout) == 5_000
    end)

    refute_received {:mix_invocation, _, _, _}
  end

  test "equal-ceiling prelaunch probe_timeout with exhausted residual is unstarted capacity", %{
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
          Agent.update(clock_agent, fn _ -> 5_000 end)
          {:error, :probe_timeout}

        other ->
          flunk("must not retry or launch a later child: #{inspect(other)}")
      end
    end)

    check = Shell.run_app_tests(worktree, ["apps/alpha/test"], 5_000, 5_000)

    refute check["passed"]
    refute check["reason"] == "tests_timed_out"
    assert check["reason"] == "validation_capacity_exceeded"
    handoff = check["capacity_handoff"]
    assert Arbor.Contracts.Coding.ValidationCapacityHandoff.valid?(handoff)
    assert handoff["phase"] == "runtime"
    assert handoff["interrupted_batch"] == nil

    assert handoff["unstarted_batches"] == [
             compact_capacity_batch(batch1),
             compact_capacity_batch(batch2)
           ]

    assert_receive {:mix_invocation, ["test", "--" | received], opts}
    assert received == batch1.paths
    assert Keyword.get(opts, :timeout) == 5_000
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

    assert {:ok, [alpha_batch, beta_batch]} =
             Core.partition_test_batches([
               "apps/alpha/test/alpha_test.exs",
               "apps/beta/test/beta_test.exs"
             ])

    assert alpha_batch.count == 1
    assert alpha_batch.paths == ["apps/alpha/test/alpha_test.exs"]
    assert beta_batch.count == 1
    assert beta_batch.paths == ["apps/beta/test/beta_test.exs"]

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
        5_000,
        10_000
      )

    refute check["passed"]
    assert check["reason"] == "validation_capacity_exceeded"
    assert check["capacity_handoff"]["schema_version"] == 3
    assert check["capacity_handoff"]["phase"] == "runtime"
    assert check["capacity_handoff"]["available_budget_ms"] == 0
    assert check["capacity_handoff"]["interrupted_batch"] == nil
    refute Map.has_key?(check["capacity_handoff"], "required_budget_ms")

    assert check["capacity_handoff"]["unstarted_batches"] == [
             %{
               "index" => alpha_batch.index,
               "total" => alpha_batch.total,
               "count" => alpha_batch.count,
               "label" => alpha_batch.label,
               "inventory_sha256" => alpha_batch.inventory_sha256
             },
             %{
               "index" => beta_batch.index,
               "total" => beta_batch.total,
               "count" => beta_batch.count,
               "label" => beta_batch.label,
               "inventory_sha256" => beta_batch.inventory_sha256
             }
           ]

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
        10_000,
        20_000
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

  test "run_validation_checks list arities remain compatible for direct test-path lists", %{
    worktree: worktree
  } do
    parent = self()
    mkdir_app_tests!(worktree, ["alpha"])
    resource = %{id: "run-validation-list-arity"}

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      send(parent, {:validation_invocation, args})

      {:ok,
       %{
         exit_code: 0,
         stdout: "ok #{Enum.join(args, " ")}",
         stderr: "",
         timed_out: false
       }}
    end)

    assert {:ok, checks_3} = Shell.run_validation_checks(worktree, ["apps/alpha/test"], 30_000)
    assert checks_3.test["passed"]
    assert_receive {:validation_invocation, ["compile", "--warnings-as-errors"]}
    assert_receive {:validation_invocation, ["xref", "graph"]}
    assert_receive {:validation_invocation, ["compile", "--warnings-as-errors"]}
    assert_receive {:validation_invocation, ["test", "--", "apps/alpha/test/alpha_test.exs"]}

    # 4-arity with resource map (legacy selection seam)
    assert {:ok, checks_4_resource} =
             Shell.run_validation_checks(
               worktree,
               ["apps/alpha/test"],
               30_000,
               resource
             )

    assert checks_4_resource.test["passed"]

    # 4-arity with explicit test-stage timeout
    assert {:ok, checks_4_timeout} =
             Shell.run_validation_checks(worktree, ["apps/alpha/test"], 30_000, 40_000)

    assert checks_4_timeout.test["passed"]

    # 5-arity with explicit test-stage timeout + resource
    assert {:ok, checks_5} =
             Shell.run_validation_checks(
               worktree,
               ["apps/alpha/test"],
               30_000,
               40_000,
               resource
             )

    assert checks_5.test["passed"]

    # 6-arity map/list-aware stage timeout + resource
    assert {:ok, checks_6} =
             Shell.run_validation_checks(
               worktree,
               ["apps/alpha/test"],
               30_000,
               40_000,
               50_000,
               resource
             )

    assert checks_6.test["passed"]
  end

  test "whole-validation deadline caps each pre-test child from one monotonic budget", %{
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
      now = Agent.get(clock_agent, & &1)
      send(parent, {:mix_invocation, args, opts, now})

      case args do
        ["compile", "--warnings-as-errors"] ->
          Agent.update(clock_agent, &(&1 + 1_000))
          {:ok, %{exit_code: 0, stdout: "compile ok", stderr: "", timed_out: false}}

        ["xref", "graph"] ->
          {:ok, %{exit_code: 1, stdout: "xref failed", stderr: "", timed_out: false}}

        other ->
          flunk("unexpected mix invocation: #{inspect(other)}")
      end
    end)

    assert {:ok, checks} =
             Shell.run_validation_checks(
               worktree,
               ["apps/alpha/test"],
               10_000,
               20_000,
               5_000,
               %{id: "res"}
             )

    assert checks.compile["passed"]
    refute checks.xref["passed"]

    assert_receive {:mix_invocation, ["compile", "--warnings-as-errors"], compile_opts, 0}
    assert Keyword.get(compile_opts, :timeout) == 5_000

    assert_receive {:mix_invocation, ["xref", "graph"], xref_opts, 1_000}
    assert Keyword.get(xref_opts, :timeout) == 4_000
    refute_received {:mix_invocation, _, _, _}
  end

  test "direct changed app executes before alphabetically earlier downstream app in test stage",
       %{
         worktree: worktree
       } do
    parent = self()
    mkdir_app_tests!(worktree, ["arbor_actions", "arbor_security"])

    selection = %{
      changed_files: ["apps/arbor_security/lib/security.ex"],
      changed_apps: ["arbor_security"],
      affected_apps: ["arbor_actions", "arbor_security"],
      test_paths: ["apps/arbor_actions/test", "apps/arbor_security/test"],
      root_wide: false
    }

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})

      cond do
        args == ["compile", "--warnings-as-errors"] and
            Keyword.get(opts, :env) == %{"MIX_ENV" => "test"} ->
          {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}

        args == ["compile", "--warnings-as-errors"] ->
          {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}

        args == ["xref", "graph"] ->
          {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}

        args == ["test", "--", "apps/arbor_security/test/arbor_security_test.exs"] ->
          {:ok, %{exit_code: 0, stdout: "security ok", stderr: "", timed_out: false}}

        args == ["test", "--", "apps/arbor_actions/test/arbor_actions_test.exs"] ->
          {:ok, %{exit_code: 0, stdout: "actions ok", stderr: "", timed_out: false}}

        true ->
          flunk("unexpected mix invocation: #{inspect(args)}")
      end
    end)

    assert {:ok, checks} =
             Shell.run_validation_checks(
               worktree,
               selection,
               30_000,
               30_000,
               60_000,
               %{id: "res"}
             )

    assert checks.test["passed"]
    assert checks.test["reason"] == nil
    refute checks.test["reason"] == "no_existing_test_files"

    assert_receive {:mix_invocation, ["compile", "--warnings-as-errors"], _dev_opts}
    assert_receive {:mix_invocation, ["xref", "graph"], _xref_opts}
    assert_receive {:mix_invocation, ["compile", "--warnings-as-errors"], _test_compile_opts}

    assert_receive {:mix_invocation,
                    ["test", "--", "apps/arbor_security/test/arbor_security_test.exs"] =
                      security_args, security_run_opts}

    assert_receive {:mix_invocation,
                    ["test", "--", "apps/arbor_actions/test/arbor_actions_test.exs"],
                    _actions_test}

    assert Enum.drop(security_args, 2) != []
    assert Keyword.get(security_run_opts, :timeout) == 30_000
    refute_received {:mix_invocation, ["test", "--", _], _}
  end

  test "malformed or incomplete app selection fails before any Mix invocation", %{
    worktree: worktree
  } do
    parent = self()
    mkdir_app_tests!(worktree, ["arbor_actions", "arbor_security"])

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      send(parent, {:unexpected_mix_invocation, args})
      {:ok, %{exit_code: 0, stdout: "unexpected", stderr: "", timed_out: false}}
    end)

    duplicate_metadata = %{
      changed_apps: ["arbor_security"],
      affected_apps: ["arbor_security", "arbor_security"],
      test_paths: ["apps/arbor_security/test"]
    }

    assert {:error, {:invalid_validation_selection, :invalid_app_order_input}} =
             Shell.run_validation_checks(
               worktree,
               duplicate_metadata,
               30_000,
               30_000,
               nil
             )

    incomplete_inventory = %{
      changed_apps: ["arbor_security"],
      affected_apps: ["arbor_actions", "arbor_security"],
      test_paths: ["apps/arbor_security/test"]
    }

    assert {:error, {:invalid_validation_selection, :invalid_app_order_input}} =
             Shell.run_validation_checks(
               worktree,
               incomplete_inventory,
               30_000,
               30_000,
               nil
             )

    refute_received {:unexpected_mix_invocation, _}
  end

  test "run_app_tests rejects malformed canonical conversion input before filesystem enumeration",
       %{worktree: worktree} do
    mkdir_app_tests!(worktree, ["arbor_actions"])

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, _opts ->
      flunk("must fail closed before mix invocation: #{inspect(args)}")
    end)

    thrown =
      catch_throw(
        Shell.run_app_tests(
          worktree,
          ["apps/arbor_security", "apps/arbor_actions"],
          10_000,
          20_000
        )
      )

    assert match?(
             {:execution_error,
              {:invalid_test_dir, ["apps/arbor_security", "apps/arbor_actions"]}},
             thrown
           )
  end

  test "direct-first completed batch is preserved when downstream batch is handed off", %{
    worktree: worktree
  } do
    parent = self()
    mkdir_app_tests!(worktree, ["arbor_actions", "arbor_security"])

    selection = %{
      changed_files: ["apps/arbor_security/lib/security.ex"],
      changed_apps: ["arbor_security"],
      affected_apps: ["arbor_actions", "arbor_security"],
      test_paths: ["apps/arbor_actions/test", "apps/arbor_security/test"],
      root_wide: false
    }

    {:ok, clock_agent} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(clock_agent), do: Agent.stop(clock_agent)
    end)

    Application.put_env(:arbor_actions, :cross_app_monotonic_ms, fn ->
      Agent.get(clock_agent, & &1)
    end)

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})

      cond do
        args == ["compile", "--warnings-as-errors"] ->
          {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}

        args == ["xref", "graph"] ->
          {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}

        args == ["test", "--", "apps/arbor_security/test/arbor_security_test.exs"] ->
          Agent.update(clock_agent, fn _ -> 10_000 end)
          {:ok, %{exit_code: 0, stdout: "security ok", stderr: "", timed_out: false}}

        args == ["test", "--", "apps/arbor_actions/test/arbor_actions_test.exs"] ->
          flunk("downstream batch must not launch after runtime cap")

        true ->
          {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}
      end
    end)

    assert {:ok, checks} =
             Shell.run_validation_checks(
               worktree,
               selection,
               5_000,
               5_000,
               20_000,
               %{id: "res"}
             )

    assert checks.test["passed"] == false
    assert checks.test["reason"] == "validation_capacity_exceeded"
    handoff = checks.test["capacity_handoff"]
    assert handoff["completed_batch_count"] == 1
    assert handoff["unstarted_batch_count"] == 1
    assert handoff["interrupted_batch"] == nil
    assert handoff["phase"] == "runtime"

    assert {:ok, [_security_batch, actions_batch]} =
             Core.partition_test_batches(
               [
                 "apps/arbor_security/test/arbor_security_test.exs",
                 "apps/arbor_actions/test/arbor_actions_test.exs"
               ],
               ["arbor_security", "arbor_actions"]
             )

    assert handoff["unstarted_batches"] == [
             %{
               "index" => actions_batch.index,
               "total" => actions_batch.total,
               "count" => actions_batch.count,
               "label" => actions_batch.label,
               "inventory_sha256" => actions_batch.inventory_sha256
             }
           ]

    assert_receive {:mix_invocation, ["compile", "--warnings-as-errors"], _}
    assert_receive {:mix_invocation, ["xref", "graph"], _}
    assert_receive {:mix_invocation, ["compile", "--warnings-as-errors"], _}

    assert_receive {:mix_invocation,
                    ["test", "--", "apps/arbor_security/test/arbor_security_test.exs"], _}

    refute_received {:mix_invocation,
                     ["test", "--", "apps/arbor_actions/test/arbor_actions_test.exs"], _}
  end

  test "whole-validation deadline rejects an overrun immediately after a child", %{
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
      send(parent, {:mix_invocation, args, opts})
      Agent.update(clock_agent, fn _ -> 5_000 end)
      {:ok, %{exit_code: 0, stdout: "late success", stderr: "", timed_out: false}}
    end)

    assert {:error, {:validation_stage_timeout, :compile}} =
             Shell.run_validation_checks(
               worktree,
               ["apps/alpha/test"],
               10_000,
               20_000,
               5_000,
               %{id: "res"}
             )

    assert_receive {:mix_invocation, ["compile", "--warnings-as-errors"], opts}
    assert Keyword.get(opts, :timeout) == 5_000
    refute_received {:mix_invocation, _, _}
  end

  test "success-shaped final test remains complete at the whole-validation deadline", %{
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
      send(parent, {:mix_invocation, args, opts})

      case args do
        ["compile", "--warnings-as-errors"] ->
          {:ok, %{exit_code: 0, stdout: "compile ok", stderr: "", timed_out: false}}

        ["xref", "graph"] ->
          {:ok, %{exit_code: 0, stdout: "xref ok", stderr: "", timed_out: false}}

        ["test", "--", "apps/alpha/test/alpha_test.exs"] ->
          Agent.update(clock_agent, fn _ -> 5_000 end)
          {:ok, %{exit_code: 0, stdout: "late test success", stderr: "", timed_out: false}}

        other ->
          flunk("unexpected mix invocation: #{inspect(other)}")
      end
    end)

    assert {:ok, checks} =
             Shell.run_validation_checks(
               worktree,
               ["apps/alpha/test"],
               5_000,
               20_000,
               5_000,
               %{id: "res"}
             )

    assert checks.test["passed"]
    assert checks.test["reason"] == nil

    assert_receive {:mix_invocation, ["test", "--", "apps/alpha/test/alpha_test.exs"], test_opts}
    assert Keyword.get(test_opts, :timeout) == 5_000
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
               60_000,
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

    # Runtime batch cap admits up to 5 exact files; three-file inventory is one child.
    assert Core.max_test_batch_files() == 5
    assert Core.max_test_batch_runtime_files() == 5

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

    assert Core.max_test_batch_runtime_files() == 5

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

    # App root boundary forces separate per-app batches.
    assert_receive {:mix_invocation, alpha_args, opts_a}
    assert alpha_args == ["test", "--", "apps/alpha/test/alpha_test.exs"]
    assert Keyword.get(opts_a, :timeout) == 10_000

    assert_receive {:mix_invocation, beta_args, opts_b}
    assert beta_args == ["test", "--", "apps/beta/test/beta_test.exs"]
    assert Keyword.get(opts_b, :timeout) == 10_000

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

  test "deleted tracked test files are excluded from candidate test inventory", %{
    worktree: worktree
  } do
    parent = self()
    dir = Path.join(worktree, "apps/alpha/test")
    kept = Path.join(dir, "kept_test.exs")
    deleted = Path.join(dir, "deleted_test.exs")
    File.mkdir_p!(dir)
    File.write!(kept, "defmodule KeptTest do\nend\n")
    File.write!(deleted, "defmodule DeletedTest do\nend\n")
    _base = git_commit_all!(worktree, "track tests before candidate deletion")
    File.rm!(deleted)

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})
      {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}
    end)

    check = Shell.run_app_tests(worktree, ["apps/alpha/test"], 10_000, 20_000)
    assert check["passed"]

    assert_receive {:mix_invocation, ["test", "--", "apps/alpha/test/kept_test.exs"], _}
    refute_received {:mix_invocation, ["test", "--", "apps/alpha/test/deleted_test.exs"], _}
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

  test "resolve_selection: base app removed or merged forces full remaining candidate", %{
    worktree: worktree
  } do
    write_app_mix!(worktree, "alpha", [])
    write_app_mix!(worktree, "beta", ["alpha"])
    write_app_lib!(worktree, "alpha")
    write_app_lib!(worktree, "beta")
    mkdir_app_tests!(worktree, ["alpha", "beta"])
    base = git_commit_all!(worktree, "base with alpha+beta")

    # Merge/delete beta in candidate (committed dirty surface).
    File.rm_rf!(Path.join(worktree, "apps/beta"))
    write_app_lib!(worktree, "alpha", "changed")
    _cand = git_commit_all!(worktree, "candidate drops beta")

    assert {:ok, resolved} = Shell.resolve_selection(worktree, base)
    selection = resolved.selection

    assert selection.topology_change.changed?
    assert selection.topology_change.removed_apps == ["beta"]
    assert selection.affected_apps == ["alpha"]
    assert selection.test_paths == ["apps/alpha/test"]
    refute "apps/beta/test" in selection.test_paths
    assert is_binary(resolved.candidate_tree_oid)
    assert resolved.candidate_tree_oid != ""
  end

  test "resolve_selection: path unknown to both base and candidate fails closed", %{
    worktree: worktree
  } do
    write_app_mix!(worktree, "alpha", [])
    write_app_lib!(worktree, "alpha")
    base = git_commit_all!(worktree, "base alpha only")

    ghost_dir = Path.join(worktree, "apps/ghost/lib")
    File.mkdir_p!(ghost_dir)
    File.write!(Path.join(ghost_dir, "x.ex"), "defmodule Ghost do\nend\n")

    assert {:error, {:changed_unknown_app, "ghost"}} =
             Shell.resolve_selection(worktree, base)
  end

  test "resolve_selection: ordinary same-topology change retains focused selection", %{
    worktree: worktree
  } do
    write_app_mix!(worktree, "alpha", [])
    write_app_mix!(worktree, "beta", ["alpha"])
    write_app_mix!(worktree, "delta", [])
    write_app_lib!(worktree, "alpha")
    write_app_lib!(worktree, "beta")
    write_app_lib!(worktree, "delta")
    base = git_commit_all!(worktree, "base topology")

    write_app_lib!(worktree, "alpha", "focused-change")

    assert {:ok, resolved} = Shell.resolve_selection(worktree, base)
    selection = resolved.selection

    refute selection.topology_change.changed?
    assert selection.changed_apps == ["alpha"]
    assert selection.affected_apps == ["alpha", "beta"]
    assert selection.test_paths == ["apps/alpha/test", "apps/beta/test"]
    refute "delta" in selection.affected_apps
  end

  test "resolve_selection: dependency-edge change forces full candidate", %{worktree: worktree} do
    write_app_mix!(worktree, "alpha", [])
    write_app_mix!(worktree, "gamma", [])
    write_app_mix!(worktree, "delta", [])
    write_app_lib!(worktree, "alpha")
    write_app_lib!(worktree, "gamma")
    write_app_lib!(worktree, "delta")
    base = git_commit_all!(worktree, "base edges")

    write_app_mix!(worktree, "gamma", ["alpha"])

    assert {:ok, resolved} = Shell.resolve_selection(worktree, base)
    selection = resolved.selection

    assert selection.topology_change.changed?
    assert selection.topology_change.edge_changed_apps == ["gamma"]
    assert selection.affected_apps == ["alpha", "delta", "gamma"]
  end

  test "resolve_selection: unstaged app deletion omits app without read failure", %{
    worktree: worktree
  } do
    write_app_mix!(worktree, "alpha", [])
    write_app_mix!(worktree, "beta", ["alpha"])
    write_app_lib!(worktree, "alpha")
    write_app_lib!(worktree, "beta")
    base = git_commit_all!(worktree, "base both")

    # Unstaged deletion: index still lists beta; disk is gone.
    File.rm_rf!(Path.join(worktree, "apps/beta"))

    assert {:ok, resolved} = Shell.resolve_selection(worktree, base)
    selection = resolved.selection

    assert selection.topology_change.changed?
    assert selection.topology_change.removed_apps == ["beta"]
    assert selection.affected_apps == ["alpha"]
    refute "apps/beta/test" in selection.test_paths
    dirs = Enum.map(resolved.candidate_app_mix_exs, fn {dir, _} -> dir end)
    assert dirs == ["alpha"]
  end

  test "resolve_selection: untracked new app is included in candidate freeze", %{
    worktree: worktree
  } do
    write_app_mix!(worktree, "alpha", [])
    write_app_lib!(worktree, "alpha")
    base = git_commit_all!(worktree, "base alpha")

    # Untracked new app (not git-added).
    write_app_mix!(worktree, "omega", [])
    write_app_lib!(worktree, "omega")
    mkdir_app_tests!(worktree, ["omega"])

    assert {:ok, resolved} = Shell.resolve_selection(worktree, base)
    selection = resolved.selection

    assert selection.topology_change.changed?
    assert selection.topology_change.added_apps == ["omega"]
    assert "omega" in selection.affected_apps
    assert "apps/omega/test" in selection.test_paths
    dirs = Enum.map(resolved.candidate_app_mix_exs, fn {dir, _} -> dir end)
    assert "omega" in dirs
  end

  test "committable_app_mix_inventory freezes staged bytes against post-capture ABA mutation", %{
    worktree: worktree
  } do
    alias Arbor.Actions.Mix, as: MixAction
    alias Arbor.Actions.Coding.CrossApp.Parser

    content_a = mix_exs_source("alpha", [])
    content_b = mix_exs_source("alpha", ["beta"])

    write_app_mix_source!(worktree, "alpha", content_a)
    write_app_mix!(worktree, "beta", [])
    write_app_lib!(worktree, "alpha")
    write_app_lib!(worktree, "beta")
    _base = git_commit_all!(worktree, "content A")

    assert {:ok, freeze1} = MixAction.committable_app_mix_inventory(worktree)
    assert is_binary(freeze1.tree_oid)
    assert {"alpha", ^content_a} = List.keyfind(freeze1.app_mix_exs, "alpha", 0)

    # Mutate worktree to B after freeze returns.
    write_app_mix_source!(worktree, "alpha", content_b)
    assert File.read!(Path.join(worktree, "apps/alpha/mix.exs")) == content_b

    # Original freeze still carries A (private staged snapshot).
    assert {"alpha", ^content_a} = List.keyfind(freeze1.app_mix_exs, "alpha", 0)
    assert {:ok, [def_a | _]} = Parser.parse_many(freeze1.app_mix_exs)
    assert def_a.dir == "alpha"
    assert def_a.deps == []

    # Classic ABA: mutate B→A again; new capture may match A, freeze1 still A.
    write_app_mix_source!(worktree, "alpha", content_a)
    assert {:ok, freeze2} = MixAction.committable_app_mix_inventory(worktree)
    assert {"alpha", ^content_a} = List.keyfind(freeze2.app_mix_exs, "alpha", 0)
    assert {"alpha", ^content_a} = List.keyfind(freeze1.app_mix_exs, "alpha", 0)
  end

  test "resolve_selection ABA: selection graph cannot observe post-freeze worktree deps", %{
    worktree: worktree
  } do
    content_a = mix_exs_source("alpha", [])
    content_b = mix_exs_source("alpha", ["beta"])

    write_app_mix_source!(worktree, "alpha", content_a)
    write_app_mix!(worktree, "beta", [])
    write_app_lib!(worktree, "alpha")
    write_app_lib!(worktree, "beta")
    base = git_commit_all!(worktree, "A topology")

    # Capture freeze sources via resolve path, then mutate before asserting
    # the returned freeze sources (not a second worktree read).
    assert {:ok, resolved} = Shell.resolve_selection(worktree, base)
    assert {"alpha", source_a} = List.keyfind(resolved.candidate_app_mix_exs, "alpha", 0)
    assert source_a == content_a

    write_app_mix_source!(worktree, "alpha", content_b)
    # Returned freeze is immutable relative to later worktree mutation.
    assert {"alpha", ^content_a} =
             List.keyfind(resolved.candidate_app_mix_exs, "alpha", 0)

    refute resolved.selection.topology_change.edge_changed_apps == ["alpha"]
  end

  test "changed-path skew: freeze blob_manifest ignores post-capture worktree paths", %{
    worktree: worktree
  } do
    alias Arbor.Actions.Mix, as: MixAction

    write_app_mix!(worktree, "alpha", [])
    write_app_lib!(worktree, "alpha", "base")
    base = git_commit_all!(worktree, "base for path skew")

    # Dirty change present at freeze time.
    write_app_lib!(worktree, "alpha", "dirty-at-freeze")
    assert {:ok, freeze} = MixAction.committable_app_mix_inventory(worktree)
    assert is_list(freeze.blob_manifest)

    freeze_paths = Enum.map(freeze.blob_manifest, & &1.path)
    assert "apps/alpha/lib/alpha.ex" in freeze_paths
    refute "apps/alpha/lib/post_freeze.ex" in freeze_paths

    alpha_entry = Enum.find(freeze.blob_manifest, &(&1.path == "apps/alpha/lib/alpha.ex"))
    assert alpha_entry.oid

    # Post-capture mutation: new path + content rewrite on disk.
    write_app_lib!(worktree, "alpha", "post-freeze-rewrite")
    post_path = Path.join(worktree, "apps/alpha/lib/post_freeze.ex")
    File.write!(post_path, "defmodule Alpha.PostFreeze do\nend\n")

    # Freeze manifest is unchanged (immutable snapshot).
    assert Enum.find(freeze.blob_manifest, &(&1.path == "apps/alpha/lib/alpha.ex")).oid ==
             alpha_entry.oid

    refute Enum.any?(freeze.blob_manifest, &(&1.path == "apps/alpha/lib/post_freeze.ex"))

    # Immutable base vs freeze delta does not include the post-freeze path.
    assert {:ok, base_manifest} =
             load_base_manifest_for_test(worktree, base)

    assert {:ok, frozen_changed} =
             Core.diff_blob_manifests(base_manifest, freeze.blob_manifest)

    assert "apps/alpha/lib/alpha.ex" in frozen_changed
    refute "apps/alpha/lib/post_freeze.ex" in frozen_changed

    # Mutable worktree listing *would* observe the post-freeze path — proves skew.
    mutable_changed = mutable_changed_paths_for_test(worktree, base)
    assert "apps/alpha/lib/post_freeze.ex" in mutable_changed
    assert frozen_changed != mutable_changed
  end

  test "resolve_selection derives changed paths and topology solely from held freeze", %{
    worktree: worktree
  } do
    write_app_mix!(worktree, "alpha", [])
    write_app_mix!(worktree, "beta", [])
    write_app_lib!(worktree, "alpha", "base")
    write_app_lib!(worktree, "beta", "base")
    base = git_commit_all!(worktree, "base dual apps")

    # Pre-freeze dirty change under alpha only — topology unchanged.
    write_app_lib!(worktree, "alpha", "pre-freeze-dirty")
    content_a = mix_exs_source("alpha", [])
    content_b = mix_exs_source("alpha", ["beta"])
    write_app_mix_source!(worktree, "alpha", content_a)

    hook_ran? = :atomics.new(1, [])
    freeze_tree_oid = :ets.new(:cross_app_freeze_oid, [:set, :public])

    Application.put_env(:arbor_actions, :cross_app_after_candidate_freeze, fn path, freeze ->
      assert path == worktree
      assert is_binary(freeze.tree_oid)
      assert is_list(freeze.blob_manifest)
      assert is_list(freeze.app_mix_exs)
      :ets.insert(freeze_tree_oid, {:oid, freeze.tree_oid})
      :atomics.put(hook_ran?, 1, 1)

      # Mutate worktree AFTER freeze is held by resolve_selection:
      # 1) new path that mutable git-diff would observe
      # 2) mix.exs topology-changing rewrite that would alter candidate graph
      post = Path.join(path, "apps/alpha/lib/post_freeze_only.ex")
      File.write!(post, "defmodule Alpha.PostFreezeOnly do\nend\n")
      write_app_mix_source!(path, "alpha", content_b)
      write_app_lib!(path, "alpha", "post-freeze-rewrite")
      :ok
    end)

    assert {:ok, resolved} = Shell.resolve_selection(worktree, base)
    assert :atomics.get(hook_ran?, 1) == 1

    selection = resolved.selection
    freeze_paths = Enum.map(resolved.candidate_blob_manifest, & &1.path)

    # Held freeze did not observe post-hook paths or topology rewrite.
    refute "apps/alpha/lib/post_freeze_only.ex" in freeze_paths
    refute "apps/alpha/lib/post_freeze_only.ex" in selection.changed_files
    assert "apps/alpha/lib/alpha.ex" in selection.changed_files

    assert {"alpha", freeze_alpha_src} =
             List.keyfind(resolved.candidate_app_mix_exs, "alpha", 0)

    assert freeze_alpha_src == content_a
    refute freeze_alpha_src == content_b

    # Topology from freeze mix.exs only — alpha still has no deps on beta.
    refute selection.topology_change.changed?
    assert selection.topology_change.edge_changed_apps == []
    assert selection.topology_change.added_apps == []
    assert selection.topology_change.removed_apps == []

    # Focused selection (unchanged topology): alpha only, not full candidate.
    assert selection.changed_apps == ["alpha"]
    assert selection.affected_apps == ["alpha"]
    assert selection.test_paths == ["apps/alpha/test"]
    refute "beta" in selection.affected_apps

    # Tree OID returned is the freeze captured before mutation.
    assert [{:oid, oid}] = :ets.lookup(freeze_tree_oid, :oid)
    assert resolved.candidate_tree_oid == oid

    # Contrast: mutable worktree listing sees the post-freeze-only path.
    mutable_changed = mutable_changed_paths_for_test(worktree, base)
    assert "apps/alpha/lib/post_freeze_only.ex" in mutable_changed
    refute "apps/alpha/lib/post_freeze_only.ex" in selection.changed_files

    # A fresh freeze after mutation would see the rewrite; held freeze did not.
    alias Arbor.Actions.Mix, as: MixAction
    assert {:ok, later} = MixAction.committable_app_mix_inventory(worktree)
    assert {"alpha", later_src} = List.keyfind(later.app_mix_exs, "alpha", 0)
    assert later_src == content_b
    assert later.tree_oid != resolved.candidate_tree_oid
  end

  test "resolve_selection rejects non-full base commit OIDs", %{worktree: worktree} do
    write_app_mix!(worktree, "alpha", [])
    write_app_lib!(worktree, "alpha")
    _base = git_commit_all!(worktree, "need a commit")

    assert {:error, :invalid_base_commit_oid} =
             Shell.resolve_selection(worktree, "abc1234")
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

  defp compact_capacity_batch(batch) when is_map(batch) do
    %{
      "index" => batch.index,
      "total" => batch.total,
      "count" => batch.count,
      "label" => batch.label,
      "inventory_sha256" => batch.inventory_sha256
    }
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

  defp mix_exs_source(app, deps) when is_binary(app) and is_list(deps) do
    dep_lines =
      deps
      |> Enum.map(fn dep -> "          {:#{dep}, in_umbrella: true}" end)
      |> Enum.join(",\n")

    deps_body =
      if deps == [] do
        "        []"
      else
        "        [\n#{dep_lines}\n        ]"
      end

    """
    defmodule #{Macro.camelize(app)}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{app},
          version: "0.1.0",
          deps: deps()
        ]
      end

      defp deps do
    #{deps_body}
      end
    end
    """
  end

  defp write_app_mix!(worktree, app, deps) do
    write_app_mix_source!(worktree, app, mix_exs_source(app, deps))
  end

  defp write_app_mix_source!(worktree, app, source) do
    dir = Path.join(worktree, "apps/#{app}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.exs"), source)
  end

  defp write_app_lib!(worktree, app, suffix \\ "ok") do
    dir = Path.join(worktree, "apps/#{app}/lib")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "#{app}.ex"),
      "defmodule #{Macro.camelize(app)} do\n  # #{suffix}\nend\n"
    )
  end

  # Test-only: parse base ls-tree the same way production load_base_blob_manifest does.
  defp load_base_manifest_for_test(worktree, base_commit) do
    {listing, 0} =
      System.cmd("git", ["-C", worktree, "ls-tree", "-r", "-z", base_commit],
        stderr_to_stdout: true
      )

    entries =
      listing
      |> String.split(<<0>>, trim: true)
      |> Enum.reduce([], fn entry, acc ->
        case String.split(entry, "\t") do
          [meta, path] ->
            case String.split(meta, " ", parts: 3) do
              [mode, "blob", oid] when mode in ["100644", "100755", "120000"] ->
                [%{path: path, mode: mode, oid: oid} | acc]

              _ ->
                acc
            end

          _ ->
            acc
        end
      end)
      |> Enum.reverse()
      |> Enum.sort_by(& &1.path)

    {:ok, entries}
  end

  # Test-only contrast: mutable worktree changed-path listing (the skew we reject).
  defp mutable_changed_paths_for_test(worktree, base_commit) do
    {tracked, 0} =
      System.cmd(
        "git",
        ["-C", worktree, "diff", "--name-only", "--find-renames", "-z", base_commit],
        stderr_to_stdout: true
      )

    {untracked, 0} =
      System.cmd(
        "git",
        ["-C", worktree, "ls-files", "--others", "--exclude-standard", "-z"],
        stderr_to_stdout: true
      )

    (String.split(tracked, <<0>>, trim: true) ++ String.split(untracked, <<0>>, trim: true))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp git_commit_all!(worktree, message) do
    {_, 0} = System.cmd("git", ["add", "-A"], cd: worktree, stderr_to_stdout: true)

    {_, 0} =
      System.cmd(
        "git",
        ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", message],
        cd: worktree,
        stderr_to_stdout: true
      )

    {oid, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: worktree, stderr_to_stdout: true)
    String.trim(oid)
  end

  defp init_git_repo!(worktree) do
    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: worktree, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@arbor.local"], cd: worktree)
    {_, 0} = System.cmd("git", ["config", "user.name", "CrossApp Test"], cd: worktree)
    {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: worktree)
    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_actions, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_actions, key, value)
end
