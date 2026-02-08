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

  alias Arbor.Memory.TokenBudget

  require Logger

  @version 2

  @type thought :: %{
          content: String.t(),
          timestamp: DateTime.t(),
          cached_tokens: non_neg_integer()
        }

  @type goal :: %{
          id: String.t(),
          description: String.t(),
          type: atom(),
          priority: atom(),
          progress: number(),
          added_at: DateTime.t()
        }

  @type t :: %__MODULE__{
          agent_id: String.t(),
          name: String.t() | nil,
          current_human: String.t() | nil,
          current_conversation: map() | nil,
          recent_thoughts: [thought()],
          active_goals: [goal()],
          relationship_context: String.t() | map() | nil,
          concerns: [String.t()],
          curiosity: [String.t()],
          engagement_level: float(),
          max_tokens: TokenBudget.spec() | nil,
          model: String.t() | nil,
          last_consolidated_at: DateTime.t() | nil,
          started_at: DateTime.t(),
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
    relationship_context: nil,
    concerns: [],
    curiosity: [],
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
  @spec add_goal(t(), String.t() | map(), keyword()) :: t()
  def add_goal(wm, goal, opts \\ []) do
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
    goal = Enum.find(wm.active_goals, fn g ->
      g.id == goal_or_id or g.description == goal_or_id
    end)

    wm = %{wm | active_goals: Enum.reject(wm.active_goals, fn g ->
      g.id == goal_or_id or g.description == goal_or_id
    end)}

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
    signals_mod = Arbor.Memory.Signals
    if Code.ensure_loaded?(signals_mod) and
         function_exported?(signals_mod, :query_recent, 2) do
      case apply(signals_mod, :query_recent, [wm.agent_id, [limit: 100]]) do
        {:ok, signals} ->
          rebuilt = Enum.reduce(signals, wm, &apply_memory_event/2)
          Logger.info("Rebuilt working memory for #{wm.agent_id} from #{length(signals)} signals")
          {:ok, rebuilt}

        {:error, _} = error ->
          error
      end
    else
      {:error, :signals_not_available}
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
    |> maybe_add_section(opts, :include_relationship, wm.relationship_context, &format_relationship/1)
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
      recent_thoughts: wm.recent_thoughts |> Enum.take(max_thoughts) |> Enum.map(&thought_content/1),
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
  def serialize(wm) do
    %{
      "agent_id" => wm.agent_id,
      "name" => wm.name,
      "current_human" => wm.current_human,
      "current_conversation" => wm.current_conversation,
      "recent_thoughts" => Enum.map(wm.recent_thoughts, &serialize_thought/1),
      "active_goals" => Enum.map(wm.active_goals, &serialize_goal/1),
      "relationship_context" => wm.relationship_context,
      "concerns" => wm.concerns,
      "curiosity" => wm.curiosity,
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

  Handles both v1 (plain strings) and v2 (structured maps) formats.
  """
  @spec deserialize(map()) :: t()
  def deserialize(data) when is_map(data) do
    get_field = fn key ->
      Map.get(data, key) || Map.get(data, to_string(key))
    end

    raw_thoughts = get_field.(:recent_thoughts) || []
    raw_goals = get_field.(:active_goals) || []

    %__MODULE__{
      agent_id: get_field.(:agent_id),
      name: get_field.(:name),
      current_human: get_field.(:current_human),
      current_conversation: get_field.(:current_conversation),
      recent_thoughts: Enum.map(raw_thoughts, &deserialize_thought/1),
      active_goals: Enum.map(raw_goals, &deserialize_goal/1),
      relationship_context: get_field.(:relationship_context),
      concerns: get_field.(:concerns) || [],
      curiosity: get_field.(:curiosity) || [],
      engagement_level: get_field.(:engagement_level) || 0.5,
      max_tokens: deserialize_token_spec(get_field.(:max_tokens)),
      model: get_field.(:model),
      last_consolidated_at: parse_datetime(get_field.(:last_consolidated_at)),
      started_at: parse_datetime(get_field.(:started_at)),
      thought_count: get_field.(:thought_count) || 0,
      version: get_field.(:version) || @version
    }
  end

  # ============================================================================
  # Migration
  # ============================================================================

  @doc """
  Migrate state to current version.

  Called on every GenServer callback to ensure state is current after hot reloads.
  Handles version upgrades, nil-versioned state, and plain maps.
  """
  @spec migrate(t() | map()) :: t()
  def migrate(%__MODULE__{version: @version} = wm), do: wm

  def migrate(%__MODULE__{version: 1} = wm) do
    %{wm | version: @version, max_tokens: nil, model: nil}
    |> ensure_defaults()
    |> migrate()
  end

  def migrate(%__MODULE__{version: nil} = wm) do
    %{wm | version: @version, max_tokens: nil, model: nil}
    |> ensure_defaults()
    |> migrate()
  end

  def migrate(%{} = old) when not is_struct(old) do
    deserialize(old)
  end

  defp ensure_defaults(%__MODULE__{} = wm) do
    %{
      wm
      | recent_thoughts: wm.recent_thoughts || [],
        active_goals: wm.active_goals || [],
        curiosity: wm.curiosity || [],
        concerns: wm.concerns || [],
        engagement_level: wm.engagement_level || 0.5,
        started_at: wm.started_at || DateTime.utc_now(),
        thought_count: wm.thought_count || 0
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
      content: thought,
      timestamp: DateTime.utc_now(),
      cached_tokens: TokenBudget.estimate_tokens(thought)
    }
  end

  defp normalize_thought(%{content: _} = thought) do
    Map.merge(%{
      timestamp: DateTime.utc_now(),
      cached_tokens: TokenBudget.estimate_tokens(thought[:content] || "")
    }, thought)
  end

  defp normalize_thought(%{"content" => content} = thought) do
    %{
      content: content,
      timestamp: parse_datetime(thought["timestamp"]) || DateTime.utc_now(),
      cached_tokens: thought["cached_tokens"] || TokenBudget.estimate_tokens(content)
    }
  end

  defp normalize_goal(goal) when is_binary(goal) do
    %{
      id: generate_id(),
      description: goal,
      type: :general,
      priority: :normal,
      progress: 0,
      added_at: DateTime.utc_now()
    }
  end

  defp normalize_goal(%{description: _} = goal) do
    Map.merge(%{
      id: generate_id(),
      type: :general,
      priority: :normal,
      progress: 0,
      added_at: DateTime.utc_now()
    }, goal)
  end

  defp normalize_goal(%{"description" => desc} = goal) do
    %{
      id: goal["id"] || generate_id(),
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
      [format_thoughts(Enum.take(thoughts, max_thoughts)) | sections]
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

  defp format_thoughts(thoughts) do
    thought_list = Enum.map_join(thoughts, "\n", fn t -> "- #{thought_content(t)}" end)
    "## Recent Thoughts\n\n#{thought_list}" |> String.trim()
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
      new_wm = Map.put(wm, field, trimmed)
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

  defp serialize_thought(%{content: content, timestamp: ts, cached_tokens: tokens}) do
    %{
      "content" => content,
      "timestamp" => serialize_datetime(ts),
      "cached_tokens" => tokens
    }
  end

  defp serialize_thought(str) when is_binary(str) do
    %{"content" => str, "timestamp" => nil, "cached_tokens" => 0}
  end

  defp serialize_goal(%{id: id, description: desc, type: type, priority: priority, progress: progress, added_at: added_at}) do
    %{
      "id" => id,
      "description" => desc,
      "type" => to_string(type),
      "priority" => to_string(priority),
      "progress" => progress,
      "added_at" => serialize_datetime(added_at)
    }
  end

  defp serialize_goal(str) when is_binary(str) do
    %{"description" => str, "type" => "general", "priority" => "normal", "progress" => 0}
  end

  defp deserialize_thought(str) when is_binary(str) do
    # v1 format: plain string
    %{
      content: str,
      timestamp: DateTime.utc_now(),
      cached_tokens: TokenBudget.estimate_tokens(str)
    }
  end

  defp deserialize_thought(%{"content" => content} = data) do
    %{
      content: content,
      timestamp: parse_datetime(data["timestamp"]) || DateTime.utc_now(),
      cached_tokens: data["cached_tokens"] || TokenBudget.estimate_tokens(content)
    }
  end

  defp deserialize_thought(%{content: _} = thought), do: thought

  defp deserialize_goal(str) when is_binary(str) do
    # v1 format: plain string
    %{
      id: generate_id(),
      description: str,
      type: :general,
      priority: :normal,
      progress: 0,
      added_at: DateTime.utc_now()
    }
  end

  defp deserialize_goal(%{"description" => desc} = data) do
    %{
      id: data["id"] || generate_id(),
      description: desc,
      type: atomize(data["type"]) || :general,
      priority: atomize(data["priority"]) || :normal,
      progress: data["progress"] || 0,
      added_at: parse_datetime(data["added_at"]) || DateTime.utc_now()
    }
  end

  defp deserialize_goal(%{description: _} = goal), do: goal

  defp serialize_token_spec(nil), do: nil
  defp serialize_token_spec(n) when is_integer(n), do: n
  defp serialize_token_spec({:percentage, pct}), do: %{"type" => "percentage", "value" => pct}
  defp serialize_token_spec({:fixed, n}), do: %{"type" => "fixed", "value" => n}
  defp serialize_token_spec({:min_max, min, max, pct}), do: %{"type" => "min_max", "min" => min, "max" => max, "value" => pct}
  defp serialize_token_spec(other), do: other

  defp deserialize_token_spec(nil), do: nil
  defp deserialize_token_spec(n) when is_integer(n), do: n
  defp deserialize_token_spec(%{"type" => "percentage", "value" => pct}), do: {:percentage, pct}
  defp deserialize_token_spec(%{"type" => "fixed", "value" => n}), do: {:fixed, n}
  defp deserialize_token_spec(%{"type" => "min_max", "min" => min, "max" => max, "value" => pct}), do: {:min_max, min, max, pct}
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
    try do
      String.to_existing_atom(s)
    rescue
      ArgumentError -> String.to_atom(s)
    end
  end

  defp generate_id do
    "goal_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
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

    case type do
      t when t in [:identity, "identity"] ->
        %{wm | name: data[:name] || data["name"]}

      t when t in [:relationship, "relationship"] ->
        human = data[:human_name] || data["human_name"]
        context = data[:context] || data["context"]
        set_relationship(wm, human || wm.current_human, context || wm.relationship_context)

      t when t in [:goal, "goal"] ->
        goal = data[:goal] || data["goal"]
        event_type = data[:event_type] || data["event_type"]

        case event_type do
          et when et in [:added, "added"] -> add_goal(wm, goal)
          et when et in [:achieved, "achieved", :failed, "failed"] -> remove_goal(wm, goal[:id] || goal["id"])
          _ -> add_goal(wm, goal)
        end

      t when t in [:thought, "thought"] ->
        content = data[:content] || data["content"] || data[:thought_preview] || data["thought_preview"]
        if content, do: add_thought(wm, content), else: wm

      t when t in [:engagement, "engagement"] ->
        level = data[:level] || data["level"]
        if is_number(level), do: set_engagement_level(wm, level), else: wm

      t when t in [:concern, "concern"] ->
        concern = data[:concern] || data["concern"]
        action = data[:action] || data["action"]
        cond do
          action in [:resolved, "resolved"] ->
            %{wm | concerns: Enum.reject(wm.concerns, &(normalize_concern_text(&1) == concern))}
          concern ->
            add_concern(wm, concern)
          true ->
            wm
        end

      t when t in [:curiosity, "curiosity"] ->
        item = data[:item] || data["item"]
        action = data[:action] || data["action"]
        cond do
          action in [:satisfied, "satisfied"] ->
            %{wm | curiosity: Enum.reject(wm.curiosity, &(normalize_curiosity_text(&1) == item))}
          item ->
            add_curiosity(wm, item)
          true ->
            wm
        end

      t when t in [:conversation, "conversation"] ->
        conv = data[:conversation] || data["conversation"]
        set_conversation(wm, conv)

      _ ->
        wm
    end
  end

  # Fallback for signals without :type field (legacy format with just :data)
  def apply_memory_event(%{data: _data} = signal, wm) do
    apply_memory_event(Map.put(signal, :type, nil), wm)
  end

  def apply_memory_event(_signal, wm), do: wm

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
