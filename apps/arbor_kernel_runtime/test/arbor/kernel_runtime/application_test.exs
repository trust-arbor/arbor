defmodule Arbor.KernelRuntime.ApplicationTest do
  @moduledoc """
  P1A-2: `Arbor.KernelRuntime.Application` starts the boot-profile binding
  owner first under `:rest_for_one`, then nests Common, Signals, and Monitor
  Application start MFAs in that order without flattening their strategies.
  Owner death tears down later children. Missing or `:full` keeps those
  nested applications after the owner; `:activation_only` starts only the
  owner; unknown start profiles fail closed.

  Malformed `:kernel_runtime` namespace values raise `ArgumentError`
  from Config. `children_for_profile_safe/0` remaps that raise to
  `{:error, {:boot_profile_binding_failed, :malformed_stage_zero}}`
  so `Application.start` fails closed as a binding error, later
  rest_for_one children never start, and the VM-lifetime freeze is
  not replaced.
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
  @config_sections [:common, :signals, :monitor, :kernel_runtime]
  @full_child_ids MapSet.new([
                    Arbor.KernelRuntime.BootProfileBinding,
                    Arbor.KernelRuntime.ProviderGate,
                    Arbor.Common.Application,
                    Arbor.Signals.Application,
                    Arbor.Monitor.Application
                  ])
  @provider_roots [:os_mon, :recon, :mint, :finch, :req]
  @required_apps MapSet.new([
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
  @activation_only_child_ids MapSet.new([Arbor.KernelRuntime.BootProfileBinding])
  @invalid_start_profiles [:unknown, "full", "activation_only", nil, 1, %{}]

  test "the runtime supervisor owns the three nested application supervisors" do
    assert Process.whereis(Arbor.KernelRuntime.Supervisor)
    assert Process.whereis(Arbor.KernelRuntime.BootProfileBinding)
    assert Process.whereis(Arbor.KernelRuntime.ProviderGate)
    assert Process.whereis(Arbor.Common.Supervisor)
    assert Process.whereis(Arbor.Signals.Supervisor)
    assert Process.whereis(Arbor.Monitor.Supervisor)

    assert runtime_child_ids() == @full_child_ids

    assert rest_for_one_order() == [
             Arbor.KernelRuntime.BootProfileBinding,
             Arbor.KernelRuntime.ProviderGate,
             Arbor.Common.Application,
             Arbor.Signals.Application,
             Arbor.Monitor.Application
           ]

    started = started_app_set()

    Enum.each(@provider_roots, fn app ->
      assert MapSet.member?(started, app), "expected #{inspect(app)} started on :full"
    end)
  end

  test "security regression: arbor_kernel_runtime required apps omit network and os_mon providers" do
    assert required_app_set(:arbor_kernel_runtime) == @required_apps
    refute_spec_members(:arbor_kernel_runtime, @provider_roots ++ [:llm_db, :boundary])
    assert optional_app_list(:arbor_kernel_runtime) == []
    assert included_app_list(:arbor_kernel_runtime) == []
  end

  test "missing or :full start profile nests the three application supervisors" do
    config_before = Map.new(@config_sections, &{&1, Application.fetch_env(:arbor_kernel, &1)})

    on_exit(fn -> restore_test_runtime(config_before) end)

    stop_runtime()
    drop_start_profile()

    assert {:ok, _} = Application.ensure_all_started(:arbor_kernel_runtime)
    assert_nested_supervisors()
    assert runtime_child_ids() == @full_child_ids
    assert Process.whereis(Arbor.Common.OAuth.HttpClient.Pool)

    stop_runtime()
    put_section(:kernel_runtime, start_profile: :full)

    assert {:ok, _} = Application.ensure_all_started(:arbor_kernel_runtime)
    assert_nested_supervisors()
    assert runtime_child_ids() == @full_child_ids
    assert Process.whereis(Arbor.Common.OAuth.HttpClient.Pool)
  end

  test "activation_only starts none of Common, Signals, or Monitor" do
    config_before = Map.new(@config_sections, &{&1, Application.fetch_env(:arbor_kernel, &1)})

    on_exit(fn -> restore_test_runtime(config_before) end)

    stop_runtime()
    put_section(:kernel_runtime, start_profile: :activation_only)

    assert {:ok, _} = Application.ensure_all_started(:arbor_kernel_runtime)
    assert Process.whereis(Arbor.KernelRuntime.Supervisor)
    assert Process.whereis(Arbor.KernelRuntime.BootProfileBinding)
    assert runtime_child_ids() == @activation_only_child_ids
    refute Process.whereis(Arbor.Common.Supervisor)
    refute Process.whereis(Arbor.Signals.Supervisor)
    refute Process.whereis(Arbor.Monitor.Supervisor)
    refute Process.whereis(Arbor.Common.OAuth.HttpClient.Pool)
    refute Process.whereis(Arbor.Signals.Bus)
    refute Process.whereis(Arbor.Monitor.Poller)
    refute Process.whereis(Arbor.Common.Extension.ProtectedRegistry)
    refute Process.whereis(Arbor.KernelRuntime.ProviderGate)
  end

  test "unknown or malformed start profile fails closed" do
    config_before = Map.new(@config_sections, &{&1, Application.fetch_env(:arbor_kernel, &1)})

    on_exit(fn -> restore_test_runtime(config_before) end)

    stop_runtime()

    Enum.each(@invalid_start_profiles, fn value ->
      put_section(:kernel_runtime, start_profile: value)

      # ensure_all_started/1 nests the reason with the MFA that produced it.
      assert {:error,
              {:arbor_kernel_runtime, {reason, {Arbor.KernelRuntime.Application, :start, _}}}} =
               Application.ensure_all_started(:arbor_kernel_runtime)

      assert reason == {:invalid_start_profile, value}

      refute Process.whereis(Arbor.KernelRuntime.Supervisor)
      refute Process.whereis(Arbor.Common.OAuth.HttpClient.Pool)
      refute Process.whereis(Arbor.Signals.Bus)
      refute Process.whereis(Arbor.Monitor.Poller)
      refute Process.whereis(Arbor.KernelRuntime.ProviderGate)
    end)
  end

  test "security regression: invalid start profile starts zero provider apps" do
    config_before = Map.new(@config_sections, &{&1, Application.fetch_env(:arbor_kernel, &1)})
    on_exit(fn -> restore_test_runtime(config_before) end)

    stop_runtime()
    stop_provider_roots()
    before = started_app_set()
    put_section(:kernel_runtime, start_profile: :unknown)

    assert {:error, _} = Application.ensure_all_started(:arbor_kernel_runtime)
    refute Process.whereis(Arbor.KernelRuntime.Supervisor)

    assert MapSet.intersection(
             MapSet.difference(started_app_set(), before),
             MapSet.new(@provider_roots)
           ) ==
             MapSet.new()
  end

  test "security regression: downstream start failure leaves admitted providers running and does not peel unrelated errors" do
    config_before = Map.new(@config_sections, &{&1, Application.fetch_env(:arbor_kernel, &1)})
    on_exit(fn -> restore_test_runtime(config_before) end)

    stop_runtime()
    stop_provider_roots()
    {:ok, squat} = Agent.start_link(fn -> :ok end, name: Arbor.Common.Supervisor)
    on_exit(fn -> stop_named(Arbor.Common.Supervisor) end)
    assert Process.alive?(squat)

    put_section(:kernel_runtime, start_profile: :full)

    assert {:error,
            {:arbor_kernel_runtime, {reason, {Arbor.KernelRuntime.Application, :start, _}}}} =
             Application.ensure_all_started(:arbor_kernel_runtime)

    refute reason == {:provider_gate_name_collision, squat}
    refute match?({:provider_gate_name_collision, _}, reason)
    refute Process.whereis(Arbor.KernelRuntime.Supervisor)
    refute Process.whereis(Arbor.KernelRuntime.ProviderGate)
    assert Process.whereis(Arbor.Common.Supervisor) == squat

    Enum.each(@provider_roots, fn app ->
      assert MapSet.member?(started_app_set(), app), "expected #{inspect(app)} to remain started"
    end)
  end

  test "security regression: gate crash does not stop shared req" do
    assert Process.whereis(Arbor.KernelRuntime.ProviderGate)
    assert req_started?()

    old_common = Process.whereis(Arbor.Common.Supervisor)
    assert is_pid(old_common)

    gate = Process.whereis(Arbor.KernelRuntime.ProviderGate)
    ref = Process.monitor(gate)
    Process.exit(gate, :kill)
    assert_receive {:DOWN, ^ref, :process, ^gate, _reason}, 1_000

    await_true(
      fn ->
        new_gate = Process.whereis(Arbor.KernelRuntime.ProviderGate)
        new_common = Process.whereis(Arbor.Common.Supervisor)

        is_pid(new_gate) and new_gate != gate and is_pid(new_common) and new_common != old_common
      end,
      5_000
    )

    assert req_started?()
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

  defp runtime_child_ids do
    Arbor.KernelRuntime.Supervisor
    |> Supervisor.which_children()
    |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
    |> MapSet.new()
  end

  defp rest_for_one_order do
    Arbor.KernelRuntime.Supervisor
    |> Supervisor.which_children()
    |> Enum.map(&elem(&1, 0))
    |> Enum.reverse()
  end

  defp required_app_set(app) do
    MapSet.new(Application.spec(app, :applications) || [])
  end

  defp optional_app_list(app), do: Application.spec(app, :optional_applications) || []
  defp included_app_list(app), do: Application.spec(app, :included_applications) || []

  defp refute_spec_members(app, names) do
    required = required_app_set(app)
    optional = MapSet.new(optional_app_list(app))
    included = MapSet.new(included_app_list(app))

    Enum.each(names, fn name ->
      refute MapSet.member?(required, name)
      refute MapSet.member?(optional, name)
      refute MapSet.member?(included, name)
    end)
  end

  defp started_app_set do
    Application.started_applications()
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp req_started?, do: MapSet.member?(started_app_set(), :req)

  defp stop_provider_roots do
    Enum.each(Enum.reverse(@provider_roots), fn app ->
      _ = Application.stop(app)
    end)

    :ok
  end

  defp await_true(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_true_loop(fun, deadline)
  end

  defp await_true_loop(fun, deadline) do
    if fun.() do
      true
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        flunk("condition not met before deadline")
      else
        receive do
        after
          min(remaining, 10) -> await_true_loop(fun, deadline)
        end
      end
    end
  end

  defp drop_start_profile do
    current = Application.get_env(:arbor_kernel, :kernel_runtime, []) || []

    value =
      cond do
        is_list(current) and Keyword.keyword?(current) ->
          Keyword.delete(current, :start_profile)

        is_map(current) ->
          Map.delete(current, :start_profile)

        true ->
          current
      end

    Application.put_env(:arbor_kernel, :kernel_runtime, value)
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
