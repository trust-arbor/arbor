defmodule Mix.Tasks.Arbor.Packaging.StartupFootprintProductionPathTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.StartupFootprint

  @moduletag :slow
  @moduletag timeout: 300_000

  # Nested `mix compile` of the owner apps will OOM/timeout a root-wide
  # umbrella suite (validator exit 137). The Mix task remains the
  # executable artifact-side probe. Opt in with
  # ARBOR_STARTUP_FOOTPRINT_PROBE=1.
  if System.get_env("ARBOR_STARTUP_FOOTPRINT_PROBE") != "1" do
    @moduletag skip:
                 "set ARBOR_STARTUP_FOOTPRINT_PROBE=1 or run mix arbor.packaging.startup_footprint"
  end

  test "isolated production probe emits required metrics for all three scenarios" do
    root = umbrella_root()
    lock_path = Path.join(root, "mix.lock")
    source_deps = selected_deps(root)
    canary = Path.join(source_deps, "jason/mix.exs")
    before_lock = File.read!(lock_path)
    before_mtime = File.stat!(lock_path).mtime
    before_canary = canary_snapshot(canary)

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
    end

    pids =
      Enum.map(["baseline", "proposed_gated", "proposed_eager"], fn scenario ->
        report["samples"][scenario]["os_pid"]
      end)
    assert length(Enum.uniq(pids)) == 3

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
    assert "os_mon" in List.wrap(gated["started_runtime_apps"])
    assert "os_mon" in List.wrap(eager["started_runtime_apps"])
    assert eager["logger_filter_count"] >= 1
    assert eager["telemetry_handler_count"] >= 1

    assert File.read!(lock_path) == before_lock
    assert File.stat!(lock_path).mtime == before_mtime
    assert canary_snapshot(canary) == before_canary
  end

  defp selected_deps(root) do
    case System.get_env("MIX_DEPS_PATH") do
      nil -> Path.expand("deps", root)
      path -> Path.expand(path, root)
    end
  end

  defp canary_snapshot(path) do
    if File.regular?(path) do
      {File.read!(path), File.stat!(path).mtime}
    else
      :absent
    end
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
