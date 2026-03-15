defmodule Arbor.AI.LLMTrace do
  @moduledoc """
  Structured tracing for LLM calls.

  Logs entry/exit for every LLM call with consistent metadata:
  trace_id, provider, model, agent_id, prompt size, response size,
  duration, cost, and tool rounds.

  ## Example log output

      [LLM] trace=abc123 START provider=openrouter model=gemini-3-flash agent=agent_x prompt=2048 chars
      [LLM] trace=abc123 OK    provider=openrouter model=gemini-3-flash agent=agent_x duration=1234ms tokens=456 cost=$0.0023 tools=0

  ## Usage

      trace_id = LLMTrace.start(:generate_text, provider, model, agent_id, prompt)
      result = do_llm_call(...)
      LLMTrace.finish(trace_id, result)
  """

  require Logger

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
      start_time: System.monotonic_time(:millisecond)
    }
  end

  @doc "Log the completion of an LLM call."
  def finish(trace, {:ok, response}) when is_map(response) do
    duration = System.monotonic_time(:millisecond) - trace.start_time

    # Extract metrics from various response formats
    text = response[:text] || response[:content] || Map.get(response, :text, "")
    text_len = if is_binary(text), do: String.length(text), else: 0

    usage = response[:usage] || Map.get(response, :usage, %{})
    tokens = Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens", 0)
    cost = Map.get(usage, :cost)

    tool_rounds = response[:tool_rounds] || Map.get(response, :tool_rounds, 0)

    cost_str = if cost, do: " cost=$#{Float.round(cost * 1.0, 4)}", else: ""
    tools_str = if tool_rounds > 0, do: " tools=#{tool_rounds}", else: ""

    Logger.info(
      "[LLM] trace=#{trace.trace_id} OK    #{trace.call_type} " <>
        "provider=#{trace.provider} model=#{trace.model} agent=#{trace.agent_id} " <>
        "duration=#{duration}ms response=#{text_len} chars tokens=#{tokens}#{cost_str}#{tools_str}"
    )

    trace.trace_id
  end

  def finish(trace, {:error, reason}) do
    duration = System.monotonic_time(:millisecond) - trace.start_time

    Logger.warning(
      "[LLM] trace=#{trace.trace_id} FAIL  #{trace.call_type} " <>
        "provider=#{trace.provider} model=#{trace.model} agent=#{trace.agent_id} " <>
        "duration=#{duration}ms error=#{inspect(reason)}"
    )

    trace.trace_id
  end

  def finish(trace, other) do
    duration = System.monotonic_time(:millisecond) - trace.start_time

    Logger.info(
      "[LLM] trace=#{trace.trace_id} DONE  #{trace.call_type} " <>
        "provider=#{trace.provider} model=#{trace.model} agent=#{trace.agent_id} " <>
        "duration=#{duration}ms"
    )

    trace.trace_id
  end
end
