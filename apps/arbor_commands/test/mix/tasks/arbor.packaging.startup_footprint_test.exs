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

  test "checked-in candidate policy admits and is reversible" do
    root = find_umbrella(__DIR__)

    path =
      Path.join(root, "apps/arbor_commands/priv/packaging/startup_footprint_policy.v1.json")

    {:ok, raw} = Jason.decode(File.read!(path))
    assert {:ok, policy} = Core.admit_policy(raw)
    assert policy["decision"]["reversible"] == true
    assert policy["decision"]["status"] == "candidate"
    assert policy["decision"]["choice"] == "measure_only"
    assert policy["scenarios"] == Core.scenarios()

    dead_probe = Path.join(root, "apps/arbor_commands/priv/packaging/startup_footprint_probe")

    for rel <- [
          "mix.exs",
          "README.md",
          "config/config.exs",
          "lib/arbor_kernel_startup_footprint_probe.ex",
          "lib/arbor_kernel_startup_footprint_probe/application.ex"
        ] do
      refute File.exists?(Path.join(dead_probe, rel))
    end
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
    File.write!(Path.join(root, "apps/arbor_kernel/mix.exs"), "defmodule K do\nend\n")

    policy = %{
      "schema" => "arbor.packaging.startup_footprint.policy.v1",
      "version" => 1,
      "policy_version" => "k3b.v1",
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
