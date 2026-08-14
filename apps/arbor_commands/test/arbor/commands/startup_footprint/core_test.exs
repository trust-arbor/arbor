defmodule Arbor.Commands.StartupFootprint.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.StartupFootprint
  alias Arbor.Commands.StartupFootprint.{Core, Encode}

  @moduletag :fast

  defp policy(overrides \\ %{}) do
    Map.merge(
      %{
        "schema" => Core.policy_schema(),
        "version" => 1,
        "policy_version" => Core.policy_version(),
        "decision" => %{
          "status" => "candidate",
          "choice" => "measure_only",
          "rationale" => "Reversible candidate budgets for K3B.",
          "reversible" => true
        },
        "scenarios" => Core.scenarios(),
        "budgets" => %{
          "baseline" => budget(0, 16, 0, 0),
          "proposed_gated" => budget(0, 16, 0, 0),
          "proposed_eager" => budget(1, 100, 1, 8)
        }
      },
      overrides
    )
  end

  defp budget(min_children, max_process, min_filter, max_filter) do
    %{
      "process_count_delta" => %{"min" => 0, "max" => max_process},
      "supervisor_children" => %{"min" => min_children, "max" => 100},
      "ets_table_count_delta" => %{"min" => 0, "max" => 50},
      "ets_memory_words_delta" => %{"min" => 0, "max" => 10_000},
      "beam_memory_bytes_delta" => %{"min" => 0, "max" => 1_000_000},
      "boot_time_us" => %{"min" => 0, "max" => 1_000_000},
      "logger_filter_count" => %{"min" => min_filter, "max" => max_filter},
      "telemetry_handler_count" => %{"min" => min_filter, "max" => max_filter}
    }
  end

  defp raw_sample(scenario, opts \\ []) do
    before = %{
      "process_count" => 100,
      "ets_table_count" => 10,
      "ets_memory_words" => 1_000,
      "beam_memory_bytes" => 10_000_000
    }

    after_count = Keyword.get(opts, :after_process, 112)

    %{
      "scenario" => scenario,
      "os_pid" => Keyword.get(opts, :os_pid, 1_001),
      "before" => before,
      "after" => %{
        "process_count" => after_count,
        "ets_table_count" => 14,
        "ets_memory_words" => 1_400,
        "beam_memory_bytes" => 10_500_000
      },
      "boot_time_us" => Keyword.get(opts, :boot, 1_234),
      "supervisor_children" => Keyword.get(opts, :children, 8),
      "logger_filter_count" => Keyword.get(opts, :filter, 1),
      "telemetry_handler_count" => Keyword.get(opts, :telemetry, 1),
      "started_owner_apps" => Keyword.get(opts, :started_owner_apps, []),
      "started_runtime_apps" => Keyword.get(opts, :started_runtime_apps, [])
    }
  end

  defp normalized_sample(scenario, opts \\ []) do
    opts =
      if scenario in ["proposed_gated", "proposed_eager"] and
           not Keyword.has_key?(opts, :started_runtime_apps) do
        Keyword.put(opts, :started_runtime_apps, ["os_mon"])
      else
        opts
      end

    {:ok, sample} = Core.normalize_sample(raw_sample(scenario, opts))
    sample
  end

  defp evidence(samples) do
    %{
      "schema" => Core.evidence_schema(),
      "version" => 1,
      "policy_version" => Core.policy_version(),
      "samples" => samples
    }
  end

  test "normalize_sample reports non-negative deltas and bounds raw errors" do
    {:ok, sample} =
      Core.normalize_sample(
        raw_sample("baseline",
          after_process: 90,
          children: 0,
          filter: 0,
          telemetry: 0
        )
      )

    assert sample["process_count_delta"] == 0
    assert sample["ets_table_count_delta"] == 4
    assert sample["ets_memory_words_delta"] == 400
    assert sample["beam_memory_bytes_delta"] == 500_000
    assert sample["supervisor_children"] == 0
    assert sample["logger_filter_count"] == 0
    assert sample["started_owner_apps"] == []

    assert [
             %{"reason" => "negative_delta", "metric" => "process_count", "raw" => -10}
           ] = sample["raw_errors"]
  end

  test "normalize_sample rejects malformed snapshots" do
    raw = raw_sample("baseline")
    raw = put_in(raw, ["before", "process_count"], "nope")
    assert {:error, {:invalid_snapshot, "baseline", "before", ["process_count"]}} =
             Core.normalize_sample(raw)

    assert {:error, :malformed_sample} = Core.normalize_sample(:not_a_map)
    assert {:error, {:invalid_scenario, "merged"}} =
             Core.normalize_sample(%{"scenario" => "merged"})
  end

  test "scenario isolation requires distinct positive child pids" do
    samples = %{
      "baseline" => normalized_sample("baseline", baseline_opts(os_pid: 11)),
      "proposed_gated" =>
        normalized_sample("proposed_gated", os_pid: 11, children: 0, filter: 0, telemetry: 0),
      "proposed_eager" => normalized_sample("proposed_eager", os_pid: 13, children: 5)
    }

    assert {:ok, cmp} = Core.compare(policy(), evidence(samples))
    assert cmp["status"] == "failed"
    assert Enum.any?(cmp["failures"], &(&1["reason"] == "shared_os_pid"))

    zeroed = put_in(samples, ["baseline", "os_pid"], 0)
    assert {:error, {:invalid_os_pid, "baseline"}} = Core.admit_evidence(evidence(zeroed))
  end

  test "policy comparison admits in-budget samples and fails above ceiling" do
    ok = %{
      "baseline" => normalized_sample("baseline", baseline_opts(os_pid: 21)),
      "proposed_gated" =>
        normalized_sample("proposed_gated",
          os_pid: 22,
          children: 0,
          filter: 0,
          telemetry: 0,
          after_process: 102
        ),
      "proposed_eager" => normalized_sample("proposed_eager", os_pid: 23, children: 5)
    }

    assert {:ok, cmp} = Core.compare(policy(), evidence(ok))
    assert cmp["status"] == "ok"
    assert cmp["failure_count"] == 0

    over =
      put_in(ok, ["baseline", "process_count_delta"], 10_000)

    assert {:ok, failed} = Core.compare(policy(), evidence(over))
    assert failed["status"] == "failed"
    assert Enum.any?(failed["failures"], &(&1["reason"] == "above_budget"))

    dirty =
      put_in(ok, ["baseline", "raw_errors"], [
        %{"reason" => "negative_delta", "metric" => "process_count", "raw" => -4}
      ])

    assert {:ok, raw_failed} = Core.compare(policy(), evidence(dirty))
    assert raw_failed["status"] == "failed"
    assert Enum.any?(raw_failed["failures"], &(&1["reason"] == "raw_errors_present"))
  end

  test "baseline owner callbacks and started owner apps must remain zero" do
    clean = %{
      "baseline" => normalized_sample("baseline", baseline_opts(os_pid: 51)),
      "proposed_gated" =>
        normalized_sample("proposed_gated", os_pid: 52, children: 0, filter: 0, telemetry: 0),
      "proposed_eager" => normalized_sample("proposed_eager", os_pid: 53, children: 5)
    }

    assert {:ok, ok} = Core.compare(policy(), evidence(clean))
    assert ok["status"] == "ok"

    started =
      put_in(clean, ["baseline", "started_owner_apps"], ["arbor_common"])

    assert {:ok, apps_failed} = Core.compare(policy(), evidence(started))
    assert apps_failed["status"] == "failed"

    assert Enum.any?(
             apps_failed["failures"],
             &(&1["reason"] == "baseline_owner_apps_started")
           )

    callbacks =
      clean
      |> put_in(["baseline", "logger_filter_count"], 1)
      |> put_in(["baseline", "telemetry_handler_count"], 1)

    assert {:ok, cb_failed} = Core.compare(policy(), evidence(callbacks))
    assert cb_failed["status"] == "failed"

    reasons = Enum.map(cb_failed["failures"], & &1["reason"])
    assert "baseline_owner_callback" in reasons
  end

  test "proposed scenarios must record merged-app runtime extras inside the sample" do
    clean = %{
      "baseline" => normalized_sample("baseline", baseline_opts(os_pid: 61)),
      "proposed_gated" =>
        normalized_sample("proposed_gated",
          os_pid: 62,
          children: 0,
          filter: 0,
          telemetry: 0,
          started_runtime_apps: ["os_mon"]
        ),
      "proposed_eager" =>
        normalized_sample("proposed_eager",
          os_pid: 63,
          children: 5,
          started_runtime_apps: ["os_mon"]
        )
    }

    assert {:ok, ok} = Core.compare(policy(), evidence(clean))
    assert ok["status"] == "ok"

    widened =
      put_in(clean, ["baseline", "started_runtime_apps"], ["os_mon"])

    assert {:ok, base_failed} = Core.compare(policy(), evidence(widened))
    assert Enum.any?(base_failed["failures"], &(&1["reason"] == "baseline_widened_runtime"))

    missing = put_in(clean, ["proposed_gated", "started_runtime_apps"], [])
    assert {:ok, prop_failed} = Core.compare(policy(), evidence(missing))
    assert Enum.any?(prop_failed["failures"], &(&1["reason"] == "proposed_missing_runtime"))
  end

  test "gated callback budgets reject leaked logger and telemetry side effects" do
    leaked = %{
      "baseline" => normalized_sample("baseline", baseline_opts(os_pid: 31)),
      "proposed_gated" =>
        normalized_sample("proposed_gated", os_pid: 32, children: 0, filter: 1, telemetry: 1),
      "proposed_eager" => normalized_sample("proposed_eager", os_pid: 33, children: 5)
    }

    assert {:ok, cmp} = Core.compare(policy(), evidence(leaked))
    assert cmp["status"] == "failed"

    details = Enum.map(cmp["failures"], & &1["detail"])
    assert Enum.any?(details, &String.contains?(&1, "proposed_gated.logger_filter_count"))
    assert Enum.any?(details, &String.contains?(&1, "proposed_gated.telemetry_handler_count"))
  end

  test "malformed policy and evidence fail closed" do
    assert {:error, :malformed_policy} = Core.admit_policy(%{"schema" => "nope"})
    assert {:error, :malformed_policy} = Core.admit_policy(%{})
    assert {:error, :malformed_evidence} = Core.admit_evidence(%{"schema" => "nope"})

    bad_decision = policy(%{"decision" => %{"status" => "candidate", "choice" => "x"}})
    assert {:error, :malformed_decision} = Core.admit_policy(bad_decision)

    unknown_choice =
      policy(%{
        "decision" => %{
          "status" => "candidate",
          "choice" => "merge",
          "rationale" => "Not a closed choice until measurements exist.",
          "reversible" => true
        }
      })

    assert {:error, :malformed_decision} = Core.admit_policy(unknown_choice)

    omitted_owner =
      normalized_sample("baseline", baseline_opts())
      |> Map.delete("started_owner_apps")

    assert {:error, {:invalid_started_owner_apps, "baseline"}} =
             Core.admit_normalized_sample(omitted_owner)

    omitted_runtime =
      normalized_sample("proposed_gated", os_pid: 77, children: 0, filter: 0, telemetry: 0)
      |> Map.delete("started_runtime_apps")

    assert {:error, {:invalid_started_runtime_apps, "proposed_gated"}} =
             Core.admit_normalized_sample(omitted_runtime)

    irreversible =
      policy(%{
        "decision" => %{
          "status" => "candidate",
          "choice" => "measure_only",
          "rationale" => "nope",
          "reversible" => false
        }
      })

    assert {:error, :decision_must_be_reversible} = Core.admit_policy(irreversible)

    missing = evidence(%{"baseline" => normalized_sample("baseline")})
    assert {:error, :malformed_sample} = Core.admit_evidence(missing)

    inverted =
      policy()
      |> put_in(["budgets", "baseline", "process_count_delta"], %{"min" => 9, "max" => 1})

    assert {:error, :malformed_budget_bound} = Core.admit_policy(inverted)
  end

  test "show renders a report without requiring byte-identical samples" do
    samples = %{
      "baseline" => normalized_sample("baseline", baseline_opts(os_pid: 41)),
      "proposed_gated" =>
        normalized_sample("proposed_gated", os_pid: 42, children: 0, filter: 0, telemetry: 0),
      "proposed_eager" => normalized_sample("proposed_eager", os_pid: 43)
    }

    {:ok, admitted_policy} = Core.admit_policy(policy())
    {:ok, admitted_evidence} = Core.admit_evidence(evidence(samples))
    {:ok, compare} = Core.compare(admitted_policy, admitted_evidence)

    report =
      Core.show(admitted_policy, admitted_evidence, %{
        "mode" => "report",
        "output" => "json",
        "comparison" => compare
      })

    assert report["schema"] == Core.report_schema()
    assert report["status"] == "ok"
    assert report["decision"]["reversible"] == true
    assert {:ok, bytes} = Encode.encode_report(report)
    assert {:ok, again} = Encode.encode_report(report)
    assert bytes == again
    refute String.contains?(bytes, "before")
  end

  test "scenario commands stay isolated and do not start owner apps in the parent" do
    assert StartupFootprint.scenarios() == ["baseline", "proposed_gated", "proposed_eager"]

    assert StartupFootprint.scenario_command("baseline") ==
             ["run", "--no-start", "-e", "ArborKernelStartupFootprintProbe.run()"]

    test_pid = self()

    runner = fn scenario, ctx ->
      send(test_pid, {:child, scenario, ctx.command, System.pid()})

      opts =
        case scenario do
          "baseline" ->
            baseline_opts(after_process: 100)

          "proposed_gated" ->
            [children: 0, filter: 0, telemetry: 0, after_process: 102]

          _ ->
            [children: 4]
        end

      {:ok,
       normalized_sample(
         scenario,
         Keyword.put(opts, :os_pid, :erlang.unique_integer([:positive, :monotonic]))
       )}
    end

    root = tmp_root()
    write_policy!(root, policy())

    assert {:ok, report} =
             StartupFootprint.run_for_test(
               mode: "check",
               root: root,
               run_child: runner
             )

    assert report["status"] == "ok"
    assert_received {:child, "baseline", command, _}
    assert command == StartupFootprint.scenario_command("baseline")
    assert_received {:child, "proposed_gated", _, _}
    assert_received {:child, "proposed_eager", _, _}
    refute Process.whereis(Arbor.Common.Supervisor)
    refute Process.whereis(Arbor.Signals.Supervisor)
    refute Process.whereis(Arbor.Monitor.Supervisor)
    refute Process.whereis(ArborKernelStartupFootprintProbe.Supervisor)

    File.rm_rf(root)
  end

  defp baseline_opts(opts) do
    [
      children: 0,
      filter: 0,
      telemetry: 0,
      after_process: 100,
      started_owner_apps: []
    ]
    |> Keyword.merge(opts)
  end

  defp tmp_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "sf-core-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "apps/arbor_kernel"))
    File.mkdir_p!(Path.join(root, "apps/arbor_commands/priv/packaging"))
    File.write!(Path.join(root, "apps/arbor_kernel/mix.exs"), "defmodule K do\nend\n")
    root
  end

  defp write_policy!(root, policy) do
    path = Path.join(root, "apps/arbor_commands/priv/packaging/startup_footprint_policy.v1.json")
    File.write!(path, Jason.encode!(policy))
  end
end
