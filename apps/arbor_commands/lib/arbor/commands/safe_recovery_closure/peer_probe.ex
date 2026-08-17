defmodule Arbor.Commands.SafeRecoveryClosure.PeerProbe do
  @moduledoc """
  Commands-owned measurement protocol for one E0B3 fresh-VM closure run.

  A fresh OTP `:peer` BEAM invokes only `measure/1` with the closed
  profile name. The probe takes a pre-start snapshot, starts the frozen
  selected applications, takes a post-start snapshot, then stops what it
  started and reports bounded shutdown. Callers cannot choose the
  executable, module, function, cookie, or selected set.
  """

  @profile "safe_recovery"
  @selected ["arbor_kernel", "arbor_kernel_runtime", "arbor_security", "arbor_trust"]
  @app_atoms %{
    "arbor_kernel" => :arbor_kernel,
    "arbor_kernel_runtime" => :arbor_kernel_runtime,
    "arbor_security" => :arbor_security,
    "arbor_trust" => :arbor_trust,
    "e0b3_fixture" => :e0b3_fixture
  }
  @keep_apps MapSet.new([:kernel, :stdlib, :compiler, :elixir, :logger, :sasl])
  @max_names 512
  @max_modules 4_096

  @spec measure(String.t()) :: {:ok, map()} | {:error, term()}
  def measure(@profile) do
    measure_selected(@selected)
  rescue
    exception ->
      {:error, {:probe_exception, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:probe_crash, {kind, reason}}}
  end

  def measure(other), do: {:error, {:invalid_profile, other}}

  if Mix.env() == :test do
    @doc false
    @spec __test_measure__([String.t()]) :: {:ok, map()} | {:error, term()}
    def __test_measure__(selected) when is_list(selected) do
      if Enum.all?(selected, &is_binary/1) do
        measure_selected(selected)
      else
        {:error, :invalid_selected}
      end
    end

    def __test_measure__(_), do: {:error, :invalid_selected}
  end

  defp measure_selected(selected) do
    apps = Enum.map(selected, &app_atom!/1)
    pre = snapshot()
    started_at = :erlang.monotonic_time()
    started = start_selected(apps)

    boot_time_us =
      System.convert_time_unit(:erlang.monotonic_time() - started_at, :native, :microsecond)

    post = snapshot()
    shutdown = stop_started(started)

    {:ok,
     %{
       "pre_start" => pre,
       "post_start" => post,
       "shutdown" => shutdown,
       "observations" => %{
         "os_pid" => os_pid(),
         "boot_time_us" => boot_time_us,
         "cookie_set" => cookie_set?()
       }
     }}
  end

  defp app_atom!(name) do
    case Map.fetch(@app_atoms, name) do
      {:ok, atom} -> atom
      :error -> raise "unknown selected application #{name}"
    end
  end

  defp start_selected(apps) do
    Enum.reduce(apps, [], fn app, acc ->
      case Application.ensure_all_started(app) do
        {:ok, started} -> acc ++ started
        {:error, {:already_started, ^app}} -> acc
        {:error, reason} -> raise "selected start failed: #{inspect(app)} #{inspect(reason)}"
      end
    end)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(@keep_apps, &1))
  end

  defp stop_started(started) do
    Enum.each(Enum.reverse(started), fn app ->
      _ = Application.stop(app)
    end)

    remaining =
      started
      |> Enum.filter(&started?/1)
      |> Enum.map(&Atom.to_string/1)
      |> Enum.sort()

    %{
      "status" => if(remaining == [], do: "bounded", else: "failed"),
      "remaining_names" => remaining
    }
  end

  defp started?(app) do
    Enum.any?(Application.started_applications(), fn {name, _desc, _vsn} -> name == app end)
  end

  defp snapshot do
    %{
      "applications" => started_apps(),
      "modules" => loaded_modules(),
      "registered_names" => registered_names(),
      "supervisors" => supervisors(),
      "ets_tables" => ets_tables(),
      "ports" => named_ports(),
      "nifs" => nifs(),
      "logger_handlers" => logger_handlers(),
      "telemetry_handlers" => telemetry_handlers(),
      "listeners" => listeners()
    }
  end

  defp started_apps do
    Application.started_applications()
    |> Enum.map(fn {name, _desc, _vsn} ->
      %{"name" => Atom.to_string(name), "state" => "started"}
    end)
    |> Enum.sort_by(& &1["name"])
    |> Enum.take(@max_names)
  end

  defp loaded_modules do
    :code.all_loaded()
    |> Enum.flat_map(fn {mod, _file} ->
      case :application.get_application(mod) do
        {:ok, app} ->
          [%{"module" => Atom.to_string(mod), "application" => Atom.to_string(app)}]

        :undefined ->
          []
      end
    end)
    |> Enum.sort_by(&{&1["module"], &1["application"]})
    |> Enum.take(@max_modules)
  end

  defp registered_names do
    Process.registered()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
    |> Enum.take(@max_names)
  end

  defp supervisors do
    Process.registered()
    |> Enum.flat_map(fn name ->
      case supervisor_children(name) do
        :error ->
          []

        children ->
          [%{"name" => Atom.to_string(name), "children" => Enum.sort(children)}]
      end
    end)
    |> Enum.sort_by(& &1["name"])
    |> Enum.take(@max_names)
  end

  defp supervisor_children(name) do
    pid = Process.whereis(name)

    if is_pid(pid) and supervisor_process?(pid) do
      for {id, _child, _type, _mods} <- Supervisor.which_children(pid) do
        child_name(id)
      end
    else
      :error
    end
  catch
    :exit, _ -> :error
  end

  defp supervisor_process?(pid) do
    match?({:supervisor, _, _}, :proc_lib.translate_initial_call(pid))
  rescue
    _ -> false
  end

  defp child_name(id) when is_atom(id), do: Atom.to_string(id)
  defp child_name(id) when is_binary(id), do: id
  defp child_name(_id), do: "anonymous"

  defp ets_tables do
    :ets.all()
    |> Enum.flat_map(&ets_entry/1)
    |> Enum.sort_by(& &1["name"])
    |> Enum.take(@max_names)
  end

  defp ets_entry(tid) do
    name = :ets.info(tid, :name)
    protection = :ets.info(tid, :protection)
    heir = :ets.info(tid, :heir)
    owner = :ets.info(tid, :owner)

    if is_atom(name) and name != :undefined and protection in [:public, :protected, :private] do
      [
        %{
          "name" => Atom.to_string(name),
          "owner_application" => owner_app(owner),
          "protection" => Atom.to_string(protection),
          "heir" => heir_token(heir)
        }
      ]
    else
      []
    end
  rescue
    _ -> []
  end

  defp heir_token(:none), do: "none"
  defp heir_token(_), do: "named"

  defp named_ports do
    :erlang.ports()
    |> Enum.flat_map(&port_entry/1)
    |> Enum.sort_by(& &1["name"])
    |> Enum.take(@max_names)
  end

  defp port_entry(port) do
    case :erlang.port_info(port, :name) do
      {:name, name} when is_list(name) ->
        owner =
          case :erlang.port_info(port, :connected) do
            {:connected, pid} -> owner_app(pid)
            _ -> "unknown"
          end

        [%{"name" => List.to_string(name), "owner_application" => owner}]

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp nifs do
    :code.all_loaded()
    |> Enum.flat_map(fn {mod, _} ->
      if native_module?(mod), do: [Atom.to_string(mod)], else: []
    end)
    |> Enum.sort()
    |> Enum.take(@max_names)
  end

  defp native_module?(mod) do
    case mod.module_info(:nifs) do
      [_ | _] -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp logger_handlers do
    :logger.get_handler_ids()
    |> Enum.map(&handler_id/1)
    |> Enum.sort()
    |> Enum.take(@max_names)
  end

  defp handler_id(id) when is_atom(id), do: Atom.to_string(id)
  defp handler_id(id) when is_binary(id), do: id
  defp handler_id(_id), do: "anonymous"

  defp telemetry_handlers do
    :telemetry.list_handlers([:arbor])
    |> Enum.map(&handler_id(Map.get(&1, :id)))
    |> Enum.sort()
    |> Enum.uniq()
    |> Enum.take(@max_names)
  rescue
    _ -> []
  end

  defp listeners do
    :erlang.ports()
    |> Enum.flat_map(&listener_entry/1)
    |> Enum.sort_by(&{&1["kind"], &1["owner_application"]})
    |> Enum.take(@max_names)
  end

  defp listener_entry(port) do
    case classify_listener(port) do
      nil ->
        []

      kind ->
        owner =
          case :erlang.port_info(port, :connected) do
            {:connected, pid} -> owner_app(pid)
            _ -> "unknown"
          end

        [%{"kind" => kind, "owner_application" => owner}]
    end
  rescue
    _ -> []
  end

  defp classify_listener(port) do
    case :inet.sockname(port) do
      {:ok, _} ->
        case :inet.peername(port) do
          {:error, :enotconn} -> "listen"
          {:ok, _} -> "connect"
          _ -> "accept"
        end

      _ ->
        nil
    end
  end

  defp owner_app(pid) when is_pid(pid) do
    case :application.get_application(pid) do
      {:ok, app} -> Atom.to_string(app)
      :undefined -> "unknown"
    end
  end

  defp owner_app(_), do: "unknown"

  defp os_pid do
    case Integer.parse(System.pid()) do
      {pid, ""} -> pid
      _ -> 0
    end
  end

  defp cookie_set? do
    case System.fetch_env("RELEASE_COOKIE") do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> true
      _ -> false
    end
  end
end
