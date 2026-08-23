defmodule Arbor.Commands.SafeRecoveryClosure.PeerProbe do
  @moduledoc """
  Commands-owned measurement protocol for one E0B3 fresh-VM closure run.

  A fresh OTP `:peer` BEAM invokes only `measure/1` with the closed
  profile name. The probe takes a pre-start snapshot, starts the frozen
  selected applications, takes a post-start snapshot, then stops what it
  started and reports bounded shutdown. Callers cannot choose the
  executable, module, function, cookie, or selected set.
  """

  alias Arbor.Common.SafePath

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
  @max_authority_root_bytes 4_096
  # Keep these paired with PeerRunner's generated prefix and 32-byte token
  # (64 lowercase hexadecimal characters).
  @authority_root_prefix "arbor-e0b3-security-"
  @authority_root_token_hex_bytes 64

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

    @doc false
    @spec __test_authority_root_validation__(:missing | :wrong_prefix) :: {:error, term()}
    def __test_authority_root_validation__(:missing) do
      System.delete_env("ARBOR_SECURITY_STATE_DIR")
      install_ephemeral_authority_root()
    end

    def __test_authority_root_validation__(:wrong_prefix) do
      case System.fetch_env("ARBOR_SECURITY_STATE_DIR") do
        {:ok, root} ->
          System.put_env("ARBOR_SECURITY_STATE_DIR", root <> "-wrong-prefix")
          install_ephemeral_authority_root()

        :error ->
          {:error, :ephemeral_authority_root_missing}
      end
    end

    @doc false
    @spec __test_install_ephemeral_authority_root__() :: :ok | {:error, term()}
    def __test_install_ephemeral_authority_root__, do: install_ephemeral_authority_root()
  end

  defp measure_selected(selected) do
    apps = Enum.map(selected, &app_atom!/1)
    pre = snapshot()

    with {:ok, sys_config} <- apply_release_sys_config(),
         :ok <- install_ephemeral_authority_root() do
      started_at = :erlang.monotonic_time()
      {started, start_failures} = start_selected(apps)

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
           "cookie_set" => cookie_set?(),
           "authority_root_configured" => true,
           "sys_config" => sys_config,
           "start_failures" => Enum.sort_by(start_failures, & &1["name"])
         }
       }}
    end
  end

  defp app_atom!(name) do
    case Map.fetch(@app_atoms, name) do
      {:ok, atom} -> atom
      :error -> raise "unknown selected application #{name}"
    end
  end

  defp start_selected(apps) do
    {started, failed} =
      Enum.reduce(apps, {[], []}, fn app, {started_acc, failed_acc} ->
        case Application.ensure_all_started(app) do
          {:ok, started} ->
            {started_acc ++ started, failed_acc}

          {:error, {:already_started, ^app}} ->
            {started_acc, failed_acc}

          {:error, reason} ->
            {started_acc,
             [
               %{
                 "name" => Atom.to_string(app),
                 "reason" => format_start_reason(reason)
               }
               | failed_acc
             ]}
        end
      end)

    started =
      started
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(@keep_apps, &1))

    {started, failed}
  end

  defp format_start_reason(reason) do
    text = inspect(reason, limit: 8, printable_limit: 64)

    cond do
      not String.valid?(text) -> "invalid_utf8"
      byte_size(text) > 256 -> binary_part(text, 0, 256)
      true -> text
    end
  end

  defp apply_release_sys_config do
    case System.fetch_env("RELEASE_ROOT") do
      :error ->
        {:ok, "absent"}

      {:ok, root} ->
        apply_sys_config_from_root(root)
    end
  end

  # The manager is the sole producer of this process-private value. Validate
  # its exact shape and filesystem binding before making it the final
  # descendant-local override; never select a fallback in the peer.
  defp install_ephemeral_authority_root do
    with {:ok, root} <- fetch_ephemeral_authority_root(),
         :ok <- validate_ephemeral_authority_root(root) do
      Application.put_env(:arbor_security, :authority_state_root, root)
    end
  end

  defp fetch_ephemeral_authority_root do
    case System.fetch_env("ARBOR_SECURITY_STATE_DIR") do
      {:ok, root} when is_binary(root) -> {:ok, root}
      _missing -> {:error, :ephemeral_authority_root_missing}
    end
  end

  defp validate_ephemeral_authority_root(root) do
    with :ok <- validate_ephemeral_authority_root_text(root),
         {:ok, tmp} <- resolve_tmp_root(),
         :ok <- validate_ephemeral_authority_root_name(root, tmp),
         {:ok, real} <- resolve_authority_root(root),
         true <- real == root,
         {:ok, %File.Stat{type: :directory, mode: mode}} <- File.lstat(real),
         true <- Bitwise.band(mode, 0o077) == 0 do
      :ok
    else
      _unsafe -> {:error, :ephemeral_authority_root_unsafe}
    end
  end

  defp validate_ephemeral_authority_root_text(root) do
    cond do
      root == "" -> {:error, :invalid}
      not String.valid?(root) -> {:error, :invalid}
      byte_size(root) > @max_authority_root_bytes -> {:error, :invalid}
      String.contains?(root, <<0>>) -> {:error, :invalid}
      String.contains?(root, "\n") -> {:error, :invalid}
      Path.type(root) != :absolute -> {:error, :invalid}
      Path.expand(root) != root -> {:error, :invalid}
      true -> :ok
    end
  end

  defp resolve_tmp_root do
    case SafePath.resolve_real(System.tmp_dir!()) do
      {:ok, tmp} -> {:ok, tmp}
      {:error, _reason} -> {:error, :unsafe}
    end
  end

  defp validate_ephemeral_authority_root_name(root, tmp) do
    name = Path.basename(root)
    token = String.replace_prefix(name, @authority_root_prefix, "")

    if Path.dirname(root) == tmp and
         byte_size(token) == @authority_root_token_hex_bytes and
         byte_size(name) == byte_size(@authority_root_prefix) + @authority_root_token_hex_bytes and
         lower_hex?(token) do
      :ok
    else
      {:error, :unsafe}
    end
  end

  defp resolve_authority_root(root) do
    case SafePath.resolve_real(root) do
      {:ok, real} -> {:ok, real}
      {:error, _reason} -> {:error, :unsafe}
    end
  end

  defp lower_hex?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte in ?0..?9 or byte in ?a..?f end)
  end

  defp apply_sys_config_from_root(root) do
    cond do
      not is_binary(root) or root == "" or not String.valid?(root) ->
        {:error, :invalid_release_root}

      String.contains?(root, <<0>>) or String.contains?(root, "\n") ->
        {:error, :invalid_release_root}

      true ->
        case find_sys_config(root) do
          {:ok, path} -> consult_and_apply_sys_config(path)
          :none -> {:ok, "absent"}
          {:error, _} = error -> error
        end
    end
  end

  defp find_sys_config(root) do
    releases = Path.join(root, "releases")

    case File.lstat(releases) do
      {:error, :enoent} -> :none
      {:ok, %{type: :symlink}} -> {:error, :sys_config_releases_symlink}
      {:ok, %{type: :directory}} -> list_sys_configs(releases)
      {:ok, _} -> {:error, :sys_config_releases_not_directory}
      {:error, reason} -> {:error, {:sys_config_releases_unreadable, reason}}
    end
  end

  defp list_sys_configs(releases) do
    case File.ls(releases) do
      {:ok, entries} -> select_sys_config(releases, Enum.sort(entries))
      {:error, reason} -> {:error, {:sys_config_releases_unreadable, reason}}
    end
  end

  defp select_sys_config(releases, entries) do
    paths = Enum.flat_map(entries, &sys_config_entry(releases, &1))

    case paths do
      [] -> :none
      [{:error, _} = error | _] -> error
      [path] -> {:ok, path}
      [_ | _] -> {:error, :sys_config_ambiguous}
    end
  end

  defp sys_config_entry(releases, entry) do
    path = Path.join([releases, entry, "sys.config"])

    case File.lstat(path) do
      {:ok, %{type: :regular}} -> [path]
      {:ok, %{type: :symlink}} -> [{:error, :sys_config_symlink}]
      _ -> []
    end
  end

  defp consult_and_apply_sys_config(path) do
    case :file.consult(String.to_charlist(path)) do
      {:ok, [config]} when is_list(config) ->
        case apply_consulted_config(config) do
          :ok -> {:ok, "applied"}
          {:error, _} = error -> error
        end

      {:ok, _} ->
        {:error, :invalid_sys_config}

      {:error, reason} ->
        {:error, {:sys_config_unreadable, reason}}
    end
  end

  defp apply_consulted_config(config) do
    Enum.reduce_while(config, :ok, fn
      {app, kvs}, :ok when is_atom(app) and is_list(kvs) ->
        if Keyword.keyword?(kvs) do
          Enum.each(kvs, fn {key, value} ->
            Application.put_env(app, key, value)
          end)

          {:cont, :ok}
        else
          {:halt, {:error, :invalid_sys_config}}
        end

      _other, :ok ->
        {:halt, {:error, :invalid_sys_config}}
    end)
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
