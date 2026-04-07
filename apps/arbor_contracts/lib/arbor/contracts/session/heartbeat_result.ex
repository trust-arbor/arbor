defmodule Arbor.Contracts.Session.HeartbeatResult do
  @moduledoc """
  Typed outcome of a single agent heartbeat.

  A heartbeat is structurally different from a chat turn — there's no user
  message, no reply to deliver, and the side effects (goals, intents,
  memory notes, identity insights, decompositions, proposal decisions)
  are the entire point. This struct is the **single source of truth** for
  "what happened during a heartbeat", populated once at the orchestrator
  boundary and consumed everywhere else through the `to_*` converters.

  ## Why this exists

  Heartbeat data used to flow through the system as a free-form pipeline
  context map (`result.context`) with string keys like `"session.usage"`,
  `"llm.content"`, `"session.cognitive_mode"`. Producers wrote to one set
  of keys; consumers read from another. The persistence layer read from
  `"llm.usage"` and `"llm.content"` — keys nothing in the codebase ever
  wrote — and silently stored `nil` for every heartbeat. The chat_live HB
  panel showed `IN: 0 / OUT: 0` for the same reason: the signal payload
  forgot to include usage entirely, and nothing in the type system
  noticed.

  Constructing through `from_result_ctx/2` means:
  - the field shape is fixed at one place
  - missing data is `nil`, loud and obvious
  - downstream consumers read typed fields, not magic-string `Map.get/3`

  ## Construction (Construct)

      hr = HeartbeatResult.from_result_ctx(state, result)

  ## Conversion (Convert)

      hr |> HeartbeatResult.to_signal_data()
      hr |> HeartbeatResult.to_persistence()
      hr |> HeartbeatResult.to_telemetry()

  These are the only sanctioned crossings between the typed world and
  the loose world (signal payloads, DB rows, telemetry events).
  """

  use TypedStruct

  alias Arbor.Contracts.LLM.TokenUsage

  typedstruct do
    @typedoc "One agent heartbeat outcome"

    field(:agent_id, String.t(), enforce: true)
    field(:session_id, String.t() | nil)
    field(:cognitive_mode, atom() | String.t() | nil)
    field(:thinking, String.t() | nil)
    field(:usage, TokenUsage.t(), default: %TokenUsage{})
    field(:actions, [map()], default: [])
    field(:goal_updates, [map()], default: [])
    field(:new_goals, [map()], default: [])
    field(:memory_notes, [String.t() | map()], default: [])
    field(:concerns, [String.t()], default: [])
    field(:curiosity, [String.t()], default: [])
    field(:identity_insights, [map()], default: [])
    field(:decompositions, [map()], default: [])
    field(:proposal_decisions, [map()], default: [])
    field(:completed_nodes, [String.t()], default: [])
    field(:duration_ms, non_neg_integer() | nil)
    field(:emitted_at, DateTime.t())
  end

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Build a HeartbeatResult from session state and a pipeline result.

  `state` must expose `:agent_id` and may expose `:session_id`. `result`
  is the engine result whose `:context` map carries the heartbeat outputs.
  Any field not present in the context is left at its default.
  """
  @spec from_result_ctx(map(), map() | nil) :: t()
  def from_result_ctx(state, %{context: ctx}) when is_map(ctx) do
    usage =
      ctx
      |> Map.get("session.usage")
      |> TokenUsage.from_map()

    %__MODULE__{
      agent_id: Map.get(state, :agent_id),
      session_id: Map.get(state, :session_id),
      cognitive_mode: Map.get(ctx, "session.cognitive_mode", "reflection"),
      thinking: Map.get(ctx, "last_response") || Map.get(ctx, "llm.content"),
      usage: usage,
      actions: List.wrap(Map.get(ctx, "session.actions", [])),
      goal_updates: List.wrap(Map.get(ctx, "session.goal_updates", [])),
      new_goals: List.wrap(Map.get(ctx, "session.new_goals", [])),
      memory_notes: List.wrap(Map.get(ctx, "session.memory_notes", [])),
      concerns: List.wrap(Map.get(ctx, "session.concerns", [])),
      curiosity: List.wrap(Map.get(ctx, "session.curiosity", [])),
      identity_insights: List.wrap(Map.get(ctx, "session.identity_insights", [])),
      decompositions: List.wrap(Map.get(ctx, "session.decompositions", [])),
      proposal_decisions: List.wrap(Map.get(ctx, "session.proposal_decisions", [])),
      completed_nodes: List.wrap(Map.get(ctx, "__completed_nodes__", [])),
      duration_ms: usage.duration_ms,
      emitted_at: DateTime.utc_now()
    }
  end

  def from_result_ctx(state, _result) do
    %__MODULE__{
      agent_id: Map.get(state, :agent_id),
      session_id: Map.get(state, :session_id),
      emitted_at: DateTime.utc_now()
    }
  end

  # ============================================================================
  # Conversion
  # ============================================================================

  @doc """
  Convert to the data map used in `Arbor.Signals.emit/4` for the
  `:agent / :heartbeat_complete` signal.
  """
  @spec to_signal_data(t()) :: map()
  def to_signal_data(%__MODULE__{} = hr) do
    %{
      agent_id: hr.agent_id,
      session_id: hr.session_id,
      cognitive_mode: hr.cognitive_mode,
      agent_thinking: hr.thinking,
      usage: TokenUsage.to_signal_data(hr.usage),
      actions: hr.actions,
      llm_actions: length(hr.actions),
      goal_updates_count: length(hr.goal_updates) + length(hr.new_goals),
      memory_notes_count: length(hr.memory_notes),
      memory_notes: hr.memory_notes,
      concerns: hr.concerns,
      curiosity: hr.curiosity,
      identity_insights: hr.identity_insights,
      decompositions: hr.decompositions,
      proposal_decisions: hr.proposal_decisions,
      goal_updates: hr.goal_updates,
      new_goals: hr.new_goals,
      completed_nodes: hr.completed_nodes
    }
  end

  @doc """
  Convert to a flat map suitable for persisting to the event log / DB.
  """
  @spec to_persistence(t()) :: map()
  def to_persistence(%__MODULE__{} = hr) do
    %{
      agent_id: hr.agent_id,
      session_id: hr.session_id,
      cognitive_mode: hr.cognitive_mode,
      thinking: hr.thinking,
      token_usage: TokenUsage.to_persistence(hr.usage),
      actions_count: length(hr.actions),
      goal_updates_count: length(hr.goal_updates) + length(hr.new_goals),
      memory_notes_count: length(hr.memory_notes),
      duration_ms: hr.duration_ms,
      emitted_at: hr.emitted_at
    }
  end

  @doc """
  Convert to a measurements map for `:telemetry.execute/3`.
  """
  @spec to_telemetry(t()) :: map()
  def to_telemetry(%__MODULE__{} = hr) do
    TokenUsage.to_telemetry(hr.usage)
  end

  @doc "Returns true when no LLM-side activity happened in this heartbeat."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = hr) do
    TokenUsage.empty?(hr.usage) and hr.actions == [] and hr.thinking in [nil, ""]
  end
end
