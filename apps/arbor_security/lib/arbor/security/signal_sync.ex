defmodule Arbor.Security.SignalSync do
  @moduledoc false

  alias Arbor.Signals

  @max_resubscribe_attempts 5
  @resubscribe_base_delay_ms 50
  @resubscribe_message :arbor_security_sync_resubscribe

  defstruct [
    :role,
    :bus_pid,
    :bus_monitor_ref,
    events: [],
    subscription_ids: [],
    resubscribe_attempt: 0
  ]

  @type t :: %__MODULE__{
          role: atom(),
          events: [atom()],
          bus_pid: pid() | nil,
          bus_monitor_ref: reference() | nil,
          subscription_ids: [String.t()],
          resubscribe_attempt: non_neg_integer()
        }

  @spec establish(atom(), [atom()], boolean()) :: {:ok, t() | nil} | {:error, term()}
  def establish(_role, _events, false), do: {:ok, nil}

  def establish(role, events, true) when is_atom(role) and is_list(events) do
    establish_with_bus(role, events)
  end

  @spec handle_info(term(), t() | nil) ::
          :unhandled | {:ok, t()} | {:stop, term(), t()}
  def handle_info(
        {:DOWN, ref, :process, bus_pid, _reason},
        %__MODULE__{bus_monitor_ref: ref, bus_pid: bus_pid} = sync
      ) do
    sync = %{sync | bus_pid: nil, bus_monitor_ref: nil, subscription_ids: []}
    {:ok, schedule_resubscribe(sync)}
  end

  def handle_info(
        {@resubscribe_message, role, attempt},
        %__MODULE__{role: role, resubscribe_attempt: attempt} = sync
      ) do
    case establish(sync.role, sync.events, true) do
      {:ok, established} ->
        {:ok, established}

      {:error, _reason} when attempt < @max_resubscribe_attempts ->
        {:ok, schedule_resubscribe(sync)}

      {:error, reason} ->
        {:stop, {:security_sync_resubscribe_failed, role, reason}, sync}
    end
  end

  def handle_info(_message, _sync), do: :unhandled

  @spec release(t() | nil) :: :ok
  def release(nil), do: :ok

  def release(%__MODULE__{} = sync) do
    if is_reference(sync.bus_monitor_ref) do
      Process.demonitor(sync.bus_monitor_ref, [:flush])
    end

    unsubscribe_all(sync.subscription_ids)
  end

  defp establish_with_bus(role, events) do
    case subscribe_all(role, events) do
      {:ok, subscription_ids, bus_pid} ->
        monitor_ref = Process.monitor(bus_pid)

        if Process.alive?(bus_pid) do
          {:ok,
           %__MODULE__{
             role: role,
             events: events,
             bus_pid: bus_pid,
             bus_monitor_ref: monitor_ref,
             subscription_ids: subscription_ids
           }}
        else
          Process.demonitor(monitor_ref, [:flush])
          unsubscribe_all(subscription_ids)
          {:error, :signals_bus_restarted_during_subscription}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp subscribe_all(role, events) do
    Enum.reduce_while(events, {:ok, [], nil}, fn event,
                                                 {:ok, subscription_ids, expected_bus_pid} ->
      case subscribe(role, event) do
        {:ok, subscription_id, bus_pid}
        when is_nil(expected_bus_pid) or expected_bus_pid == bus_pid ->
          {:cont, {:ok, [subscription_id | subscription_ids], bus_pid}}

        {:ok, subscription_id, _different_bus_pid} ->
          unsubscribe_all([subscription_id | subscription_ids])
          {:halt, {:error, :signals_bus_restarted_during_subscription}}

        {:error, reason} ->
          unsubscribe_all(subscription_ids)
          {:halt, {:error, {:subscription_failed, event, reason}}}
      end
    end)
    |> case do
      {:ok, subscription_ids, bus_pid} when is_pid(bus_pid) ->
        {:ok, Enum.reverse(subscription_ids), bus_pid}

      {:ok, [], nil} ->
        {:error, :no_security_sync_events}

      {:error, _reason} = error ->
        error
    end
  end

  defp subscribe(role, event) do
    Signals.subscribe_security_sync(role, event)
  rescue
    error -> {:error, {:exception, error}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  defp unsubscribe_all(subscription_ids) do
    Enum.each(subscription_ids, fn subscription_id ->
      try do
        _ = Signals.unsubscribe(subscription_id)
      catch
        :exit, _reason -> :ok
      end
    end)

    :ok
  end

  defp schedule_resubscribe(sync) do
    attempt = sync.resubscribe_attempt + 1
    delay_ms = @resubscribe_base_delay_ms * Integer.pow(2, attempt - 1)
    Process.send_after(self(), {@resubscribe_message, sync.role, attempt}, delay_ms)
    %{sync | resubscribe_attempt: attempt}
  end
end
