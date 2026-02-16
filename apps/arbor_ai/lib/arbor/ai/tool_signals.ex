defmodule Arbor.AI.ToolSignals do
  @moduledoc """
  Signal emission and stats recording for AI tool-calling requests.

  Centralizes the observability instrumentation that wraps tool-calling
  LLM interactions: signal emission, budget tracking, and usage stats.
  """

  alias Arbor.AI.{BudgetTracker, UsageStats}

  # ── Signal emission for tool requests ──

  @doc false
  def emit_started(provider, model, prompt_length) do
    Arbor.Signals.emit(:ai, :tool_request_started, %{
      provider: provider,
      model: model,
      prompt_length: prompt_length,
      backend: :api_with_tools
    })
  rescue
    _ -> :ok
  end

  @doc false
  def emit_completed(provider, model, duration_ms, response) do
    Arbor.Signals.emit(:ai, :tool_request_completed, %{
      provider: provider,
      model: model,
      duration_ms: duration_ms,
      turns: response[:turns],
      tool_calls_count: length(response[:tool_calls] || []),
      backend: :api_with_tools
    })
  rescue
    _ -> :ok
  end

  @doc false
  def emit_failed(provider, model, reason) do
    Arbor.Signals.emit(:ai, :tool_request_failed, %{
      provider: provider,
      model: model,
      error: inspect(reason),
      backend: :api_with_tools
    })
  rescue
    _ -> :ok
  end

  # ── Budget/stats recording ──

  @doc false
  def record_budget_usage(provider, opts, response) do
    if BudgetTracker.started?() do
      usage = response[:usage] || %{}

      BudgetTracker.record_usage(provider, %{
        input_tokens: usage[:input_tokens] || 0,
        output_tokens: usage[:output_tokens] || 0,
        model: Keyword.get(opts, :model, "unknown")
      })
    end
  rescue
    _ -> :ok
  end

  @doc false
  def record_usage_success(provider, opts, response, latency_ms) do
    if UsageStats.started?() do
      usage = response[:usage] || %{}

      UsageStats.record_success(provider, %{
        model: Keyword.get(opts, :model, "unknown"),
        input_tokens: usage[:input_tokens] || 0,
        output_tokens: usage[:output_tokens] || 0,
        latency_ms: latency_ms,
        backend: :api_with_tools
      })
    end
  rescue
    _ -> :ok
  end

  @doc false
  def record_usage_failure(provider, opts, error, latency_ms) do
    if UsageStats.started?() do
      UsageStats.record_failure(provider, %{
        model: Keyword.get(opts, :model, "unknown"),
        error: inspect(error),
        latency_ms: latency_ms,
        backend: :api_with_tools
      })
    end
  rescue
    _ -> :ok
  end
end
