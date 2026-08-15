defmodule Arbor.KernelRuntime.ApplicationTest do
  @moduledoc """
  K4B: `Arbor.KernelRuntime.Application` nests the existing Common, Signals,
  and Monitor Application start MFAs as `:one_for_one` supervisor children,
  in that order, without flattening or altering their own supervision
  strategies. This test proves the composed lifecycle in both the disabled
  (test-default) gate state, and hermetically flipped to enabled.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  @common_registries [
    Arbor.Common.NodeRegistry,
    Arbor.Common.ReadableRegistry,
    Arbor.Common.WriteableRegistry,
    Arbor.Common.ComputeRegistry,
    Arbor.Common.PipelineResolver,
    Arbor.Common.ActionRegistry
  ]

  @security_bridge_handler_id "arbor-signals-security-telemetry-bridge"
  @signals_children [
    {Arbor.Signals.Store, []},
    {Arbor.Signals.TopicKeys, []},
    {Arbor.Signals.Channels, []},
    {Arbor.Signals.Bus, []},
    {Arbor.Signals.Relay, []}
  ]
  @config_sections [:common, :signals, :monitor]

  test "the runtime supervisor owns the three nested application supervisors" do
    assert Process.whereis(Arbor.KernelRuntime.Supervisor)
    assert Process.whereis(Arbor.Common.Supervisor)
    assert Process.whereis(Arbor.Signals.Supervisor)
    assert Process.whereis(Arbor.Monitor.Supervisor)

    child_ids =
      Arbor.KernelRuntime.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
      |> MapSet.new()

    assert child_ids ==
             MapSet.new([
               Arbor.Common.Application,
               Arbor.Signals.Application,
               Arbor.Monitor.Application
             ])
  end

  test "nested applications honor disabled and enabled child gates" do
    config_before = Map.new(@config_sections, &{&1, Application.fetch_env(:arbor_kernel, &1)})

    on_exit(fn -> restore_test_runtime(config_before) end)

    stop_runtime()
    put_section(:common, start_children: false)
    put_section(:signals, start_children: false, security_telemetry_bridge: false)
    put_section(:monitor, start_children: false)
    Arbor.Signals.Telemetry.detach(@security_bridge_handler_id)
    remove_redaction_filter()

    assert {:ok, _} = Application.ensure_all_started(:arbor_kernel_runtime)
    assert_nested_supervisors()
    assert Process.whereis(Arbor.Common.OAuth.HttpClient.Pool)

    for reg <- @common_registries do
      refute Process.whereis(reg), "expected #{inspect(reg)} to be absent"
    end

    refute Process.whereis(Arbor.Common.SkillLibrary)
    refute Process.whereis(Arbor.Common.AgentTelemetry.Store)
    refute Process.whereis(Arbor.Common.CapabilityIndex)

    for {module, _opts} <- @signals_children do
      refute Process.whereis(module), "expected #{inspect(module)} to be absent"
    end

    refute Process.whereis(Arbor.Monitor.HealingSupervisor)
    refute Process.whereis(Arbor.Monitor.MetricsStore)
    refute Process.whereis(Arbor.Monitor.Poller)
    refute Process.whereis(Arbor.Monitor.SupervisorMonitor)
    assert :api_key_redaction in logger_filter_ids()
    refute @security_bridge_handler_id in telemetry_handler_ids()

    stop_runtime()
    put_section(:common, start_children: true)

    put_section(:signals,
      start_children: true,
      security_telemetry_bridge: true,
      checkpoint_module: nil,
      checkpoint_store: nil,
      authorizer: Arbor.Signals.Adapters.OpenAuthorizer,
      allow_open_authorizer: true
    )

    put_section(:monitor,
      start_children: true,
      signal_emission_enabled: false,
      suppression_window_ms: :timer.seconds(5)
    )

    assert {:ok, _} = Application.ensure_all_started(:arbor_kernel_runtime)
    assert_nested_supervisors()
    assert Process.whereis(:arbor_registry)

    for reg <- @common_registries do
      assert Process.whereis(reg), "expected #{inspect(reg)} to be present"
    end

    assert Process.whereis(Arbor.Common.SkillLibrary)
    assert Process.whereis(Arbor.Common.AgentTelemetry.Store)
    assert Process.whereis(Arbor.Common.CapabilityIndex)
    assert Process.whereis(Arbor.Common.OAuth.HttpClient.Pool)

    for {module, _opts} <- @signals_children do
      assert Process.whereis(module), "expected #{inspect(module)} to be present"
    end

    assert @security_bridge_handler_id in telemetry_handler_ids()
    assert Process.whereis(Arbor.Monitor.HealingSupervisor)
    assert Process.whereis(Arbor.Monitor.MetricsStore)
    assert Process.whereis(Arbor.Monitor.Poller)
    assert Process.whereis(Arbor.Monitor.SupervisorMonitor)
  end

  defp assert_nested_supervisors do
    assert Process.whereis(Arbor.KernelRuntime.Supervisor)
    assert Process.whereis(Arbor.Common.Supervisor)
    assert Process.whereis(Arbor.Signals.Supervisor)
    assert Process.whereis(Arbor.Monitor.Supervisor)
  end

  defp put_section(section, updates) do
    current = Application.get_env(:arbor_kernel, section, []) || []
    value = Enum.reduce(updates, current, fn {key, item}, acc -> Keyword.put(acc, key, item) end)
    Application.put_env(:arbor_kernel, section, value)
  end

  defp stop_runtime do
    case Application.stop(:arbor_kernel_runtime) do
      :ok -> :ok
      {:error, {:not_started, :arbor_kernel_runtime}} -> :ok
    end

    stop_named(Arbor.Monitor.MetricsStore)
    stop_named(Arbor.Monitor.Poller)
  end

  defp stop_named(name) do
    if pid = Process.whereis(name), do: GenServer.stop(pid)
    :ok
  end

  defp restore_test_runtime(config_before) do
    stop_runtime()

    Enum.each(config_before, fn
      {section, {:ok, value}} -> Application.put_env(:arbor_kernel, section, value)
      {section, :error} -> Application.delete_env(:arbor_kernel, section)
    end)

    assert {:ok, _} = Application.ensure_all_started(:arbor_kernel_runtime)
    restore_signals_test_children()
    restore_monitor_test_children()
  end

  defp restore_signals_test_children do
    Enum.each(@signals_children, fn {module, _opts} = child ->
      case Supervisor.start_child(Arbor.Signals.Supervisor, child) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, :already_present} ->
          :ok = Supervisor.delete_child(Arbor.Signals.Supervisor, module)
          {:ok, _pid} = Supervisor.start_child(Arbor.Signals.Supervisor, child)
      end
    end)
  end

  defp restore_monitor_test_children do
    Enum.each([Arbor.Monitor.MetricsStore, Arbor.Monitor.Poller], fn module ->
      case Supervisor.start_child(Arbor.Monitor.Supervisor, {module, []}) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, :already_present} ->
          :ok = Supervisor.delete_child(Arbor.Monitor.Supervisor, module)
          {:ok, _pid} = Supervisor.start_child(Arbor.Monitor.Supervisor, {module, []})
      end
    end)
  end

  defp remove_redaction_filter do
    case :logger.remove_handler_filter(:default, :api_key_redaction) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp logger_filter_ids do
    case :logger.get_handler_config(:default) do
      {:ok, %{filters: filters}} -> Enum.map(filters, fn {id, _filter} -> id end)
      _ -> []
    end
  end

  defp telemetry_handler_ids do
    for handler <- :telemetry.list_handlers([]), do: handler.id
  end
end
