defmodule Arbor.Contracts.Agent.Telemetry do
  @moduledoc """
  Data structure for agent telemetry metrics.

  Tracks per-agent resource consumption, performance, and operational statistics
  across both session-scoped and lifetime-scoped windows.

  Lifecycle: write-heavy, continuous. Externalized to ETS, not part of
  core agent GenServer state. Async writes via Signal Bus.

  Storage: single global ETS table `:arbor_agent_telemetry` with
  `read_concurrency: true`, keyed by agent_id.

  ## Scopes

  - **Session**: Reset when the agent's session resets (e.g., context compaction,
    explicit `/clear`). Useful for per-conversation cost tracking.
  - **Lifetime**: Accumulated from agent creation until deletion. Never reset.

  ## Tracked Metrics

  - Token usage (input, output, cached) by provider
  - Cost breakdown by provider
  - LLM call latency (P50/P95 from rolling window)
  - Tool call statistics (per-tool success/failure/gated rates)
  - Sensitivity routing decisions
  - Context compaction frequency and utilization
  """

  @type tool_stats :: %{
          calls: non_neg_integer(),
          succeeded: non_neg_integer(),
          failed: non_neg_integer(),
          gated: non_neg_integer(),
          total_duration_ms: non_neg_integer()
        }

  @type routing_stats :: %{
          classified: non_neg_integer(),
          rerouted: non_neg_integer(),
          tokenized: non_neg_integer(),
          blocked: non_neg_integer()
        }

  @type t :: %__MODULE__{
          agent_id: String.t(),
          # Session-scoped token counts
          session_input_tokens: non_neg_integer(),
          session_output_tokens: non_neg_integer(),
          session_cached_tokens: non_neg_integer(),
          session_cost: float(),
          # Lifetime token counts
          lifetime_input_tokens: non_neg_integer(),
          lifetime_output_tokens: non_neg_integer(),
          lifetime_cached_tokens: non_neg_integer(),
          lifetime_cost: float(),
          # Per-provider cost breakdown: %{"anthropic" => 0.05, "openai" => 0.02}
          cost_by_provider: %{String.t() => float()},
          # Turn counter
          turn_count: non_neg_integer(),
          # LLM latency rolling windows (last 100 each)
          llm_latencies: [non_neg_integer()],
          tool_latencies: [non_neg_integer()],
          # Per-tool stats: %{"file.read" => %{calls: 5, succeeded: 4, ...}}
          tool_stats: %{String.t() => tool_stats()},
          # Sensitivity routing counters
          routing_stats: routing_stats(),
          # Context compaction
          compaction_count: non_neg_integer(),
          avg_utilization: float(),
          # Timestamps
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  defstruct [
    :agent_id,
    session_input_tokens: 0,
    session_output_tokens: 0,
    session_cached_tokens: 0,
    session_cost: 0.0,
    lifetime_input_tokens: 0,
    lifetime_output_tokens: 0,
    lifetime_cached_tokens: 0,
    lifetime_cost: 0.0,
    cost_by_provider: %{},
    turn_count: 0,
    llm_latencies: [],
    tool_latencies: [],
    tool_stats: %{},
    routing_stats: %{classified: 0, rerouted: 0, tokenized: 0, blocked: 0},
    compaction_count: 0,
    avg_utilization: 0.0,
    created_at: nil,
    updated_at: nil
  ]
end
