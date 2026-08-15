defmodule Mix.Tasks.Arbor.Packaging.StartupFootprintTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.StartupFootprint
  alias Arbor.Commands.StartupFootprint.Core
  alias Mix.Tasks.Arbor.Packaging.StartupFootprint, as: Task

  @moduletag :fast

  test "rejects unknown options and unexpected positionals" do
    assert {:error, {:arguments, :unknown_or_invalid_option}} =
             Task.execute(["--write-report"])

    assert {:error, {:arguments, :unexpected_positional}} =
             Task.execute(["baseline"])
  end

  test "production execute refuses runtime hooks" do
    assert {:error, {:production_task_forbids_runtime_hooks, _}} =
             Task.execute(["--json"], samples: %{})
  end

  test "production run refuses synthetic sample injection" do
    assert {:error, {:production_opts_forbid_synthetic, _}} =
             StartupFootprint.run(mode: "report", samples: %{})
  end

  test "checked-in accepted policy admits and records the passive split" do
    root = find_umbrella(__DIR__)

    path =
      Path.join(root, "apps/arbor_commands/priv/packaging/startup_footprint_policy.v1.json")

    {:ok, raw} = Jason.decode(File.read!(path))
    assert {:ok, policy} = Core.admit_policy(raw)
    assert policy["decision"]["reversible"] == true
    assert policy["decision"]["status"] == "accepted"
    assert policy["decision"]["choice"] == "split_passive_protocols"
    assert policy["scenarios"] == Core.scenarios()

    assert policy["budgets"]["proposed_gated"]["supervisor_children"] == %{
             "min" => 4,
             "max" => 4
           }

    assert policy["budgets"]["proposed_gated"]["logger_filter_count"] == %{
             "min" => 1,
             "max" => 1
           }

    assert policy["budgets"]["proposed_gated"]["telemetry_handler_count"] == %{
             "min" => 0,
             "max" => 0
           }

    shell =
      File.read!(Path.join(root, "apps/arbor_commands/lib/arbor/commands/startup_footprint.ex"))

    runner =
      File.read!(
        Path.join(root, "apps/arbor_commands/lib/arbor/commands/startup_footprint/peer_runner.ex")
      )

    refute File.exists?(
             Path.join(root, "apps/arbor_commands/priv/packaging/startup_footprint_probe")
           )

    refute File.exists?(
             Path.join(root, "apps/arbor_kernel/priv/packaging/startup_footprint_probe")
           )

    refute String.contains?(shell, "startup_footprint_probe")
    refute String.contains?(shell, "System.cmd")
    refute String.contains?(shell, "execute_process_tree")
    refute String.contains?(shell, "validate_mise")
    refute String.contains?(shell, "allocate_workspace")
    refute String.contains?(shell, "Task.yield")
    refute String.contains?(runner, "System.cmd")
    refute String.contains?(runner, "Task.yield")
    refute String.contains?(runner, "Task.shutdown")
    refute String.contains?(runner, "__test_sleep_touch__")
    refute String.contains?(runner, "write_file")
    assert String.contains?(runner, "connection: :standard_io")
    assert String.contains?(runner, "spawn_monitor")
    assert String.contains?(runner, "if Mix.env() == :test")
    assert String.contains?(shell, "PeerRunner.measure_all()")
  end

  test "check mode compares injected samples against policy and does not write" do
    root = tmp_root()

    policy_path =
      Path.join(root, "apps/arbor_commands/priv/packaging/startup_footprint_policy.v1.json")

    before = File.read!(policy_path)

    samples = %{
      "baseline" => sample("baseline", 101, 0, 0),
      "proposed_gated" => sample("proposed_gated", 102, 0, 0),
      "proposed_eager" => sample("proposed_eager", 103, 5, 1)
    }

    assert {:ok, report} =
             StartupFootprint.run_for_test(
               mode: "check",
               root: root,
               json: true,
               samples: samples
             )

    assert report["status"] == "ok"
    assert report["mode"] == "check"
    assert File.read!(policy_path) == before

    over = put_in(samples, ["baseline", "process_count_delta"], 9_999)

    assert {:ok, failed} =
             StartupFootprint.run_for_test(
               mode: "check",
               root: root,
               samples: over
             )

    assert failed["status"] == "failed"
    assert File.read!(policy_path) == before

    File.rm_rf(root)
  end

  defp sample(scenario, pid, children, side_effects) do
    %{
      "scenario" => scenario,
      "os_pid" => pid,
      "process_count_delta" => 8,
      "supervisor_children" => children,
      "ets_table_count_delta" => 2,
      "ets_memory_words_delta" => 100,
      "beam_memory_bytes_delta" => 1_000,
      "boot_time_us" => 50,
      "logger_filter_count" => side_effects,
      "telemetry_handler_count" => side_effects,
      "started_owner_apps" => [],
      "started_runtime_apps" =>
        if(scenario in ["proposed_gated", "proposed_eager"], do: ["os_mon"], else: []),
      "raw_errors" => []
    }
  end

  defp tmp_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "sf-cli-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "apps/arbor_kernel"))
    File.mkdir_p!(Path.join(root, "apps/arbor_commands/priv/packaging"))
    File.write!(Path.join(root, "mix.exs"), "defmodule Root do\nend\n")
    File.write!(Path.join(root, "apps/arbor_commands/mix.exs"), "defmodule C do\nend\n")
    File.write!(Path.join(root, "apps/arbor_kernel/mix.exs"), "defmodule K do\nend\n")

    policy = %{
      "schema" => "arbor.packaging.startup_footprint.policy.v1",
      "version" => 1,
      "policy_version" => Core.policy_version(),
      "decision" => %{
        "status" => "candidate",
        "choice" => "measure_only",
        "rationale" => "CLI closure test policy.",
        "reversible" => true
      },
      "scenarios" => ["baseline", "proposed_gated", "proposed_eager"],
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

  defp find_umbrella(dir) do
    cond do
      File.regular?(Path.join([dir, "apps", "arbor_kernel", "mix.exs"])) -> dir
      Path.dirname(dir) == dir -> raise "umbrella root not found"
      true -> find_umbrella(Path.dirname(dir))
    end
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
end
