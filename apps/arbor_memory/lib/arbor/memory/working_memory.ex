defmodule Arbor.Memory.WorkingMemory do
  @moduledoc """
  The agent's "present moment" awareness — short-term context that persists
  within a session and across sessions.

  WorkingMemory holds the ephemeral state that makes an agent feel present
  and aware: recent thoughts, active goals, relationship context, concerns,
  curiosity, and engagement level.

  ## Structured Data

  Thoughts are stored as maps with metadata:

      %{content: "User seems interested", timestamp: ~U[...], cached_tokens: 12}

  Goals are stored as maps with tracking fields:

      %{id: "goal_abc", description: "Explain GenServer", type: :task,
        priority: :normal, progress: 0, added_at: ~U[...]}

  Both `add_thought/3` and `add_goal/3` accept plain strings for convenience —
  they are automatically wrapped in the structured format.

  ## Token-Based Trimming

  When `max_tokens` is set, thoughts are trimmed by token count rather than
  a fixed count limit. This works with the `model` field to determine context
  budgets.

  ## Hybrid Memory Model

  ```
  ┌──────────────────────────────────────────────────────────────┐
  │                           Mind                                │
  │  ┌────────────────────────────────────────────────────────┐  │
  │  │           Working Memory (in-process)                  │  │
  │  │                                                        │  │
  │  │  - Recent thoughts (with timestamps + token counts)    │  │
  │  │  - Active goals (with progress tracking)               │  │
  │  │  - Identity (name, agent_id)                           │  │
  │  │  - Relationship (current_human, context)               │  │
  │  │  - Emotional state (engagement, curiosity, concerns)   │  │
  │  └────────────────────────────────────────────────────────┘  │
  │                           │                                   │
  │                           │ consolidate periodically          │
  │                           ▼                                   │
  │  ┌────────────────────────────────────────────────────────┐  │
  │  │         Long-term Memory (Signals events)              │  │
  │  │  - Past conversations and facts                        │  │
  │  │  - Relationship history                                │  │
  │  │  - Decisions and outcomes                              │  │
  │  └────────────────────────────────────────────────────────┘  │
  └──────────────────────────────────────────────────────────────┘
  ```

  ## Dual-Agent Support

  - **Native agents:** Hold in process state, auto-persisted on shutdown
  - **Bridged agents:** Serialized to/from JSON for gateway transport
  """

  alias Arbor.Common.SafeAtom
  alias Arbor.Memory.Signals
  alias Arbor.Memory.TokenBudget

  require Logger

  @version 4
  @max_item_id_bytes 128
  @generated_id_bytes 16
  @max_deserialized_items 256
  @legacy_epoch ~U[1970-01-01 00:00:00Z]

  @type thought :: %{
          id: String.t(),
          content: String.t(),
          timestamp: DateTime.t(),
          cached_tokens: non_neg_integer(),
          referenced_date: DateTime.t() | nil
        }

  @type goal :: %{
          id: String.t(),
          description: String.t(),
          type: atom(),
          priority: atom(),
          progress: number(),
          added_at: DateTime.t()
        }

  @type active_skill :: %{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          body: String.t(),
          activated_at: DateTime.t()
        }

  @type t :: %__MODULE__{
          agent_id: String.t(),
          name: String.t() | nil,
          current_human: String.t() | nil,
          current_conversation: map() | nil,
          recent_thoughts: [thought()],
          active_goals: [goal()],
          active_skills: [active_skill()],
          relationship_context: String.t() | map() | nil,
          concerns: [String.t()],
          concern_ids: [String.t()],
          curiosity: [String.t()],
          curiosity_ids: [String.t()],
          engagement_level: float(),
          max_tokens: TokenBudget.spec() | nil,
          model: String.t() | nil,
          last_consolidated_at: DateTime.t() | nil,
          started_at: DateTime.t() | nil,
          thought_count: non_neg_integer(),
          version: pos_integer()
        }

  defstruct [
    :agent_id,
    :name,
    :current_human,
    :current_conversation,
    recent_thoughts: [],
    active_goals: [],
    active_skills: [],
    relationship_context: nil,
    concerns: [],
    concern_ids: [],
    curiosity: [],
    curiosity_ids: [],
    engagement_level: 0.5,
    max_tokens: nil,
    model: nil,
    last_consolidated_at: nil,
    started_at: nil,
    thought_count: 0,
    version: @version
  ]

  @default_max_thoughts 20
  @default_max_goals 10
  @default_max_concerns 5
  @default_max_curiosity 10

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create a new working memory for an agent.

  ## Options

  - `:name` - Agent name (default: nil)
  - `:max_tokens` - Token budget for thought trimming (default: nil, uses count)
  - `:model` - Model ID for context size lookup (default: nil)
  - `:engagement_level` - Initial engagement level (default: 0.5)
  - `:rebuild_from_signals` - Whether to rebuild from long-term memory (default: false)

  ## Examples

      wm = WorkingMemory.new("agent_001")
      wm = WorkingMemory.new("agent_001", name: "Atlas", max_tokens: 5000)
  """
  @spec new(String.t(), keyword()) :: t()
  def new(agent_id, opts \\ []) do
    base = %__MODULE__{
      agent_id: agent_id,
      name: Keyword.get(opts, :name),
      engagement_level: Keyword.get(opts, :engagement_level, 0.5),
      max_tokens: Keyword.get(opts, :max_tokens),
      model: Keyword.get(opts, :model),
      started_at: DateTime.utc_now(),
      thought_count: 0
    }

    if Keyword.get(opts, :rebuild_from_signals, true) do
      case rebuild_from_long_term(base) do
        {:ok, rebuilt} -> rebuilt
        {:error, _reason} -> base
      end
    else
      base
    end
  end

  # ============================================================================
  # Thought Management
  # ============================================================================

  @doc """
  Add a thought to working memory.

  Accepts either a plain string or a structured map. Strings are automatically
  wrapped with timestamp and token count metadata.

  Thoughts are prepended (newest first) and bounded by `max_thoughts` (count-based)
  or `max_tokens` (token-based).

  ## Examples

      wm = WorkingMemory.add_thought(wm, "User seems curious about Elixir")

      wm = WorkingMemory.add_thought(wm, %{
        content: "Important insight",
        timestamp: DateTime.utc_now(),
        cached_tokens: 10
      })
  """
  @spec add_thought(t(), String.t() | map(), keyword()) :: t()
  def add_thought(wm, thought, opts \\ []) do
    thought_record = normalize_thought(thought)
    new_thoughts = trim_thoughts([thought_record | wm.recent_thoughts], wm, opts)

    %{wm | recent_thoughts: new_thoughts, thought_count: wm.thought_count + 1}
  end

  @doc """
  Clear all recent thoughts.
  """
  @spec clear_thoughts(t()) :: t()
  def clear_thoughts(wm) do
    %{wm | recent_thoughts: []}
  end

  @doc """
  Get total token count of recent thoughts.
  """
  @spec thought_tokens(t()) :: non_neg_integer()
  def thought_tokens(%__MODULE__{recent_thoughts: thoughts}) do
    Enum.reduce(thoughts, 0, fn thought, acc ->
      acc + (thought[:cached_tokens] || TokenBudget.estimate_tokens(thought_content(thought)))
    end)
  end

  # ============================================================================
  # Goal Management
  # ============================================================================

  @doc """
  Set active goals, replacing any existing goals.

  Accepts plain strings or structured goal maps. Strings are automatically
  wrapped with id, type, priority, and progress metadata.
  """
  @spec set_goals(t(), [String.t() | map()], keyword()) :: t()
  def set_goals(wm, goals, opts \\ []) do
    max = Keyword.get(opts, :max_goals, @default_max_goals)
    normalized = Enum.map(goals, &normalize_goal/1)
    %{wm | active_goals: Enum.take(normalized, max)}
  end

  @doc """
  Add a goal to the active goals list.

  Accepts a plain string or a structured goal map. If a goal with the same `id`
  already exists, it is replaced.

  ## Examples

      wm = WorkingMemory.add_goal(wm, "Explain GenServer basics")

      wm = WorkingMemory.add_goal(wm, %{
        id: "goal_001",
        description: "Explain GenServer basics",
        type: :task,
        priority: :high,
        progress: 0
      })
  """
  @spec add_goal(t(), String.t() | map() | nil, keyword()) :: t()
  def add_goal(wm, goal, opts \\ [])
  def add_goal(wm, nil, _opts), do: wm

  def add_goal(wm, goal, opts) do
    max = Keyword.get(opts, :max_goals, @default_max_goals)
    goal_record = normalize_goal(goal)

    # Replace existing goal with same id, or add new
    new_goals =
      case Enum.find_index(wm.active_goals, &(&1.id == goal_record.id)) do
        nil -> [goal_record | wm.active_goals]
        idx -> List.replace_at(wm.active_goals, idx, goal_record)
      end
      |> Enum.take(max)

    %{wm | active_goals: new_goals}
  end

  @doc """
  Mark a goal as completed and remove it from active goals.
  Also records the completion as a thought for audit trail.
  """
  @spec complete_goal(t(), String.t()) :: t()
  def complete_goal(wm, goal_or_id) do
    goal =
      Enum.find(wm.active_goals, fn g ->
        g.id == goal_or_id or g.description == goal_or_id
      end)

    wm = %{
      wm
      | active_goals:
          Enum.reject(wm.active_goals, fn g ->
            g.id == goal_or_id or g.description == goal_or_id
          end)
    }

    if goal do
      add_thought(wm, "Completed goal: #{goal.description}")
    else
      wm
    end
  end

  @doc """
  Mark a goal as abandoned and remove it from active goals.
  Records the abandonment as a thought for audit trail.
  """
  @spec abandon_goal(t(), String.t()) :: t()
  def abandon_goal(wm, goal_id) do
    goal = Enum.find(wm.active_goals, &(&1.id == goal_id))
    wm = remove_goal(wm, goal_id)

    if goal do
      add_thought(wm, "Abandoned goal: #{goal.description}")
    else
      wm
    end
  end

  @doc """
  Remove a goal by id.
  """
  @spec remove_goal(t(), String.t()) :: t()
  def remove_goal(wm, goal_id) do
    %{wm | active_goals: Enum.reject(wm.active_goals, &(&1.id == goal_id))}
  end

  @doc """
  Update progress on a goal (0-100).
  """
  @spec update_goal_progress(t(), String.t(), number()) :: t()
  def update_goal_progress(wm, goal_id, progress) when is_number(progress) do
    progress = max(0, min(100, progress))

    new_goals =
      Enum.map(wm.active_goals, fn goal ->
        if goal.id == goal_id do
          %{goal | progress: progress}
        else
          goal
        end
      end)

    %{wm | active_goals: new_goals}
  end

  # ============================================================================
  # Active Skill Management
  # ============================================================================

  @default_max_active_skills 5

  @doc """
  Activate a skill in working memory.

  The skill's name, description, and body are stored in `active_skills`.
  Returns `{:error, :max_skills_reached}` if the limit is exceeded.
  Returns `{:error, :already_active}` if the skill is already active.

  ## Options

  - `:max_active_skills` — maximum active skills (default: #{@default_max_active_skills})
  """
  @spec activate_skill(t(), map() | struct(), keyword()) :: {:ok, t()} | {:error, atom()}
  def activate_skill(wm, skill, opts \\ []) do
    max = Keyword.get(opts, :max_active_skills, @default_max_active_skills)
    name = Map.get(skill, :name)

    cond do
      has_skill?(wm, name) ->
        {:error, :already_active}

      length(wm.active_skills) >= max ->
        {:error, :max_skills_reached}

      true ->
        entry = %{
          id: generate_item_id("skill"),
          name: name,
          description: Map.get(skill, :description, ""),
          body: Map.get(skill, :body, ""),
          activated_at: DateTime.utc_now()
        }

        {:ok, %{wm | active_skills: [entry | wm.active_skills]}}
    end
  end

  @doc """
  Deactivate a skill by name.
  """
  @spec deactivate_skill(t(), String.t()) :: t()
  def deactivate_skill(wm, skill_name) when is_binary(skill_name) do
    %{wm | active_skills: Enum.reject(wm.active_skills, &(&1.name == skill_name))}
  end

  @doc """
  List currently active skills.
  """
  @spec list_active_skills(t()) :: [active_skill()]
  def list_active_skills(%__MODULE__{active_skills: skills}), do: skills

  @doc """
  Check if a skill is currently active.
  """
  @spec has_skill?(t(), String.t()) :: boolean()
  def has_skill?(%__MODULE__{active_skills: skills}, name) when is_binary(name) do
    Enum.any?(skills, &(&1.name == name))
  end

  def has_skill?(_, _), do: false

  # ============================================================================
  # Identity and Relationship
  # ============================================================================

  @doc """
  Set the agent's name.
  """
  @spec set_name(t(), String.t() | nil) :: t()
  def set_name(wm, name) do
    %{wm | name: name}
  end

  @doc """
  Set the current human the agent is interacting with.
  """
  @spec set_current_human(t(), String.t() | nil) :: t()
  def set_current_human(wm, human_name) do
    %{wm | current_human: human_name}
  end

  @doc """
  Set the relationship context (summary of current relationship).
  """
  @spec set_relationship_context(t(), String.t() | map() | nil) :: t()
  def set_relationship_context(wm, context) do
    %{wm | relationship_context: context}
  end

  @doc """
  Set both current human and relationship context in one call.
  """
  @spec set_relationship(t(), String.t(), String.t() | map() | nil) :: t()
  def set_relationship(wm, human_name, context) do
    %{wm | current_human: human_name, relationship_context: context}
  end

  @doc """
  Set the current conversation context.
  """
  @spec set_conversation(t(), map() | nil) :: t()
  def set_conversation(wm, conversation) do
    %{wm | current_conversation: conversation}
  end

  # ============================================================================
  # Concerns and Curiosity
  # ============================================================================

  @doc """
  Add a concern to the concerns list.
  """
  @spec add_concern(t(), String.t(), keyword()) :: t()
  def add_concern(wm, concern, opts \\ []) do
    wm = migrate(wm)
    max = Keyword.get(opts, :max_concerns, @default_max_concerns)

    existing_id =
      wm
      |> scalar_pairs(:concerns)
      |> Enum.find_value(fn {value, id} -> if value == concern, do: id end)

    pairs =
      [{concern, existing_id || generate_item_id("concern")} | scalar_pairs(wm, :concerns)]
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.take(max)

    put_scalar_pairs(wm, :concerns, pairs)
  end

  @doc """
  Remove a resolved concern.
  """
  @spec resolve_concern(t(), String.t()) :: t()
  def resolve_concern(wm, concern) do
    wm = migrate(wm)
    pairs = Enum.reject(scalar_pairs(wm, :concerns), &(elem(&1, 0) == concern))
    put_scalar_pairs(wm, :concerns, pairs)
  end

  @doc """
  Add something the agent is curious about.
  """
  @spec add_curiosity(t(), String.t(), keyword()) :: t()
  def add_curiosity(wm, item, opts \\ []) do
    wm = migrate(wm)
    max = Keyword.get(opts, :max_curiosity, @default_max_curiosity)

    existing_id =
      wm
      |> scalar_pairs(:curiosity)
      |> Enum.find_value(fn {value, id} -> if value == item, do: id end)

    pairs =
      [{item, existing_id || generate_item_id("curiosity")} | scalar_pairs(wm, :curiosity)]
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.take(max)

    put_scalar_pairs(wm, :curiosity, pairs)
  end

  @doc """
  Remove a satisfied curiosity item.
  """
  @spec satisfy_curiosity(t(), String.t()) :: t()
  def satisfy_curiosity(wm, item) do
    wm = migrate(wm)
    pairs = Enum.reject(scalar_pairs(wm, :curiosity), &(elem(&1, 0) == item))
    put_scalar_pairs(wm, :curiosity, pairs)
  end

  # ============================================================================
  # Engagement Level
  # ============================================================================

  @doc """
  Set the engagement level (0.0 - 1.0).
  """
  @spec set_engagement_level(t(), float()) :: t()
  def set_engagement_level(wm, level) when is_number(level) do
    clamped = level |> max(0.0) |> min(1.0)
    %{wm | engagement_level: clamped}
  end

  @doc """
  Adjust engagement level by a delta (positive or negative).
  """
  @spec adjust_engagement(t(), float()) :: t()
  def adjust_engagement(wm, delta) when is_number(delta) do
    new_level = (wm.engagement_level + delta) |> max(0.0) |> min(1.0)
    %{wm | engagement_level: new_level}
  end

  # ============================================================================
  # Consolidation and Lifecycle
  # ============================================================================

  @doc """
  Mark consolidation timestamp.
  """
  @spec mark_consolidated(t()) :: t()
  def mark_consolidated(wm) do
    %{wm | last_consolidated_at: DateTime.utc_now()}
  end

  @doc """
  Get uptime in seconds since working memory was created.
  """
  @spec uptime(t()) :: non_neg_integer()
  def uptime(%__MODULE__{started_at: nil}), do: 0

  def uptime(%__MODULE__{started_at: started_at}) do
    DateTime.diff(DateTime.utc_now(), started_at, :second)
  end

  @doc """
  Rebuild working memory from long-term Signals events.

  Queries recent memory events and replays them to reconstruct state.
  """
  @spec rebuild_from_long_term(t()) :: {:ok, t()} | {:error, term()}
  def rebuild_from_long_term(%__MODULE__{} = wm) do
    case Signals.query_recent(wm.agent_id, limit: 100) do
      {:ok, signals} ->
        rebuilt = Enum.reduce(signals, wm, &apply_memory_event/2)
        Logger.info("Rebuilt working memory for #{wm.agent_id} from #{length(signals)} signals")
        {:ok, rebuilt}

      {:error, _} = error ->
        error
    end
  end

  # ============================================================================
  # Rendering for LLM Context
  # ============================================================================

  @doc """
  Render working memory as text suitable for LLM system prompt injection.

  ## Options

  - `:include_identity` - Include identity section (default: true)
  - `:include_thoughts` - Include recent thoughts (default: true)
  - `:include_goals` - Include active goals (default: true)
  - `:include_relationship` - Include relationship context (default: true)
  - `:include_concerns` - Include concerns (default: true)
  - `:include_curiosity` - Include curiosity (default: true)
  - `:max_thoughts` - Limit thoughts to this count (default: 5)
  """
  @spec to_prompt_text(t(), keyword()) :: String.t()
  def to_prompt_text(wm, opts \\ []) do
    max_thoughts = Keyword.get(opts, :max_thoughts, 5)

    []
    |> maybe_add_identity(opts, wm)
    |> maybe_add_section(
      opts,
      :include_relationship,
      wm.relationship_context,
      &format_relationship/1
    )
    |> maybe_add_section(opts, :include_goals, wm.active_goals, &format_goals/1)
    |> maybe_add_thoughts(opts, wm.recent_thoughts, max_thoughts)
    |> maybe_add_section(opts, :include_concerns, wm.concerns, &format_concerns/1)
    |> maybe_add_section(opts, :include_curiosity, wm.curiosity, &format_curiosity/1)
    |> Enum.reverse()
    |> Enum.join("\n\n")
  end

  @doc """
  Return working memory as a structured map for prompt context.
  """
  @spec to_prompt_context(t(), keyword()) :: map()
  def to_prompt_context(wm, opts \\ []) do
    max_thoughts = Keyword.get(opts, :max_thoughts, 5)

    %{
      agent_id: wm.agent_id,
      name: wm.name,
      current_human: wm.current_human,
      recent_thoughts:
        wm.recent_thoughts |> Enum.take(max_thoughts) |> Enum.map(&thought_content/1),
      active_goals: Enum.map(wm.active_goals, &goal_description/1),
      relationship_context: wm.relationship_context,
      concerns: wm.concerns,
      curiosity: wm.curiosity,
      engagement_level: wm.engagement_level
    }
  end

  # ============================================================================
  # Serialization (for persistence and gateway transport)
  # ============================================================================

  @doc """
  Serialize working memory to a JSON-safe map.
  """
  @spec serialize(t()) :: map()
  def serialize(%__MODULE__{} = wm) do
    wm = migrate(wm)

    %{
      "agent_id" => wm.agent_id,
      "name" => wm.name,
      "current_human" => wm.current_human,
      "current_conversation" => wm.current_conversation,
      "recent_thoughts" => Enum.map(wm.recent_thoughts, &serialize_thought/1),
      "active_goals" => Enum.map(wm.active_goals, &serialize_goal/1),
      "active_skills" => Enum.map(wm.active_skills, &serialize_active_skill/1),
      "relationship_context" => wm.relationship_context,
      "concerns" => wm.concerns,
      "concern_ids" => wm.concern_ids,
      "curiosity" => wm.curiosity,
      "curiosity_ids" => wm.curiosity_ids,
      "engagement_level" => wm.engagement_level,
      "max_tokens" => serialize_token_spec(wm.max_tokens),
      "model" => wm.model,
      "last_consolidated_at" => serialize_datetime(wm.last_consolidated_at),
      "started_at" => serialize_datetime(wm.started_at),
      "thought_count" => wm.thought_count,
      "version" => wm.version
    }
  end

  @doc """
  Deserialize a JSON-safe map back to a WorkingMemory struct.

  Handles legacy plain strings and structured maps. Missing item identities are
  generated deterministically from the owning working-memory boundary so
  repeated legacy reads do not churn IDs.
  """
  @spec deserialize(map()) :: t()
  def deserialize(data) when is_map(data) do
    agent_id = get_field(data, :agent_id)
    started_at = parse_datetime(get_field(data, :started_at))
    item_fallback_datetime = started_at || @legacy_epoch
    owner_seed = legacy_owner_seed(agent_id, item_fallback_datetime)
    concerns = proper_list(get_field(data, :concerns, []))
    curiosity = proper_list(get_field(data, :curiosity, []))

    %__MODULE__{
      agent_id: agent_id,
      name: get_field(data, :name),
      current_human: get_field(data, :current_human),
      current_conversation: get_field(data, :current_conversation),
      recent_thoughts:
        deserialize_collection(
          get_field(data, :recent_thoughts, []),
          :thought,
          owner_seed,
          item_fallback_datetime
        ),
      active_goals:
        deserialize_collection(
          get_field(data, :active_goals, []),
          :goal,
          owner_seed,
          item_fallback_datetime
        ),
      active_skills:
        deserialize_collection(
          get_field(data, :active_skills, []),
          :skill,
          owner_seed,
          item_fallback_datetime
        ),
      relationship_context: get_field(data, :relationship_context),
      concerns: concerns,
      concern_ids:
        stable_scalar_ids(
          concerns,
          get_field(data, :concern_ids, []),
          :concern,
          owner_seed
        ),
      curiosity: curiosity,
      curiosity_ids:
        stable_scalar_ids(
          curiosity,
          get_field(data, :curiosity_ids, []),
          :curiosity,
          owner_seed
        ),
      engagement_level: numeric_or_default(get_field(data, :engagement_level), 0.5),
      max_tokens: deserialize_token_spec(get_field(data, :max_tokens)),
      model: get_field(data, :model),
      last_consolidated_at: parse_datetime(get_field(data, :last_consolidated_at)),
      started_at: started_at,
      thought_count: non_negative_integer_or_default(get_field(data, :thought_count), 0),
      version: @version
    }
  end

  def deserialize(_data), do: empty_legacy_memory()

  # ============================================================================
  # Migration
  # ============================================================================

  @doc """
  Migrate state to current version.

  Called on every GenServer callback to ensure state is current after hot reloads.
  Handles version upgrades, nil-versioned state, and plain maps.
  """
  @spec migrate(t() | map()) :: t()
  def migrate(%__MODULE__{} = wm) do
    wm
    |> ensure_defaults()
    |> ensure_stable_item_ids()
    |> Map.put(:version, @version)
  end

  def migrate(%{} = old) when not is_struct(old) do
    deserialize(old)
  end

  def migrate(_old), do: empty_legacy_memory()

  defp ensure_defaults(%__MODULE__{} = wm) do
    %{
      wm
      | recent_thoughts: wm.recent_thoughts || [],
        active_goals: wm.active_goals || [],
        active_skills: wm.active_skills || [],
        curiosity: proper_list(wm.curiosity || []),
        curiosity_ids: proper_list(wm.curiosity_ids || []),
        concerns: proper_list(wm.concerns || []),
        concern_ids: proper_list(wm.concern_ids || []),
        engagement_level: wm.engagement_level || 0.5,
        started_at: wm.started_at,
        thought_count: wm.thought_count || 0
    }
  end

  defp ensure_stable_item_ids(%__MODULE__{} = wm) do
    item_fallback_datetime = wm.started_at || @legacy_epoch
    owner_seed = legacy_owner_seed(wm.agent_id, item_fallback_datetime)

    %{
      wm
      | recent_thoughts:
          deserialize_collection(
            wm.recent_thoughts,
            :thought,
            owner_seed,
            item_fallback_datetime
          ),
        active_goals:
          deserialize_collection(wm.active_goals, :goal, owner_seed, item_fallback_datetime),
        active_skills:
          deserialize_collection(wm.active_skills, :skill, owner_seed, item_fallback_datetime),
        concern_ids: stable_scalar_ids(wm.concerns, wm.concern_ids, :concern, owner_seed),
        curiosity_ids: stable_scalar_ids(wm.curiosity, wm.curiosity_ids, :curiosity, owner_seed)
    }
  end

  # ============================================================================
  # Token Budget Management
  # ============================================================================

  @doc """
  Trim working memory to fit within a token budget.

  Trims from the back of lists (oldest thoughts first, etc.).
  Uses TokenBudget for estimation.

  ## Options

  - `:model_id` - Model ID for context size lookup
  - `:budget` - Budget specification (default: {:percentage, 0.05})
  """
  @spec trim_to_budget(t(), keyword()) :: t()
  def trim_to_budget(wm, opts \\ []) do
    model_id = Keyword.get(opts, :model_id, "anthropic:claude-3-5-sonnet-20241022")
    budget = Keyword.get(opts, :budget, {:percentage, 0.05})

    max_tokens = TokenBudget.resolve_for_model(budget, model_id)
    current_tokens = TokenBudget.estimate_tokens(to_prompt_text(wm))

    if current_tokens <= max_tokens do
      wm
    else
      wm
      |> trim_list(:recent_thoughts, max_tokens)
      |> trim_list(:concerns, max_tokens)
      |> trim_list(:curiosity, max_tokens)
      |> trim_list(:active_goals, max_tokens)
    end
  end

  # ============================================================================
  # Temporal Retrieval
  # ============================================================================

  @doc """
  Filter thoughts where the effective date falls within `[start_date, end_date]`.

  The effective date is `referenced_date` when set, otherwise `timestamp`.
  Returns newest-first. Accepts both `Date` and `DateTime` for boundaries.
  """
  @spec thoughts_for_period(t(), Date.t() | DateTime.t(), Date.t() | DateTime.t()) :: [thought()]
  def thoughts_for_period(%__MODULE__{recent_thoughts: thoughts}, start_date, end_date) do
    start_d = to_date(start_date)
    end_d = to_date(end_date)

    thoughts
    |> Enum.filter(fn thought ->
      case thought_effective_date(thought) do
        nil ->
          false

        date ->
          Date.compare(date, start_d) in [:eq, :gt] and Date.compare(date, end_d) in [:eq, :lt]
      end
    end)
    |> Enum.sort_by(&thought_effective_date/1, {:desc, Date})
  end

  @doc """
  Return only today's thoughts (by effective date).
  """
  @spec thoughts_today(t()) :: [thought()]
  def thoughts_today(%__MODULE__{} = wm) do
    today = Date.utc_today()
    thoughts_for_period(wm, today, today)
  end

  @doc """
  Return thoughts since a relative time ago.

  ## Options

  - `:hours_ago` — thoughts from the last N hours
  - `:days_ago` — thoughts from the last N days
  """
  @spec thoughts_since(t(), keyword()) :: [thought()]
  def thoughts_since(%__MODULE__{recent_thoughts: thoughts}, opts) do
    cutoff = compute_cutoff(opts)

    thoughts
    |> Enum.filter(fn thought ->
      case thought_effective_datetime(thought) do
        nil -> false
        dt -> DateTime.compare(dt, cutoff) in [:eq, :gt]
      end
    end)
    |> Enum.sort_by(&thought_effective_datetime/1, {:desc, DateTime})
  end

  defp thought_effective_date(thought) do
    case Map.get(thought, :referenced_date) do
      nil -> datetime_to_date(Map.get(thought, :timestamp))
      %Date{} = d -> d
      %DateTime{} = dt -> DateTime.to_date(dt)
      _ -> datetime_to_date(Map.get(thought, :timestamp))
    end
  end

  defp thought_effective_datetime(thought) do
    case Map.get(thought, :referenced_date) do
      %DateTime{} = dt -> dt
      _ -> Map.get(thought, :timestamp)
    end
  end

  defp datetime_to_date(nil), do: nil
  defp datetime_to_date(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp datetime_to_date(%Date{} = d), do: d
  defp datetime_to_date(_), do: nil

  defp to_date(%Date{} = d), do: d
  defp to_date(%DateTime{} = dt), do: DateTime.to_date(dt)

  defp compute_cutoff(opts) do
    cond do
      hours = Keyword.get(opts, :hours_ago) ->
        DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

      days = Keyword.get(opts, :days_ago) ->
        DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

      true ->
        DateTime.utc_now()
    end
  end

  # ============================================================================
  # Statistics
  # ============================================================================

  @doc """
  Get statistics about this working memory instance.
  """
  @spec stats(t()) :: map()
  def stats(wm) do
    text = to_prompt_text(wm)

    %{
      agent_id: wm.agent_id,
      name: wm.name,
      current_human: wm.current_human,
      thought_count: wm.thought_count,
      recent_thought_count: length(wm.recent_thoughts),
      thought_tokens: thought_tokens(wm),
      goal_count: length(wm.active_goals),
      concern_count: length(wm.concerns),
      curiosity_count: length(wm.curiosity),
      engagement_level: wm.engagement_level,
      has_relationship_context: wm.relationship_context != nil,
      estimated_tokens: TokenBudget.estimate_tokens(text),
      max_tokens: wm.max_tokens,
      model: wm.model,
      uptime_seconds: uptime(wm),
      last_consolidated: wm.last_consolidated_at,
      version: wm.version
    }
  end

  # ============================================================================
  # Private Helpers — Normalization
  # ============================================================================

  defp normalize_thought(thought) when is_binary(thought) do
    %{
      id: generate_item_id("thought"),
      content: thought,
      timestamp: DateTime.utc_now(),
      cached_tokens: TokenBudget.estimate_tokens(thought),
      referenced_date: nil
    }
  end

  defp normalize_thought(%{content: _} = thought) do
    Map.merge(
      %{
        id: generate_item_id("thought"),
        timestamp: DateTime.utc_now(),
        cached_tokens: TokenBudget.estimate_tokens(thought[:content] || ""),
        referenced_date: nil
      },
      thought
    )
    |> ensure_runtime_item_id("thought")
  end

  defp normalize_thought(%{"content" => content} = thought) do
    %{
      id: valid_id_or_new(thought["id"], "thought"),
      content: content,
      timestamp: parse_datetime(thought["timestamp"]) || DateTime.utc_now(),
      cached_tokens: thought["cached_tokens"] || TokenBudget.estimate_tokens(content),
      referenced_date: parse_datetime(thought["referenced_date"])
    }
  end

  # Documented temporal-note shape emitted by the heartbeat prompt:
  # {"text": "...", "referenced_date": "YYYY-MM-DD"}. Treat "text" as the content.
  defp normalize_thought(%{"text" => text} = thought) do
    %{
      id: valid_id_or_new(thought["id"], "thought"),
      content: text,
      timestamp: parse_datetime(thought["timestamp"]) || DateTime.utc_now(),
      cached_tokens: thought["cached_tokens"] || TokenBudget.estimate_tokens(text),
      referenced_date: parse_datetime(thought["referenced_date"])
    }
  end

  defp normalize_thought(%{text: text} = thought) do
    %{
      id: valid_id_or_new(thought[:id], "thought"),
      content: text,
      timestamp: parse_datetime(thought[:timestamp]) || DateTime.utc_now(),
      cached_tokens: thought[:cached_tokens] || TokenBudget.estimate_tokens(text),
      referenced_date: parse_datetime(thought[:referenced_date])
    }
  end

  defp normalize_goal(nil), do: nil

  defp normalize_goal(goal) when is_binary(goal) do
    %{
      id: generate_item_id("goal"),
      description: goal,
      type: :general,
      priority: :normal,
      progress: 0,
      added_at: DateTime.utc_now()
    }
  end

  defp normalize_goal(%{description: _} = goal) do
    Map.merge(
      %{
        id: generate_item_id("goal"),
        type: :general,
        priority: :normal,
        progress: 0,
        added_at: DateTime.utc_now()
      },
      goal
    )
    |> ensure_runtime_item_id("goal")
  end

  defp normalize_goal(%{"description" => desc} = goal) do
    %{
      id: valid_id_or_new(goal["id"], "goal"),
      description: desc,
      type: atomize(goal["type"]) || :general,
      priority: atomize(goal["priority"]) || :normal,
      progress: goal["progress"] || 0,
      added_at: parse_datetime(goal["added_at"]) || DateTime.utc_now()
    }
  end

  defp thought_content(%{content: content}), do: content
  defp thought_content(content) when is_binary(content), do: content

  defp goal_description(%{description: desc}), do: desc
  defp goal_description(desc) when is_binary(desc), do: desc

  # ============================================================================
  # Private Helpers — Thought Trimming
  # ============================================================================

  defp trim_thoughts(thoughts, %__MODULE__{max_tokens: nil}, opts) do
    max = Keyword.get(opts, :max_thoughts, @default_max_thoughts)
    Enum.take(thoughts, max)
  end

  defp trim_thoughts(thoughts, %__MODULE__{max_tokens: budget_spec, model: model}, _opts) do
    budget =
      cond do
        is_integer(budget_spec) -> budget_spec
        model -> TokenBudget.resolve_for_model(budget_spec, model)
        true -> TokenBudget.resolve(budget_spec, TokenBudget.default_context_size())
      end

    {kept, _tokens} =
      Enum.reduce_while(thoughts, {[], 0}, fn thought, {acc, total} ->
        tokens = thought[:cached_tokens] || TokenBudget.estimate_tokens(thought_content(thought))
        new_total = total + tokens

        if new_total <= budget do
          {:cont, {[thought | acc], new_total}}
        else
          {:halt, {acc, total}}
        end
      end)

    Enum.reverse(kept)
  end

  # ============================================================================
  # Private Helpers — Rendering
  # ============================================================================

  defp maybe_add_identity(sections, opts, wm) do
    if Keyword.get(opts, :include_identity, true) do
      identity =
        if wm.name do
          "## Identity\n\nName: #{wm.name}\nAgent ID: #{wm.agent_id}"
        else
          "## Identity\n\nAgent ID: #{wm.agent_id}"
        end

      [identity | sections]
    else
      sections
    end
  end

  defp maybe_add_section(sections, opts, key, nil, _formatter) do
    _ = Keyword.get(opts, key, true)
    sections
  end

  defp maybe_add_section(sections, opts, key, data, formatter) do
    enabled = Keyword.get(opts, key, true)
    has_data = (is_list(data) and data != []) or (not is_list(data) and data != nil)

    if enabled and has_data do
      [formatter.(data) | sections]
    else
      sections
    end
  end

  defp maybe_add_thoughts(sections, opts, thoughts, max_thoughts) do
    if Keyword.get(opts, :include_thoughts, true) and thoughts != [] do
      taken = Enum.take(thoughts, max_thoughts)
      temporal = Keyword.get(opts, :temporal_grouping, true)
      [format_thoughts(taken, temporal: temporal) | sections]
    else
      sections
    end
  end

  defp format_relationship(context) when is_binary(context) do
    "## Relationship Context\n\n#{context}" |> String.trim()
  end

  defp format_relationship(context) when is_map(context) do
    lines = Enum.map_join(context, "\n", fn {k, v} -> "- #{k}: #{inspect(v)}" end)
    "## Relationship Context\n\n#{lines}" |> String.trim()
  end

  defp format_goals(goals) do
    goal_list = Enum.map_join(goals, "\n", fn g -> "- #{goal_description(g)}" end)
    "## Active Goals\n\n#{goal_list}" |> String.trim()
  end

  defp format_thoughts(thoughts, opts) do
    temporal = Keyword.get(opts, :temporal, true)

    if temporal do
      format_thoughts_temporal(thoughts)
    else
      format_thoughts_flat(thoughts)
    end
  end

  defp format_thoughts_flat(thoughts) do
    thought_list = Enum.map_join(thoughts, "\n", fn t -> "- #{thought_content(t)}" end)
    "## Recent Thoughts\n\n#{thought_list}" |> String.trim()
  end

  defp format_thoughts_temporal(thoughts) do
    alias Arbor.Common.TemporalGrouping

    extract_fn = fn thought ->
      obs_dt = Map.get(thought, :timestamp)
      ref_dt = Map.get(thought, :referenced_date)
      {obs_dt, ref_dt}
    end

    format_fn = fn thought, annotation ->
      content = thought_content(thought)

      if annotation == "" do
        "- #{content}"
      else
        "- #{annotation} #{content}"
      end
    end

    grouped = TemporalGrouping.group_by_time(thoughts, extract_fn)

    if grouped == [] do
      format_thoughts_flat(thoughts)
    else
      body = TemporalGrouping.format_grouped(grouped, extract_fn, format_fn)
      "## Recent Thoughts\n\n#{body}" |> String.trim()
    end
  end

  defp format_concerns(concerns) do
    concern_list = Enum.map_join(concerns, "\n", &"- #{&1}")
    "## Current Concerns\n\n#{concern_list}" |> String.trim()
  end

  defp format_curiosity(items) do
    curiosity_list = Enum.map_join(items, "\n", &"- #{&1}")
    "## Things I'm Curious About\n\n#{curiosity_list}" |> String.trim()
  end

  defp trim_list(wm, field, max_tokens) do
    list = Map.get(wm, field)

    if length(list) <= 1 do
      wm
    else
      trimmed = Enum.take(list, length(list) - 1)
      new_wm = put_trimmed_list(wm, field, trimmed)
      current_tokens = TokenBudget.estimate_tokens(to_prompt_text(new_wm))

      if current_tokens <= max_tokens do
        new_wm
      else
        trim_list(new_wm, field, max_tokens)
      end
    end
  end

  # ============================================================================
  # Private Helpers — Serialization
  # ============================================================================

  defp serialize_thought(
         %{
           id: id,
           content: content,
           timestamp: ts,
           cached_tokens: tokens
         } = thought
       ) do
    base = %{
      "id" => id,
      "content" => content,
      "timestamp" => serialize_datetime(ts),
      "cached_tokens" => tokens
    }

    case Map.get(thought, :referenced_date) do
      nil -> base
      rd -> Map.put(base, "referenced_date", serialize_datetime(rd))
    end
  end

  defp serialize_goal(%{
         id: id,
         description: desc,
         type: type,
         priority: priority,
         progress: progress,
         added_at: added_at
       }) do
    %{
      "id" => id,
      "description" => desc,
      "type" => to_string(type),
      "priority" => to_string(priority),
      "progress" => progress,
      "added_at" => serialize_datetime(added_at)
    }
  end

  defp serialize_active_skill(%{
         id: id,
         name: name,
         description: desc,
         body: body,
         activated_at: at
       }) do
    %{
      "id" => id,
      "name" => name,
      "description" => desc,
      "body" => body,
      "activated_at" => serialize_datetime(at)
    }
  end

  defp deserialize_item(:thought, str, fallback_id, fallback_datetime) when is_binary(str) do
    %{
      id: fallback_id,
      content: str,
      timestamp: fallback_datetime,
      cached_tokens: TokenBudget.estimate_tokens(str),
      referenced_date: nil
    }
  end

  defp deserialize_item(:thought, %{"content" => content} = data, fallback_id, fallback_datetime)
       when is_binary(content) do
    %{
      id: valid_id_or_fallback(data["id"], fallback_id),
      content: content,
      timestamp: parse_datetime(data["timestamp"]) || fallback_datetime,
      cached_tokens: data["cached_tokens"] || TokenBudget.estimate_tokens(content),
      referenced_date: parse_datetime(data["referenced_date"])
    }
  end

  defp deserialize_item(:thought, %{content: content} = data, fallback_id, fallback_datetime)
       when is_binary(content) do
    %{
      id: valid_id_or_fallback(data[:id], fallback_id),
      content: content,
      timestamp: parse_datetime(data[:timestamp]) || fallback_datetime,
      cached_tokens: data[:cached_tokens] || TokenBudget.estimate_tokens(content),
      referenced_date: parse_datetime(data[:referenced_date])
    }
  end

  defp deserialize_item(:goal, str, fallback_id, fallback_datetime) when is_binary(str) do
    %{
      id: fallback_id,
      description: str,
      type: :general,
      priority: :normal,
      progress: 0,
      added_at: fallback_datetime
    }
  end

  defp deserialize_item(:goal, %{"description" => desc} = data, fallback_id, fallback_datetime)
       when is_binary(desc) do
    %{
      id: valid_id_or_fallback(data["id"], fallback_id),
      description: desc,
      type: atomize(data["type"]) || :general,
      priority: atomize(data["priority"]) || :normal,
      progress: data["progress"] || 0,
      added_at: parse_datetime(data["added_at"]) || fallback_datetime
    }
  end

  defp deserialize_item(:goal, %{description: desc} = data, fallback_id, fallback_datetime)
       when is_binary(desc) do
    %{
      id: valid_id_or_fallback(data[:id], fallback_id),
      description: desc,
      type: atomize(data[:type]) || :general,
      priority: atomize(data[:priority]) || :normal,
      progress: data[:progress] || 0,
      added_at: parse_datetime(data[:added_at]) || fallback_datetime
    }
  end

  defp deserialize_item(:skill, %{"name" => name} = data, fallback_id, fallback_datetime)
       when is_binary(name) do
    %{
      id: valid_id_or_fallback(data["id"], fallback_id),
      name: name,
      description: data["description"] || "",
      body: data["body"] || "",
      activated_at: parse_datetime(data["activated_at"]) || fallback_datetime
    }
  end

  defp deserialize_item(:skill, %{name: name} = data, fallback_id, fallback_datetime)
       when is_binary(name) do
    %{
      id: valid_id_or_fallback(data[:id], fallback_id),
      name: name,
      description: data[:description] || "",
      body: data[:body] || "",
      activated_at: parse_datetime(data[:activated_at]) || fallback_datetime
    }
  end

  defp deserialize_item(_kind, _item, _fallback_id, _fallback_datetime), do: nil

  defp deserialize_collection(raw_items, kind, owner_seed, fallback_datetime) do
    raw_items
    |> proper_list()
    |> Enum.with_index()
    |> Enum.reduce({[], MapSet.new()}, fn {raw_item, index}, {items, seen_ids} ->
      fallback_id = unique_legacy_item_id(kind, owner_seed, index, seen_ids)

      case deserialize_item(kind, raw_item, fallback_id, fallback_datetime) do
        nil ->
          {items, seen_ids}

        item ->
          item_id =
            if MapSet.member?(seen_ids, item.id),
              do: fallback_id,
              else: item.id

          item = Map.put(item, :id, item_id)
          {[item | items], MapSet.put(seen_ids, item_id)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp unique_legacy_item_id(kind, owner_seed, index, seen_ids, salt \\ 0) do
    id = legacy_item_id(kind, owner_seed, index, salt)

    if MapSet.member?(seen_ids, id) do
      unique_legacy_item_id(kind, owner_seed, index, seen_ids, salt + 1)
    else
      id
    end
  end

  defp legacy_item_id(kind, owner_seed, index, salt) do
    digest =
      :crypto.hash(
        :sha256,
        [
          owner_seed,
          <<0>>,
          Atom.to_string(kind),
          <<0>>,
          Integer.to_string(index),
          <<0>>,
          Integer.to_string(salt)
        ]
      )
      |> binary_part(0, @generated_id_bytes)
      |> Base.url_encode64(padding: false)

    "#{item_id_prefix(kind)}_#{digest}"
  end

  defp legacy_owner_seed(agent_id, started_at) do
    owner = if is_binary(agent_id) and String.valid?(agent_id), do: agent_id, else: "legacy_owner"
    started = serialize_datetime(started_at) || DateTime.to_iso8601(@legacy_epoch)
    :crypto.hash(:sha256, [owner, <<0>>, started])
  end

  defp item_id_prefix(:thought), do: "thought"
  defp item_id_prefix(:goal), do: "goal"
  defp item_id_prefix(:skill), do: "skill"
  defp item_id_prefix(:concern), do: "concern"
  defp item_id_prefix(:curiosity), do: "curiosity"

  defp stable_scalar_ids(values, raw_ids, kind, owner_seed) do
    ids = proper_list(raw_ids)
    missing_count = max(length(values) - length(ids), 0)
    existing_count = length(ids)

    values
    |> Enum.with_index()
    |> Enum.reduce({[], MapSet.new()}, fn {_value, index}, {acc, seen_ids} ->
      candidate =
        if index < missing_count do
          unique_legacy_item_id(kind, owner_seed, existing_count + index, seen_ids)
        else
          ids
          |> Enum.at(index - missing_count)
          |> valid_id_or_fallback(unique_legacy_item_id(kind, owner_seed, index, seen_ids))
        end

      id =
        if MapSet.member?(seen_ids, candidate) do
          unique_legacy_item_id(kind, owner_seed, index, seen_ids, index + 1)
        else
          candidate
        end

      {[id | acc], MapSet.put(seen_ids, id)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp scalar_pairs(wm, :concerns), do: Enum.zip(wm.concerns, wm.concern_ids)
  defp scalar_pairs(wm, :curiosity), do: Enum.zip(wm.curiosity, wm.curiosity_ids)

  defp put_scalar_pairs(wm, :concerns, pairs) do
    %{wm | concerns: Enum.map(pairs, &elem(&1, 0)), concern_ids: Enum.map(pairs, &elem(&1, 1))}
  end

  defp put_scalar_pairs(wm, :curiosity, pairs) do
    %{
      wm
      | curiosity: Enum.map(pairs, &elem(&1, 0)),
        curiosity_ids: Enum.map(pairs, &elem(&1, 1))
    }
  end

  defp put_trimmed_list(wm, :concerns, trimmed) do
    %{wm | concerns: trimmed, concern_ids: Enum.take(wm.concern_ids, length(trimmed))}
  end

  defp put_trimmed_list(wm, :curiosity, trimmed) do
    %{wm | curiosity: trimmed, curiosity_ids: Enum.take(wm.curiosity_ids, length(trimmed))}
  end

  defp put_trimmed_list(wm, field, trimmed), do: Map.put(wm, field, trimmed)

  defp ensure_runtime_item_id(item, prefix) do
    Map.update(item, :id, generate_item_id(prefix), &valid_id_or_new(&1, prefix))
  end

  defp valid_id_or_new(id, prefix) do
    if valid_item_id?(id), do: id, else: generate_item_id(prefix)
  end

  defp valid_id_or_fallback(id, fallback) do
    if valid_item_id?(id), do: id, else: fallback
  end

  defp valid_item_id?(id) when is_binary(id) do
    byte_size(id) <= @max_item_id_bytes and String.valid?(id) and String.trim(id) != ""
  end

  defp valid_item_id?(_id), do: false

  defp proper_list(value) do
    case walk_proper_list(value, @max_deserialized_items, []) do
      {:ok, items} -> Enum.reverse(items)
      :error -> []
    end
  end

  defp walk_proper_list([], _remaining, acc), do: {:ok, acc}
  defp walk_proper_list([_item | _rest], 0, acc), do: {:ok, acc}

  defp walk_proper_list([item | rest], remaining, acc) when remaining > 0 do
    walk_proper_list(rest, remaining - 1, [item | acc])
  end

  defp walk_proper_list(_improper_tail, _remaining, _acc), do: :error

  defp get_field(data, key, default \\ nil) do
    case Map.fetch(data, key) do
      {:ok, value} -> value
      :error -> Map.get(data, Atom.to_string(key), default)
    end
  end

  defp numeric_or_default(value, _default) when is_number(value), do: value
  defp numeric_or_default(_value, default), do: default

  defp non_negative_integer_or_default(value, _default)
       when is_integer(value) and value >= 0,
       do: value

  defp non_negative_integer_or_default(_value, default), do: default

  defp empty_legacy_memory do
    %__MODULE__{started_at: nil, version: @version}
  end

  defp serialize_token_spec(nil), do: nil
  defp serialize_token_spec(n) when is_integer(n), do: n
  defp serialize_token_spec({:percentage, pct}), do: %{"type" => "percentage", "value" => pct}
  defp serialize_token_spec({:fixed, n}), do: %{"type" => "fixed", "value" => n}

  defp serialize_token_spec({:min_max, min, max, pct}),
    do: %{"type" => "min_max", "min" => min, "max" => max, "value" => pct}

  defp serialize_token_spec(other), do: other

  defp deserialize_token_spec(nil), do: nil
  defp deserialize_token_spec(n) when is_integer(n), do: n
  defp deserialize_token_spec(%{"type" => "percentage", "value" => pct}), do: {:percentage, pct}
  defp deserialize_token_spec(%{"type" => "fixed", "value" => n}), do: {:fixed, n}

  defp deserialize_token_spec(%{"type" => "min_max", "min" => min, "max" => max, "value" => pct}),
    do: {:min_max, min, max, pct}

  defp deserialize_token_spec(other), do: other

  defp serialize_datetime(nil), do: nil
  defp serialize_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp atomize(nil), do: nil
  defp atomize(a) when is_atom(a), do: a

  defp atomize(s) when is_binary(s) do
    case SafeAtom.to_existing(s) do
      {:ok, atom} -> atom
      {:error, _} -> s
    end
  end

  defp generate_item_id(prefix) do
    prefix <>
      "_" <>
      (@generated_id_bytes
       |> :crypto.strong_rand_bytes()
       |> Base.url_encode64(padding: false))
  end

  # ============================================================================
  # Private Helpers — Signal Replay
  # ============================================================================

  @doc """
  Apply a memory event signal to reconstruct working memory state.

  Handles both legacy format (data contains `:type` key) and signal format
  (type inferred from signal's `.type` field via `infer_type/1`).
  """
  @doc since: "0.1.0"
  def apply_memory_event(%{type: sig_type, data: data}, wm) do
    type = data[:type] || data["type"] || infer_type(sig_type)
    apply_event_by_type(type, data, wm)
  end

  # Fallback for signals without :type field (legacy format with just :data)
  def apply_memory_event(%{data: _data} = signal, wm) do
    apply_memory_event(Map.put(signal, :type, nil), wm)
  end

  def apply_memory_event(_signal, wm), do: wm

  # Event type dispatch — each clause extracted for reduced complexity
  defp apply_event_by_type(:identity, data, wm), do: apply_identity_event(data, wm)
  defp apply_event_by_type("identity", data, wm), do: apply_identity_event(data, wm)
  defp apply_event_by_type(:relationship, data, wm), do: apply_relationship_event(data, wm)
  defp apply_event_by_type("relationship", data, wm), do: apply_relationship_event(data, wm)
  defp apply_event_by_type(:goal, data, wm), do: apply_goal_event(data, wm)
  defp apply_event_by_type("goal", data, wm), do: apply_goal_event(data, wm)
  defp apply_event_by_type(:thought, data, wm), do: apply_thought_event(data, wm)
  defp apply_event_by_type("thought", data, wm), do: apply_thought_event(data, wm)
  defp apply_event_by_type(:engagement, data, wm), do: apply_engagement_event(data, wm)
  defp apply_event_by_type("engagement", data, wm), do: apply_engagement_event(data, wm)
  defp apply_event_by_type(:concern, data, wm), do: apply_concern_event(data, wm)
  defp apply_event_by_type("concern", data, wm), do: apply_concern_event(data, wm)
  defp apply_event_by_type(:curiosity, data, wm), do: apply_curiosity_event(data, wm)
  defp apply_event_by_type("curiosity", data, wm), do: apply_curiosity_event(data, wm)
  defp apply_event_by_type(:conversation, data, wm), do: apply_conversation_event(data, wm)
  defp apply_event_by_type("conversation", data, wm), do: apply_conversation_event(data, wm)
  defp apply_event_by_type(_type, _data, wm), do: wm

  defp apply_identity_event(data, wm) do
    %{wm | name: data[:name] || data["name"]}
  end

  defp apply_relationship_event(data, wm) do
    human = data[:human_name] || data["human_name"]
    context = data[:context] || data["context"]
    set_relationship(wm, human || wm.current_human, context || wm.relationship_context)
  end

  defp apply_goal_event(data, wm) do
    goal = data[:goal] || data["goal"]
    event_type = data[:event_type] || data["event_type"]

    if goal do
      apply_goal_by_event_type(event_type, goal, wm)
    else
      wm
    end
  end

  defp apply_goal_by_event_type(et, goal, wm) when et in [:added, "added"],
    do: add_goal(wm, goal)

  defp apply_goal_by_event_type(et, goal, wm)
       when et in [:achieved, "achieved", :failed, "failed"],
       do: remove_goal(wm, goal[:id] || goal["id"])

  defp apply_goal_by_event_type(_et, goal, wm),
    do: add_goal(wm, goal)

  defp apply_thought_event(data, wm) do
    content =
      data[:content] || data["content"] || data[:thought_preview] || data["thought_preview"]

    if content, do: add_thought(wm, content), else: wm
  end

  defp apply_engagement_event(data, wm) do
    level = data[:level] || data["level"]
    if is_number(level), do: set_engagement_level(wm, level), else: wm
  end

  defp apply_concern_event(data, wm) do
    concern = data[:concern] || data["concern"]
    action = data[:action] || data["action"]
    apply_concern_action(action, concern, wm)
  end

  defp apply_concern_action(action, concern, wm) when action in [:resolved, "resolved"] do
    %{wm | concerns: Enum.reject(wm.concerns, &(normalize_concern_text(&1) == concern))}
  end

  defp apply_concern_action(_action, concern, wm) when is_binary(concern) do
    add_concern(wm, concern)
  end

  defp apply_concern_action(_action, concern, wm) when is_map(concern) do
    add_concern(wm, concern)
  end

  defp apply_concern_action(_action, _concern, wm), do: wm

  defp apply_curiosity_event(data, wm) do
    item = data[:item] || data["item"]
    action = data[:action] || data["action"]
    apply_curiosity_action(action, item, wm)
  end

  defp apply_curiosity_action(action, item, wm) when action in [:satisfied, "satisfied"] do
    %{wm | curiosity: Enum.reject(wm.curiosity, &(normalize_curiosity_text(&1) == item))}
  end

  defp apply_curiosity_action(_action, item, wm) when is_binary(item) do
    add_curiosity(wm, item)
  end

  defp apply_curiosity_action(_action, item, wm) when is_map(item) do
    add_curiosity(wm, item)
  end

  defp apply_curiosity_action(_action, _item, wm), do: wm

  defp apply_conversation_event(data, wm) do
    conv = data[:conversation] || data["conversation"]
    set_conversation(wm, conv)
  end

  # Map signal types to working memory data types
  defp infer_type(:identity_change), do: :identity
  defp infer_type(:identity_rollback), do: :identity
  defp infer_type(:thought_recorded), do: :thought
  defp infer_type(:goal_created), do: :goal
  defp infer_type(:goal_achieved), do: :goal
  defp infer_type(:goal_abandoned), do: :goal
  defp infer_type(:goal_progress), do: :goal
  defp infer_type(:engagement_changed), do: :engagement
  defp infer_type(:concern_added), do: :concern
  defp infer_type(:concern_resolved), do: :concern
  defp infer_type(:curiosity_added), do: :curiosity
  defp infer_type(:curiosity_satisfied), do: :curiosity
  defp infer_type(:conversation_changed), do: :conversation
  defp infer_type(:relationship_changed), do: :relationship
  defp infer_type(_), do: nil

  defp normalize_concern_text(concern) when is_binary(concern), do: concern
  defp normalize_concern_text(%{content: content}), do: content
  defp normalize_concern_text(%{"content" => content}), do: content
  defp normalize_concern_text(_), do: nil

  defp normalize_curiosity_text(item) when is_binary(item), do: item
  defp normalize_curiosity_text(%{topic: topic}), do: topic
  defp normalize_curiosity_text(%{"topic" => topic}), do: topic
  defp normalize_curiosity_text(_), do: nil
end
