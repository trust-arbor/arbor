defmodule Arbor.Commands.StartupFootprint.PeerRunnerTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.StartupFootprint.PeerProbe
  alias Arbor.Commands.StartupFootprint.PeerRunner
  alias Arbor.Commands.StartupFootprint.PeerTestOps

  @moduletag :slow
  @moduletag timeout: 180_000

  @isolation_names [
    Arbor.Common.Supervisor,
    Arbor.Signals.Supervisor,
    Arbor.Monitor.Supervisor,
    Arbor.Commands.StartupFootprint.ProposedSupervisor,
    Arbor.Monitor.HealingSupervisor,
    Arbor.Signals.Bus,
    Arbor.Signals.Relay
  ]

  @delayed_write_ms 20_000

  test "runner timeout kills worker, controller, and guardian before a delayed write" do
    marker = marker_path("sf-timeout")
    on_exit(fn -> File.rm(marker) end)
    started_at = System.monotonic_time(:millisecond)

    result =
      PeerTestOps.sleep_touch(marker, @delayed_write_ms,
        budget_ms: 10_000,
        announce: self()
      )

    assert_received {:peer_work_started, _}
    announced = collect_announced()
    assert match?({:error, {:peer_timeout, "test", _}}, result)
    refute_live_descendants(announced)
    refute File.exists?(marker)
    wait_past(started_at, @delayed_write_ms + 1_000)
    refute File.exists?(marker)
  end

  test "caller death terminates worker, controller, and guardian before a delayed write" do
    marker = marker_path("sf-owner")
    on_exit(fn -> File.rm(marker) end)
    parent = self()
    started_at = System.monotonic_time(:millisecond)

    owner =
      spawn(fn ->
        _ =
          PeerTestOps.sleep_touch(marker, @delayed_write_ms,
            budget_ms: 30_000,
            announce: parent
          )
      end)

    receive do
      {:peer_work_started, _} -> :ok
    after
      30_000 -> flunk("peer work did not start")
    end

    announced = collect_announced(1_000)
    assert is_pid(announced.worker)
    assert is_pid(announced.guardian)
    assert is_pid(announced.control)
    assert Process.alive?(announced.worker)
    assert Process.alive?(announced.guardian)
    assert Process.alive?(announced.control)
    refute File.exists?(marker)

    Process.exit(owner, :kill)
    wait_until(fn -> not Process.alive?(owner) end, 2_000)
    wait_until(fn -> not Process.alive?(announced.worker) end, 5_000)
    wait_until(fn -> not Process.alive?(announced.guardian) end, 5_000)
    wait_until(fn -> not Process.alive?(announced.control) end, 5_000)
    refute_live_descendants(announced)
    wait_past(started_at, @delayed_write_ms + 1_000)
    refute File.exists?(marker)
  end

  test "peer halt leaves no live worker, controller, or guardian" do
    result = PeerTestOps.halt_peer(announce: self(), budget_ms: 30_000)

    assert_received {:peer_work_started, _}
    announced = collect_announced()

    assert match?({:error, {:peer_crash, "test", _}}, result) or
             match?({:error, {:peer_call_crash, :halt, _}}, result) or
             match?({:error, {:peer_cleanup_failed, "test", _}}, result)

    refute_live_descendants(announced)
  end

  test "malformed and unreadable .app files fail closed" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sf-app-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    File.write!(Path.join(dir, "broken.app"), "not an erlang term")

    assert {:error, {:peer_app_consult_failed, :broken, _}} =
             PeerTestOps.consult_app_file(dir, :broken)

    File.write!(Path.join(dir, "wrong.app"), "{hello, world}.\n")

    assert {:error, {:peer_app_consult_malformed, :wrong, _}} =
             PeerTestOps.consult_app_file(dir, :wrong)

    assert {:error, {:application_spec_missing, :definitely_not_loaded_sf, nil}} =
             PeerProbe.__test_app_applications__(:definitely_not_loaded_sf)
  end

  test "consult subtracts optional_applications and keeps included applications required" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sf-opt-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    File.write!(
      Path.join(dir, "req.app"),
      """
      {application, req, [
        {applications, [kernel, stdlib, nimble_csv, plug, brotli, ezstd, telemetry]},
        {optional_applications, [nimble_csv, plug, brotli, ezstd]},
        {included_applications, [req_included]}
      ]}.
      """
    )

    assert {:ok, required} = PeerTestOps.consult_app_file(dir, :req)
    assert required == [:kernel, :stdlib, :telemetry, :req_included]
    refute :nimble_csv in required
    refute :plug in required
    refute :brotli in required
    refute :ezstd in required

    File.write!(
      Path.join(dir, "keep.app"),
      """
      {application, keep, [
        {applications, [kernel, stdlib, jason]},
        {included_applications, [keep_inc]}
      ]}.
      """
    )

    assert {:ok, [:kernel, :stdlib, :jason, :keep_inc]} =
             PeerTestOps.consult_app_file(dir, :keep)

    File.write!(
      Path.join(dir, "overlap.app"),
      """
      {application, overlap, [
        {applications, [kernel, extra]},
        {optional_applications, [extra, extra_inc]},
        {included_applications, [extra_inc]}
      ]}.
      """
    )

    assert {:ok, [:kernel, :extra_inc]} = PeerTestOps.consult_app_file(dir, :overlap)

    File.write!(
      Path.join(dir, "badopt.app"),
      """
      {application, badopt, [
        {applications, [kernel]},
        {optional_applications, not_a_list}
      ]}.
      """
    )

    assert {:error, {:peer_app_spec_malformed, :badopt}} =
             PeerTestOps.consult_app_file(dir, :badopt)
  end

  test "a normal run leaves no worker, controller, or guardian descendant" do
    marker = marker_path("sf-clean")
    on_exit(fn -> File.rm(marker) end)

    result = PeerTestOps.sleep_touch(marker, 0, announce: self())
    assert result == :ok
    assert_received {:peer_work_started, _}
    announced = collect_announced()
    refute_live_descendants(announced)
    assert File.exists?(marker)
  end

  test "a real descendant BEAM measurement returns a normalized envelope" do
    before = snapshot_registered()
    parent_pid = parent_os_pid()

    assert {:ok, sample} = PeerRunner.measure_scenario("baseline")
    assert sample["scenario"] == "baseline"
    assert is_integer(sample["os_pid"]) and sample["os_pid"] > 0
    assert sample["os_pid"] != parent_pid
    assert is_integer(sample["process_count_delta"])
    assert is_integer(sample["supervisor_children"])
    assert is_integer(sample["ets_table_count_delta"])
    assert is_integer(sample["ets_memory_words_delta"])
    assert is_integer(sample["beam_memory_bytes_delta"])
    assert is_integer(sample["boot_time_us"])
    assert is_integer(sample["logger_filter_count"])
    assert is_integer(sample["telemetry_handler_count"])
    assert is_list(sample["started_owner_apps"])
    assert is_list(sample["started_runtime_apps"])
    assert sample["raw_errors"] == []
    assert snapshot_registered() == before
  end

  defp snapshot_registered do
    Map.new(@isolation_names, fn name -> {name, Process.whereis(name)} end)
  end

  defp parent_os_pid do
    {pid, ""} = Integer.parse(System.pid())
    pid
  end

  defp marker_path(prefix) do
    Path.join(
      System.tmp_dir!(),
      "#{prefix}-#{System.unique_integer([:positive])}.txt"
    )
  end

  defp collect_announced(timeout_ms \\ 0) do
    collect_announced(%{worker: nil, guardian: nil, control: nil}, 3, timeout_ms)
  end

  defp collect_announced(acc, 0, _timeout_ms), do: acc

  defp collect_announced(acc, remaining, timeout_ms) do
    receive do
      {:peer_worker, pid} ->
        collect_announced(%{acc | worker: pid}, remaining - 1, timeout_ms)

      {:peer_guardian, pid} ->
        collect_announced(%{acc | guardian: pid}, remaining - 1, timeout_ms)

      {:peer_control, pid} ->
        collect_announced(%{acc | control: pid}, remaining - 1, timeout_ms)
    after
      timeout_ms -> acc
    end
  end

  defp refute_live_descendants(announced) do
    assert is_pid(announced.worker)
    assert is_pid(announced.guardian)
    assert is_pid(announced.control)
    refute Process.alive?(announced.worker)
    refute Process.alive?(announced.guardian)
    refute Process.alive?(announced.control)
    assert Process.info(announced.worker) == nil
    assert Process.info(announced.guardian) == nil
    assert Process.info(announced.control) == nil
  end

  defp wait_past(started_at, min_elapsed_ms) do
    remaining = min_elapsed_ms - (System.monotonic_time(:millisecond) - started_at)

    if remaining > 0 do
      Process.sleep(remaining)
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition did not become true before deadline")
      else
        Process.sleep(25)
        do_wait_until(fun, deadline)
      end
    end
  end
end
