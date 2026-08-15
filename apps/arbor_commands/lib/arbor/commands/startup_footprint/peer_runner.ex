defmodule Arbor.Commands.StartupFootprint.PeerRunner do
  @moduledoc """
  Monitored OTP `:peer` ownership for the K3B startup-footprint probe.

  Starts one descendant BEAM over `standard_io` using the current pinned
  Erlang executable, installs a validated current code path, and invokes
  only the fixed Commands-owned probe MFA. Callers cannot choose the
  executable, module, function, environment, or Erlang arguments.
  """

  alias Arbor.Commands.StartupFootprint.PeerProbe
  alias Arbor.Common.SafePath

  @probe_module PeerProbe
  @probe_function :measure
  @probe_arity 1
  @scenarios ["baseline", "proposed_gated", "proposed_eager"]

  @boot_timeout_ms 30_000
  @call_timeout_ms 60_000
  @shutdown_timeout_ms 5_000
  @worker_slack_ms 5_000

  @max_code_paths 512
  @max_path_bytes 4_096
  @max_path_bytes_total 256_000

  @seed_apps [
    :elixir,
    :jason,
    :telemetry,
    :recon,
    :arbor_kernel,
    :arbor_kernel_runtime
  ]

  # Probe module only — do not start or recurse this application's closure.
  @path_only_apps [:arbor_commands]

  @otp_path_owned MapSet.new([
                    :asn1,
                    :common_test,
                    :compiler,
                    :crypto,
                    :dialyzer,
                    :diameter,
                    :edoc,
                    :eldap,
                    :erl_interface,
                    :erts,
                    :et,
                    :eunit,
                    :ftp,
                    :hipe,
                    :inets,
                    :jinterface,
                    :kernel,
                    :megaco,
                    :mnesia,
                    :observer,
                    :odbc,
                    :os_mon,
                    :parsetools,
                    :public_key,
                    :reltool,
                    :runtime_tools,
                    :sasl,
                    :snmp,
                    :ssh,
                    :ssl,
                    :stdlib,
                    :syntax_tools,
                    :tftp,
                    :tools,
                    :wx
                  ])

  @spec probe_mfa() :: {module(), atom(), 1}
  def probe_mfa, do: {@probe_module, @probe_function, @probe_arity}

  @spec timeouts() :: %{
          boot_ms: pos_integer(),
          call_ms: pos_integer(),
          shutdown_ms: pos_integer()
        }
  def timeouts do
    %{
      boot_ms: @boot_timeout_ms,
      call_ms: @call_timeout_ms,
      shutdown_ms: @shutdown_timeout_ms
    }
  end

  @spec pinned_erlang_executable() :: {:ok, String.t()} | {:error, term()}
  def pinned_erlang_executable do
    root = List.to_string(:code.root_dir())
    exec = Path.join([root, "bin", "erl"])

    cond do
      not String.valid?(exec) ->
        {:error, :peer_exec_invalid}

      control_bytes?(exec) ->
        {:error, :peer_exec_control_byte}

      true ->
        case File.stat(exec) do
          {:ok, %{type: :regular, mode: mode}} ->
            if Bitwise.band(mode, 0o111) != 0 do
              {:ok, exec}
            else
              {:error, {:peer_exec_not_executable, exec}}
            end

          {:ok, _} ->
            {:error, {:peer_exec_not_regular, exec}}

          {:error, :enoent} ->
            {:error, :peer_exec_missing}

          {:error, reason} ->
            {:error, {:peer_exec_unreadable, reason}}
        end
    end
  end

  @doc false
  @spec start_opts() :: {:ok, map()} | {:error, term()}
  def start_opts do
    with {:ok, exec} <- pinned_erlang_executable() do
      {:ok, fixed_start_opts(exec)}
    end
  end

  @spec admit_current_code_path() :: {:ok, [String.t()]} | {:error, term()}
  def admit_current_code_path do
    with {:ok, paths} <- collect_required_paths() do
      admit_paths(paths)
    end
  end

  @spec admit_paths([term()]) :: {:ok, [String.t()]} | {:error, term()}
  def admit_paths(paths) when is_list(paths) do
    case proper_list_count(paths) do
      :invalid ->
        {:error, :peer_code_path_invalid}

      0 ->
        {:error, :peer_code_path_empty}

      count when count > @max_code_paths ->
        {:error, {:peer_code_path_count, count}}

      _count ->
        reduce_paths(paths)
    end
  end

  def admit_paths(_), do: {:error, :peer_code_path_invalid}

  @spec measure_all() :: {:ok, %{String.t() => map()}} | {:error, term()}
  def measure_all do
    with {:ok, _exec} <- pinned_erlang_executable(),
         {:ok, paths} <- admit_current_code_path() do
      Enum.reduce_while(@scenarios, {:ok, %{}}, fn scenario, {:ok, acc} ->
        case measure_with_admitted_paths(scenario, paths) do
          {:ok, sample} -> {:cont, {:ok, Map.put(acc, scenario, sample)}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  @spec measure_scenario(String.t()) :: {:ok, map()} | {:error, term()}
  def measure_scenario(scenario) when scenario in @scenarios do
    with {:ok, _exec} <- pinned_erlang_executable(),
         {:ok, paths} <- admit_current_code_path() do
      measure_with_admitted_paths(scenario, paths)
    end
  end

  def measure_scenario(scenario), do: {:error, {:invalid_scenario, scenario}}

  if Mix.env() == :test do
    @doc false
    @spec __test_run_owned__(pos_integer(), pid() | nil, (pid() -> term())) :: term()
    def __test_run_owned__(budget_ms, announce, work_fun)
        when is_integer(budget_ms) and budget_ms > 0 and is_function(work_fun, 1) do
      announce_pid =
        case announce do
          pid when is_pid(pid) -> pid
          _ -> nil
        end

      with {:ok, paths} <- admit_current_code_path() do
        run_owned(
          "test",
          budget_ms,
          fn control ->
            with :ok <- install_runtime(control, paths) do
              work_fun.(control)
            end
          end,
          announce_pid
        )
      end
    end

    def __test_run_owned__(_, _, _), do: {:error, :invalid_test_run_owned}

    @doc false
    @spec __test_peer_call__(pid(), module(), atom(), list(), term()) ::
            {:ok, term()} | {:error, term()}
    def __test_peer_call__(control, module, function, args, context)
        when is_pid(control) and is_atom(module) and is_atom(function) and is_list(args) do
      bounded_peer_call(control, module, function, args, context)
    end

    def __test_peer_call__(_, _, _, _, _), do: {:error, :invalid_test_peer_call}

    @doc false
    @spec __test_consult_app_file__(String.t(), atom()) :: {:ok, [atom()]} | {:error, term()}
    def __test_consult_app_file__(ebin, app) when is_binary(ebin) and is_atom(app) do
      consult_app_applications(ebin, app)
    end

    def __test_consult_app_file__(_, _), do: {:error, :invalid_consult}
  end

  defp measure_with_admitted_paths(scenario, paths) do
    run_owned(scenario, worker_budget_ms(), fn control ->
      with :ok <- install_runtime(control, paths) do
        call_probe(control, scenario)
      end
    end)
  end

  defp install_runtime(control, paths) when is_pid(control) and is_list(paths) do
    with {:ok, admitted} <- admit_paths(paths),
         :ok <- add_paths(control, admitted) do
      start_elixir(control)
    end
  end

  defp stop_peer(control) when is_pid(control) do
    if Process.alive?(control) do
      mon = Process.monitor(control)

      try do
        _ = :peer.stop(control)
      catch
        _, _ ->
          Process.exit(control, :kill)
      end

      case await_down(mon, @shutdown_timeout_ms) do
        :ok ->
          :ok

        :timeout ->
          Process.exit(control, :kill)

          case await_down(mon, @shutdown_timeout_ms) do
            :ok -> :ok
            :timeout -> {:error, {:peer_stop_timeout, control}}
          end
      end
    else
      :ok
    end
  end

  defp stop_peer(_), do: :ok

  defp run_owned(scenario, budget_ms, work_fun, announce \\ nil) do
    parent = self()
    token = make_ref()

    {worker, worker_mon} =
      spawn_monitor(fn ->
        owned_worker(parent, token, work_fun)
      end)

    if is_pid(announce), do: send(announce, {:peer_worker, worker})

    deadline = monotonic_ms() + budget_ms

    await_owned(
      token,
      worker,
      worker_mon,
      _control = nil,
      _control_mon = nil,
      _guardian = nil,
      false,
      false,
      scenario,
      deadline,
      announce
    )
  end

  defp owned_worker(caller, token, work_fun) do
    guardian = spawn_link(fn -> guard_caller(caller) end)
    send(caller, {token, :guardian, guardian})

    result =
      case start_peer() do
        {:ok, control} ->
          send(caller, {token, :control, control})
          work_result = invoke_work(work_fun, control)
          true = Process.unlink(control)
          stop_result = stop_peer(control)
          finish_work(work_result, stop_result, control)

        {:error, _} = err ->
          err
      end

    case reap_guardian(guardian) do
      :ok ->
        send(caller, {token, :result, result})

      {:error, reason} ->
        send(caller, {token, :result, {:error, {:guardian_reap_failed, reason}}})
    end
  end

  defp guard_caller(caller) do
    mon = Process.monitor(caller)

    receive do
      {:DOWN, ^mon, :process, ^caller, reason} ->
        exit({:caller_death, reason})
    end
  end

  defp reap_guardian(guardian) when is_pid(guardian) do
    Process.unlink(guardian)
    Process.exit(guardian, :shutdown)
    mon = Process.monitor(guardian)

    case await_down(mon, @shutdown_timeout_ms) do
      :ok ->
        :ok

      :timeout ->
        Process.exit(guardian, :kill)

        case await_down(mon, @shutdown_timeout_ms) do
          :ok -> :ok
          :timeout -> {:error, {:guardian_alive, guardian}}
        end
    end
  end

  defp invoke_work(work_fun, control) do
    work_fun.(control)
  catch
    kind, reason ->
      {:error, {:peer_crash, {kind, reason}}}
  end

  defp finish_work(result, :ok, _control), do: result

  defp finish_work(_result, {:error, reason}, control) do
    {:error, {:peer_cleanup_failed, control, reason}}
  end

  defp await_owned(
         token,
         worker,
         worker_mon,
         control,
         control_mon,
         guardian,
         worker_down?,
         control_down?,
         scenario,
         deadline,
         announce
       ) do
    timeout = max(0, deadline - monotonic_ms())

    receive do
      {^token, :guardian, new_guardian} when is_pid(new_guardian) ->
        if is_pid(announce), do: send(announce, {:peer_guardian, new_guardian})

        await_owned(
          token,
          worker,
          worker_mon,
          control,
          control_mon,
          new_guardian,
          worker_down?,
          control_down?,
          scenario,
          deadline,
          announce
        )

      {^token, :control, new_control} when is_pid(new_control) ->
        mon = Process.monitor(new_control)
        if is_pid(announce), do: send(announce, {:peer_control, new_control})

        await_owned(
          token,
          worker,
          worker_mon,
          new_control,
          mon,
          guardian,
          worker_down?,
          false,
          scenario,
          deadline,
          announce
        )

      {^token, :result, result} ->
        case await_descendants_down(
               worker,
               worker_mon,
               control,
               control_mon,
               guardian,
               worker_down?,
               control_down?
             ) do
          :ok ->
            result

          {:error, reason} ->
            {:error, {:peer_cleanup_failed, scenario, reason}}
        end

      {:DOWN, ^worker_mon, :process, ^worker, reason} ->
        case flush_result(token) do
          {:ok, result} ->
            case await_descendants_down(
                   worker,
                   worker_mon,
                   control,
                   control_mon,
                   guardian,
                   true,
                   control_down?
                 ) do
              :ok ->
                result

              {:error, cleanup} ->
                {:error, {:peer_cleanup_failed, scenario, cleanup}}
            end

          :none ->
            case await_descendants_down(
                   worker,
                   worker_mon,
                   control,
                   control_mon,
                   guardian,
                   true,
                   control_down?
                 ) do
              :ok ->
                {:error, {:peer_crash, scenario, reason}}

              {:error, cleanup} ->
                {:error, {:peer_cleanup_failed, scenario, cleanup}}
            end
        end

      {:DOWN, ^control_mon, :process, ^control, _reason} ->
        await_owned(
          token,
          worker,
          worker_mon,
          control,
          control_mon,
          guardian,
          worker_down?,
          true,
          scenario,
          deadline,
          announce
        )
    after
      timeout ->
        Process.exit(worker, :kill)

        {control, control_mon, control_down?} =
          absorb_late_control(token, control, control_mon, control_down?, announce)

        guardian = absorb_late_guardian(token, guardian, announce)

        if is_pid(control) and not control_down? do
          Process.exit(control, :kill)
        end

        case await_descendants_down(
               worker,
               worker_mon,
               control,
               control_mon,
               guardian,
               worker_down?,
               control_down?
             ) do
          :ok ->
            {:error,
             {:peer_timeout, scenario, %{worker: worker, control: control, guardian: guardian}}}

          {:error, reason} ->
            {:error, {:peer_cleanup_failed, scenario, reason}}
        end
    end
  end

  defp flush_result(token) do
    receive do
      {^token, :result, result} -> {:ok, result}
    after
      0 -> :none
    end
  end

  defp absorb_late_control(token, control, control_mon, control_down?, announce) do
    receive do
      {^token, :control, new_control} when is_pid(new_control) ->
        mon = Process.monitor(new_control)
        if is_pid(announce), do: send(announce, {:peer_control, new_control})
        {new_control, mon, false}
    after
      100 ->
        {control, control_mon, control_down?}
    end
  end

  defp absorb_late_guardian(token, guardian, announce) do
    receive do
      {^token, :guardian, new_guardian} when is_pid(new_guardian) ->
        if is_pid(announce), do: send(announce, {:peer_guardian, new_guardian})
        new_guardian
    after
      100 ->
        guardian
    end
  end

  defp await_descendants_down(
         worker,
         worker_mon,
         control,
         control_mon,
         guardian,
         worker_down?,
         control_down?
       ) do
    with :ok <-
           await_pair_down(
             worker,
             worker_mon,
             control,
             control_mon,
             worker_down?,
             control_down?
           ) do
      await_guardian_down(guardian)
    end
  end

  defp await_guardian_down(nil), do: :ok

  defp await_guardian_down(guardian) when is_pid(guardian) do
    mon = Process.monitor(guardian)

    case await_down(mon, @shutdown_timeout_ms) do
      :ok ->
        :ok

      :timeout ->
        Process.exit(guardian, :kill)

        case await_down(mon, @shutdown_timeout_ms) do
          :ok -> :ok
          :timeout -> {:error, {:guardian_alive, guardian}}
        end
    end
  end

  defp await_pair_down(worker, worker_mon, control, control_mon, worker_down?, control_down?) do
    deadline = monotonic_ms() + @shutdown_timeout_ms

    await_pair_loop(
      worker,
      worker_mon,
      control,
      control_mon,
      worker_down?,
      control_down? or is_nil(control_mon),
      deadline
    )
  end

  defp await_pair_loop(_worker, _worker_mon, _control, _control_mon, true, true, _deadline) do
    :ok
  end

  defp await_pair_loop(
         worker,
         worker_mon,
         control,
         control_mon,
         worker_down?,
         control_down?,
         deadline
       ) do
    timeout = max(0, deadline - monotonic_ms())

    receive do
      {:DOWN, ^worker_mon, :process, _, _} ->
        await_pair_loop(worker, worker_mon, control, control_mon, true, control_down?, deadline)

      {:DOWN, ^control_mon, :process, _, _} ->
        await_pair_loop(worker, worker_mon, control, control_mon, worker_down?, true, deadline)
    after
      timeout ->
        missing =
          []
          |> then(fn acc -> if worker_down?, do: acc, else: [{:worker_down, worker} | acc] end)
          |> then(fn acc ->
            if control_down?, do: acc, else: [{:control_down, control} | acc]
          end)

        {:error, {:monitor_down_missing, missing}}
    end
  end

  defp start_peer do
    with {:ok, exec} <- pinned_erlang_executable() do
      case :peer.start_link(fixed_start_opts(exec)) do
        {:ok, control, _node} when is_pid(control) ->
          {:ok, control}

        {:ok, control} when is_pid(control) ->
          {:ok, control}

        {:error, reason} ->
          {:error, {:peer_boot_failed, reason}}
      end
    end
  catch
    :exit, {:timeout, _} ->
      {:error, {:peer_boot_timeout, @boot_timeout_ms}}

    kind, reason ->
      {:error, {:peer_boot_failed, {kind, reason}}}
  end

  defp fixed_start_opts(exec) do
    %{
      connection: :standard_io,
      exec: String.to_charlist(exec),
      wait_boot: @boot_timeout_ms,
      shutdown: {:halt, @shutdown_timeout_ms},
      peer_down: :crash
    }
  end

  defp add_paths(control, paths) do
    charlists = Enum.map(paths, &String.to_charlist/1)

    case bounded_peer_call(control, :code, :add_paths, [charlists], :install) do
      {:ok, :ok} -> :ok
      {:ok, true} -> :ok
      {:ok, other} -> {:error, {:peer_code_path_install, other}}
      {:error, _} = err -> err
    end
  end

  defp start_elixir(control) do
    case bounded_peer_call(
           control,
           :application,
           :ensure_all_started,
           [:elixir],
           :elixir
         ) do
      {:ok, {:ok, _started}} -> :ok
      {:ok, :ok} -> :ok
      {:ok, other} -> {:error, {:peer_elixir_start_failed, other}}
      {:error, _} = err -> err
    end
  end

  defp call_probe(control, scenario) do
    case bounded_peer_call(
           control,
           @probe_module,
           @probe_function,
           [scenario],
           {:measure, scenario}
         ) do
      {:ok, {:ok, sample}} when is_map(sample) ->
        {:ok, sample}

      {:ok, {:error, reason}} ->
        {:error, {:peer_measure_failed, scenario, reason}}

      {:ok, other} ->
        {:error, {:peer_measure_invalid, scenario, other}}

      {:error, _} = err ->
        err
    end
  end

  defp bounded_peer_call(control, module, function, args, context) do
    {:ok, :peer.call(control, module, function, args, @call_timeout_ms)}
  catch
    :exit, {:timeout, _} ->
      {:error, {:peer_call_timeout, context}}

    :exit, reason ->
      {:error, {:peer_call_crash, context, reason}}

    kind, reason ->
      {:error, {:peer_call_crash, context, {kind, reason}}}
  end

  defp await_down(nil, _timeout_ms), do: :ok

  defp await_down(mon, timeout_ms) do
    receive do
      {:DOWN, ^mon, :process, _, _} -> :ok
    after
      timeout_ms -> :timeout
    end
  end

  defp worker_budget_ms do
    @boot_timeout_ms + @call_timeout_ms + @shutdown_timeout_ms + @worker_slack_ms
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp collect_required_paths do
    with {:ok, paths} <- collect_required_paths(@seed_apps, MapSet.new(), []) do
      add_path_only_apps(paths)
    end
  end

  defp add_path_only_apps(paths) do
    Enum.reduce_while(@path_only_apps, {:ok, paths}, fn app, {:ok, acc} ->
      case app_ebin(app) do
        {:ok, ebin} ->
          if ebin in acc do
            {:cont, {:ok, acc}}
          else
            {:cont, {:ok, acc ++ [ebin]}}
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp collect_required_paths([], _seen, paths), do: {:ok, Enum.reverse(paths)}

  defp collect_required_paths([app | rest], seen, paths) do
    cond do
      not is_atom(app) ->
        {:error, {:peer_code_path_app, app}}

      MapSet.member?(seen, app) ->
        collect_required_paths(rest, seen, paths)

      MapSet.member?(@otp_path_owned, app) ->
        collect_required_paths(rest, MapSet.put(seen, app), paths)

      true ->
        seen = MapSet.put(seen, app)

        case app_ebin(app) do
          {:ok, ebin} ->
            case consult_app_applications(ebin, app) do
              {:ok, more} ->
                collect_required_paths(more ++ rest, seen, [ebin | paths])

              {:error, _} = err ->
                err
            end

          {:error, _} = err ->
            err
        end
    end
  end

  defp app_ebin(app) do
    case :code.lib_dir(app) do
      {:error, _} ->
        {:error, {:peer_code_path_missing_app, app}}

      dir when is_list(dir) or is_binary(dir) ->
        dir_string = if is_list(dir), do: List.to_string(dir), else: dir
        ebin = Path.join(dir_string, "ebin")

        cond do
          app_file?(ebin, app) ->
            {:ok, ebin}

          app_file?(dir_string, app) ->
            {:ok, dir_string}

          true ->
            {:error, {:peer_code_path_missing_app, app}}
        end

      _ ->
        {:error, {:peer_code_path_missing_app, app}}
    end
  end

  defp app_file?(dir, app) do
    File.dir?(dir) and File.regular?(Path.join(dir, Atom.to_string(app) <> ".app"))
  end

  defp consult_app_applications(ebin, app) do
    app_file = Path.join(ebin, Atom.to_string(app) <> ".app")

    case :file.consult(String.to_charlist(app_file)) do
      {:ok, [{:application, ^app, props}]} when is_list(props) ->
        applications = Keyword.get(props, :applications, [])
        included = Keyword.get(props, :included_applications, [])
        optional = Keyword.get(props, :optional_applications, [])

        if is_list(applications) and is_list(included) and is_list(optional) do
          {:ok, (applications -- optional) ++ included}
        else
          {:error, {:peer_app_spec_malformed, app}}
        end

      {:ok, other} ->
        {:error, {:peer_app_consult_malformed, app, other}}

      {:error, reason} ->
        {:error, {:peer_app_consult_failed, app, reason}}
    end
  end

  defp reduce_paths(paths) do
    Enum.reduce_while(paths, {:ok, [], MapSet.new(), 0}, fn path, {:ok, acc, seen, total} ->
      case admit_one_path(path) do
        {:ok, canonical, size} ->
          cond do
            MapSet.member?(seen, canonical) ->
              {:cont, {:ok, acc, seen, total}}

            total + size > @max_path_bytes_total ->
              {:halt, {:error, :peer_code_path_total_bytes}}

            true ->
              {:cont, {:ok, acc ++ [canonical], MapSet.put(seen, canonical), total + size}}
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, admitted, _seen, _total} -> {:ok, admitted}
      {:error, _} = err -> err
    end
  end

  defp admit_one_path(path) when is_list(path) do
    case path_list_to_string(path) do
      {:ok, string} -> admit_one_path(string)
      :error -> {:error, :peer_code_path_invalid}
    end
  end

  defp admit_one_path(path) when is_binary(path) do
    cond do
      path == "" ->
        {:error, :peer_code_path_empty_entry}

      not String.valid?(path) ->
        {:error, :peer_code_path_invalid}

      byte_size(path) > @max_path_bytes ->
        {:error, {:peer_code_path_entry_bytes, byte_size(path)}}

      control_bytes?(path) ->
        {:error, :peer_code_path_control_byte}

      true ->
        admit_resolved_path(path)
    end
  end

  defp admit_one_path(_), do: {:error, :peer_code_path_invalid}

  defp admit_resolved_path(path) do
    case SafePath.resolve_real(path) do
      {:ok, real} ->
        size = byte_size(real)

        cond do
          size > @max_path_bytes ->
            {:error, {:peer_code_path_entry_bytes, size}}

          true ->
            case File.lstat(real) do
              {:ok, %{type: :directory}} ->
                {:ok, real, size}

              {:ok, _} ->
                {:error, {:peer_code_path_not_directory, path}}

              {:error, reason} ->
                {:error, {:peer_code_path_stat, path, reason}}
            end
        end

      {:error, reason} ->
        {:error, {:peer_code_path_unresolved, path, reason}}
    end
  end

  defp path_list_to_string(list) when is_list(list) do
    if proper_charlist?(list) do
      case :unicode.characters_to_binary(list) do
        bin when is_binary(bin) -> {:ok, bin}
        _ -> :error
      end
    else
      :error
    end
  end

  defp proper_charlist?([]), do: true

  defp proper_charlist?([cp | rest]) when is_integer(cp) and cp >= 0 and cp <= 0x10FFFF do
    proper_charlist?(rest)
  end

  defp proper_charlist?(_), do: false

  defp proper_list_count(list), do: proper_list_count(list, 0)
  defp proper_list_count([], n), do: n
  defp proper_list_count([_head | rest], n), do: proper_list_count(rest, n + 1)
  defp proper_list_count(_improper, _n), do: :invalid

  defp control_bytes?(path) when is_binary(path) do
    path
    |> :binary.bin_to_list()
    |> Enum.any?(&(&1 <= 0x1F))
  end

  defp control_bytes?(_), do: true
end
