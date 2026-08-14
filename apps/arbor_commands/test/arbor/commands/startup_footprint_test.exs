defmodule Arbor.Commands.StartupFootprintTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.StartupFootprint
  alias Arbor.Commands.StartupFootprint.Core
  alias Arbor.Commands.StartupFootprint.PeerRunner

  @moduletag :fast

  test "production run refuses synthetic sample and peer injection" do
    assert {:error, {:production_opts_forbid_synthetic, _}} =
             StartupFootprint.run(mode: "report", samples: %{})

    assert {:error, {:production_opts_forbid_synthetic, _}} =
             StartupFootprint.run(mode: "report", run_peer: fn _scenario -> {:ok, %{}} end)
  end

  test "peer start opts are fixed and do not accept caller exec or MFA" do
    assert {Arbor.Commands.StartupFootprint.PeerProbe, :measure, 1} = PeerRunner.probe_mfa()
    assert {:ok, opts} = PeerRunner.start_opts()
    assert opts.connection == :standard_io
    assert opts.peer_down == :crash
    assert match?({:halt, _}, opts.shutdown)
    refute Map.has_key?(opts, :args)
    refute Map.has_key?(opts, :env)
    refute Map.has_key?(opts, :name)

    {:ok, exec} = PeerRunner.pinned_erlang_executable()
    assert opts.exec == String.to_charlist(exec)
    assert File.regular?(exec)
    assert Bitwise.band(File.stat!(exec).mode, 0o111) != 0
    refute function_exported?(PeerRunner, :measure_scenario, 2)
    refute function_exported?(StartupFootprint, :run, 2)
  end

  test "code-path admission fails closed on control bytes, missing dirs, and ceilings" do
    assert {:error, :peer_code_path_empty} = PeerRunner.admit_paths([])
    assert {:error, :peer_code_path_control_byte} = PeerRunner.admit_paths(["/tmp/\nmissing"])
    assert {:error, :peer_code_path_control_byte} = PeerRunner.admit_paths(["/tmp/" <> <<0>>])

    missing =
      Path.join(
        System.tmp_dir!(),
        "sf-missing-#{System.unique_integer([:positive])}"
      )

    assert {:error, {:peer_code_path_unresolved, ^missing, _}} =
             PeerRunner.admit_paths([missing])

    file =
      Path.join(
        System.tmp_dir!(),
        "sf-file-#{System.unique_integer([:positive])}"
      )

    File.write!(file, "not-a-dir")
    on_exit(fn -> File.rm(file) end)

    assert {:error, {:peer_code_path_not_directory, ^file}} = PeerRunner.admit_paths([file])

    too_long = "/" <> String.duplicate("a", 4_097)
    assert {:error, {:peer_code_path_entry_bytes, 4_098}} = PeerRunner.admit_paths([too_long])

    overflow = Enum.map(1..513, fn i -> "/tmp/sf-#{i}" end)
    assert {:error, {:peer_code_path_count, 513}} = PeerRunner.admit_paths(overflow)
  end

  test "current code path admits existing canonical directories" do
    assert {:ok, paths} = PeerRunner.admit_current_code_path()
    assert paths != []
    assert Enum.all?(paths, &is_binary/1)
    assert Enum.all?(paths, &File.dir?/1)
    assert Enum.all?(paths, &(not String.contains?(&1, <<0>>)))
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
      "schema" => Core.policy_schema(),
      "version" => 1,
      "policy_version" => Core.policy_version(),
      "decision" => %{
        "status" => "candidate",
        "choice" => "measure_only",
        "rationale" => "CLI closure test policy.",
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
end
