defmodule Arbor.Commands.StartupFootprintTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.StartupFootprint
  alias Arbor.Commands.StartupFootprint.Core

  @moduletag :fast

  test "mise fallback is rejected unless the path is an executable regular file" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sf-mise-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    missing = Path.join(dir, "missing-mise")
    assert {:error, :mise_unavailable} = StartupFootprint.validate_mise_path(missing)

    not_exec = Path.join(dir, "mise")
    File.write!(not_exec, "#!/bin/sh\n")
    File.chmod!(not_exec, 0o644)
    assert {:error, {:mise_not_executable, ^not_exec}} =
             StartupFootprint.validate_mise_path(not_exec)

    File.chmod!(not_exec, 0o755)
    assert {:ok, ^not_exec} = StartupFootprint.validate_mise_path(not_exec)
  end

  test "classify_command_result returns structured timeout, output-limit, and containment failures" do
    assert {:error, {:probe_timeout, :compile}} =
             StartupFootprint.classify_command_result(
               %{timed_out: true, exit_code: 137, stdout: ""},
               :compile
             )

    assert {:error, {:probe_output_limit, :compile}} =
             StartupFootprint.classify_command_result(
               %{output_limit_exceeded: true, exit_code: 137, stdout: "x"},
               :compile
             )

    assert {:error, {:probe_containment_failure, :compile}} =
             StartupFootprint.classify_command_result(
               %{containment_failure: true, exit_code: 137, stdout: ""},
               :compile
             )

    assert {:ok, "ok\n"} =
             StartupFootprint.classify_command_result(
               %{exit_code: 0, stdout: "ok\n", timed_out: false},
               :compile
             )
  end

  test "security regression: pre-created symlink workspace is rejected and not followed" do
    victim =
      Path.join(
        System.tmp_dir!(),
        "sf-victim-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(victim)
    secret = Path.join(victim, "secret.txt")
    File.write!(secret, "keep")

    planted =
      Path.join(
        System.tmp_dir!(),
        "arbor-startup-footprint-planted-#{System.unique_integer([:positive])}"
      )

    File.ln_s!(victim, planted)

    on_exit(fn ->
      File.rm(planted)
      File.rm_rf(victim)
    end)

    assert {:error, :root_exists} = StartupFootprint.allocate_workspace_at(planted)
    assert File.read!(secret) == "keep"
    refute File.exists?(Path.join(victim, "mix.exs"))
    refute File.exists?(Path.join(victim, "deps"))
    assert {:ok, %{type: :symlink}} = File.lstat(planted)
  end

  test "security regression: pre-created directory workspace is rejected" do
    planted =
      Path.join(
        System.tmp_dir!(),
        "arbor-startup-footprint-existing-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(planted)
    marker = Path.join(planted, "keep.txt")
    File.write!(marker, "keep")

    on_exit(fn -> File.rm_rf(planted) end)

    assert {:error, :root_exists} = StartupFootprint.allocate_workspace_at(planted)
    assert File.read!(marker) == "keep"
  end

  test "production-path hermeticity: mutating child MIX_DEPS_PATH cannot mutate the source cache" do
    root = hermetic_root()
    source_deps = Path.join(root, "deps")
    sentinel = Path.join(source_deps, "jason/sentinel.txt")
    link = Path.join(source_deps, "jason/link")
    before = File.read!(sentinel)
    previous_deps = System.get_env("MIX_DEPS_PATH")
    System.put_env("MIX_DEPS_PATH", source_deps)

    on_exit(fn ->
      restore_env("MIX_DEPS_PATH", previous_deps)
      File.rm_rf(root)
    end)

    test_pid = self()

    runner = fn scenario, ctx ->
      send(test_pid, {:workspace, scenario, ctx})
      assert ctx.deps_path != source_deps
      assert ctx.env["MIX_DEPS_PATH"] == ctx.deps_path
      assert ctx.env["HEX_OFFLINE"] == "1"
      assert {:ok, %{type: :regular}} = File.lstat(Path.join(ctx.deps_path, "jason/link"))
      File.write!(Path.join(ctx.deps_path, "jason/link"), "mutated-through-copy")
      File.write!(Path.join(ctx.deps_path, "mutated"), "child-only")

      {:ok,
       sample(
         scenario,
         :erlang.unique_integer([:positive, :monotonic])
       )}
    end

    assert {:ok, report} =
             StartupFootprint.run_for_test(
               mode: "check",
               root: root,
               use_production_workspace: true,
               run_child: runner
             )

    assert report["status"] == "ok"
    assert_received {:workspace, "baseline", _}
    assert_received {:workspace, "proposed_gated", _}
    assert_received {:workspace, "proposed_eager", _}
    assert File.read!(sentinel) == before
    assert File.read!(link) == before
    assert {:ok, %{type: :symlink}} = File.lstat(link)
    refute File.exists?(Path.join(source_deps, "mutated"))
  end

  defp sample(scenario, pid) do
    side = if scenario == "proposed_eager", do: 1, else: 0
    children = if scenario == "proposed_eager", do: 5, else: 0

    %{
      "scenario" => scenario,
      "os_pid" => pid,
      "process_count_delta" => 8,
      "supervisor_children" => children,
      "ets_table_count_delta" => 2,
      "ets_memory_words_delta" => 100,
      "beam_memory_bytes_delta" => 1_000,
      "boot_time_us" => 50,
      "logger_filter_count" => side,
      "telemetry_handler_count" => side,
      "started_owner_apps" => [],
      "started_runtime_apps" =>
        if(scenario in ["proposed_gated", "proposed_eager"], do: ["os_mon"], else: []),
      "raw_errors" => []
    }
  end

  defp hermetic_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "sf-hermetic-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "apps/arbor_kernel/priv/packaging/startup_footprint_probe/lib"))
    File.mkdir_p!(Path.join(root, "apps/arbor_kernel/priv/packaging/startup_footprint_probe/config"))
    File.mkdir_p!(Path.join(root, "apps/arbor_commands/priv/packaging"))
    File.mkdir_p!(Path.join(root, "deps/jason"))
    File.write!(Path.join(root, "apps/arbor_kernel/mix.exs"), "defmodule K do\nend\n")
    File.write!(Path.join(root, "mix.lock"), "%{}\n")

    File.write!(
      Path.join(root, "apps/arbor_kernel/priv/packaging/startup_footprint_probe/lib/probe.ex"),
      "# probe\n"
    )

    File.write!(
      Path.join(root, "apps/arbor_kernel/priv/packaging/startup_footprint_probe/config/config.exs"),
      "import Config\n"
    )

    sentinel = Path.join(root, "deps/jason/sentinel.txt")
    File.write!(sentinel, "original-source-bytes")
    File.ln_s!("sentinel.txt", Path.join(root, "deps/jason/link"))

    policy = %{
      "schema" => Core.policy_schema(),
      "version" => 1,
      "policy_version" => Core.policy_version(),
      "decision" => %{
        "status" => "candidate",
        "choice" => "measure_only",
        "rationale" => "Hermeticity fixture policy.",
        "reversible" => true
      },
      "scenarios" => Core.scenarios(),
      "budgets" => %{
        "baseline" => bounds(0, 16, 0, 0),
        "proposed_gated" => bounds(0, 16, 0, 0),
        "proposed_eager" => bounds(1, 100, 1, 8)
      }
    }

    File.write!(
      Path.join(root, "apps/arbor_commands/priv/packaging/startup_footprint_policy.v1.json"),
      Jason.encode!(policy)
    )

    root
  end

  defp bounds(min_children, max_process, min_side, max_side) do
    %{
      "process_count_delta" => %{"min" => 0, "max" => max_process},
      "supervisor_children" => %{"min" => min_children, "max" => 100},
      "ets_table_count_delta" => %{"min" => 0, "max" => 50},
      "ets_memory_words_delta" => %{"min" => 0, "max" => 10_000},
      "beam_memory_bytes_delta" => %{"min" => 0, "max" => 1_000_000},
      "boot_time_us" => %{"min" => 0, "max" => 1_000_000},
      "logger_filter_count" => %{"min" => min_side, "max" => max_side},
      "telemetry_handler_count" => %{"min" => min_side, "max" => max_side}
    }
  end

  defp restore_env(name, nil), do: System.delete_env(name)

  defp restore_env(name, value) when is_binary(value) do
    System.put_env(name, value)
  end
end
