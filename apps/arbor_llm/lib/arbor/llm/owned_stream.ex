defmodule Arbor.LLM.OwnedStream do
  @moduledoc false

  alias Arbor.LLM.RequestTimeoutError

  @claim_timeout_ms 100
  @cleanup_grace_ms 100

  # `stream` and `cancel` remain only so stale caller-built structs fail as
  # values instead of becoming process-control capabilities. Enumerable never
  # trusts those fields; only the private controller token is authoritative.
  defstruct [:producer, :controller, :token, :deadline_ms, :timeout_ms, :stream, :cancel]

  @type t :: %__MODULE__{}

  @spec new(Enumerable.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(source, opts) do
    with {:ok, deadline_ms} <- option(opts, :deadline_ms, &is_integer/1),
         {:ok, timeout_ms} <- option(opts, :timeout_ms, &(is_integer(&1) and &1 > 0)),
         {:ok, validator} <- option(opts, :validator, &is_function(&1, 1)),
         true <- not match?(%__MODULE__{}, source) or {:error, :owned_stream_nesting_forbidden},
         true <- not is_nil(Enumerable.impl_for(source)) or {:error, :enumerable_stream_required} do
      start_controller(source, deadline_ms, timeout_ms, validator)
    end
  end

  @spec cancel(t()) :: :ok | {:error, term()}
  def cancel(%__MODULE__{} = stream), do: finalize(stream)
  def cancel(_stream), do: {:error, :invalid_owned_stream}

  @doc false
  def claim(%__MODULE__{controller: controller, token: token})
      when is_pid(controller) and is_reference(token) do
    ref = make_ref()
    send(controller, {token, :claim, self(), ref})

    receive do
      {^token, ^ref, :claimed} -> :ok
      {^token, ^ref, {:error, reason}} -> {:error, reason}
    after
      @claim_timeout_ms -> {:error, :invalid_owned_stream}
    end
  end

  def claim(_stream), do: {:error, :invalid_owned_stream}

  @doc false
  def demand(%__MODULE__{controller: controller, token: token, deadline_ms: deadline_ms}) do
    ref = make_ref()
    send(controller, {token, :demand, self(), ref})
    remaining = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^token, ^ref, :item, item, completed_mono} ->
        if completed_mono <= deadline_ms,
          do: {:item, item},
          else: {:timeout, :late_item}

      {^token, ^ref, :done, completed_mono} ->
        if completed_mono <= deadline_ms,
          do: :done,
          else: {:timeout, :late_completion}

      {^token, ^ref, {:error, reason}, completed_mono} ->
        if completed_mono <= deadline_ms,
          do: {:error, reason},
          else: {:timeout, :late_error}

      {^token, ^ref, :timeout} ->
        {:timeout, :deadline}
    after
      remaining -> {:timeout, :deadline}
    end
  end

  @doc false
  def finalize(%__MODULE__{controller: controller, token: token})
      when is_pid(controller) and is_reference(token) do
    ref = make_ref()
    monitor = Process.monitor(controller)
    send(controller, {token, :finalize, self(), ref})

    receive do
      {^token, ^ref, :finalized} ->
        await_controller_down(controller, monitor)
        :ok

      {:DOWN, ^monitor, :process, ^controller, _reason} ->
        :ok
    end
  end

  def finalize(_stream), do: {:error, :invalid_owned_stream}

  @doc false
  def timeout_error(%__MODULE__{timeout_ms: timeout_ms}),
    do: RequestTimeoutError.exception(timeout_ms: timeout_ms)

  defp option(opts, key, predicate) when is_list(opts) and is_function(predicate, 1) do
    case safe_keyword_fetch(opts, key) do
      {:ok, value} ->
        if predicate.(value), do: {:ok, value}, else: {:error, {:invalid_option, key}}

      :error ->
        {:error, {:missing_option, key}}

      {:error, _reason} = error ->
        error
    end
  end

  defp option(_opts, key, _predicate), do: {:error, {:invalid_option, key}}

  defp safe_keyword_fetch([], _key), do: :error
  defp safe_keyword_fetch([{key, value} | _rest], key), do: {:ok, value}

  defp safe_keyword_fetch([{key, _value} | rest], wanted) when is_atom(key),
    do: safe_keyword_fetch(rest, wanted)

  defp safe_keyword_fetch(_improper, _key), do: {:error, :keyword_required}

  defp start_controller(source, deadline_ms, timeout_ms, validator) do
    caller = self()
    ready_ref = make_ref()
    token = make_ref()

    {controller, startup_monitor} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        controller = self()

        {producer, producer_monitor} =
          :erlang.spawn_opt(fn -> produce(source, controller, token, validator) end, [
            :link,
            :monitor
          ])

        send(caller, {ready_ref, controller, producer})

        controller_loop(%{
          token: token,
          producer: producer,
          producer_monitor: producer_monitor,
          consumer: nil,
          consumer_monitor: nil,
          demand: nil,
          item: nil,
          terminal: nil,
          delivered?: false,
          deadline_ms: deadline_ms
        })
      end)

    receive do
      {^ready_ref, ^controller, producer} ->
        Process.demonitor(startup_monitor, [:flush])

        {:ok,
         %__MODULE__{
           producer: producer,
           controller: controller,
           token: token,
           deadline_ms: deadline_ms,
           timeout_ms: timeout_ms
         }}
    after
      @claim_timeout_ms ->
        if Process.alive?(controller), do: Process.exit(controller, :kill)
        await_controller_down(controller, startup_monitor)
        {:error, :owned_stream_start_timeout}
    end
  end

  defp produce(source, controller, token, validator) do
    try do
      Enum.reduce_while(source, :ok, fn event, :ok ->
        case safely_validate(validator, event) do
          {:ok, normalized} ->
            completed_mono = System.monotonic_time(:millisecond)
            send(controller, {token, :item_ready, normalized, completed_mono})

            receive do
              {^token, :continue} -> {:cont, :ok}
              {^token, :cancel} -> {:halt, :ok}
            end

          {:error, reason} ->
            completed_mono = System.monotonic_time(:millisecond)
            send(controller, {token, :source_error, reason, completed_mono})
            {:halt, :error}
        end
      end)

      send(controller, {token, :source_done, System.monotonic_time(:millisecond)})
    rescue
      exception ->
        send(
          controller,
          {token, :source_error, bounded_exception(exception),
           System.monotonic_time(:millisecond)}
        )
    catch
      kind, reason ->
        send(
          controller,
          {token, :source_error, {kind, bounded_reason(reason)},
           System.monotonic_time(:millisecond)}
        )
    end
  end

  defp safely_validate(validator, event) do
    case validator.(event) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_stream_validator_result}
    end
  rescue
    exception -> {:error, bounded_exception(exception)}
  catch
    kind, reason -> {:error, {kind, bounded_reason(reason)}}
  end

  defp controller_loop(state) do
    remaining = max(state.deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {token, :claim, consumer, ref} when token == state.token and is_pid(consumer) ->
        cond do
          is_nil(state.consumer) ->
            monitor = Process.monitor(consumer)
            send(consumer, {token, ref, :claimed})
            controller_loop(%{state | consumer: consumer, consumer_monitor: monitor})

          state.consumer == consumer ->
            send(consumer, {token, ref, :claimed})
            controller_loop(state)

          true ->
            send(consumer, {token, ref, {:error, :owned_stream_already_claimed}})
            controller_loop(state)
        end

      {token, :demand, consumer, ref}
      when token == state.token and consumer == state.consumer and is_reference(ref) ->
        state = advance_producer_for_demand(state)
        controller_loop(dispatch_ready(%{state | demand: {consumer, ref}}))

      {token, :item_ready, item, completed_mono} when token == state.token ->
        state = %{state | item: {item, completed_mono}, delivered?: false}
        controller_loop(dispatch_ready(state))

      {token, :source_done, completed_mono} when token == state.token ->
        terminal = state.terminal || {:done, completed_mono}
        controller_loop(dispatch_ready(%{state | terminal: terminal}))

      {token, :source_error, reason, completed_mono} when token == state.token ->
        controller_loop(dispatch_ready(%{state | terminal: {:error, reason, completed_mono}}))

      {token, :finalize, requester, ref} when token == state.token and is_pid(requester) ->
        finalize_controller(state)
        send(requester, {token, ref, :finalized})

      {:DOWN, monitor, :process, producer, _reason}
      when monitor == state.producer_monitor and producer == state.producer ->
        state = %{
          state
          | terminal: state.terminal || {:done, System.monotonic_time(:millisecond)}
        }

        controller_loop(dispatch_ready(state))

      {:DOWN, monitor, :process, consumer, _reason}
      when monitor == state.consumer_monitor and consumer == state.consumer ->
        finalize_controller(state)

      _other ->
        controller_loop(state)
    after
      remaining ->
        notify_timeout(state)
        finalize_controller(state)
    end
  end

  defp advance_producer_for_demand(%{delivered?: true, producer: producer, token: token} = state) do
    send(producer, {token, :continue})
    %{state | delivered?: false}
  end

  defp advance_producer_for_demand(state), do: state

  defp dispatch_ready(%{demand: {consumer, ref}, item: {item, completed_mono}} = state) do
    send(consumer, {state.token, ref, :item, item, completed_mono})
    %{state | demand: nil, item: nil, delivered?: true}
  end

  defp dispatch_ready(%{demand: {consumer, ref}, terminal: {:done, completed_mono}} = state) do
    send(consumer, {state.token, ref, :done, completed_mono})
    %{state | demand: nil}
  end

  defp dispatch_ready(
         %{demand: {consumer, ref}, terminal: {:error, reason, completed_mono}} = state
       ) do
    send(consumer, {state.token, ref, {:error, reason}, completed_mono})
    %{state | demand: nil}
  end

  defp dispatch_ready(state), do: state

  defp notify_timeout(%{demand: {consumer, ref}, token: token}) when is_pid(consumer),
    do: send(consumer, {token, ref, :timeout})

  defp notify_timeout(_state), do: :ok

  defp finalize_controller(state) do
    if Process.alive?(state.producer) do
      send(state.producer, {state.token, :cancel})

      receive do
        {:DOWN, monitor, :process, producer, _reason}
        when monitor == state.producer_monitor and producer == state.producer ->
          :ok
      after
        @cleanup_grace_ms ->
          if Process.alive?(state.producer), do: Process.exit(state.producer, :kill)
          await_producer_down(state)
      end
    end

    demonitor_if_present(state.consumer_monitor)
    Process.demonitor(state.producer_monitor, [:flush])
    :ok
  end

  defp await_producer_down(state) do
    receive do
      {:DOWN, monitor, :process, producer, _reason}
      when monitor == state.producer_monitor and producer == state.producer ->
        :ok
    end
  end

  defp await_controller_down(controller, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^controller, _reason} -> :ok
    end
  end

  defp demonitor_if_present(nil), do: :ok
  defp demonitor_if_present(monitor), do: Process.demonitor(monitor, [:flush])

  defp bounded_exception(%{__struct__: module}), do: {:stream_exception, module}
  defp bounded_exception(_exception), do: :stream_exception
  defp bounded_reason(reason) when is_atom(reason) or is_number(reason), do: reason
  defp bounded_reason(_reason), do: :external_reason
end

defimpl Enumerable, for: Arbor.LLM.OwnedStream do
  alias Arbor.LLM.OwnedStream

  def reduce(stream, acc, fun) do
    case OwnedStream.claim(stream) do
      :ok -> reduce_claimed(stream, acc, fun)
      {:error, reason} -> raise ArgumentError, "invalid owned stream: #{inspect(reason)}"
    end
  end

  defp reduce_claimed(stream, {:halt, acc}, _fun) do
    :ok = OwnedStream.finalize(stream)
    {:halted, acc}
  end

  defp reduce_claimed(stream, {:suspend, acc}, fun),
    do: {:suspended, acc, &reduce_claimed(stream, &1, fun)}

  defp reduce_claimed(stream, {:cont, acc}, fun) do
    case OwnedStream.demand(stream) do
      {:item, item} ->
        invoke_reducer(stream, item, acc, fun)

      :done ->
        :ok = OwnedStream.finalize(stream)
        {:done, acc}

      {:error, reason} ->
        :ok = OwnedStream.finalize(stream)
        raise Arbor.LLM.StreamError, reason: reason

      {:timeout, _reason} ->
        :ok = OwnedStream.finalize(stream)
        raise OwnedStream.timeout_error(stream)
    end
  end

  defp invoke_reducer(stream, item, acc, fun) do
    next = fun.(item, acc)
    reduce_claimed(stream, next, fun)
  rescue
    exception ->
      _ = OwnedStream.finalize(stream)
      reraise(exception, __STACKTRACE__)
  catch
    kind, reason ->
      _ = OwnedStream.finalize(stream)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  def count(_stream), do: {:error, __MODULE__}
  def member?(_stream, _value), do: {:error, __MODULE__}
  def slice(_stream), do: {:error, __MODULE__}
end
