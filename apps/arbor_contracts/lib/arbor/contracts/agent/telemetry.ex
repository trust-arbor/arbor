defmodule Arbor.Contracts.Agent.Telemetry do
  @moduledoc """
  Telemetry domain — agent performance metrics.

  Lifecycle: write-heavy, continuous. Externalized to ETS, not part of
  core agent GenServer state. Async writes via Signal Bus.

  Storage: single global ETS table `:arbor_agent_telemetry` with
  `read_concurrency: true`, keyed by agent_id.
  """

  @type token_counts :: %{
          input: non_neg_integer(),
          output: non_neg_integer(),
          cached: non_neg_integer()
        }

  @type cost_breakdown :: %{
          session: float(),
          lifetime: float(),
          by_provider: %{atom() => float()}
        }

  @type latency_stats :: %{
          recent_llm_ms: [non_neg_integer()],
          recent_tool_ms: [non_neg_integer()],
          p50_ms: non_neg_integer(),
          p95_ms: non_neg_integer()
        }

  @type tool_stats :: %{
          succeeded: non_neg_integer(),
          failed: non_neg_integer(),
          gated: non_neg_integer(),
          total_duration_ms: non_neg_integer(),
          call_count: non_neg_integer()
        }

  @type routing_stats :: %{
          classifications: non_neg_integer(),
          rerouted: non_neg_integer(),
          tokenized: non_neg_integer(),
          blocked: non_neg_integer()
        }

  @type context_stats :: %{
          compaction_triggers: non_neg_integer(),
          total_utilization: float(),
          utilization_samples: non_neg_integer(),
          resets: non_neg_integer()
        }

  @type t :: %__MODULE__{
          agent_id: String.t(),
          tokens: %{
            session: token_counts(),
            lifetime: token_counts(),
            by_provider: %{atom() => token_counts()}
          },
          cost: cost_breakdown(),
          latency: latency_stats(),
          tools: %{String.t() => tool_stats()},
          routing: routing_stats(),
          context: context_stats(),
          turn_count: non_neg_integer(),
          started_at: DateTime.t(),
          last_turn_at: DateTime.t() | nil
        }

  @enforce_keys [:agent_id]
  defstruct [
    :agent_id,
    :last_turn_at,
    tokens: %{
      session: %{input: 0, output: 0, cached: 0},
      lifetime: %{input: 0, output: 0, cached: 0},
      by_provider: %{}
    },
    cost: %{session: 0.0, lifetime: 0.0, by_provider: %{}},
    latency: %{recent_llm_ms: [], recent_tool_ms: [], p50_ms: 0, p95_ms: 0},
    tools: %{},
    routing: %{classifications: 0, rerouted: 0, tokenized: 0, blocked: 0},
    context: %{compaction_triggers: 0, total_utilization: 0.0, utilization_samples: 0, resets: 0},
    turn_count: 0,
    started_at: nil
  ]
end
