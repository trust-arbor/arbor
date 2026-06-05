defmodule Arbor.LLM.Plugs.RateLimitBackoff do
  @moduledoc """
  Same-path retry plug for rate-limit errors.

  Sits AFTER `Arbor.LLM.Plugs.Dispatch` in the pipeline. When the
  dispatch plug stamps a rate-limit error onto the call (HTTP 429 or a
  `%ProviderError{status: 429}` / `retryable: true` with a populated
  `retry_after_ms`), this plug:

    1. Sleeps for the indicated `retry_after_ms` (or an exponential
       backoff when the field is missing), capped at `:max_delay_ms`.
    2. Clears the result and re-invokes `Plugs.Dispatch.call/1` to
       retry the same path with the same `(model, provider, runtime)`.
    3. Recurses up to `:max_retries` times. Stops at the first
       success, the first non-rate-limit error, or when retries are
       exhausted.

  ## How this composes with Dispatch's fallback chain

  RateLimitBackoff handles **same-path transient backoff** —
  "this provider is rate-limiting us; wait and try again." Dispatch's
  fallback chain handles **multi-path swap** — "this provider keeps
  failing; try a different one." They compose cleanly:

      anthropic 429 → RateLimitBackoff retries 2× → still 429
        → bubbles up → Dispatch.dispatch sees an eligible error
          → fallback chain swaps to openai

  This avoids the previous behavior where Dispatch would fall back on
  the first 429 even though waiting 5 seconds would have worked.

  ## Configuration

      config :arbor_llm, Arbor.LLM.Plugs.RateLimitBackoff,
        max_retries: 2,           # attempts after the first failure
        max_delay_ms: 5_000,      # cap per-sleep at 5s (intentionally
                                  # short — if a provider says wait
                                  # longer, bubble up to Dispatch's
                                  # fallback chain instead)
        initial_backoff_ms: 1_000,
        backoff_factor: 2.0       # exponential when retry_after missing

  Defaults match the values above. Per-call overrides via
  `Call.metadata[:rate_limit_backoff]` aren't supported in v1 — the
  Application env shape is sufficient for the heartbeat + turn paths
  this is currently wired into.

  ## Streaming

  Skipped on `operation: :stream`. Once a stream starts, the consumer
  is already iterating events; restarting mid-stream would orphan
  partial output. Stream rate-limit handling is a separate problem.

  ## Telemetry

  Emits `[:arbor, :llm, :rate_limit_backoff]` per retry with:
    - `attempt` — 1-based retry number
    - `delay_ms` — actual sleep duration
    - `retry_after_ms_from_provider` — value from the error if present
    - `operation` — `:complete`, `:embed_cloud`, etc.
    - `provider` — extracted from the error if available
  """

  use Arbor.LLM.Plug
  require Logger

  alias Arbor.LLM.Call
  alias Arbor.LLM.Plugs.Dispatch
  alias Arbor.LLM.ProviderError

  @default_max_retries 2
  @default_max_delay_ms 5_000
  @default_initial_backoff_ms 1_000
  @default_backoff_factor 2.0

  @assign_key :rate_limit_attempts

  @impl Arbor.LLM.Plug
  def call(%Call{halted: true} = call), do: call

  def call(%Call{operation: :stream} = call), do: call

  def call(%Call{result: {:error, error}} = call) do
    if rate_limited?(error) do
      maybe_retry(call, error)
    else
      call
    end
  end

  def call(%Call{} = call), do: call

  # ── Internals ───────────────────────────────────────────────────────

  defp maybe_retry(%Call{} = call, error) do
    attempts = Map.get(call.assigns, @assign_key, 0)
    cfg = config()

    if attempts >= cfg.max_retries do
      Logger.warning(
        "[RateLimitBackoff] giving up after #{attempts} retries for #{call.operation}"
      )

      call
    else
      delay = compute_delay(error, attempts, cfg)
      emit_telemetry(call, attempts + 1, delay, error)
      sleep(delay)

      call
      |> Call.assign(@assign_key, attempts + 1)
      |> redispatch()
      |> __MODULE__.call()
    end
  end

  defp redispatch(%Call{} = call) do
    cleared = %{call | result: nil}
    dispatch_fn().(cleared)
  end

  # Default to Plugs.Dispatch; tests inject a stub via Application env
  # so they don't need to spin up req_llm to exercise the retry loop.
  defp dispatch_fn do
    case Application.get_env(:arbor_llm, :rate_limit_backoff_dispatch_fn) do
      fun when is_function(fun, 1) -> fun
      _ -> &Dispatch.call/1
    end
  end

  # ── Rate-limit detection ────────────────────────────────────────────

  defp rate_limited?(%ProviderError{status: 429}), do: true

  defp rate_limited?(%ProviderError{retryable: true, retry_after_ms: ms}) when is_integer(ms),
    do: true

  defp rate_limited?(:rate_limited), do: true
  defp rate_limited?({:http_status, 429}), do: true
  defp rate_limited?(_), do: false

  # ── Delay computation ───────────────────────────────────────────────

  defp compute_delay(error, attempt, cfg) do
    base = retry_after_ms(error) || exponential_backoff(attempt, cfg)
    min(base, cfg.max_delay_ms)
  end

  defp retry_after_ms(%ProviderError{retry_after_ms: ms}) when is_integer(ms) and ms > 0, do: ms
  defp retry_after_ms(_), do: nil

  defp exponential_backoff(attempt, cfg) do
    # attempt is 0-indexed at this point; cfg.initial_backoff_ms * factor^attempt
    trunc(cfg.initial_backoff_ms * :math.pow(cfg.backoff_factor, attempt))
  end

  # ── Telemetry ───────────────────────────────────────────────────────

  defp emit_telemetry(%Call{} = call, attempt, delay_ms, error) do
    metadata = %{
      attempt: attempt,
      delay_ms: delay_ms,
      retry_after_ms_from_provider: retry_after_ms(error),
      operation: call.operation,
      provider: provider_from_error(error)
    }

    safe_telemetry([:arbor, :llm, :rate_limit_backoff], %{count: 1}, metadata)
  end

  defp provider_from_error(%ProviderError{provider: provider}), do: provider
  defp provider_from_error(_), do: nil

  defp safe_telemetry(event, measurements, metadata) do
    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      apply(:telemetry, :execute, [event, measurements, metadata])
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ── Sleep (mockable for tests) ──────────────────────────────────────

  defp sleep(ms) do
    case Application.get_env(:arbor_llm, :rate_limit_backoff_sleep_fn) do
      fun when is_function(fun, 1) -> fun.(ms)
      _ -> Process.sleep(ms)
    end
  end

  # ── Config ──────────────────────────────────────────────────────────

  defp config do
    raw = Application.get_env(:arbor_llm, __MODULE__, [])

    %{
      max_retries: Keyword.get(raw, :max_retries, @default_max_retries),
      max_delay_ms: Keyword.get(raw, :max_delay_ms, @default_max_delay_ms),
      initial_backoff_ms: Keyword.get(raw, :initial_backoff_ms, @default_initial_backoff_ms),
      backoff_factor: Keyword.get(raw, :backoff_factor, @default_backoff_factor)
    }
  end
end
