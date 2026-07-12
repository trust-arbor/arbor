defmodule Arbor.LLM.Deadline do
  @moduledoc false

  @default_timeout_ms 30_000
  @maximum_timeout_ms 900_000
  @worker_key {__MODULE__, :worker_deadline}
  @timeout_keys [
    :timeout_ms,
    :stream_read_timeout_ms,
    :receive_timeout,
    :request_timeout,
    :timeout
  ]

  @type receipt :: %{deadline_ms: integer(), timeout_ms: pos_integer()}

  @spec receipt(term(), term()) :: {:ok, receipt()} | {:error, term()}
  def receipt(opts, fallback \\ nil) do
    with {:ok, requested} <- requested_timeout(opts, fallback) do
      now = System.monotonic_time(:millisecond)
      inherited = Process.get(@worker_key)
      own_deadline = now + min(requested, @maximum_timeout_ms)
      deadline_ms = if is_integer(inherited), do: min(inherited, own_deadline), else: own_deadline

      {:ok, %{deadline_ms: deadline_ms, timeout_ms: min(requested, @maximum_timeout_ms)}}
    end
  end

  @spec receipt_until(term(), term()) :: {:ok, receipt()} | {:error, term()}
  def receipt_until(deadline_ms, timeout_ms)
      when is_integer(deadline_ms) and is_integer(timeout_ms) and timeout_ms > 0 do
    now = System.monotonic_time(:millisecond)
    closed_timeout = min(timeout_ms, @maximum_timeout_ms)
    closed_deadline = min(deadline_ms, now + closed_timeout)
    inherited = Process.get(@worker_key)

    effective_deadline =
      if is_integer(inherited), do: min(inherited, closed_deadline), else: closed_deadline

    {:ok, %{deadline_ms: effective_deadline, timeout_ms: closed_timeout}}
  end

  def receipt_until(_deadline_ms, _timeout_ms),
    do: {:error, {:invalid_timeout, {1, @maximum_timeout_ms}}}

  @spec run((-> term()), receipt(), term()) :: term()
  def run(fun, %{deadline_ms: deadline_ms} = receipt, timeout_error)
      when is_function(fun, 0) and is_integer(deadline_ms) do
    effective = inherited_deadline(deadline_ms)
    receipt = %{receipt | deadline_ms: effective}

    if Process.get(@worker_key) do
      run_inline(fun, receipt, timeout_error)
    else
      run_owned(fun, receipt, timeout_error)
    end
  end

  def run(_fun, _receipt, _timeout_error), do: {:error, :invalid_deadline_operation}

  @spec current_deadline() :: integer() | nil
  def current_deadline, do: Process.get(@worker_key)

  defp requested_timeout(opts, fallback) do
    with {:ok, options} <- collect_options(opts, %{}, 0) do
      supplied = Enum.flat_map(@timeout_keys, &Map.get(options, &1, []))
      values = if valid_fallback(fallback), do: [fallback | supplied], else: supplied

      case Enum.find(values, &(not (is_integer(&1) and &1 > 0))) do
        nil ->
          requested = if values == [], do: @default_timeout_ms, else: Enum.min(values)
          {:ok, min(requested, @maximum_timeout_ms)}

        _invalid ->
          {:error, {:invalid_timeout, {1, @maximum_timeout_ms}}}
      end
    end
  end

  defp collect_options([], options, _count), do: {:ok, options}

  defp collect_options(_opts, _options, count) when count >= 128,
    do: {:error, {:invalid_options, :too_many_options}}

  defp collect_options([{key, value} | rest], options, count) when is_atom(key) do
    next = Map.update(options, key, [value], &[value | &1])
    collect_options(rest, next, count + 1)
  end

  defp collect_options(_improper_or_non_keyword, _options, _count),
    do: {:error, {:invalid_options, :keyword_required}}

  defp valid_fallback(value) when is_integer(value) and value > 0, do: value
  defp valid_fallback(_value), do: nil

  defp inherited_deadline(deadline_ms) do
    case Process.get(@worker_key) do
      inherited when is_integer(inherited) -> min(inherited, deadline_ms)
      _ -> deadline_ms
    end
  end

  defp run_inline(fun, receipt, timeout_error) do
    result = safely_apply(fun)
    completed_mono = System.monotonic_time(:millisecond)

    if completed_mono <= receipt.deadline_ms,
      do: unwrap(result),
      else: {:error, timeout_error}
  end

  defp run_owned(fun, receipt, timeout_error) do
    caller = self()
    reply_alias = :erlang.alias()
    operation_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        Process.put(@worker_key, receipt.deadline_ms)
        result = safely_apply(fun)
        completed_mono = System.monotonic_time(:millisecond)

        send(reply_alias, {operation_ref, result, completed_mono, self()})

        receive do
          {^operation_ref, :ack, ^caller} -> :ok
        after
          5_000 -> :ok
        end
      end)

    await_receipt(pid, monitor_ref, reply_alias, operation_ref, receipt, timeout_error)
  end

  defp await_receipt(pid, monitor_ref, reply_alias, operation_ref, receipt, timeout_error) do
    remaining = max(receipt.deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^operation_ref, result, completed_mono, ^pid} ->
        :erlang.unalias(reply_alias)

        if completed_mono <= receipt.deadline_ms do
          send(pid, {operation_ref, :ack, self()})
          await_down(pid, monitor_ref)
          unwrap(result)
        else
          terminate_and_await(pid, monitor_ref)
          {:error, timeout_error}
        end

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        :erlang.unalias(reply_alias)
        {:error, {:deadline_worker_exit, bounded_reason(reason)}}
    after
      remaining ->
        :erlang.unalias(reply_alias)
        terminate_and_await(pid, monitor_ref)
        {:error, timeout_error}
    end
  end

  defp terminate_and_await(pid, monitor_ref) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    await_down(pid, monitor_ref)
  end

  defp await_down(pid, monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp safely_apply(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:raised, :error, bounded_exception(exception)}
  catch
    kind, reason -> {:raised, kind, bounded_reason(reason)}
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:raised, kind, reason}), do: {:error, {:operation_failed, kind, reason}}

  defp bounded_exception(%{__struct__: module, message: message}) when is_binary(message),
    do: {module, bounded_binary(message)}

  defp bounded_exception(%{__struct__: module}), do: module
  defp bounded_exception(_exception), do: :exception

  defp bounded_reason(reason) when is_atom(reason) or is_number(reason), do: reason
  defp bounded_reason(reason) when is_binary(reason), do: bounded_binary(reason)
  defp bounded_reason(_reason), do: :external_reason

  defp bounded_binary(value) when byte_size(value) <= 512, do: String.replace_invalid(value, "")

  defp bounded_binary(value) do
    value
    |> binary_part(0, 512)
    |> String.replace_invalid("")
  end
end
