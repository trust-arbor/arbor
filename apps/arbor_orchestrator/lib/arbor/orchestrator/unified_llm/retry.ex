defmodule Arbor.Orchestrator.UnifiedLLM.Retry do
  @moduledoc false

  @spec execute((-> any()), keyword()) :: {:ok, any()} | {:error, term()}
  def execute(fun, opts \\ []) when is_function(fun, 0) do
    max_retries = Keyword.get(opts, :max_retries, 2)
    initial_delay = Keyword.get(opts, :initial_delay_ms, 200)
    factor = Keyword.get(opts, :backoff_factor, 2.0)
    max_delay = Keyword.get(opts, :max_delay_ms, 60_000)
    jitter = Keyword.get(opts, :jitter, false)
    should_retry = Keyword.get(opts, :should_retry, &default_should_retry/1)
    on_retry = Keyword.get(opts, :on_retry)
    sleep_fn = Keyword.get(opts, :sleep_fn, fn ms -> Process.sleep(ms) end)

    do_execute(
      fun,
      0,
      max_retries,
      initial_delay,
      factor,
      max_delay,
      jitter,
      should_retry,
      on_retry,
      sleep_fn
    )
  end

  defp do_execute(
         fun,
         attempt,
         max_retries,
         initial_delay,
         factor,
         max_delay,
         jitter,
         should_retry,
         on_retry,
         sleep_fn
       ) do
    case safe_call(fun) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} = error ->
        if attempt < max_retries and should_retry.(reason) do
          with {:ok, delay} <-
                 retry_delay(reason, initial_delay, factor, attempt + 1, max_delay, jitter) do
            if is_function(on_retry, 2),
              do: on_retry.(reason, %{attempt: attempt + 1, delay_ms: delay})

            sleep_fn.(delay)

            do_execute(
              fun,
              attempt + 1,
              max_retries,
              initial_delay,
              factor,
              max_delay,
              jitter,
              should_retry,
              on_retry,
              sleep_fn
            )
          else
            :do_not_retry ->
              error
          end
        else
          error
        end
    end
  end

  defp safe_call(fun) do
    case fun.() do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
      other -> {:ok, other}
    end
  rescue
    exception -> {:error, exception}
  end

  defp backoff_delay(initial, factor, attempt, max_delay, jitter) do
    base = trunc(initial * :math.pow(factor, attempt - 1)) |> min(max_delay)

    if jitter do
      trunc(base * (:rand.uniform() + 0.5))
    else
      base
    end
  end

  defp retry_delay(
         %Arbor.Orchestrator.UnifiedLLM.ProviderError{retry_after_ms: retry_after_ms},
         _initial,
         _factor,
         _attempt,
         max_delay,
         _jitter
       )
       when is_integer(retry_after_ms) and retry_after_ms > max_delay do
    :do_not_retry
  end

  defp retry_delay(
         %Arbor.Orchestrator.UnifiedLLM.ProviderError{retry_after_ms: retry_after_ms},
         _initial,
         _factor,
         _attempt,
         max_delay,
         _jitter
       )
       when is_integer(retry_after_ms) and retry_after_ms >= 0 and retry_after_ms <= max_delay do
    {:ok, retry_after_ms}
  end

  defp retry_delay(_reason, initial, factor, attempt, max_delay, jitter) do
    {:ok, backoff_delay(initial, factor, attempt, max_delay, jitter)}
  end

  defp default_should_retry(%Arbor.Orchestrator.UnifiedLLM.ProviderError{retryable: retryable}),
    do: retryable

  defp default_should_retry(%Arbor.Orchestrator.UnifiedLLM.RequestTimeoutError{}), do: true

  defp default_should_retry(reason) when is_atom(reason) do
    reason in [:timeout, :rate_limited, :network_error, :transient_error]
  end

  defp default_should_retry({:http_status, status}) when is_integer(status),
    do: status == 429 or status >= 500

  defp default_should_retry(_), do: false
end
