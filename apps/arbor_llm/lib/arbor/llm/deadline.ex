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

  @spec timeout_keys() :: [atom()]
  def timeout_keys, do: @timeout_keys

  @spec select(term(), [atom()], term(), pos_integer()) :: {:ok, pos_integer()} | {:error, term()}
  def select(opts, keys, default, maximum)
      when is_list(keys) and is_integer(maximum) and maximum > 0 do
    with true <- Enum.all?(keys, &is_atom/1) or {:error, :invalid_timeout_aliases},
         {:ok, options} <- collect_options(opts, %{}, 0),
         values = Enum.flat_map(keys, &Map.get(options, &1, [])),
         selected = if(values == [], do: [default], else: values),
         :ok <- validate_timeout_values(selected, maximum) do
      {:ok, Enum.min(selected)}
    end
  end

  def select(_opts, _keys, _default, _maximum), do: {:error, :invalid_timeout_selection}

  @spec normalize_options(term(), pos_integer()) ::
          {:ok, keyword(), pos_integer()} | {:error, term()}
  def normalize_options(opts, default) do
    with {:ok, timeout} <- select(opts, @timeout_keys, default, @maximum_timeout_ms),
         {:ok, options} <- option_list(opts, [], 0) do
      normalized =
        options
        |> Enum.reject(fn {key, _value} -> key in @timeout_keys end)
        |> Keyword.put(:timeout_ms, timeout)

      {:ok, normalized, timeout}
    end
  end

  @spec narrow_options(term(), term(), pos_integer()) ::
          {:ok, keyword(), pos_integer()} | {:error, term()}
  def narrow_options(caller_opts, delegated_opts, default \\ @default_timeout_ms) do
    with {:ok, caller} <- collect_options(caller_opts, %{}, 0),
         {:ok, delegated} <- collect_options(delegated_opts, %{}, 0),
         values = timeout_values(caller) ++ timeout_values(delegated),
         selected = if(values == [], do: [default], else: values),
         :ok <- validate_timeout_values(selected, @maximum_timeout_ms),
         {:ok, delegated_list} <- option_list(delegated_opts, [], 0) do
      timeout = Enum.min(selected)

      normalized =
        delegated_list
        |> Enum.reject(fn {key, _value} -> key in @timeout_keys end)
        |> Keyword.put(:timeout_ms, timeout)

      {:ok, normalized, timeout}
    end
  end

  @spec normalize_transport_options(term(), term()) ::
          {:ok, keyword(), pos_integer()} | {:error, term()}
  def normalize_transport_options(opts, fallback \\ nil) do
    caller_opts = if is_nil(fallback), do: [], else: [receive_timeout: fallback]

    with {:ok, normalized, timeout} <- narrow_options(caller_opts, opts) do
      {:ok, Keyword.put(normalized, :receive_timeout, timeout), timeout}
    end
  end

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
      when is_integer(deadline_ms) and is_integer(timeout_ms) and timeout_ms > 0 and
             timeout_ms <= @maximum_timeout_ms do
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
      supplied = timeout_values(options)

      with {:ok, values} <- include_fallback(supplied, fallback),
           values = if(values == [], do: [@default_timeout_ms], else: values),
           :ok <- validate_timeout_values(values, @maximum_timeout_ms) do
        {:ok, Enum.min(values)}
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

  defp timeout_values(options),
    do: Enum.flat_map(@timeout_keys, &Map.get(options, &1, []))

  defp include_fallback(values, nil), do: {:ok, values}
  defp include_fallback(values, fallback), do: {:ok, [fallback | values]}

  defp validate_timeout_values(values, maximum) do
    if Enum.all?(values, &(is_integer(&1) and &1 > 0 and &1 <= maximum)),
      do: :ok,
      else: {:error, {:invalid_timeout, {1, maximum}}}
  end

  defp option_list([], acc, _count), do: {:ok, Enum.reverse(acc)}

  defp option_list(_opts, _acc, count) when count >= 128,
    do: {:error, {:invalid_options, :too_many_options}}

  defp option_list([{key, value} | rest], acc, count) when is_atom(key),
    do: option_list(rest, [{key, value} | acc], count + 1)

  defp option_list(_improper_or_non_keyword, _acc, _count),
    do: {:error, {:invalid_options, :keyword_required}}

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
    exception -> {:raised, :error, Arbor.LLM.ExternalTerm.exception(exception)}
  catch
    kind, reason -> {:raised, kind, Arbor.LLM.ExternalTerm.sanitize(reason)}
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:raised, kind, reason}), do: {:error, {:operation_failed, kind, reason}}

  defp bounded_reason(reason), do: Arbor.LLM.ExternalTerm.sanitize(reason)
end
