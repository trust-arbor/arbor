defmodule Arbor.KernelRuntime.ApplicationSpecSecurityRegressionTest do
  @moduledoc """
  Security regression: generated OTP spec omits network/os_mon providers, and
  a fresh peer :activation_only start neither starts nor loads them.
  """
  use ExUnit.Case, async: false

  @omitted [:os_mon, :finch, :mint, :req, :recon]
  @required MapSet.new([
              :arbor_kernel,
              :crypto,
              :elixir,
              :jason,
              :kernel,
              :logger,
              :stdlib,
              :telemetry,
              :zoi
            ])
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

  @tag :fast
  test "security regression: consulted .app required set includes crypto and omits provider roots" do
    props = consult_env_app!(:arbor_kernel_runtime)
    required = MapSet.new(Keyword.get(props, :applications, []))
    optional = Keyword.get(props, :optional_applications, [])
    included = Keyword.get(props, :included_applications, [])

    assert required == @required
    assert optional == []
    assert included == []

    Enum.each(@omitted, fn app ->
      refute app in required
      refute app in optional
      refute app in included
    end)
  end

  @tag :slow
  @tag :integration
  @tag :security_regression
  test "security regression: activation_only peer does not start or load provider apps" do
    control = start_peer!()

    try do
      prepare_restricted_peer!(control, :arbor_kernel_runtime)
      refute_omitted_env_ebins_on_peer(control)
      put_peer_runtime(control, start_profile: :activation_only)

      assert {:ok, _} =
               peer_call(control, Application, :ensure_all_started, [:arbor_kernel_runtime])

      refute_omitted_env_ebins_on_peer(control)

      started = peer_started_apps(control)
      loaded = peer_loaded_apps(control)

      assert :crypto in started

      Enum.each(@omitted, fn app ->
        refute app in started
        refute app in loaded
      end)

      refute peer_call(control, :erlang, :module_loaded, [Mint])
      refute peer_call(control, :erlang, :module_loaded, [Finch])
      refute peer_call(control, :erlang, :module_loaded, [Req])
      refute peer_call(control, :erlang, :module_loaded, [:recon])
      refute peer_call(control, :erlang, :module_loaded, [Arbor.Common.Application])
      refute peer_call(control, :erlang, :module_loaded, [Arbor.Signals.Application])
      refute peer_call(control, :erlang, :module_loaded, [Arbor.Monitor.Application])

      assert is_pid(
               peer_call(control, Process, :whereis, [Arbor.KernelRuntime.BootProfileBinding])
             )

      assert peer_call(control, Process, :whereis, [Arbor.KernelRuntime.ProviderGate]) == nil
      assert peer_call(control, Process, :whereis, [Arbor.Common.Supervisor]) == nil
      assert peer_call(control, Process, :whereis, [Arbor.Signals.Supervisor]) == nil
      assert peer_call(control, Process, :whereis, [Arbor.Monitor.Supervisor]) == nil
      assert peer_call(control, Process, :whereis, [Arbor.Common.OAuth.HttpClient.Pool]) == nil
      assert peer_call(control, Process, :whereis, [Arbor.Signals.Bus]) == nil
      assert peer_call(control, Process, :whereis, [Arbor.Monitor.Poller]) == nil
    after
      stop_peer(control)
    end
  end

  defp consult_env_app!(app) do
    path = env_app_file!(app)
    {:ok, [{:application, ^app, props}]} = :file.consult(String.to_charlist(path))
    props
  end

  defp env_app_file!(app) do
    Path.join([Mix.Project.build_path(), "lib", "#{app}", "ebin", "#{app}.app"])
  end

  defp start_peer! do
    case :peer.start_link(%{connection: :standard_io, wait_boot: 30_000}) do
      {:ok, control} when is_pid(control) -> control
      {:ok, control, _node} -> control
      other -> flunk("peer start failed: #{inspect(other)}")
    end
  end

  defp stop_peer(control) do
    try do
      :peer.stop(control)
    catch
      _, _ -> :ok
    end
  end

  defp prepare_restricted_peer!(control, app) do
    paths = required_ebins(app)
    _ = peer_call(control, :code, :add_paths, [Enum.map(paths, &String.to_charlist/1)])
    {:ok, _} = peer_call(control, :application, :ensure_all_started, [:elixir])
    copy_kernel_runtime_env!(control)
    :ok
  end

  defp required_ebins(app) do
    collect_ebins([app], MapSet.new(), [])
  end

  defp collect_ebins([], _seen, paths), do: Enum.reverse(paths)

  defp collect_ebins([app | rest], seen, paths) do
    cond do
      MapSet.member?(seen, app) ->
        collect_ebins(rest, seen, paths)

      MapSet.member?(@otp_boot, app) ->
        collect_ebins(rest, MapSet.put(seen, app), paths)

      MapSet.member?(@language_runtime, app) ->
        seen = MapSet.put(seen, app)
        ebin = language_runtime_ebin!(app)
        more = consult_required(ebin, app)
        collect_ebins(more ++ rest, seen, [ebin | paths])

      true ->
        seen = MapSet.put(seen, app)
        ebin = env_app_ebin!(app)
        more = consult_required(ebin, app)
        collect_ebins(more ++ rest, seen, [ebin | paths])
    end
  end

  defp env_app_ebin!(app) do
    ebin = Path.join([Mix.Project.build_path(), "lib", "#{app}", "ebin"])
    path = Path.join(ebin, "#{app}.app")

    unless File.exists?(path) do
      flunk("missing env-build .app for #{inspect(app)} at #{path}")
    end

    ebin
  end

  defp language_runtime_ebin!(app) do
    dir =
      case :code.lib_dir(app) do
        path when is_list(path) -> List.to_string(path)
        path when is_binary(path) -> path
        other -> flunk("language runtime #{inspect(app)} lib_dir failed: #{inspect(other)}")
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

  defp copy_kernel_runtime_env!(control) do
    current = Application.get_env(:arbor_kernel, :kernel_runtime, [])

    :ok =
      peer_call(control, Application, :put_env, [
        :arbor_kernel,
        :kernel_runtime,
        current,
        [persistent: true]
      ])
  end

  defp put_peer_runtime(control, updates) do
    current = peer_call(control, Application, :get_env, [:arbor_kernel, :kernel_runtime, []])

    value =
      Enum.reduce(updates, current, fn {key, item}, acc -> Keyword.put(acc, key, item) end)

    :ok =
      peer_call(control, Application, :put_env, [
        :arbor_kernel,
        :kernel_runtime,
        value,
        [persistent: true]
      ])
  end

  defp refute_omitted_env_ebins_on_peer(control) do
    peer_path =
      control
      |> peer_call(:code, :get_path, [])
      |> Enum.map(&path_entry_to_string/1)
      |> Enum.map(&Path.expand/1)
      |> MapSet.new()

    Enum.each(@omitted, fn app ->
      ebin = Path.join([Mix.Project.build_path(), "lib", "#{app}", "ebin"])

      if File.dir?(ebin) do
        refute MapSet.member?(peer_path, Path.expand(ebin)),
               "peer inherited omitted env-build ebin #{ebin}"
      end
    end)
  end

  defp path_entry_to_string(entry) when is_list(entry), do: List.to_string(entry)
  defp path_entry_to_string(entry) when is_binary(entry), do: entry

  defp peer_started_apps(control) do
    control
    |> peer_call(Application, :started_applications, [])
    |> Enum.map(&elem(&1, 0))
  end

  defp peer_loaded_apps(control) do
    control
    |> peer_call(Application, :loaded_applications, [])
    |> Enum.map(&elem(&1, 0))
  end

  defp peer_call(control, module, function, args) do
    :peer.call(control, module, function, args, 60_000)
  end
end
