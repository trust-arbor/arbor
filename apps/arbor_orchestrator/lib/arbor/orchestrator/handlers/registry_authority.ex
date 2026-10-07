defmodule Arbor.Orchestrator.Handlers.RegistryAuthority do
  @moduledoc false

  use GenServer

  alias Arbor.Orchestrator.Handlers.Registry

  @directory :arbor_orchestrator_handler_registry_authority
  @reconcile_delay_ms 100

  @spec authority_config() :: keyword()
  def authority_config do
    [
      name: __MODULE__,
      directory: @directory,
      application: :arbor_orchestrator,
      child_path: [__MODULE__]
    ]
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ensure_registered() :: :ok | {:error, term()}
  def ensure_registered do
    GenServer.call(__MODULE__, :ensure_registered, 60_000)
  end

  @impl true
  def init(_opts) do
    Process.flag(:sensitive, true)

    custody_table = :ets.new(__MODULE__, [:private, :set])
    custody = :crypto.strong_rand_bytes(32)
    true = :ets.insert(custody_table, {:custody, custody})

    @directory =
      :ets.new(@directory, [
        :named_table,
        :protected,
        :set,
        {:read_concurrency, true}
      ])

    true = :ets.insert(@directory, {:custody_sha256, :crypto.hash(:sha256, custody)})

    state = %{
      custody_table: custody_table,
      registry_pid: nil,
      registry_monitor: nil,
      reconcile_timer: nil
    }

    {:ok, schedule_reconcile(state, 0)}
  end

  @impl true
  def handle_call(:ensure_registered, _from, state) do
    {result, state} = reconcile_registry(state)
    {:reply, result, state}
  end

  @impl true
  def handle_call(_request, _from, state) do
    {:reply, {:error, :unsupported_request}, state}
  end

  @impl true
  def handle_info(:reconcile_registry, state) do
    {_result, state} = reconcile_registry(%{state | reconcile_timer: nil})
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, registry_pid, _reason},
        %{registry_monitor: monitor_ref, registry_pid: registry_pid} = state
      ) do
    state = %{state | registry_pid: nil, registry_monitor: nil}
    {:noreply, schedule_reconcile(state, @reconcile_delay_ms)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp reconcile_registry(state) do
    case Arbor.Common.handler_registry_pid() do
      registry_pid when is_pid(registry_pid) ->
        state = monitor_registry(state, registry_pid)
        result = register_with_custody(state)

        state =
          case result do
            :ok -> cancel_reconcile(state)
            {:error, _reason} -> schedule_reconcile(state, @reconcile_delay_ms)
          end

        {result, state}

      _other ->
        result = {:error, :handler_registry_unavailable}
        {result, schedule_reconcile(state, @reconcile_delay_ms)}
    end
  end

  defp register_with_custody(state) do
    case :ets.lookup(state.custody_table, :custody) do
      [{:custody, custody}] -> Registry.register_core_handlers_with_custody(custody)
      _other -> {:error, :core_handler_custody_unavailable}
    end
  end

  defp monitor_registry(%{registry_pid: registry_pid} = state, registry_pid), do: state

  defp monitor_registry(state, registry_pid) do
    if is_reference(state.registry_monitor) do
      Process.demonitor(state.registry_monitor, [:flush])
    end

    %{state | registry_pid: registry_pid, registry_monitor: Process.monitor(registry_pid)}
  end

  defp schedule_reconcile(%{reconcile_timer: nil} = state, delay) do
    %{state | reconcile_timer: Process.send_after(self(), :reconcile_registry, delay)}
  end

  defp schedule_reconcile(state, _delay), do: state

  defp cancel_reconcile(%{reconcile_timer: timer} = state) when is_reference(timer) do
    Process.cancel_timer(timer)
    %{state | reconcile_timer: nil}
  end

  defp cancel_reconcile(state), do: state
end
