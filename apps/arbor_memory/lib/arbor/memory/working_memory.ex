defmodule Arbor.Memory.WorkingMemory do
  @moduledoc """
  The agent's "present moment" awareness — short-term context that persists
  within a session and across sessions.

  WorkingMemory holds the ephemeral state that makes an agent feel present
  and aware: recent thoughts, active goals, relationship context, concerns,
  curiosity, and engagement level.

  ## Dual-Agent Support

  - **Native agents:** Hold in process state, auto-persisted on shutdown
  - **Bridged agents:** Serialized to/from JSON for gateway transport

  ## Examples

      # Create working memory for an agent
      wm = WorkingMemory.new("agent_001")

      # Add a thought
      wm = WorkingMemory.add_thought(wm, "User seems curious about Elixir")

      # Set goals
      wm = WorkingMemory.set_goals(wm, ["Explain GenServer basics", "Show examples"])

      # Render for LLM context
      text = WorkingMemory.to_prompt_text(wm)

      # Serialize for gateway transport
      json_map = WorkingMemory.serialize(wm)
      restored_wm = WorkingMemory.deserialize(json_map)
  """

  alias Arbor.Memory.TokenBudget

  @type t :: %__MODULE__{
          agent_id: String.t(),
          recent_thoughts: [String.t()],
          active_goals: [String.t()],
          relationship_context: String.t() | nil,
          concerns: [String.t()],
          curiosity: [String.t()],
          engagement_level: float(),
          version: pos_integer()
        }

  defstruct [
    :agent_id,
    recent_thoughts: [],
    active_goals: [],
    relationship_context: nil,
    concerns: [],
    curiosity: [],
    engagement_level: 0.5,
    version: 1
  ]

  @default_max_thoughts 20
  @default_max_goals 10
  @default_max_concerns 5
  @default_max_curiosity 5

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create a new working memory for an agent.

  ## Options

  - `:max_thoughts` - Maximum recent thoughts to retain (default: 20)
  - `:max_goals` - Maximum active goals (default: 10)
  - `:max_concerns` - Maximum concerns (default: 5)
  - `:max_curiosity` - Maximum curiosity items (default: 5)
  - `:engagement_level` - Initial engagement level (default: 0.5)

  ## Examples

      wm = WorkingMemory.new("agent_001")
      wm = WorkingMemory.new("agent_001", max_thoughts: 50)
  """
  @spec new(String.t(), keyword()) :: t()
  def new(agent_id, opts \\ []) do
    %__MODULE__{
      agent_id: agent_id,
      engagement_level: Keyword.get(opts, :engagement_level, 0.5)
    }
  end

  # ============================================================================
  # Thought Management
  # ============================================================================

  @doc """
  Add a thought to working memory.

  Thoughts are prepended (newest first) and bounded by max_thoughts.
  """
  @spec add_thought(t(), String.t(), keyword()) :: t()
  def add_thought(wm, thought, opts \\ []) do
    max = Keyword.get(opts, :max_thoughts, @default_max_thoughts)
    new_thoughts = [thought | wm.recent_thoughts] |> Enum.take(max)
    %{wm | recent_thoughts: new_thoughts}
  end

  @doc """
  Clear all recent thoughts.
  """
  @spec clear_thoughts(t()) :: t()
  def clear_thoughts(wm) do
    %{wm | recent_thoughts: []}
  end

  # ============================================================================
  # Goal Management
  # ============================================================================

  @doc """
  Set active goals, replacing any existing goals.
  """
  @spec set_goals(t(), [String.t()], keyword()) :: t()
  def set_goals(wm, goals, opts \\ []) do
    max = Keyword.get(opts, :max_goals, @default_max_goals)
    %{wm | active_goals: Enum.take(goals, max)}
  end

  @doc """
  Add a goal to the active goals list.
  """
  @spec add_goal(t(), String.t(), keyword()) :: t()
  def add_goal(wm, goal, opts \\ []) do
    max = Keyword.get(opts, :max_goals, @default_max_goals)
    new_goals = [goal | wm.active_goals] |> Enum.uniq() |> Enum.take(max)
    %{wm | active_goals: new_goals}
  end

  @doc """
  Remove a completed goal.
  """
  @spec complete_goal(t(), String.t()) :: t()
  def complete_goal(wm, goal) do
    %{wm | active_goals: Enum.reject(wm.active_goals, &(&1 == goal))}
  end

  # ============================================================================
  # Relationship Context
  # ============================================================================

  @doc """
  Set the relationship context (summary of current relationship).
  """
  @spec set_relationship_context(t(), String.t() | nil) :: t()
  def set_relationship_context(wm, context) do
    %{wm | relationship_context: context}
  end

  # ============================================================================
  # Concerns and Curiosity
  # ============================================================================

  @doc """
  Add a concern to the concerns list.
  """
  @spec add_concern(t(), String.t(), keyword()) :: t()
  def add_concern(wm, concern, opts \\ []) do
    max = Keyword.get(opts, :max_concerns, @default_max_concerns)
    new_concerns = [concern | wm.concerns] |> Enum.uniq() |> Enum.take(max)
    %{wm | concerns: new_concerns}
  end

  @doc """
  Remove a resolved concern.
  """
  @spec resolve_concern(t(), String.t()) :: t()
  def resolve_concern(wm, concern) do
    %{wm | concerns: Enum.reject(wm.concerns, &(&1 == concern))}
  end

  @doc """
  Add something the agent is curious about.
  """
  @spec add_curiosity(t(), String.t(), keyword()) :: t()
  def add_curiosity(wm, item, opts \\ []) do
    max = Keyword.get(opts, :max_curiosity, @default_max_curiosity)
    new_curiosity = [item | wm.curiosity] |> Enum.uniq() |> Enum.take(max)
    %{wm | curiosity: new_curiosity}
  end

  @doc """
  Remove a satisfied curiosity item.
  """
  @spec satisfy_curiosity(t(), String.t()) :: t()
  def satisfy_curiosity(wm, item) do
    %{wm | curiosity: Enum.reject(wm.curiosity, &(&1 == item))}
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
  # Rendering for LLM Context
  # ============================================================================

  @doc """
  Render working memory as text suitable for LLM system prompt injection.

  ## Options

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
    |> maybe_add_section(opts, :include_relationship, wm.relationship_context, &format_relationship/1)
    |> maybe_add_section(opts, :include_goals, wm.active_goals, &format_goals/1)
    |> maybe_add_thoughts(opts, wm.recent_thoughts, max_thoughts)
    |> maybe_add_section(opts, :include_concerns, wm.concerns, &format_concerns/1)
    |> maybe_add_section(opts, :include_curiosity, wm.curiosity, &format_curiosity/1)
    |> Enum.reverse()
    |> Enum.join("\n\n")
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
      [format_thoughts(Enum.take(thoughts, max_thoughts)) | sections]
    else
      sections
    end
  end

  @doc """
  Return working memory as a structured map for prompt context.

  This format is useful for structured prompt templates that prefer
  machine-readable data over prose.
  """
  @spec to_prompt_context(t(), keyword()) :: map()
  def to_prompt_context(wm, opts \\ []) do
    max_thoughts = Keyword.get(opts, :max_thoughts, 5)

    %{
      agent_id: wm.agent_id,
      recent_thoughts: Enum.take(wm.recent_thoughts, max_thoughts),
      active_goals: wm.active_goals,
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

  This format is suitable for:
  - Persistence to Postgres
  - Transport to/from bridged agents via gateway
  """
  @spec serialize(t()) :: map()
  def serialize(wm) do
    %{
      "agent_id" => wm.agent_id,
      "recent_thoughts" => wm.recent_thoughts,
      "active_goals" => wm.active_goals,
      "relationship_context" => wm.relationship_context,
      "concerns" => wm.concerns,
      "curiosity" => wm.curiosity,
      "engagement_level" => wm.engagement_level,
      "version" => wm.version
    }
  end

  @doc """
  Deserialize a JSON-safe map back to a WorkingMemory struct.

  Handles version migration if needed.
  """
  @spec deserialize(map()) :: t()
  def deserialize(data) when is_map(data) do
    # Handle both string and atom keys for flexibility
    get_field = fn key ->
      Map.get(data, key) || Map.get(data, to_string(key))
    end

    %__MODULE__{
      agent_id: get_field.(:agent_id),
      recent_thoughts: get_field.(:recent_thoughts) || [],
      active_goals: get_field.(:active_goals) || [],
      relationship_context: get_field.(:relationship_context),
      concerns: get_field.(:concerns) || [],
      curiosity: get_field.(:curiosity) || [],
      engagement_level: get_field.(:engagement_level) || 0.5,
      version: get_field.(:version) || 1
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
      # Trim progressively: thoughts first, then other lists
      wm
      |> trim_list(:recent_thoughts, max_tokens)
      |> trim_list(:concerns, max_tokens)
      |> trim_list(:curiosity, max_tokens)
      |> trim_list(:active_goals, max_tokens)
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
      thought_count: length(wm.recent_thoughts),
      goal_count: length(wm.active_goals),
      concern_count: length(wm.concerns),
      curiosity_count: length(wm.curiosity),
      engagement_level: wm.engagement_level,
      has_relationship_context: wm.relationship_context != nil,
      estimated_tokens: TokenBudget.estimate_tokens(text),
      version: wm.version
    }
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp format_relationship(context) do
    """
    ## Relationship Context

    #{context}
    """
    |> String.trim()
  end

  defp format_goals(goals) do
    goal_list = Enum.map_join(goals, "\n", &"- #{&1}")

    """
    ## Active Goals

    #{goal_list}
    """
    |> String.trim()
  end

  defp format_thoughts(thoughts) do
    thought_list = Enum.map_join(thoughts, "\n", &"- #{&1}")

    """
    ## Recent Thoughts

    #{thought_list}
    """
    |> String.trim()
  end

  defp format_concerns(concerns) do
    concern_list = Enum.map_join(concerns, "\n", &"- #{&1}")

    """
    ## Current Concerns

    #{concern_list}
    """
    |> String.trim()
  end

  defp format_curiosity(items) do
    curiosity_list = Enum.map_join(items, "\n", &"- #{&1}")

    """
    ## Things I'm Curious About

    #{curiosity_list}
    """
    |> String.trim()
  end

  defp trim_list(wm, field, max_tokens) do
    list = Map.get(wm, field)

    if length(list) <= 1 do
      wm
    else
      # Try removing one item at a time from the end
      trimmed = Enum.take(list, length(list) - 1)
      new_wm = Map.put(wm, field, trimmed)
      current_tokens = TokenBudget.estimate_tokens(to_prompt_text(new_wm))

      if current_tokens <= max_tokens do
        new_wm
      else
        trim_list(new_wm, field, max_tokens)
      end
    end
  end
end
