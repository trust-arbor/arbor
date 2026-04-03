defmodule Arbor.Contracts.Agent.TelemetryEvent do
  @moduledoc """
  Data structure for individual telemetry events.

  While `Arbor.Contracts.Agent.Telemetry` holds aggregated metrics,
  this struct represents a single discrete event that can be persisted
  and queried historically.

  ## Event Types

  - `:turn_completed` -- an LLM turn finished
    - data: `%{input_tokens, output_tokens, cached_tokens, cost, duration_ms, provider, model}`
  - `:tool_call` -- a tool was invoked
    - data: `%{tool_name, result: :ok | :error | :gated, duration_ms}`
  - `:routing_decision` -- sensitivity routing classified a request
    - data: `%{decision: :classified | :rerouted | :tokenized | :blocked, sensitivity, provider, model}`
  - `:compaction` -- context was compacted
    - data: `%{utilization, tokens_before, tokens_after}`
  """

  @type event_type :: :turn_completed | :tool_call | :routing_decision | :compaction

  @type t :: %__MODULE__{
          id: String.t(),
          agent_id: String.t(),
          event_type: event_type(),
          timestamp: DateTime.t(),
          data: map()
        }

  defstruct [
    :id,
    :agent_id,
    :event_type,
    :timestamp,
    data: %{}
  ]

  @valid_types [:turn_completed, :tool_call, :routing_decision, :compaction]

  @doc """
  Create a new telemetry event.
  """
  @spec new(String.t(), event_type(), map()) :: t()
  def new(agent_id, event_type, data \\ %{})
      when is_binary(agent_id) and event_type in @valid_types and is_map(data) do
    %__MODULE__{
      id: generate_id(),
      agent_id: agent_id,
      event_type: event_type,
      timestamp: DateTime.utc_now(),
      data: data
    }
  end

  defp generate_id do
    "tevt_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
