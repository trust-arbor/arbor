defmodule Arbor.Signals.TelemetryBridge do
  @moduledoc false

  use GenServer

  alias Arbor.Common

  @default_capacity 256
  @max_capacity 1_024
  @call_timeout_ms 1_000
  @drop_event [:arbor, :signals, :telemetry_bridge, :dropped]
  @custody_anchor {__MODULE__, :bridge_custody}

  @type payload :: {atom(), atom(), map(), keyword(), boolean()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  @spec enqueue(atom(), atom(), map(), keyword(), boolean()) ::
          :ok | {:error, :queue_full | :unavailable | :unauthorized | :invalid_event}
  def enqueue(category, type, data, opts, durable)
      when is_atom(category) and is_atom(type) and is_map(data) and is_list(opts) and
             is_boolean(durable) do
    if Keyword.keyword?(opts) do
      call_bridge({:enqueue, {category, type, data, opts, durable}})
    else
      {:error, :invalid_event}
    end
  end

  def enqueue(_category, _type, _data, _opts, _durable), do: {:error, :invalid_event}

  @impl true
  def init(opts) do
    Process.flag(:sensitive, true)
    capacity = normalize_capacity(Keyword.get(opts, :capacity, @default_capacity))
    secret = :crypto.strong_rand_bytes(32)
    owner = self()
    emitter = spawn_link(fn -> emitter_loop(owner, secret) end)
    bridge_custody = :ets.new(__MODULE__, [:set, :private])
    Process.put(@custody_anchor, bridge_custody)

    true =
      :ets.insert(
        bridge_custody,
        {:bridge, emitter, secret, capacity, 0}
      )

    {:ok,
     %{
       authenticated_calls: Common.new_authenticated_call_custody(),
       bridge_custody: bridge_custody
     }}
  end

  @impl true
  def handle_call(_request, _from, state), do: {:reply, {:error, :unauthorized}, state}

  @impl true
  def handle_cast(_request, state), do: {:noreply, state}

  @impl true
  def handle_info(message, state) do
    case Common.handle_authenticated_call(message, state.authenticated_calls) do
      {:authenticated, caller_pid, request, reply_to} ->
        {reply, state} = dispatch_authenticated(request, caller_pid, state)
        :ok = Common.reply_authenticated_call(reply_to, reply)
        {:noreply, state}

      result when result in [:pending, :expired, :rejected] ->
        {:noreply, state}

      :unrecognized ->
        handle_internal_info(message, state)
    end
  end

  @impl true
  def format_status(status) when is_map(status) do
    state = Map.get(status, :state, %{})

    {capacity, in_flight} =
      case bridge_record(state) do
        {:ok, _emitter, _secret, capacity, in_flight} -> {capacity, in_flight}
        {:error, _reason} -> {nil, nil}
      end

    Map.put(status, :state, %{
      capacity: capacity,
      in_flight: in_flight
    })
  end

  defp dispatch_authenticated({:enqueue, payload}, caller_pid, state) do
    cond do
      not authorized_bus?(caller_pid) ->
        {{:error, :unauthorized}, state}

      not valid_payload?(payload) ->
        {{:error, :invalid_event}, state}

      true ->
        admit_payload(payload, state)
    end
  end

  defp dispatch_authenticated(_request, _caller_pid, state),
    do: {{:error, :unauthorized}, state}

  defp handle_internal_info({secret, :done, emitter}, state) do
    case bridge_record(state) do
      {:ok, ^emitter, ^secret, _capacity, in_flight} when in_flight > 0 ->
        _ = update_in_flight(state, in_flight - 1)
        {:noreply, state}

      _invalid_or_forged ->
        {:noreply, state}
    end
  end

  defp handle_internal_info(_message, state), do: {:noreply, state}

  defp admit_payload(payload, state) do
    case bridge_record(state) do
      {:ok, _emitter, _secret, capacity, in_flight} when in_flight >= capacity ->
        record_drop(:queue_full, capacity)
        {{:error, :queue_full}, state}

      {:ok, emitter, secret, _capacity, in_flight} ->
        with :ok <- update_in_flight(state, in_flight + 1) do
          send(emitter, {secret, :emit, payload})
          {:ok, state}
        else
          {:error, _reason} -> {{:error, :unavailable}, state}
        end

      {:error, _reason} ->
        {{:error, :unavailable}, state}
    end
  end

  defp bridge_record(%{bridge_custody: custody}) do
    with ^custody <- Process.get(@custody_anchor),
         true <- :ets.info(custody, :owner) == self(),
         true <- :ets.info(custody, :protection) == :private,
         [{:bridge, emitter, secret, capacity, in_flight}] <- :ets.lookup(custody, :bridge),
         true <- is_pid(emitter) and Process.alive?(emitter),
         true <- is_binary(secret) and byte_size(secret) == 32,
         true <- is_integer(capacity) and capacity > 0 and capacity <= @max_capacity,
         true <- is_integer(in_flight) and in_flight >= 0 and in_flight <= capacity do
      {:ok, emitter, secret, capacity, in_flight}
    else
      _invalid -> {:error, :invalid_custody}
    end
  rescue
    ArgumentError -> {:error, :invalid_custody}
  end

  defp bridge_record(_state), do: {:error, :invalid_custody}

  defp update_in_flight(%{bridge_custody: custody}, in_flight)
       when is_integer(in_flight) and in_flight >= 0 do
    if :ets.info(custody, :owner) == self() and
         :ets.update_element(custody, :bridge, {5, in_flight}) do
      :ok
    else
      {:error, :invalid_custody}
    end
  rescue
    ArgumentError -> {:error, :invalid_custody}
  end

  defp update_in_flight(_state, _in_flight), do: {:error, :invalid_custody}

  defp call_bridge(request) do
    case supervised_bridge_pid() do
      pid when is_pid(pid) -> Common.authenticated_call(pid, request, @call_timeout_ms)
      _missing -> {:error, :unavailable}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp supervised_bridge_pid do
    supervised_child_pid(__MODULE__)
  end

  defp authorized_bus?(caller_pid) when is_pid(caller_pid) do
    Process.whereis(Arbor.Signals.Bus) == caller_pid and
      supervised_child_pid(Arbor.Signals.Bus) == caller_pid
  end

  defp authorized_bus?(_caller_pid), do: false

  defp supervised_child_pid(child_id) do
    case Process.whereis(Arbor.Signals.Supervisor) do
      supervisor when is_pid(supervisor) ->
        Enum.find_value(Supervisor.which_children(supervisor), fn
          {^child_id, pid, _type, _modules} when is_pid(pid) -> pid
          _other -> nil
        end)

      _missing ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp valid_payload?({category, type, data, opts, durable}) do
    is_atom(category) and is_atom(type) and is_map(data) and is_list(opts) and
      Keyword.keyword?(opts) and is_boolean(durable)
  end

  defp valid_payload?(_payload), do: false

  defp emitter_loop(owner, secret) do
    Process.flag(:sensitive, true)

    receive do
      {^secret, :emit, payload} ->
        safe_emit(payload)
        send(owner, {secret, :done, self()})
        emitter_loop(owner, secret)

      _untrusted ->
        emitter_loop(owner, secret)
    end
  end

  defp emit({category, type, data, opts, true}) do
    Arbor.Signals.durable_emit(category, type, data, opts)
  end

  defp emit({category, type, data, opts, false}) do
    Arbor.Signals.emit(category, type, data, opts)
  end

  defp safe_emit(payload) do
    emit(payload)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp record_drop(reason, capacity) do
    :telemetry.execute(@drop_event, %{count: 1}, %{reason: reason, capacity: capacity})
    :ok
  rescue
    _ -> :ok
  end

  defp normalize_capacity(value) when is_integer(value) and value > 0,
    do: min(value, @max_capacity)

  defp normalize_capacity(_invalid), do: @default_capacity
end
