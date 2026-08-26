defmodule Arbor.KernelRuntime.ApplicationSpecSecurityRegressionTest do
  @moduledoc """
  Security regression: generated OTP spec omits network/os_mon providers, and
  a fresh peer :activation_only start neither starts nor loads them.
  """
  use ExUnit.Case, async: false

  alias Arbor.KernelRuntime.ApplicationSpecPeer

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

  defp consult_env_app!(app),
    do: ApplicationSpecPeer.consult_env_app!(app, Mix.Project.build_path())

  defp start_peer!, do: ApplicationSpecPeer.start!()
  defp stop_peer(control), do: ApplicationSpecPeer.stop(control)

  defp prepare_restricted_peer!(control, app) do
    :ok = ApplicationSpecPeer.prepare_restricted!(control, app, [], Mix.Project.build_path())
    ApplicationSpecPeer.copy_selected_env!(control, :arbor_kernel, [:kernel_runtime])
  end

  defp put_peer_runtime(control, updates),
    do: ApplicationSpecPeer.put_activation_profile(control, updates)

  defp refute_omitted_env_ebins_on_peer(control),
    do: ApplicationSpecPeer.assert_omitted_ebins(control, @omitted, Mix.Project.build_path())

  defp peer_started_apps(control), do: ApplicationSpecPeer.started_applications(control)
  defp peer_loaded_apps(control), do: ApplicationSpecPeer.loaded_applications(control)

  defp peer_call(control, module, function, args) do
    ApplicationSpecPeer.call(control, module, function, args)
  end
end
