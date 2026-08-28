defmodule Arbor.LLM.OAuth.Login.LoopbackOwner do
  @moduledoc false

  use GenServer

  alias Arbor.LLM.OAuth.Login
  alias Arbor.LLM.OAuth.Login.AuthorizationPrompt
  alias Arbor.LLM.OAuth.Login.LoopbackFlow
  alias Arbor.LLM.OAuth.Login.PendingStore

  @registry Arbor.LLM.OAuth.Login.LoopbackRegistry
  @terminal_cleanup_ms 1_000

  def start_link(opts) do
    flow_id = Keyword.fetch!(opts, :flow_id)
    GenServer.start_link(__MODULE__, opts, name: via(flow_id))
  end

  @spec activate(reference()) :: :ok | {:error, term()}
  def activate(flow_id), do: GenServer.call(via(flow_id), :activate, :infinity)

  @spec take_authorize_url(reference()) :: {:ok, String.t()} | {:error, term()}
  def take_authorize_url(flow_id),
    do: GenServer.call(via(flow_id), :take_authorize_url, :infinity)

  @doc false
  @spec await(reference(), pos_integer()) :: :success | {:error, term()}
  def await(flow_id, timeout_ms)
      when is_reference(flow_id) and is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(via(flow_id), {:await, timeout_ms}, :infinity)
  catch
    :exit, _reason -> {:error, :timeout}
  end

  def await(_flow_id, _timeout_ms), do: {:error, :invalid_timeout}

  @doc false
  @spec active_flow() :: {:ok, LoopbackFlow.t()} | :error
  def active_flow do
    case Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}]) do
      [flow_id | _] -> {:ok, LoopbackFlow.new(flow_id)}
      [] -> :error
    end
  catch
    :exit, _reason -> :error
  end

  @doc false
  @spec callback(reference(), term()) :: :success | :failure | :invalid_state
  def callback(flow_id, callback) do
    GenServer.call(via(flow_id), {:callback, callback}, :infinity)
  catch
    :exit, _reason -> :failure
  end

  def response_sent(flow_id) do
    GenServer.cast(via(flow_id), :response_sent)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:sensitive, true)
    Process.flag(:trap_exit, true)
    pending_store_monitor = Process.monitor(Process.whereis(PendingStore))

    {:ok,
     %{
       flow_id: Keyword.fetch!(opts, :flow_id),
       selector: Keyword.fetch!(opts, :selector),
       phase: :waiting_activation,
       handle: nil,
       authorize_url: nil,
       deadline_timer: nil,
       terminal_cleanup_timer: nil,
       pending_store_monitor: pending_store_monitor,
       outcome: nil,
       waiters: []
     }}
  end

  @impl true
  def handle_call(:activate, _from, %{phase: :waiting_activation} = state) do
    deadline = System.monotonic_time(:millisecond) + Login.openai_handle_ttl_ms()

    case Login.start_openai_login(redirect_uri: state.selector) do
      {:ok, %AuthorizationPrompt{} = prompt} ->
        timer = Process.send_after(self(), :deadline, remaining_ms(deadline))

        next = %{
          state
          | phase: :active,
            handle: prompt.handle,
            authorize_url: AuthorizationPrompt.authorize_url(prompt),
            deadline_timer: timer
        }

        {:reply, :ok, next}

      {:error, reason} ->
        {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call(:activate, _from, state),
    do: {:reply, {:error, :oauth_loopback_unavailable}, state}

  def handle_call(
        :take_authorize_url,
        _from,
        %{phase: :active, authorize_url: authorize_url} = state
      )
      when is_binary(authorize_url) do
    {:reply, {:ok, authorize_url}, %{state | authorize_url: nil}}
  end

  def handle_call(:take_authorize_url, _from, state),
    do: {:reply, {:error, :oauth_loopback_unavailable}, state}

  def handle_call({:await, timeout_ms}, from, state) do
    cond do
      not is_nil(state.outcome) ->
        {:reply, state.outcome, state}

      not is_integer(timeout_ms) or timeout_ms < 1 ->
        {:reply, {:error, :invalid_timeout}, state}

      true ->
        timer = Process.send_after(self(), {:await_timeout, from}, timeout_ms)
        {:noreply, %{state | waiters: [{from, timer} | state.waiters]}}
    end
  end

  def handle_call({:callback, callback}, _from, %{phase: :active} = state) do
    received_state = callback_state(callback)

    case PendingStore.match_openai_state(state.handle, received_state) do
      :ok -> complete_callback(callback, state)
      {:error, :state_mismatch} -> {:reply, :invalid_state, state}
      {:error, reason} -> {:reply, :failure, fail_callback(state, reason)}
    end
  end

  def handle_call({:callback, _callback}, _from, state), do: {:reply, :failure, state}

  @impl true
  def handle_cast(:response_sent, %{phase: :terminal} = state) do
    {:stop, :normal, state}
  end

  def handle_cast(:response_sent, state), do: {:noreply, state}

  @impl true
  def handle_info(:deadline, %{phase: :terminal} = state) do
    {:stop, :normal, state}
  end

  def handle_info(:deadline, state) do
    {:stop, :normal, record_outcome(state, {:error, :timeout})}
  end

  def handle_info(:terminal_cleanup, %{phase: :terminal} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:await_timeout, from}, state) do
    {:noreply, timeout_waiter(state, from)}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{pending_store_monitor: monitor} = state
      ) do
    {:stop, :normal, state}
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
    case Login.complete_openai_login(state.handle, code, state_value) do
      :ok ->
        {:reply, :success, record_outcome(state, :success)}

      {:error, reason} ->
        {:reply, :failure, fail_callback(state, reason)}
    end
  end

  defp complete_callback({:provider_error, :access_denied, _state_value}, state) do
    PendingStore.discard_openai(state.handle)
    {:reply, :failure, record_outcome(state, {:error, {:access_denied, :access_denied}})}
  end

  defp complete_callback({:provider_error, closed_error, _state_value}, state) do
    PendingStore.discard_openai(state.handle)
    {:reply, :failure, record_outcome(state, {:error, {:callback_failed, closed_error}})}
  end

  defp fail_callback(state, reason),
    do: record_outcome(state, {:error, {:callback_failed, closed_reason(reason)}})

  defp timeout_waiter(state, from) do
    case List.keytake(state.waiters, from, 0) do
      {{^from, _timer}, rest} ->
        GenServer.reply(from, {:error, :timeout})
        %{state | waiters: rest}

      nil ->
        state
    end
  end

  defp record_outcome(%{outcome: existing} = state, _outcome) when not is_nil(existing) do
    terminal_state(state)
  end

  defp record_outcome(state, outcome) do
    Enum.each(state.waiters, fn {from, timer} ->
      _ = Process.cancel_timer(timer)
      GenServer.reply(from, outcome)
    end)

    state
    |> terminal_state()
    |> Map.put(:outcome, outcome)
    |> Map.put(:waiters, [])
  end

  defp callback_state({:success, _code, state}), do: state
  defp callback_state({:provider_error, _error, state}), do: state

  defp remaining_ms(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 1)

  defp terminal_state(%{terminal_cleanup_timer: nil} = state) do
    timer = Process.send_after(self(), :terminal_cleanup, @terminal_cleanup_ms)
    %{state | phase: :terminal, terminal_cleanup_timer: timer}
  end

  defp terminal_state(state), do: %{state | phase: :terminal}

  defp closed_reason(reason) when is_atom(reason), do: reason
  defp closed_reason({reason, _details}) when is_atom(reason), do: reason
  defp closed_reason(_reason), do: :closed

  defp via(flow_id), do: {:via, Registry, {@registry, flow_id}}
end
