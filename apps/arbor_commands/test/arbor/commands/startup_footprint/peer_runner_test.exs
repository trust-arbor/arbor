defmodule Arbor.Commands.StartupFootprint.PeerRunnerTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.StartupFootprint.PeerProbe
  alias Arbor.Commands.StartupFootprint.PeerRunner

  @moduletag :slow
  @moduletag timeout: 120_000

  @isolation_names [
    Arbor.Common.Supervisor,
    Arbor.Signals.Supervisor,
    Arbor.Monitor.Supervisor,
    Arbor.Commands.StartupFootprint.ProposedSupervisor,
    Arbor.Monitor.HealingSupervisor,
    Arbor.Signals.Bus,
    Arbor.Signals.Relay
  ]

  test "runner timeout kills the worker and controller before a delayed write" do
    marker =
      Path.join(
        System.tmp_dir!(),
        "sf-timeout-#{System.unique_integer([:positive])}.txt"
      )

    on_exit(fn -> File.rm(marker) end)

    result =
      PeerRunner.__test_sleep_touch__(marker, 20_000,
        budget_ms: 10_000,
        announce: self()
      )

    control =
      receive do
        {:peer_control, pid} -> pid
      after
        0 ->
          case result do
            {:error, {:peer_timeout, "test", %{control: pid}}} -> pid
            _ -> nil
          end
      end

    assert match?({:error, {:peer_timeout, "test", _}}, result)
    refute File.exists?(marker)
    assert is_pid(control)
    refute Process.alive?(control)
    Process.sleep(2_000)
    refute File.exists?(marker)
  end

  test "caller death terminates the peer controller before a delayed write" do
    marker =
      Path.join(
        System.tmp_dir!(),
        "sf-owner-#{System.unique_integer([:positive])}.txt"
      )

    on_exit(fn -> File.rm(marker) end)
    parent = self()

    owner =
      spawn(fn ->
        _ =
          PeerRunner.__test_sleep_touch__(marker, 20_000,
            budget_ms: 30_000,
            announce: parent
          )
      end)

    control =
      receive do
        {:peer_control, pid} -> pid
      after
        30_000 -> flunk("peer control was not announced")
      end

    assert Process.alive?(control)
    refute File.exists?(marker)
    Process.exit(owner, :kill)
    wait_until(fn -> not Process.alive?(owner) end, 2_000)
    wait_until(fn -> not Process.alive?(control) end, 5_000)
    refute Process.alive?(control)
    Process.sleep(2_000)
    refute File.exists?(marker)
  end

  test "peer halt leaves no live controller" do
    result = PeerRunner.__test_halt_peer__(announce: self(), budget_ms: 30_000)

    control =
      receive do
        {:peer_control, pid} -> pid
      after
        0 -> nil
      end

    assert match?({:error, {:peer_crash, "test", _}}, result) or
             match?({:error, {:peer_call_crash, :halt, _}}, result) or
             match?({:error, {:peer_cleanup_failed, "test", _}}, result)

    if is_pid(control) do
      refute Process.alive?(control)
    end
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
             PeerRunner.__test_consult_app_file__(dir, :broken)

    File.write!(Path.join(dir, "wrong.app"), "{hello, world}.\n")

    assert {:error, {:peer_app_consult_malformed, :wrong, _}} =
             PeerRunner.__test_consult_app_file__(dir, :wrong)

    assert {:error, {:application_spec_missing, :definitely_not_loaded_sf, nil}} =
             PeerProbe.__test_app_applications__(:definitely_not_loaded_sf)
  end

  test "a normal run leaves no worker, controller, or guardian descendant" do
    marker =
      Path.join(
        System.tmp_dir!(),
        "sf-clean-#{System.unique_integer([:positive])}.txt"
      )

    on_exit(fn -> File.rm(marker) end)

    result = PeerRunner.__test_sleep_touch__(marker, 0, announce: self())
    assert result == :ok

    announced = collect_announced()
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

  defp collect_announced do
    collect_announced(%{worker: nil, guardian: nil, control: nil}, 3)
  end

  defp collect_announced(acc, 0), do: acc

  defp collect_announced(acc, remaining) do
    receive do
      {:peer_worker, pid} ->
        collect_announced(%{acc | worker: pid}, remaining - 1)

      {:peer_guardian, pid} ->
        collect_announced(%{acc | guardian: pid}, remaining - 1)

      {:peer_control, pid} ->
        collect_announced(%{acc | control: pid}, remaining - 1)
    after
      0 -> acc
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
