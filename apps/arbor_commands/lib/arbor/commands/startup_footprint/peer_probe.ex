defmodule Arbor.Commands.StartupFootprint.PeerProbe do
  @moduledoc false

  alias Arbor.Commands.StartupFootprint.Core
  alias Arbor.Commands.StartupFootprint.ProposedApplication

  @scenarios ["baseline", "proposed_gated", "proposed_eager"]
  @owner_apps [:arbor_common, :arbor_signals, :arbor_monitor]
  @retired_owners [:arbor_contracts, :arbor_common, :arbor_signals, :arbor_monitor]
  @proposed_owner :arbor_startup_footprint_proposed
  @kernel_owner :arbor_kernel
  @external_runtime_exclusions MapSet.new([
                                 @proposed_owner,
                                 @kernel_owner | @retired_owners
                               ])
  @security_bridge_id "arbor-signals-security-telemetry-bridge"
  @security_bridge_event [:arbor, :security, :authorization_granted]
  @proposed_supervisor Arbor.Commands.StartupFootprint.ProposedSupervisor

  @spec measure(String.t()) :: {:ok, map()} | {:error, term()}
  def measure(scenario) when scenario in @scenarios do
    :ok = configure_kernel_gates()
    before_apps = started_app_names()
    before = snapshot()
    started_at = :erlang.monotonic_time()
    :ok = start_scenario(scenario)

    boot_time_us =
      System.convert_time_unit(:erlang.monotonic_time() - started_at, :native, :microsecond)

    after_snap = snapshot()
    after_apps = started_app_names()

    Core.normalize_sample(%{
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
    })
  rescue
    exception ->
      {:error, {:probe_exception, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:probe_crash, {kind, reason}}}
  end

  def measure(scenario), do: {:error, {:invalid_scenario, scenario}}

  @doc false
  @spec __test_app_applications__(atom()) :: {:ok, [atom()]} | {:error, term()}
  def __test_app_applications__(app) when is_atom(app) do
    case Application.spec(app, :applications) do
      apps when is_list(apps) -> {:ok, apps}
      other -> {:error, {:application_spec_missing, app, other}}
    end
  end

  def __test_app_applications__(_), do: {:error, :invalid_app}

  defp configure_kernel_gates do
    :ok = load_app!(:arbor_kernel)

    Application.put_env(:arbor_kernel, :common, [start_children: true], persistent: true)

    Application.put_env(
      :arbor_kernel,
      :signals,
      [start_children: true, security_telemetry_bridge: true],
      persistent: true
    )

    Application.put_env(:arbor_kernel, :monitor, [start_children: true], persistent: true)
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

    case Application.ensure_all_started(@proposed_owner) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "proposed start failed: #{inspect(reason)}"
    end
  end

  defp load_scenario_apps("baseline") do
    load_app!(:arbor_contracts)
  end

  defp load_scenario_apps(scenario) do
    Enum.each([:arbor_contracts | @owner_apps], &load_app!/1)
    load_proposed_owner(scenario)
  end

  defp load_app!(app) do
    case Application.load(app) do
      :ok -> :ok
      {:error, {:already_loaded, ^app}} -> :ok
      {:error, reason} -> raise "application load failed: #{inspect(app)} #{inspect(reason)}"
    end
  end

  defp load_proposed_owner(scenario) do
    spec =
      {:application, @proposed_owner,
       [
         {:description, ~c"K3B proposed owner fixture"},
         {:vsn, ~c"0.0.0"},
         {:modules, [ProposedApplication]},
         {:registered, [@proposed_supervisor]},
         {:applications, [:kernel, :stdlib, :elixir, :logger]},
         {:mod, {ProposedApplication, [scenario]}}
       ]}

    case :application.load(spec) do
      :ok -> :ok
      {:error, {:already_loaded, _}} -> :ok
      {:error, reason} -> raise "proposed owner load failed: #{inspect(reason)}"
    end
  end

  defp start_merged_runtime_deps do
    [@proposed_owner | @retired_owners]
    |> Enum.flat_map(&app_applications!/1)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(@external_runtime_exclusions, &1))
    |> Enum.each(fn dep ->
      case Application.ensure_all_started(dep) do
        {:ok, _} -> :ok
        {:error, reason} -> raise "merged runtime start failed: #{inspect(dep)} #{inspect(reason)}"
      end
    end)
  end

  defp app_applications!(app) do
    case Application.spec(app, :applications) do
      apps when is_list(apps) ->
        apps

      other ->
        raise "application spec missing: #{inspect(app)} #{inspect(other)}"
    end
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

  defp supervisor_children(_proposed), do: count_tree(@proposed_supervisor)

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
    @security_bridge_event
    |> :telemetry.list_handlers()
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
