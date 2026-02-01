defmodule Arbor.Memory.Preconscious do
  @moduledoc """
  Anticipatory retrieval — proactively surfaces relevant long-term memories.

  The preconscious runs during heartbeats and analyzes the agent's recent
  conversation context (thoughts, goals) to find related memories that
  might be useful. Results are surfaced as proposals with type `:preconscious`.

  ## Relationship to Other Memory Systems

  | System | Analyzes | Detects |
  |--------|----------|---------|
  | Subconscious (Phase 4) | Patterns across time | "You keep failing at X" |
  | Preconscious (Phase 7) | Current conversation context | "You're discussing Y, here's related context" |

  ## Integration

  This module is called by `BackgroundChecks.run/2` during heartbeats.
  It uses existing infrastructure:
  - `WorkingMemory` for recent thoughts and goals
  - `Index` (via `recall/3`) for vector similarity search
  - `Proposal` for surfacing results to the agent

  ## Examples

      # Run a preconscious check
      {:ok, anticipation} = Preconscious.check("agent_001")

      # Configure sensitivity
      :ok = Preconscious.configure("agent_001", relevance_threshold: 0.5)
  """

  alias Arbor.Memory.{Index, IndexSupervisor, Proposal, Signals}

  require Logger

  @type anticipation :: %{
          memories: [map()],
          query_used: String.t(),
          relevance_score: float(),
          context_summary: String.t()
        }

  @type context :: %{
          topics: [String.t()],
          goals: [String.t()],
          combined_query: String.t()
        }

  # Default configuration
  @default_threshold 0.4
  @default_max_per_check 3
  @default_lookback_turns 5

  # ETS table for per-agent configuration
  @config_ets :arbor_preconscious_config

  # ============================================================================
  # Main Entry Point
  # ============================================================================

  @doc """
  Run preconscious check for an agent.

  Called by BackgroundChecks during heartbeat. Extracts context from
  recent conversation, searches long-term memory, and returns relevant
  memories that might be useful to surface.

  ## Options

  - `:relevance_threshold` - Minimum similarity to include (default: 0.4)
  - `:max_results` - Maximum memories to return (default: 3)
  - `:lookback_turns` - Number of recent thoughts to consider (default: 5)

  ## Returns

  - `{:ok, anticipation}` - Found relevant memories
  - `{:ok, %{memories: []}}` - No relevant memories found
  - `{:error, reason}` - Check failed
  """
  @spec check(String.t(), keyword()) :: {:ok, anticipation()} | {:error, term()}
  def check(agent_id, opts \\ []) do
    config = get_config(agent_id)
    threshold = Keyword.get(opts, :relevance_threshold, config.relevance_threshold)
    max_results = Keyword.get(opts, :max_results, config.max_per_check)
    lookback = Keyword.get(opts, :lookback_turns, config.lookback_turns)

    # Emit signal that we're starting
    Signals.emit_preconscious_check(agent_id)

    with {:ok, context} <- extract_context(agent_id, lookback: lookback),
         {:ok, memories} <- search_memories(agent_id, context, threshold, max_results) do
      anticipation = build_anticipation(context, memories)

      # Emit signal if we found relevant memories
      if memories != [] do
        Signals.emit_preconscious_surfaced(agent_id, anticipation, length(memories))
      end

      {:ok, anticipation}
    end
  end

  # ============================================================================
  # Context Extraction
  # ============================================================================

  @doc """
  Extract searchable context from recent conversation.

  Looks at WorkingMemory for recent thoughts and active goals,
  then identifies key topics and themes to search for.

  ## Options

  - `:lookback` - Number of recent thoughts to consider (default: 5)
  """
  @spec extract_context(String.t(), keyword()) :: {:ok, context()} | {:error, term()}
  def extract_context(agent_id, opts \\ []) do
    lookback = Keyword.get(opts, :lookback, @default_lookback_turns)

    case get_working_memory(agent_id) do
      nil ->
        # No working memory yet - nothing to anticipate
        {:ok, empty_context()}

      wm ->
        # Get recent thoughts and goals
        thoughts = wm.recent_thoughts |> Enum.take(lookback)
        goals = wm.active_goals

        if thoughts == [] and goals == [] do
          {:ok, empty_context()}
        else
          # Extract topics from thoughts
          topics = extract_topics(thoughts)

          # Build a combined search query
          combined_query = build_search_query(topics, goals)

          context = %{
            topics: topics,
            goals: goals,
            combined_query: combined_query
          }

          {:ok, context}
        end
    end
  end

  # ============================================================================
  # Configuration
  # ============================================================================

  @doc """
  Configure preconscious sensitivity for an agent.

  ## Options

  - `:relevance_threshold` - Minimum similarity to include (0.0-1.0, default: 0.4)
  - `:max_per_check` - Maximum proposals per check (1-10, default: 3)
  - `:lookback_turns` - Number of recent thoughts to consider (1-20, default: 5)
  """
  @spec configure(String.t(), keyword()) :: :ok | {:error, term()}
  def configure(agent_id, opts) do
    ensure_config_table()

    current = get_config(agent_id)

    new_config = %{
      relevance_threshold:
        validate_threshold(Keyword.get(opts, :relevance_threshold, current.relevance_threshold)),
      max_per_check:
        validate_max_per_check(Keyword.get(opts, :max_per_check, current.max_per_check)),
      lookback_turns:
        validate_lookback(Keyword.get(opts, :lookback_turns, current.lookback_turns))
    }

    :ets.insert(@config_ets, {agent_id, new_config})
    :ok
  end

  @doc """
  Get current configuration for an agent.
  """
  @spec get_config(String.t()) :: map()
  def get_config(agent_id) do
    ensure_config_table()

    case :ets.lookup(@config_ets, agent_id) do
      [{^agent_id, config}] ->
        config

      [] ->
        # Return defaults from application config
        %{
          relevance_threshold: Application.get_env(:arbor_memory, :preconscious_threshold, @default_threshold),
          max_per_check: Application.get_env(:arbor_memory, :preconscious_max_per_check, @default_max_per_check),
          lookback_turns: Application.get_env(:arbor_memory, :preconscious_lookback_turns, @default_lookback_turns)
        }
    end
  end

  # ============================================================================
  # Proposal Creation
  # ============================================================================

  @doc """
  Create proposals from anticipation results.

  Called by BackgroundChecks to convert preconscious results into
  proposals that can be reviewed by the agent.
  """
  @spec create_proposals(String.t(), anticipation()) :: {:ok, [Proposal.t()]}
  def create_proposals(agent_id, anticipation) do
    proposals =
      anticipation.memories
      |> Enum.map(fn memory ->
        data = %{
          content: memory.content,
          confidence: memory.similarity,
          source: "preconscious",
          evidence: [anticipation.context_summary],
          metadata: %{
            memory_id: memory.id,
            query_used: anticipation.query_used
          }
        }

        case Proposal.create(agent_id, :preconscious, data) do
          {:ok, proposal} -> proposal
          {:error, _} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, proposals}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp empty_context do
    %{
      topics: [],
      goals: [],
      combined_query: ""
    }
  end

  defp extract_topics(thoughts) do
    # Simple topic extraction: take significant words from thoughts
    # In Phase 7b, this could use LLM-based extraction
    thoughts
    |> Enum.flat_map(&tokenize_thought/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_word, count} -> count end, :desc)
    |> Enum.take(5)
    |> Enum.map(fn {word, _count} -> word end)
  end

  defp tokenize_thought(thought) do
    # Extract significant words (simple tokenization)
    thought
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split()
    |> Enum.reject(&stop_word?/1)
    |> Enum.filter(&(String.length(&1) > 3))
  end

  defp stop_word?(word) do
    word in ~w(
      the a an is are was were be been being
      have has had do does did will would could should
      may might can this that these those
      and or but if then else when where what which who
      how why all any both each few more most other some such
      no not only own same so than too very just
      about above after again against all am at be before
      between but by down during for from further
      here in into it its itself let me my myself now
      of off on once only or out over own
      same she so some such than that the their them
      then there these they this those through to too
      under until up very was we were what when where
      which while who with would you your
    )
  end

  defp build_search_query(topics, goals) do
    # Combine topics and goals into a search query
    all_terms = topics ++ Enum.flat_map(goals, &tokenize_thought/1)

    all_terms
    |> Enum.uniq()
    |> Enum.take(10)
    |> Enum.join(" ")
  end

  defp search_memories(agent_id, context, threshold, max_results) do
    if context.combined_query == "" do
      {:ok, []}
    else
      case IndexSupervisor.get_index(agent_id) do
        {:ok, pid} ->
          Index.recall(pid, context.combined_query,
            threshold: threshold,
            limit: max_results
          )

        {:error, :not_found} ->
          # No index initialized - that's OK, just return empty
          {:ok, []}
      end
    end
  end

  defp build_anticipation(context, memories) do
    relevance_score =
      if memories == [] do
        0.0
      else
        memories
        |> Enum.map(& &1.similarity)
        |> Enum.sum()
        |> Kernel./(length(memories))
      end

    context_summary =
      if context.topics == [] and context.goals == [] do
        "No active context"
      else
        topic_part = if context.topics != [], do: "Topics: #{Enum.join(context.topics, ", ")}", else: ""
        goal_part = if context.goals != [], do: "Goals: #{Enum.join(context.goals, ", ")}", else: ""

        [topic_part, goal_part]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("; ")
      end

    %{
      memories: memories,
      query_used: context.combined_query,
      relevance_score: relevance_score,
      context_summary: context_summary
    }
  end

  defp get_working_memory(agent_id) do
    # Access ETS directly to avoid dependency on facade
    case :ets.lookup(:arbor_working_memory, agent_id) do
      [{^agent_id, wm}] -> wm
      [] -> nil
    end
  end

  defp ensure_config_table do
    if :ets.whereis(@config_ets) == :undefined do
      try do
        :ets.new(@config_ets, [:named_table, :public, :set])
      rescue
        ArgumentError ->
          # Table was created by another process
          :ok
      end
    end
  end

  # Validation helpers

  defp validate_threshold(threshold) when is_number(threshold) do
    threshold |> max(0.0) |> min(1.0)
  end
  defp validate_threshold(_), do: @default_threshold

  defp validate_max_per_check(max) when is_integer(max) do
    max |> max(1) |> min(10)
  end
  defp validate_max_per_check(_), do: @default_max_per_check

  defp validate_lookback(lookback) when is_integer(lookback) do
    lookback |> max(1) |> min(20)
  end
  defp validate_lookback(_), do: @default_lookback_turns
end
