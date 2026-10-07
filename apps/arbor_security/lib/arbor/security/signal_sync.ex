defmodule Arbor.Security.SignalSync do
  @moduledoc false

  alias Arbor.Security.PrivateState
  alias Arbor.Signals

  @max_resubscribe_attempts 5
  @resubscribe_base_delay_ms 50
  @resubscribe_message :arbor_security_sync_resubscribe
  @delivery_custody_anchor {__MODULE__, :delivery_custody}
  @delivery_custody_schema :signal_sync_delivery_refs

  defstruct [
    :role,
    :bus_pid,
    :bus_monitor_ref,
    :delivery_custody,
    events: [],
    subscription_ids: [],
    resubscribe_attempt: 0
  ]

  @type t :: %__MODULE__{
          role: atom(),
          events: [atom()],
          bus_pid: pid() | nil,
          bus_monitor_ref: reference() | nil,
          delivery_custody: PrivateState.handle() | nil,
          subscription_ids: [String.t()],
          resubscribe_attempt: non_neg_integer()
        }

  @spec establish(atom(), [atom()], boolean()) :: {:ok, t() | nil} | {:error, term()}
  # Config asks through the public Signals facade so Security does not reach
  # across the application boundary into Signals internals.
  @spec transport_configured?() :: boolean()
  def transport_configured?, do: Signals.security_sync_transport_configured?()

  def establish(_role, _events, false), do: {:ok, nil}

  def establish(role, events, true) when is_atom(role) and is_list(events) do
    if Signals.security_sync_role_configured?(role) do
      establish_with_bus(role, events, nil)
    else
      {:ok, nil}
    end
  end

  @spec handle_info(term(), t() | nil) ::
          :unhandled | {:ok, t()} | {:stop, term(), t()}
  def handle_info(
        {:DOWN, ref, :process, bus_pid, _reason},
        %__MODULE__{bus_monitor_ref: ref, bus_pid: bus_pid} = sync
      ) do
    sync = %{
      sync
      | bus_pid: nil,
        bus_monitor_ref: nil,
        subscription_ids: []
    }

    case replace_delivery_refs(sync, MapSet.new()) do
      :ok -> {:ok, schedule_resubscribe(sync)}
      {:error, reason} -> {:stop, {:security_sync_delivery_custody_failed, reason}, sync}
    end
  end

  def handle_info(
        {@resubscribe_message, role, attempt},
        %__MODULE__{role: role, resubscribe_attempt: attempt} = sync
      ) do
    case establish_with_bus(sync.role, sync.events, sync) do
      {:ok, established} ->
        {:ok, established}

      {:error, _reason} when attempt < @max_resubscribe_attempts ->
        {:ok, schedule_resubscribe(sync)}

      {:error, reason} ->
        {:stop, {:security_sync_resubscribe_failed, role, reason}, sync}
    end
  end

  def handle_info(_message, _sync), do: :unhandled

  @spec authenticated_delivery?(t() | nil, term()) :: boolean()
  def authenticated_delivery?(%__MODULE__{} = sync, delivery_ref)
      when is_reference(delivery_ref) do
    case delivery_refs(sync) do
      {:ok, refs} -> MapSet.member?(refs, delivery_ref)
      {:error, _reason} -> false
    end
  end

  def authenticated_delivery?(_sync, _delivery_ref), do: false

  @spec release(t() | nil) :: :ok
  def release(nil), do: :ok

  def release(%__MODULE__{} = sync) do
    if is_reference(sync.bus_monitor_ref) do
      Process.demonitor(sync.bus_monitor_ref, [:flush])
    end

    unsubscribe_all(sync.subscription_ids)
    PrivateState.delete(sync.delivery_custody, @delivery_custody_anchor)
  end

  defp establish_with_bus(role, events, existing_sync) do
    case subscribe_all(role, events) do
      {:ok, subscription_ids, bus_pid, delivery_refs} ->
        case store_delivery_refs(existing_sync, MapSet.new(delivery_refs)) do
          {:ok, delivery_custody} ->
            monitor_ref = Process.monitor(bus_pid)

            if Process.alive?(bus_pid) do
              {:ok,
               %__MODULE__{
                 role: role,
                 events: events,
                 bus_pid: bus_pid,
                 bus_monitor_ref: monitor_ref,
                 subscription_ids: subscription_ids,
                 delivery_custody: delivery_custody,
                 resubscribe_attempt: 0
               }}
            else
              Process.demonitor(monitor_ref, [:flush])
              unsubscribe_all(subscription_ids)
              {:error, :signals_bus_restarted_during_subscription}
            end

          {:error, reason} ->
            unsubscribe_all(subscription_ids)
            {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp subscribe_all(role, events) do
    Enum.reduce_while(events, {:ok, [], [], nil}, fn event,
                                                     {:ok, subscription_ids, delivery_refs,
                                                      expected_bus_pid} ->
      case subscribe(role, event) do
        {:ok, subscription_id, bus_pid, delivery_ref}
        when is_reference(delivery_ref) and
               (is_nil(expected_bus_pid) or expected_bus_pid == bus_pid) ->
          {:cont,
           {:ok, [subscription_id | subscription_ids], [delivery_ref | delivery_refs], bus_pid}}

        {:ok, subscription_id, _different_bus_pid, _delivery_ref} ->
          unsubscribe_all([subscription_id | subscription_ids])
          {:halt, {:error, :signals_bus_restarted_during_subscription}}

        {:error, reason} ->
          unsubscribe_all(subscription_ids)
          {:halt, {:error, {:subscription_failed, event, reason}}}
      end
    end)
    |> case do
      {:ok, subscription_ids, delivery_refs, bus_pid} when is_pid(bus_pid) ->
        {:ok, Enum.reverse(subscription_ids), bus_pid, Enum.reverse(delivery_refs)}

      {:ok, [], [], nil} ->
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

  defp store_delivery_refs(nil, refs) do
    if is_nil(Process.get(@delivery_custody_anchor)) and valid_delivery_refs?(refs) do
      {:ok, PrivateState.new(@delivery_custody_anchor, @delivery_custody_schema, refs)}
    else
      {:error, :invalid_signal_sync_delivery_custody}
    end
  end

  defp store_delivery_refs(%__MODULE__{} = sync, refs) do
    case PrivateState.replace(
           sync.delivery_custody,
           @delivery_custody_anchor,
           @delivery_custody_schema,
           refs,
           &valid_delivery_refs?/1
         ) do
      :ok -> {:ok, sync.delivery_custody}
      {:error, _reason} -> {:error, :invalid_signal_sync_delivery_custody}
    end
  end

  defp replace_delivery_refs(%__MODULE__{} = sync, refs) do
    case store_delivery_refs(sync, refs) do
      {:ok, _delivery_custody} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp delivery_refs(%__MODULE__{} = sync) do
    PrivateState.fetch(
      sync.delivery_custody,
      @delivery_custody_anchor,
      @delivery_custody_schema,
      &valid_delivery_refs?/1
    )
  end

  defp valid_delivery_refs?(%MapSet{} = refs), do: Enum.all?(refs, &is_reference/1)
  defp valid_delivery_refs?(_refs), do: false

  defp schedule_resubscribe(sync) do
    attempt = sync.resubscribe_attempt + 1
    delay_ms = @resubscribe_base_delay_ms * Integer.pow(2, attempt - 1)
    Process.send_after(self(), {@resubscribe_message, sync.role, attempt}, delay_ms)
    %{sync | resubscribe_attempt: attempt}
  end
end
