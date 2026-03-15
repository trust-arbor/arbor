defmodule Arbor.AI.LLMTrace do
  @moduledoc """
  Structured tracing for LLM calls.

  Logs entry/exit for every LLM call with consistent metadata and
  emits events to the Historian for durable querying.

  ## Log format

      [LLM] trace=abc123 START provider=openrouter model=gemini-3-flash agent=agent_x prompt=2048 chars
      [LLM] trace=abc123 OK    provider=openrouter model=gemini-3-flash agent=agent_x duration=1234ms tokens=456 cost=$0.0023

  ## Historian events

  Each completed call emits an `llm.call_completed` or `llm.call_failed`
  signal via dual_emit (ETS EventLog + Postgres). Query with:

      Arbor.Historian.for_category(:llm)
      Arbor.Historian.for_agent("agent_x")

  ## Usage

      trace = LLMTrace.start(:generate_text, provider, model, agent_id, prompt)
      result = do_llm_call(...)
      LLMTrace.finish(trace, result)
  """

  require Logger

  @signals_mod Arbor.Signals

  @doc "Generate a trace ID and log the start of an LLM call."
  def start(call_type, provider, model, agent_id, prompt) do
    trace_id = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    prompt_len = if is_binary(prompt), do: String.length(prompt), else: 0
    agent = agent_id || "system"

    Logger.info(
      "[LLM] trace=#{trace_id} START #{call_type} " <>
        "provider=#{provider} model=#{model} agent=#{agent} prompt=#{prompt_len} chars"
    )

    %{
      trace_id: trace_id,
      call_type: call_type,
      provider: provider,
      model: model,
      agent_id: agent,
      prompt_len: prompt_len,
      start_time: System.monotonic_time(:millisecond)
    }
  end

  @doc "Log the completion of an LLM call and emit to Historian."
  def finish(trace, {:ok, response}) when is_map(response) do
    duration = System.monotonic_time(:millisecond) - trace.start_time

    text = response[:text] || response[:content] || Map.get(response, :text, "")
    text_len = if is_binary(text), do: String.length(text), else: 0

    usage = response[:usage] || Map.get(response, :usage, %{})
    tokens = Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens", 0)
    cost = Map.get(usage, :cost)
    input_tokens = Map.get(usage, :input_tokens) || Map.get(usage, :prompt_tokens, 0)
    output_tokens = Map.get(usage, :output_tokens) || Map.get(usage, :completion_tokens, 0)

    tool_rounds = response[:tool_rounds] || Map.get(response, :tool_rounds, 0)

    cost_str = if cost, do: " cost=$#{Float.round(cost * 1.0, 4)}", else: ""
    tools_str = if tool_rounds > 0, do: " tools=#{tool_rounds}", else: ""

    Logger.info(
      "[LLM] trace=#{trace.trace_id} OK    #{trace.call_type} " <>
        "provider=#{trace.provider} model=#{trace.model} agent=#{trace.agent_id} " <>
        "duration=#{duration}ms response=#{text_len} chars tokens=#{tokens}#{cost_str}#{tools_str}"
    )

    # Emit to Historian for durable querying
    emit_event(:call_completed, %{
      trace_id: trace.trace_id,
      call_type: to_string(trace.call_type),
      provider: to_string(trace.provider),
      model: to_string(trace.model),
      agent_id: trace.agent_id,
      duration_ms: duration,
      prompt_chars: trace.prompt_len,
      response_chars: text_len,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: tokens,
      cost: cost,
      tool_rounds: tool_rounds,
      status: :ok
    })

    trace.trace_id
  end

  def finish(trace, {:error, reason}) do
    duration = System.monotonic_time(:millisecond) - trace.start_time

    Logger.warning(
      "[LLM] trace=#{trace.trace_id} FAIL  #{trace.call_type} " <>
        "provider=#{trace.provider} model=#{trace.model} agent=#{trace.agent_id} " <>
        "duration=#{duration}ms error=#{inspect(reason)}"
    )

    emit_event(:call_failed, %{
      trace_id: trace.trace_id,
      call_type: to_string(trace.call_type),
      provider: to_string(trace.provider),
      model: to_string(trace.model),
      agent_id: trace.agent_id,
      duration_ms: duration,
      prompt_chars: trace.prompt_len,
      error: inspect(reason),
      status: :error
    })

    trace.trace_id
  end

  def finish(trace, _other) do
    duration = System.monotonic_time(:millisecond) - trace.start_time

    Logger.info(
      "[LLM] trace=#{trace.trace_id} DONE  #{trace.call_type} " <>
        "provider=#{trace.provider} model=#{trace.model} agent=#{trace.agent_id} " <>
        "duration=#{duration}ms"
    )

    trace.trace_id
  end

  # Emit to Historian via dual_emit pattern (ETS EventLog + Postgres).
  # Non-fatal — tracing never blocks or crashes the LLM call path.
  defp emit_event(type, data) do
    if Code.ensure_loaded?(@signals_mod) do
      apply(@signals_mod, :emit, [:llm, type, data])
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
