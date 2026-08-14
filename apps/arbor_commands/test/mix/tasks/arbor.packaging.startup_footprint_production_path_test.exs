defmodule Mix.Tasks.Arbor.Packaging.StartupFootprintProductionPathTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.StartupFootprint
  alias Arbor.Commands.StartupFootprint.PeerRunner

  @moduletag :slow
  @moduletag timeout: 300_000

  @isolation_names [
    Arbor.Common.Supervisor,
    Arbor.Signals.Supervisor,
    Arbor.Monitor.Supervisor,
    Arbor.Commands.StartupFootprint.ProposedSupervisor,
    Arbor.Monitor.HealingSupervisor,
    Arbor.Signals.Bus,
    Arbor.Signals.Relay
  ]

  test "isolated production probe measures three descendant BEAMs without changing parent registrations" do
    root = umbrella_root()
    parent_pid = parent_os_pid()
    before = snapshot_registered()

    assert {:ok, report} = StartupFootprint.run(root: root, json: true)

    assert report["schema"] == "arbor.packaging.startup_footprint.report.v1"
    assert report["policy_version"] == "k3b.v1"
    assert report["decision"]["reversible"] == true
    assert report["decision"]["status"] == "candidate"
    assert report["decision"]["choice"] == "measure_only"

    for scenario <- ["baseline", "proposed_gated", "proposed_eager"] do
      sample = report["samples"][scenario]
      assert is_map(sample), "missing sample for #{scenario}"
      assert sample["scenario"] == scenario
      assert is_integer(sample["os_pid"]) and sample["os_pid"] > 0
      assert sample["os_pid"] != parent_pid
      assert is_integer(sample["process_count_delta"]) and sample["process_count_delta"] >= 0
      assert is_integer(sample["supervisor_children"]) and sample["supervisor_children"] >= 0
      assert is_integer(sample["ets_table_count_delta"]) and sample["ets_table_count_delta"] >= 0
      assert is_integer(sample["ets_memory_words_delta"]) and sample["ets_memory_words_delta"] >= 0
      assert is_integer(sample["beam_memory_bytes_delta"]) and
               sample["beam_memory_bytes_delta"] >= 0
      assert is_integer(sample["boot_time_us"]) and sample["boot_time_us"] >= 0
      assert is_integer(sample["logger_filter_count"]) and sample["logger_filter_count"] >= 0
      assert is_integer(sample["telemetry_handler_count"]) and
               sample["telemetry_handler_count"] >= 0
      assert is_list(sample["started_owner_apps"])
      assert is_list(sample["started_runtime_apps"])
      assert sample["raw_errors"] == []
    end

    pids =
      Enum.map(["baseline", "proposed_gated", "proposed_eager"], fn scenario ->
        report["samples"][scenario]["os_pid"]
      end)

    assert length(Enum.uniq(pids)) == 3
    assert Enum.all?(pids, &(&1 != parent_pid))

    gated = report["samples"]["proposed_gated"]
    assert gated["logger_filter_count"] == 0
    assert gated["telemetry_handler_count"] == 0
    assert gated["supervisor_children"] == 0

    baseline = report["samples"]["baseline"]
    eager = report["samples"]["proposed_eager"]
    assert baseline["logger_filter_count"] == 0
    assert baseline["telemetry_handler_count"] == 0
    assert baseline["started_owner_apps"] == []
    assert baseline["supervisor_children"] == 0
    refute "os_mon" in List.wrap(baseline["started_runtime_apps"])
    refute "arbor_kernel" in List.wrap(baseline["started_runtime_apps"])
    refute "arbor_kernel" in List.wrap(gated["started_runtime_apps"])
    refute "arbor_kernel" in List.wrap(eager["started_runtime_apps"])
    refute "arbor_startup_footprint_proposed" in List.wrap(baseline["started_runtime_apps"])
    refute "arbor_startup_footprint_proposed" in List.wrap(gated["started_runtime_apps"])
    refute "arbor_startup_footprint_proposed" in List.wrap(eager["started_runtime_apps"])
    assert "os_mon" in List.wrap(gated["started_runtime_apps"])
    assert "os_mon" in List.wrap(eager["started_runtime_apps"])
    assert eager["logger_filter_count"] >= 1
    assert eager["telemetry_handler_count"] >= 1

    assert snapshot_registered() == before
    assert PeerRunner.probe_mfa() == {Arbor.Commands.StartupFootprint.PeerProbe, :measure, 1}
  end

  defp snapshot_registered do
    Map.new(@isolation_names, fn name -> {name, Process.whereis(name)} end)
  end

  defp parent_os_pid do
    {pid, ""} = Integer.parse(System.pid())
    pid
  end

  defp umbrella_root do
    find_root(__DIR__)
  end

  defp find_root(dir) do
    cond do
      File.regular?(Path.join([dir, "apps", "arbor_kernel", "mix.exs"])) -> dir
      Path.dirname(dir) == dir -> raise "umbrella root not found"
      true -> find_root(Path.dirname(dir))
    end
  end
end
