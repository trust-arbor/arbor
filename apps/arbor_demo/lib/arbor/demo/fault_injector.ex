defmodule Arbor.Demo.FaultInjector do
  @moduledoc """
  Core GenServer that manages fault injection lifecycle.

  Tracks active faults by correlation_id, coordinates with the DynamicSupervisor
  for fault worker processes, and emits signals on inject/stop events.

  ## Philosophy

  Faults are "dumb chaos generators" — they create problems but don't know
  how to fix them. The FaultInjector can stop faults by terminating their
  processes, but the DebugAgent must discover which process to terminate
  through investigation.

  ## Tracking

  Faults are tracked by both:
  - `type` (e.g., :message_queue_flood) for API convenience
  - `correlation_id` for Historian tracing
  """
  use GenServer

  require Logger

  @fault_modules %{
    message_queue_flood: Arbor.Demo.Faults.MessageQueueFlood,
    process_leak: Arbor.Demo.Faults.ProcessLeak,
    supervisor_crash: Arbor.Demo.Faults.SupervisorCrash
  }

  defstruct active_faults: %{},
            faults_by_type: %{},
            fault_modules: @fault_modules,
            supervisor: Arbor.Demo.Supervisor

  # Client API

  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  # Public API - Inject fault
  # Returns {:ok, correlation_id} or {:error, reason}

  def inject_fault(server, type, opts) when is_pid(server) or is_atom(server) do
    GenServer.call(server, {:inject, type, opts})
  end

  def inject_fault(server, type) when is_pid(server) or is_atom(server) do
    GenServer.call(server, {:inject, type, []})
  end

  def inject_fault(type, opts) when is_atom(type) and is_list(opts) do
    GenServer.call(__MODULE__, {:inject, type, opts})
  end

  def inject_fault(type) when is_atom(type) do
    GenServer.call(__MODULE__, {:inject, type, []})
  end

  # Stop fault - terminates the process but doesn't "fix" the problem
  # The DebugAgent should use generic BEAM operations, not this API

  def stop_fault(server, type_or_correlation_id) when is_pid(server) or is_atom(server) do
    GenServer.call(server, {:stop, type_or_correlation_id})
  end

  def stop_fault(type_or_correlation_id) do
    GenServer.call(__MODULE__, {:stop, type_or_correlation_id})
  end

  def stop_all(server) when is_pid(server) or is_atom(server) do
    GenServer.call(server, :stop_all)
  end

  def stop_all do
    GenServer.call(__MODULE__, :stop_all)
  end

  # Query API

  def active_faults(server) when is_pid(server) or is_atom(server) do
    GenServer.call(server, :active_faults)
  end

  def active_faults do
    GenServer.call(__MODULE__, :active_faults)
  end

  def fault_status(server, type) when is_pid(server) or is_atom(server) do
    GenServer.call(server, {:status, type})
  end

  def fault_status(type) when is_atom(type) do
    GenServer.call(__MODULE__, {:status, type})
  end

  def available_faults(server) when is_pid(server) or is_atom(server) do
    GenServer.call(server, :available_faults)
  end

  def available_faults do
    GenServer.call(__MODULE__, :available_faults)
  end

  def get_correlation_id(server, type) when is_pid(server) or is_atom(server) do
    GenServer.call(server, {:get_correlation_id, type})
  end

  def get_correlation_id(type) when is_atom(type) do
    GenServer.call(__MODULE__, {:get_correlation_id, type})
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
         {:ok, ref, correlation_id} <- module.inject(inject_opts) do
      fault_info = %{
        type: type,
        module: module,
        ref: ref,
        correlation_id: correlation_id,
        injected_at: System.system_time(:millisecond),
        opts: opts
      }

      new_state = %{
        state
        | active_faults: Map.put(state.active_faults, correlation_id, fault_info),
          faults_by_type: Map.put(state.faults_by_type, type, correlation_id)
      }

      Logger.warning("[Demo] Fault injected: #{type} (#{correlation_id})")
      {:reply, {:ok, correlation_id}, new_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop, type_or_correlation_id}, _from, state) do
    # Try to find by type first, then by correlation_id
    correlation_id =
      if is_atom(type_or_correlation_id) do
        Map.get(state.faults_by_type, type_or_correlation_id)
      else
        type_or_correlation_id
      end

    case correlation_id && Map.pop(state.active_faults, correlation_id) do
      {nil, _} ->
        {:reply, {:error, :not_active}, state}

      nil ->
        {:reply, {:error, :not_active}, state}

      {fault_info, remaining_faults} ->
        terminate_fault_process(fault_info.ref)

        new_state = %{
          state
          | active_faults: remaining_faults,
            faults_by_type: Map.delete(state.faults_by_type, fault_info.type)
        }

        emit_signal(:fault_stopped, %{
          type: fault_info.type,
          correlation_id: correlation_id
        })

        Logger.info("[Demo] Fault stopped: #{fault_info.type} (#{correlation_id})")
        {:reply, :ok, new_state}
    end
  end

  def handle_call(:stop_all, _from, state) do
    Enum.each(state.active_faults, fn {correlation_id, fault_info} ->
      terminate_fault_process(fault_info.ref)

      emit_signal(:fault_stopped, %{
        type: fault_info.type,
        correlation_id: correlation_id
      })
    end)

    count = map_size(state.active_faults)
    Logger.info("[Demo] All faults stopped (#{count})")
    {:reply, {:ok, count}, %{state | active_faults: %{}, faults_by_type: %{}}}
  end

  def handle_call(:active_faults, _from, state) do
    faults =
      Map.new(state.active_faults, fn {correlation_id, info} ->
        {correlation_id,
         %{
           type: info.type,
           correlation_id: correlation_id,
           description: info.module.description(),
           injected_at: info.injected_at,
           detectable_by: info.module.detectable_by(),
           ref: info.ref
         }}
      end)

    {:reply, faults, state}
  end

  def handle_call({:status, type}, _from, state) do
    case Map.get(state.faults_by_type, type) do
      nil ->
        {:reply, :inactive, state}

      correlation_id ->
        info = Map.get(state.active_faults, correlation_id)

        {:reply,
         %{
           status: :active,
           correlation_id: correlation_id,
           injected_at: info.injected_at,
           description: info.module.description(),
           detectable_by: info.module.detectable_by()
         }, state}
    end
  end

  def handle_call({:get_correlation_id, type}, _from, state) do
    {:reply, Map.get(state.faults_by_type, type), state}
  end

  def handle_call(:available_faults, _from, state) do
    faults =
      Enum.map(state.fault_modules, fn {type, module} ->
        %{
          type: type,
          description: module.description(),
          detectable_by: module.detectable_by(),
          active: Map.has_key?(state.faults_by_type, type)
        }
      end)

    {:reply, faults, state}
  end

  @impl GenServer
  def handle_info({:EXIT, pid, _reason}, state) do
    # Fault worker processes may die — find and remove from tracking
    {correlation_id, fault_info} =
      Enum.find(state.active_faults, {nil, nil}, fn {_cid, info} ->
        info.ref == pid
      end)

    if correlation_id do
      new_state = %{
        state
        | active_faults: Map.delete(state.active_faults, correlation_id),
          faults_by_type: Map.delete(state.faults_by_type, fault_info.type)
      }

      Logger.debug("[Demo] Fault process exited: #{fault_info.type}")
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.active_faults, fn {_correlation_id, info} ->
      terminate_fault_process(info.ref)
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
    if Map.has_key?(state.faults_by_type, type),
      do: {:error, :already_active},
      else: :ok
  end

  defp terminate_fault_process(ref) when is_pid(ref) do
    if Process.alive?(ref) do
      Process.exit(ref, :shutdown)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp terminate_fault_process(_ref), do: :ok

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
