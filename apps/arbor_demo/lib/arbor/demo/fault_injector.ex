defmodule Arbor.Demo.FaultInjector do
  @moduledoc """
  Core GenServer that manages fault injection lifecycle.

  Tracks active faults, coordinates with the DynamicSupervisor for
  fault worker processes, and emits signals on inject/clear events.
  """
  use GenServer

  require Logger

  @fault_modules %{
    message_queue_flood: Arbor.Demo.Faults.MessageQueueFlood,
    process_leak: Arbor.Demo.Faults.ProcessLeak,
    supervisor_crash: Arbor.Demo.Faults.SupervisorCrash
  }

  defstruct active_faults: %{}, fault_modules: @fault_modules, supervisor: Arbor.Demo.Supervisor

  # Client API

  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def inject_fault(type, opts \\ []) do
    GenServer.call(__MODULE__, {:inject, type, opts})
  end

  def clear_fault(type) do
    GenServer.call(__MODULE__, {:clear, type})
  end

  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  def active_faults do
    GenServer.call(__MODULE__, :active_faults)
  end

  def fault_status(type) do
    GenServer.call(__MODULE__, {:status, type})
  end

  def available_faults do
    GenServer.call(__MODULE__, :available_faults)
  end

  # Server callbacks

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    extra_modules = Keyword.get(opts, :fault_modules, %{})
    modules = Map.merge(@fault_modules, extra_modules)
    supervisor = Keyword.get(opts, :supervisor, Arbor.Demo.Supervisor)
    {:ok, %__MODULE__{fault_modules: modules, supervisor: supervisor}}
  end

  @impl GenServer
  def handle_call({:inject, type, opts}, _from, state) do
    inject_opts = Keyword.put_new(opts, :supervisor, state.supervisor)

    with {:ok, module} <- find_fault_module(state, type),
         :ok <- check_not_active(state, type),
         {:ok, ref} <- module.inject(inject_opts) do
      fault_info = %{
        module: module,
        ref: ref,
        injected_at: System.system_time(:millisecond),
        opts: opts
      }

      new_state = %{state | active_faults: Map.put(state.active_faults, type, fault_info)}
      emit_signal(:fault_injected, %{type: type, description: module.description()})
      Logger.warning("[Demo] Fault injected: #{type}")
      {:reply, {:ok, type}, new_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:clear, type}, _from, state) do
    case Map.pop(state.active_faults, type) do
      {nil, _} ->
        {:reply, {:error, :not_active}, state}

      {fault_info, remaining} ->
        safe_clear(fault_info)
        new_state = %{state | active_faults: remaining}
        emit_signal(:fault_cleared, %{type: type})
        Logger.info("[Demo] Fault cleared: #{type}")
        {:reply, :ok, new_state}
    end
  end

  def handle_call(:clear_all, _from, state) do
    Enum.each(state.active_faults, fn {type, fault_info} ->
      safe_clear(fault_info)
      emit_signal(:fault_cleared, %{type: type})
    end)

    count = map_size(state.active_faults)
    Logger.info("[Demo] All faults cleared (#{count})")
    {:reply, {:ok, count}, %{state | active_faults: %{}}}
  end

  def handle_call(:active_faults, _from, state) do
    faults =
      Map.new(state.active_faults, fn {type, info} ->
        {type,
         %{
           type: type,
           description: info.module.description(),
           injected_at: info.injected_at,
           detectable_by: info.module.detectable_by()
         }}
      end)

    {:reply, faults, state}
  end

  def handle_call({:status, type}, _from, state) do
    case Map.get(state.active_faults, type) do
      nil ->
        {:reply, :inactive, state}

      info ->
        {:reply,
         %{
           status: :active,
           injected_at: info.injected_at,
           description: info.module.description(),
           detectable_by: info.module.detectable_by()
         }, state}
    end
  end

  def handle_call(:available_faults, _from, state) do
    faults =
      Enum.map(state.fault_modules, fn {type, module} ->
        %{
          type: type,
          description: module.description(),
          detectable_by: module.detectable_by(),
          active: Map.has_key?(state.active_faults, type)
        }
      end)

    {:reply, faults, state}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, _reason}, state) do
    # Fault worker processes may die — we trap exits and ignore them
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.active_faults, fn {_type, info} ->
      safe_clear(info)
    end)

    :ok
  end

  defp find_fault_module(state, type) do
    case Map.get(state.fault_modules, type) do
      nil -> {:error, :unknown_fault_type}
      module -> {:ok, module}
    end
  end

  defp check_not_active(state, type) do
    if Map.has_key?(state.active_faults, type),
      do: {:error, :already_active},
      else: :ok
  end

  defp safe_clear(%{module: module, ref: ref}) do
    module.clear(ref)
  rescue
    e -> Logger.error("[Demo] Error clearing fault: #{inspect(e)}")
  catch
    :exit, reason -> Logger.error("[Demo] Exit clearing fault: #{inspect(reason)}")
  end

  defp emit_signal(type, data) do
    if signal_emission_enabled?() do
      try do
        Arbor.Signals.emit(:demo, type, data)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp signal_emission_enabled? do
    Application.get_env(:arbor_demo, :signal_emission_enabled, true)
  end
end
