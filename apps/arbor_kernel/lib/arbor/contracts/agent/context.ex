defmodule Arbor.Contracts.Agent.Context do
  @moduledoc """
  Context domain — what the agent knows and what's happening now.

  Lifecycle: high-frequency mutation, changes every turn.
  Persistence: checkpoint + delta journal per turn.

  Sub-structs:
  - Session: per-conversation state (messages, turn count, pipelines)
  - Memory: persistent knowledge (working memory, goals, intents, knowledge graph)
  """

  alias Arbor.Contracts.Agent.Context.{Session, Memory}

  @type t :: %__MODULE__{
          session: Session.t() | nil,
          memory: Memory.t()
        }

  @enforce_keys [:memory]
  defstruct [
    :session,
    :memory
  ]
end

defmodule Arbor.Contracts.Agent.Context.Session do
  @moduledoc """
  Per-conversation session state. This is the CRC-able domain state.

  Infrastructure concerns (timer refs, task monitors, GenServer.from refs)
  live in SessionInfra inside the GenServer — NOT here. This struct contains
  only data that pure functions should operate on.
  """

  @type status :: :idle | :processing | :awaiting_approval | :context_overflow
  @type session_type :: :primary | :background | :delegation | :consultation
  @type cognitive_mode :: :reactive | :reflection | :goal_pursuit | :exploration | :maintenance

  @type message :: %{
          String.t() => term()
        }

  @type t :: %__MODULE__{
          session_id: String.t(),
          agent_id: String.t(),
          messages: [message()],
          llm_messages: [message()],
          turn_count: non_neg_integer(),
          last_turn_at: DateTime.t() | nil,
          status: status(),
          session_type: session_type(),
          cognitive_mode: cognitive_mode(),
          heartbeat_count: non_neg_integer(),
          discovered_tools: MapSet.t(),
          turn_pipeline: term(),
          heartbeat_pipeline: term(),
          compactor: term() | nil
        }

  @enforce_keys [:session_id, :agent_id]
  defstruct [
    :session_id,
    :agent_id,
    :last_turn_at,
    :compactor,
    messages: [],
    llm_messages: [],
    turn_count: 0,
    status: :idle,
    session_type: :primary,
    cognitive_mode: :reactive,
    heartbeat_count: 0,
    discovered_tools: MapSet.new(),
    turn_pipeline: nil,
    heartbeat_pipeline: nil
  ]
end

defmodule Arbor.Contracts.Agent.Context.Memory do
  @moduledoc """
  Persistent agent knowledge — working memory, goals, intents, relationships.

  Heavy sub-domains (knowledge_graph, embedding_refs) are lazy-loaded.
  Use `:not_loaded` sentinel (like Ecto associations) to indicate unloaded state.
  """

  alias Arbor.Contracts.Agent.Context.Memory.{Working, Meta}

  @type t :: %__MODULE__{
          agent_id: String.t(),
          working: Working.t(),
          meta: Meta.t(),
          goals: [map()],
          intents: [map()],
          self_knowledge: map(),
          relationships: %{String.t() => map()},
          channel_memberships: [String.t()],
          knowledge_graph: :not_loaded | map(),
          embedding_refs: [String.t()]
        }

  @enforce_keys [:agent_id]
  defstruct [
    :agent_id,
    working: nil,
    meta: nil,
    goals: [],
    intents: [],
    self_knowledge: %{},
    relationships: %{},
    channel_memberships: [],
    knowledge_graph: :not_loaded,
    embedding_refs: []
  ]
end

defmodule Arbor.Contracts.Agent.Context.Memory.Working do
  @moduledoc """
  Working memory — the agent's current cognitive state.

  Contains what the agent is thinking about, concerned with, and curious about.
  engagement_level is cognitive state (not bookkeeping) and stays here.
  """

  @type thought :: %{
          content: String.t(),
          timestamp: DateTime.t(),
          cached_tokens: non_neg_integer(),
          referenced_date: DateTime.t() | nil
        }

  @type t :: %__MODULE__{
          concerns: [String.t()],
          curiosity: [String.t()],
          notes: [String.t()],
          thoughts: [thought()],
          active_goals: [map()],
          active_skills: [map()],
          current_human: String.t() | nil,
          current_conversation: map() | nil,
          relationship_context: String.t() | map() | nil,
          engagement_level: float()
        }

  defstruct [
    :current_human,
    :current_conversation,
    :relationship_context,
    concerns: [],
    curiosity: [],
    notes: [],
    thoughts: [],
    active_goals: [],
    active_skills: [],
    engagement_level: 0.5
  ]
end

defmodule Arbor.Contracts.Agent.Context.Memory.Meta do
  @moduledoc """
  Memory bookkeeping — token budgets, versioning, timestamps.

  Not cognitive state. Infrastructure for managing memory lifecycle.
  """

  @type t :: %__MODULE__{
          version: pos_integer(),
          max_tokens: term(),
          model: String.t() | nil,
          thought_count: non_neg_integer(),
          last_consolidated_at: DateTime.t() | nil,
          started_at: DateTime.t()
        }

  defstruct [
    :max_tokens,
    :model,
    :last_consolidated_at,
    version: 3,
    thought_count: 0,
    started_at: nil
  ]
end
