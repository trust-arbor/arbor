# Probe-only fixture; not a production application.
defmodule ArborKernelStartupFootprintProbe do
  @moduledoc false

  @scenarios ["baseline", "proposed_gated", "proposed_eager"]
  @owner_apps [:arbor_common, :arbor_signals, :arbor_monitor]
  @retired_owners [:arbor_contracts, :arbor_common, :arbor_signals, :arbor_monitor]
  @proposed_owner :arbor_kernel
  @external_runtime_exclusions MapSet.new([
                                 @proposed_owner,
                                 :arbor_kernel_startup_footprint_probe | @retired_owners
                               ])
  @security_bridge_id "arbor-signals-security-telemetry-bridge"
  @security_bridge_event [:arbor, :security, :authorization_granted]

  @spec run() :: :ok
  def run do
    scenario = System.fetch_env!("ARBOR_STARTUP_FOOTPRINT_SCENARIO")

    if scenario not in @scenarios do
      raise "unknown startup-footprint scenario: #{inspect(scenario)}"
    end

    before_apps = started_app_names()
    before = snapshot()
    started_at = :erlang.monotonic_time()
    :ok = start_scenario(scenario)
    boot_time_us =
      System.convert_time_unit(:erlang.monotonic_time() - started_at, :native, :microsecond)

    after_snap = snapshot()
    after_apps = started_app_names()

    payload = %{
      "scenario" => scenario,
      "os_pid" => os_pid(),
      "before" => before,
      "after" => after_snap,
      "boot_time_us" => boot_time_us,
      "supervisor_children" => supervisor_children(scenario),
      "logger_filter_count" => logger_filter_count(),
      "telemetry_handler_count" => telemetry_handler_count(),
      "started_owner_apps" => started_owner_apps(),
      "started_runtime_apps" => started_runtime_apps(before_apps, after_apps)
    }

    IO.puts(Jason.encode!(payload))
    :ok
  end

  defp start_scenario("baseline") do
    load_scenario_apps("baseline")

    case Application.ensure_all_started(:arbor_contracts) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "baseline start failed: #{inspect(reason)}"
    end
  end

  defp start_scenario(scenario) when scenario in ["proposed_gated", "proposed_eager"] do
    load_scenario_apps(scenario)
    start_merged_runtime_deps()

    case Application.ensure_all_started(:arbor_kernel_startup_footprint_probe) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "proposed start failed: #{inspect(reason)}"
    end
  end

  defp load_scenario_apps("baseline") do
    _ = Application.load(:arbor_contracts)
    :ok
  end

  defp load_scenario_apps(_proposed) do
    Enum.each(
      [:arbor_contracts, :arbor_kernel_startup_footprint_probe | @owner_apps],
      fn app ->
        _ = Application.load(app)
      end
    )

    :ok
  end

  defp start_merged_runtime_deps do
    [:arbor_kernel_startup_footprint_probe | @retired_owners]
    |> Enum.flat_map(fn app -> List.wrap(Application.spec(app, :applications)) end)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(@external_runtime_exclusions, &1))
    |> Enum.each(fn dep ->
      case Application.ensure_all_started(dep) do
        {:ok, _} -> :ok
        {:error, reason} -> raise "merged runtime start failed: #{inspect(dep)} #{inspect(reason)}"
      end
    end)
  end

  defp snapshot do
    tables = :ets.all()

    %{
      "process_count" => :erlang.system_info(:process_count),
      "ets_table_count" => length(tables),
      "ets_memory_words" => ets_memory_words(tables),
      "beam_memory_bytes" => :erlang.memory(:total)
    }
  end

  defp ets_memory_words(tables) do
    Enum.reduce(tables, 0, fn table, acc ->
      case :ets.info(table, :memory) do
        n when is_integer(n) and n >= 0 -> acc + n
        _ -> acc
      end
    end)
  end

  defp supervisor_children("baseline") do
    Enum.reduce(
      [Arbor.Common.Supervisor, Arbor.Signals.Supervisor, Arbor.Monitor.Supervisor],
      0,
      fn name, acc -> acc + count_tree(name) end
    )
  end

  defp supervisor_children(_proposed) do
    count_tree(ArborKernelStartupFootprintProbe.Supervisor)
  end

  defp count_tree(name_or_pid) do
    case children_of(name_or_pid) do
      :error ->
        0

      children ->
        Enum.reduce(children, 0, fn
          {_id, pid, :supervisor, _mods}, acc when is_pid(pid) ->
            acc + 1 + count_tree(pid)

          {_id, pid, :worker, _mods}, acc when is_pid(pid) ->
            acc + 1

          {_id, :restarting, _type, _mods}, acc ->
            acc + 1

          _other, acc ->
            acc
        end)
    end
  end

  defp children_of(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> :error
      pid -> children_of(pid)
    end
  end

  defp children_of(pid) when is_pid(pid) do
    Supervisor.which_children(pid)
  catch
    :exit, _ -> :error
  end

  defp logger_filter_count do
    filters =
      case :logger.get_handler_config(:default) do
        {:ok, %{filters: filters}} when is_list(filters) -> filters
        {:ok, config} when is_map(config) -> Map.get(config, :filters, [])
        {:ok, config} when is_list(config) -> Keyword.get(config, :filters, [])
        _ -> []
      end

    Enum.count(List.wrap(filters), fn
      {:api_key_redaction, _} -> true
      _ -> false
    end)
  end

  defp telemetry_handler_count do
    :telemetry.list_handlers(@security_bridge_event)
    |> Enum.count(fn handler ->
      Map.get(handler, :id) == @security_bridge_id and
        Map.get(handler, :event_name) == @security_bridge_event
    end)
  end

  defp started_owner_apps do
    started = MapSet.new(started_app_names())

    @owner_apps
    |> Enum.filter(&MapSet.member?(started, &1))
    |> Enum.map(&Atom.to_string/1)
  end

  defp started_runtime_apps(before_apps, after_apps) do
    before_set = MapSet.new(before_apps)

    after_apps
    |> Enum.reject(&MapSet.member?(before_set, &1))
    |> Enum.reject(&MapSet.member?(@external_runtime_exclusions, &1))
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
  end

  defp started_app_names do
    Application.started_applications()
    |> Enum.map(fn {name, _desc, _vsn} -> name end)
    |> Enum.sort()
  end

  defp os_pid do
    case Integer.parse(System.pid()) do
      {pid, ""} -> pid
      _ -> 0
    end
  end
end
