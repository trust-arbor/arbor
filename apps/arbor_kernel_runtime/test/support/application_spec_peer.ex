defmodule Arbor.KernelRuntime.ApplicationSpecPeer do
  @moduledoc false

  @otp_boot MapSet.new([
              :asn1,
              :compiler,
              :crypto,
              :erts,
              :inets,
              :kernel,
              :os_mon,
              :public_key,
              :runtime_tools,
              :sasl,
              :ssl,
              :stdlib
            ])
  @language_runtime MapSet.new([:elixir, :eex, :ex_unit, :iex, :logger, :mix])

  @spec consult_env_app!(atom(), String.t()) :: keyword()
  def consult_env_app!(app, build_path) do
    path = Path.join([build_path, "lib", "#{app}", "ebin", "#{app}.app"])
    {:ok, [{:application, ^app, props}]} = :file.consult(String.to_charlist(path))
    props
  end

  @spec start!() :: pid()
  def start! do
    case :peer.start_link(%{connection: :standard_io, wait_boot: 30_000}) do
      {:ok, control} when is_pid(control) -> control
      {:ok, control, _node} -> control
      other -> raise "peer start failed: #{inspect(other)}"
    end
  end

  @spec stop(pid()) :: :ok
  def stop(control) do
    try do
      :peer.stop(control)
    catch
      _, _ -> :ok
    end
  end

  @spec call(pid(), module(), atom(), [term()]) :: term()
  def call(control, module, function, args) do
    :peer.call(control, module, function, args, 60_000)
  end

  @spec prepare_restricted!(pid(), atom(), [atom()], String.t()) :: :ok
  def prepare_restricted!(control, app, copied_env_apps, build_path) do
    paths = required_ebins(app, build_path)
    _ = call(control, :code, :add_paths, [Enum.map(paths, &String.to_charlist/1)])
    {:ok, _} = call(control, :application, :ensure_all_started, [:elixir])
    Enum.each(copied_env_apps, &copy_app_env!(control, &1))
    :ok
  end

  @spec copy_selected_env!(pid(), atom(), [atom()]) :: :ok
  def copy_selected_env!(control, app, keys) do
    Enum.each(keys, fn key ->
      case Application.fetch_env(app, key) do
        {:ok, value} ->
          :ok = call(control, Application, :put_env, [app, key, value, [persistent: true]])

        :error ->
          :ok
      end
    end)
  end

  @spec put_activation_profile(pid(), keyword()) :: :ok
  def put_activation_profile(control, updates) do
    current = call(control, Application, :get_env, [:arbor_kernel, :kernel_runtime, []])
    value = Enum.reduce(updates, current, fn {key, item}, acc -> Keyword.put(acc, key, item) end)

    call(control, Application, :put_env, [
      :arbor_kernel,
      :kernel_runtime,
      value,
      [persistent: true]
    ])
  end

  @spec assert_omitted_ebins(pid(), [atom()], String.t()) :: :ok
  def assert_omitted_ebins(control, omitted, build_path) do
    peer_path =
      control
      |> call(:code, :get_path, [])
      |> Enum.map(&path_entry_to_string/1)
      |> Enum.map(&Path.expand/1)
      |> MapSet.new()

    Enum.each(omitted, fn app ->
      ebin = Path.join([build_path, "lib", "#{app}", "ebin"])

      if File.dir?(ebin) and MapSet.member?(peer_path, Path.expand(ebin)) do
        raise "peer inherited omitted env-build ebin #{ebin}"
      end
    end)

    :ok
  end

  @spec started_applications(pid()) :: [atom()]
  def started_applications(control) do
    control
    |> call(Application, :started_applications, [])
    |> Enum.map(&elem(&1, 0))
  end

  @spec loaded_applications(pid()) :: [atom()]
  def loaded_applications(control) do
    control
    |> call(Application, :loaded_applications, [])
    |> Enum.map(&elem(&1, 0))
  end

  defp required_ebins(app, build_path),
    do: collect_ebins([app], MapSet.new(), [], build_path)

  defp collect_ebins([], _seen, paths, _build_path), do: Enum.reverse(paths)

  defp collect_ebins([app | rest], seen, paths, build_path) do
    cond do
      MapSet.member?(seen, app) ->
        collect_ebins(rest, seen, paths, build_path)

      MapSet.member?(@otp_boot, app) ->
        collect_ebins(rest, MapSet.put(seen, app), paths, build_path)

      MapSet.member?(@language_runtime, app) ->
        seen = MapSet.put(seen, app)
        ebin = language_runtime_ebin!(app)

        collect_ebins(
          consult_required(ebin, app) ++ rest,
          seen,
          [ebin | paths],
          build_path
        )

      true ->
        seen = MapSet.put(seen, app)
        ebin = env_app_ebin!(app, build_path)

        collect_ebins(
          consult_required(ebin, app) ++ rest,
          seen,
          [ebin | paths],
          build_path
        )
    end
  end

  defp env_app_ebin!(app, build_path) do
    ebin = Path.join([build_path, "lib", "#{app}", "ebin"])
    path = Path.join(ebin, "#{app}.app")

    unless File.exists?(path), do: raise("missing env-build .app for #{inspect(app)} at #{path}")
    ebin
  end

  defp language_runtime_ebin!(app) do
    dir =
      case :code.lib_dir(app) do
        path when is_list(path) -> List.to_string(path)
        path when is_binary(path) -> path
        other -> raise "language runtime #{inspect(app)} lib_dir failed: #{inspect(other)}"
      end

    Path.join(dir, "ebin")
  end

  defp consult_required(ebin, app) do
    props = consult_app_at!(ebin, app)
    applications = Keyword.get(props, :applications, [])
    included = Keyword.get(props, :included_applications, [])
    optional = Keyword.get(props, :optional_applications, [])
    (applications -- optional) ++ included
  end

  defp consult_app_at!(ebin, app) do
    path = Path.join(ebin, "#{app}.app")
    {:ok, [{:application, ^app, props}]} = :file.consult(String.to_charlist(path))
    props
  end

  defp copy_app_env!(control, app) do
    Enum.each(Application.get_all_env(app), fn {key, value} ->
      :ok = call(control, Application, :put_env, [app, key, value, [persistent: true]])
    end)
  end

  defp path_entry_to_string(entry) when is_list(entry), do: List.to_string(entry)
  defp path_entry_to_string(entry) when is_binary(entry), do: entry
end
