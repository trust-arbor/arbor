defmodule Arbor.LLM.OAuth.Login.LoopbackOwner do
  @moduledoc false

  use GenServer

  alias Arbor.LLM.OAuth.Login
  alias Arbor.LLM.OAuth.Login.AuthorizationPrompt
  alias Arbor.LLM.OAuth.Login.PendingStore

  @registry Arbor.LLM.OAuth.Login.LoopbackRegistry
  @call_timeout_ms 15_000

  def start_link(opts) do
    flow_id = Keyword.fetch!(opts, :flow_id)
    GenServer.start_link(__MODULE__, opts, name: via(flow_id))
  end

  @spec activate(reference()) :: {:ok, String.t()} | {:error, term()}
  def activate(flow_id), do: GenServer.call(via(flow_id), :activate, @call_timeout_ms)

  @doc false
  def arm(flow_id, flow_supervisor, listeners) do
    GenServer.call(via(flow_id), {:arm, flow_supervisor, listeners})
  end

  @spec callback(reference(), term()) :: :success | :failure | :invalid_state
  def callback(flow_id, callback) do
    GenServer.call(via(flow_id), {:callback, callback}, @call_timeout_ms)
  catch
    :exit, _reason -> :failure
  end

  def response_sent(flow_id), do: GenServer.cast(via(flow_id), :response_sent)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    pending_store_monitor = Process.monitor(Process.whereis(PendingStore))

    {:ok,
     %{
       selector: Keyword.fetch!(opts, :selector),
       phase: :waiting_activation,
       handle: nil,
       deadline_timer: nil,
       flow_supervisor: nil,
       listener_monitors: MapSet.new(),
       pending_store_monitor: pending_store_monitor
     }}
  end

  @impl true
  def handle_call(
        {:arm, flow_supervisor, listeners},
        _from,
        %{phase: :waiting_activation, flow_supervisor: nil} = state
      )
      when is_pid(flow_supervisor) and is_list(listeners) and listeners != [] do
    monitors = listeners |> Enum.map(&Process.monitor/1) |> MapSet.new()
    {:reply, :ok, %{state | flow_supervisor: flow_supervisor, listener_monitors: monitors}}
  end

  def handle_call({:arm, _flow_supervisor, _listeners}, _from, state),
    do: {:reply, {:error, :oauth_loopback_unavailable}, state}

  @impl true
  def handle_call(:activate, _from, %{phase: :waiting_activation} = state) do
    deadline = System.monotonic_time(:millisecond) + Login.openai_handle_ttl_ms()

    case Login.start_openai_login(redirect_uri: state.selector) do
      {:ok, %AuthorizationPrompt{} = prompt} ->
        timer = Process.send_after(self(), :deadline, remaining_ms(deadline))
        next = %{state | phase: :active, handle: prompt.handle, deadline_timer: timer}
        {:reply, {:ok, AuthorizationPrompt.authorize_url(prompt)}, next}

      {:error, reason} ->
        {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call(:activate, _from, state),
    do: {:reply, {:error, :oauth_loopback_unavailable}, state}

  def handle_call({:callback, callback}, _from, %{phase: :active} = state) do
    received_state = callback_state(callback)

    case PendingStore.match_openai_state(state.handle, received_state) do
      :ok -> complete_callback(callback, state)
      {:error, :state_mismatch} -> {:reply, :invalid_state, state}
      {:error, _reason} -> {:reply, :failure, %{state | phase: :terminal}}
    end
  end

  def handle_call({:callback, _callback}, _from, state), do: {:reply, :failure, state}

  @impl true
  def handle_cast(:response_sent, %{phase: :terminal} = state) do
    terminate_flow(state)
    {:noreply, state}
  end

  def handle_cast(:response_sent, state), do: {:noreply, state}

  @impl true
  def handle_info(:deadline, state) do
    terminate_flow(state)
    {:noreply, %{state | phase: :terminal}}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    if monitor == state.pending_store_monitor or MapSet.member?(state.listener_monitors, monitor),
      do: terminate_flow(state)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{handle: handle}) when is_binary(handle) do
    PendingStore.discard_openai(handle)
    :ok
  catch
    :exit, _reason -> :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason, :log] ->
        {key, "#Arbor.LLM.OAuth.Login.LoopbackOwner<redacted>"}

      pair ->
        pair
    end)
  end

  defp complete_callback({:success, code, state_value}, state) do
    result = Login.complete_openai_login(state.handle, code, state_value)
    reply = if result == :ok, do: :success, else: :failure
    {:reply, reply, %{state | phase: :terminal}}
  end

  defp complete_callback({:provider_error, _closed_error, _state_value}, state) do
    PendingStore.discard_openai(state.handle)
    {:reply, :failure, %{state | phase: :terminal}}
  end

  defp callback_state({:success, _code, state}), do: state
  defp callback_state({:provider_error, _error, state}), do: state

  defp remaining_ms(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 1)

  defp terminate_flow(%{flow_supervisor: flow_supervisor}) when is_pid(flow_supervisor) do
    Task.Supervisor.start_child(Arbor.LLM.OAuth.Login.LoopbackTaskSupervisor, fn ->
      DynamicSupervisor.terminate_child(
        Arbor.LLM.OAuth.Login.LoopbackSupervisor,
        flow_supervisor
      )
    end)

    :ok
  end

  defp terminate_flow(_state), do: :ok

  defp via(flow_id), do: {:via, Registry, {@registry, flow_id}}
end
