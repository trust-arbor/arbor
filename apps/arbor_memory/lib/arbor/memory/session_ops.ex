defmodule Arbor.Memory.SessionOps do
  @moduledoc """
  Sub-facade for session-scoped memory operations.

  Handles working memory, context windows, retrieval, summarization,
  chat history, thinking, code store, proposals, action patterns,
  background checks, preconscious, and introspection.

  This module is not intended to be called directly by external consumers.
  Use `Arbor.Memory` as the public API.
  """

  alias Arbor.Memory.{
    ActionPatterns,
    BackgroundChecks,
    ChatHistory,
    CodeStore,
    ContextWindow,
    Patterns,
    Preconscious,
    Proposal,
    Retrieval,
    Summarizer,
    Thinking,
    TokenBudget,
    WorkingMemory,
    WorkingMemoryStore
  }

  # ============================================================================
  # Working Memory (Phase 2)
  # ============================================================================

  @doc "Get working memory for an agent."
  defdelegate get_working_memory(agent_id), to: WorkingMemoryStore

  @doc "Save working memory for an agent."
  defdelegate save_working_memory(agent_id, working_memory), to: WorkingMemoryStore

  @doc "Load working memory for an agent."
  defdelegate load_working_memory(agent_id, opts \\ []), to: WorkingMemoryStore

  @doc "Delete working memory for an agent."
  defdelegate delete_working_memory(agent_id), to: WorkingMemoryStore

  # ============================================================================
  # Working Memory Serialization
  # ============================================================================

  @doc """
  Serialize a working memory struct to a JSON-safe map.
  """
  @spec serialize_working_memory(WorkingMemory.t()) :: map()
  defdelegate serialize_working_memory(wm), to: WorkingMemory, as: :serialize

  @doc """
  Deserialize a map back into a WorkingMemory struct.
  """
  @spec deserialize_working_memory(map()) :: WorkingMemory.t()
  defdelegate deserialize_working_memory(data), to: WorkingMemory, as: :deserialize

  # ============================================================================
  # Context Window
  # ============================================================================

  @doc """
  Create a new context window for an agent.

  ## Options

  - `:max_tokens` -- Maximum tokens (default: 10_000)
  - `:summary_threshold` -- Threshold for summarization (default: 0.7)
  - `:preset` -- Preset name (:balanced, :conservative, :expansive)
  """
  @spec new_context_window(String.t(), keyword()) :: ContextWindow.t()
  defdelegate new_context_window(agent_id, opts \\ []), to: ContextWindow, as: :new

  @doc """
  Add an entry to a context window.

  ## Entry Types

  - `:message` -- Conversation message
  - `:system` -- System prompt section
  - `:summary` -- Summarized content
  """
  @spec add_context_entry(ContextWindow.t(), atom(), String.t()) :: ContextWindow.t()
  defdelegate add_context_entry(window, type, content), to: ContextWindow, as: :add_entry

  @doc """
  Serialize a context window to a JSON-safe map.
  """
  @spec serialize_context_window(ContextWindow.t()) :: map()
  defdelegate serialize_context_window(window), to: ContextWindow, as: :serialize

  @doc """
  Deserialize a map back into a ContextWindow struct.
  """
  @spec deserialize_context_window(map()) :: ContextWindow.t()
  defdelegate deserialize_context_window(data), to: ContextWindow, as: :deserialize

  @doc """
  Check if a context window should be summarized based on token usage.
  """
  @spec context_should_summarize?(ContextWindow.t()) :: boolean()
  defdelegate context_should_summarize?(window), to: ContextWindow, as: :should_summarize?

  @doc """
  Get the number of entries in a context window.
  """
  @spec context_entry_count(ContextWindow.t()) :: non_neg_integer()
  defdelegate context_entry_count(window), to: ContextWindow, as: :entry_count

  @doc """
  Convert a context window to formatted prompt text.
  """
  @spec context_to_prompt_text(ContextWindow.t()) :: String.t()
  defdelegate context_to_prompt_text(window), to: ContextWindow, as: :to_prompt_text

  # ============================================================================
  # Retrieval (Phase 2)
  # ============================================================================

  @doc """
  Semantic recall with human-readable formatting for LLM context injection.

  Delegates to `Arbor.Memory.Retrieval.let_me_recall/3`.

  ## Options

  - `:limit` - Max results (default: 10)
  - `:threshold` - Min similarity (default: 0.3)
  - `:max_tokens` - Max tokens in output (default: 500)
  - `:type` / `:types` - Type filtering

  ## Examples

      {:ok, text} = Arbor.Memory.let_me_recall("agent_001", "elixir patterns")
  """
  @spec let_me_recall(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defdelegate let_me_recall(agent_id, query, opts \\ []), to: Retrieval

  # ============================================================================
  # Context Building (Phase 2)
  # ============================================================================

  @doc """
  Build combined context for LLM injection.

  Combines working memory and optional relationship context into
  formatted text suitable for system prompt injection.

  ## Options

  - `:max_thoughts` - Max recent thoughts to include (default: 5)
  - `:include_relationship` - Include relationship context (default: true)

  ## Examples

      wm = Arbor.Memory.load_working_memory("agent_001")
      context = Arbor.Memory.build_context(wm)
      context = Arbor.Memory.build_context(wm, relationship: "Close collaborator...")
  """
  @spec build_context(WorkingMemory.t(), keyword()) :: String.t()
  def build_context(working_memory, opts \\ []) do
    relationship = Keyword.get(opts, :relationship)

    wm =
      if relationship do
        WorkingMemory.set_relationship_context(working_memory, relationship)
      else
        working_memory
      end

    WorkingMemory.to_prompt_text(wm, opts)
  end

  # ============================================================================
  # Summarization (Phase 2)
  # ============================================================================

  @doc """
  Summarize text with complexity-based model routing.

  Delegates to `Arbor.Memory.Summarizer.summarize/2`.

  Note: Returns `{:error, :llm_not_configured}` until arbor_ai integration.

  ## Examples

      {:error, {:llm_not_configured, info}} = Arbor.Memory.summarize("agent_001", text)
  """
  @spec summarize(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def summarize(_agent_id, text, opts \\ []) do
    Summarizer.summarize(text, opts)
  end

  @doc """
  Assess complexity of text.

  Delegates to `Arbor.Memory.Summarizer.assess_complexity/1`.

  ## Examples

      :moderate = Arbor.Memory.assess_complexity("Some technical text...")
  """
  @spec assess_complexity(String.t()) :: Summarizer.complexity()
  defdelegate assess_complexity(text), to: Summarizer

  # ============================================================================
  # Token Budget Delegation
  # ============================================================================

  @doc """
  Resolve a token budget specification.

  See `Arbor.Memory.TokenBudget.resolve/2` for details.
  """
  defdelegate resolve_budget(budget, context_size), to: TokenBudget, as: :resolve

  @doc """
  Resolve a token budget for a specific model.

  See `Arbor.Memory.TokenBudget.resolve_for_model/2` for details.
  """
  defdelegate resolve_budget_for_model(budget, model_id), to: TokenBudget, as: :resolve_for_model

  @doc """
  Estimate tokens in text.

  See `Arbor.Memory.TokenBudget.estimate_tokens/1` for details.
  """
  defdelegate estimate_tokens(text), to: TokenBudget

  @doc """
  Get model context size.

  See `Arbor.Memory.TokenBudget.model_context_size/1` for details.
  """
  defdelegate model_context_size(model_id), to: TokenBudget

  # ============================================================================
  # Relationships (Phase 3)
  # ============================================================================

  @doc "Get a relationship by ID."
  defdelegate get_relationship(agent_id, relationship_id),
    to: Arbor.Memory.RelationshipStore,
    as: :get_with_tracking

  @doc "Get a relationship by name."
  defdelegate get_relationship_by_name(agent_id, name),
    to: Arbor.Memory.RelationshipStore,
    as: :get_by_name_with_tracking

  @doc "Get the primary relationship (highest salience)."
  defdelegate get_primary_relationship(agent_id),
    to: Arbor.Memory.RelationshipStore,
    as: :get_primary_with_tracking

  @doc "Save a relationship."
  defdelegate save_relationship(agent_id, relationship),
    to: Arbor.Memory.RelationshipStore,
    as: :save

  @doc "Add a key moment to a relationship."
  defdelegate add_moment(agent_id, relationship_id, summary, opts \\ []),
    to: Arbor.Memory.RelationshipStore

  @doc "List all relationships for an agent."
  defdelegate list_relationships(agent_id, opts \\ []),
    to: Arbor.Memory.RelationshipStore,
    as: :list

  @doc "Delete a relationship."
  defdelegate delete_relationship(agent_id, relationship_id),
    to: Arbor.Memory.RelationshipStore,
    as: :delete

  # ============================================================================
  # Background Checks (Phase 4)
  # ============================================================================

  @doc """
  Run all background checks for an agent.

  Call this during heartbeats or on scheduled intervals. Returns:
  - `:actions` - Things that should happen now (e.g., run consolidation)
  - `:warnings` - Things the agent should know about
  - `:suggestions` - Proposals created for agent review

  ## Options

  - `:action_history` - List of recent tool actions for pattern detection
  - `:last_consolidation` - DateTime of last consolidation
  - `:skip_consolidation` - Skip consolidation check (default: false)
  - `:skip_patterns` - Skip action pattern detection (default: false)
  - `:skip_insights` - Skip insight detection (default: false)

  ## Examples

      result = Arbor.Memory.run_background_checks("agent_001")
      result = Arbor.Memory.run_background_checks("agent_001", action_history: history)
  """
  @spec run_background_checks(String.t(), keyword()) :: BackgroundChecks.check_result()
  defdelegate run_background_checks(agent_id, opts \\ []), to: BackgroundChecks, as: :run

  @doc """
  Analyze memory patterns for an agent.

  Returns comprehensive analysis including type distribution, access
  concentration (Gini coefficient), decay risk, and unused pins.

  ## Examples

      analysis = Arbor.Memory.analyze_memory_patterns("agent_001")
  """
  @spec analyze_memory_patterns(String.t()) :: Patterns.analysis() | {:error, term()}
  defdelegate analyze_memory_patterns(agent_id), to: Patterns, as: :analyze

  # ============================================================================
  # Proposals (Phase 4)
  # ============================================================================

  @doc """
  Get a specific proposal by ID.

  ## Examples

      {:ok, proposal} = Arbor.Memory.get_proposal("agent_001", "prop_abc123")
  """
  @spec get_proposal(String.t(), String.t()) :: {:ok, Proposal.t()} | {:error, :not_found}
  defdelegate get_proposal(agent_id, proposal_id), to: Proposal, as: :get

  @doc """
  Create a proposal for agent review.

  ## Types

  - `:fact` - Auto-extracted facts
  - `:insight` - Behavioral insights
  - `:learning` - Tool usage patterns
  - `:pattern` - Recurring sequences

  ## Examples

      {:ok, proposal} = Arbor.Memory.create_proposal("agent_001", :fact, %{
        content: "User prefers dark mode",
        confidence: 0.8
      })
  """
  @spec create_proposal(String.t(), Proposal.proposal_type(), map()) ::
          {:ok, Proposal.t()} | {:error, term()}
  defdelegate create_proposal(agent_id, type, data), to: Proposal, as: :create

  @doc """
  List pending proposals for an agent.

  ## Options

  - `:type` - Filter by proposal type
  - `:limit` - Maximum proposals to return
  - `:sort_by` - Sort by: `:created_at` (default), `:confidence`

  ## Examples

      {:ok, proposals} = Arbor.Memory.get_proposals("agent_001")
      {:ok, facts} = Arbor.Memory.get_proposals("agent_001", type: :fact)
  """
  @spec get_proposals(String.t(), keyword()) :: {:ok, [Proposal.t()]}
  defdelegate get_proposals(agent_id, opts \\ []), to: Proposal, as: :list_pending

  @doc """
  Accept a proposal and integrate it into the knowledge graph.

  The proposal content is added as a knowledge node with a confidence boost.

  ## Examples

      {:ok, node_id} = Arbor.Memory.accept_proposal("agent_001", proposal_id)
  """
  @spec accept_proposal(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defdelegate accept_proposal(agent_id, proposal_id), to: Proposal, as: :accept

  @doc """
  Reject a proposal.

  The proposal is marked as rejected for calibration purposes.

  ## Options

  - `:reason` - Why the proposal was rejected

  ## Examples

      :ok = Arbor.Memory.reject_proposal("agent_001", proposal_id)
      :ok = Arbor.Memory.reject_proposal("agent_001", proposal_id, reason: "Not accurate")
  """
  @spec reject_proposal(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate reject_proposal(agent_id, proposal_id, opts \\ []), to: Proposal, as: :reject

  @doc """
  Defer a proposal for later review.

  ## Examples

      :ok = Arbor.Memory.defer_proposal("agent_001", proposal_id)
  """
  @spec defer_proposal(String.t(), String.t()) :: :ok | {:error, term()}
  defdelegate defer_proposal(agent_id, proposal_id), to: Proposal, as: :defer

  @doc """
  Accept all pending proposals, optionally filtered by type.

  ## Examples

      {:ok, results} = Arbor.Memory.accept_all_proposals("agent_001")
      {:ok, results} = Arbor.Memory.accept_all_proposals("agent_001", :fact)
  """
  @spec accept_all_proposals(String.t(), Proposal.proposal_type() | nil) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  defdelegate accept_all_proposals(agent_id, type \\ nil), to: Proposal, as: :accept_all

  @doc """
  Get proposal statistics for an agent.

  ## Examples

      stats = Arbor.Memory.proposal_stats("agent_001")
  """
  @spec proposal_stats(String.t()) :: map()
  defdelegate proposal_stats(agent_id), to: Proposal, as: :stats

  # ============================================================================
  # Action Patterns (Phase 4)
  # ============================================================================

  @doc """
  Analyze action history for patterns.

  Detects repeated sequences, failure-then-success patterns, and
  long sequences in tool usage history.

  ## Options

  - `:min_occurrences` - Minimum times a sequence must occur (default: 3)

  ## Examples

      patterns = Arbor.Memory.analyze_action_patterns(action_history)
  """
  @spec analyze_action_patterns([ActionPatterns.action()], keyword()) :: [
          ActionPatterns.pattern()
        ]
  defdelegate analyze_action_patterns(action_history, opts \\ []),
    to: ActionPatterns,
    as: :analyze

  @doc """
  Analyze action history and queue learnings as proposals.

  ## Examples

      {:ok, proposals} = Arbor.Memory.analyze_and_queue_learnings("agent_001", history)
  """
  @spec analyze_and_queue_learnings(String.t(), [ActionPatterns.action()], keyword()) ::
          {:ok, [Proposal.t()]} | {:error, term()}
  defdelegate analyze_and_queue_learnings(agent_id, history, opts \\ []),
    to: ActionPatterns,
    as: :analyze_and_queue

  # ============================================================================
  # Preconscious (Phase 7)
  # ============================================================================

  @doc """
  Run a preconscious anticipation check.

  Analyzes the agent's current conversation context (thoughts, goals) and
  surfaces relevant long-term memories that might be useful.

  ## Options

  - `:relevance_threshold` - Minimum similarity to include (default: 0.4)
  - `:max_results` - Maximum memories to return (default: 3)
  - `:lookback_turns` - Number of recent thoughts to consider (default: 5)

  ## Examples

      {:ok, anticipation} = Arbor.Memory.run_preconscious_check("agent_001")
  """
  @spec run_preconscious_check(String.t(), keyword()) ::
          {:ok, Preconscious.anticipation()} | {:error, term()}
  defdelegate run_preconscious_check(agent_id, opts \\ []), to: Preconscious, as: :check

  @doc """
  Configure preconscious sensitivity for an agent.

  ## Options

  - `:relevance_threshold` - Minimum similarity to include (0.0-1.0)
  - `:max_per_check` - Maximum proposals per check (1-10)
  - `:lookback_turns` - Number of recent thoughts to consider (1-20)

  ## Examples

      :ok = Arbor.Memory.configure_preconscious("agent_001", relevance_threshold: 0.5)
  """
  @spec configure_preconscious(String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate configure_preconscious(agent_id, opts), to: Preconscious, as: :configure

  # ============================================================================
  # Chat History (Seed/Host Phase 3)
  # ============================================================================

  @doc "Append a chat message to an agent's conversation history."
  defdelegate append_chat_message(agent_id, msg), to: ChatHistory, as: :append

  @doc "Load chat history for an agent, sorted chronologically."
  defdelegate load_chat_history(agent_id), to: ChatHistory, as: :load

  @doc "Clear all chat history for an agent."
  defdelegate clear_chat_history(agent_id), to: ChatHistory, as: :clear

  # ============================================================================
  # read_self -- Live System Introspection
  # ============================================================================

  @doc "Aggregate live stats from the memory system for a given aspect."
  defdelegate read_self(agent_id, aspect \\ :all, opts \\ []),
    to: Arbor.Memory.Introspection

  # ============================================================================
  # Thinking (Seed/Host Phase 3)
  # ============================================================================

  @doc """
  Record a thinking block for an agent.

  ## Options

  - `:significant` -- flag for reflection (default: false)
  - `:metadata` -- additional metadata
  """
  @spec record_thinking(String.t(), String.t(), keyword()) :: {:ok, map()}
  defdelegate record_thinking(agent_id, text, opts \\ []), to: Thinking

  @doc """
  Get recent thinking entries for an agent.

  ## Options

  - `:limit` -- max entries (default: 10)
  - `:since` -- only entries after this DateTime
  - `:significant_only` -- only significant entries (default: false)
  """
  @spec recent_thinking(String.t(), keyword()) :: [map()]
  defdelegate recent_thinking(agent_id, opts \\ []), to: Thinking

  @doc """
  Extract thinking content from an LLM response.

  Supports multiple providers: `:anthropic`, `:deepseek`, `:openai`, `:generic`.

  ## Options

  - `:fallback_to_generic` -- try generic extraction on failure (default: false)

  ## Returns

  - `{:ok, text}` -- extracted thinking text
  - `{:none, reason}` -- no thinking found (e.g., `:no_thinking_blocks`, `:hidden_reasoning`)
  """
  @spec extract_thinking(map(), atom(), keyword()) :: {:ok, String.t()} | {:none, atom()}
  def extract_thinking(response, provider, opts \\ []) do
    Thinking.extract(response, provider, opts)
  end

  @doc """
  Extract thinking from an LLM response and record it for the agent.

  Combines `extract/3` and `record_thinking/3`. Automatically flags
  identity-affecting thinking as significant.

  ## Returns

  - `{:ok, thinking_entry}` -- extracted and recorded
  - `{:none, reason}` -- no thinking found
  """
  @spec extract_and_record_thinking(String.t(), map(), atom(), keyword()) ::
          {:ok, map()} | {:none, atom()}
  def extract_and_record_thinking(agent_id, response, provider, opts \\ []) do
    Thinking.extract_and_record(agent_id, response, provider, opts)
  end

  # ============================================================================
  # CodeStore (Seed/Host Phase 3)
  # ============================================================================

  @doc """
  Store a code pattern for an agent.

  ## Required Fields

  - `:code` -- the code text
  - `:language` -- programming language
  - `:purpose` -- description of what it does
  """
  @spec store_code(String.t(), map()) :: {:ok, map()} | {:error, :missing_fields}
  defdelegate store_code(agent_id, params), to: CodeStore, as: :store

  @doc """
  Find code patterns by purpose (keyword search).
  """
  @spec find_code_by_purpose(String.t(), String.t()) :: [map()]
  defdelegate find_code_by_purpose(agent_id, query), to: CodeStore, as: :find_by_purpose

  @doc """
  Get a specific code pattern by ID.

  ## Examples

      {:ok, entry} = Arbor.Memory.get_code("agent_001", "code_abc123")
  """
  @spec get_code(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_code(agent_id, entry_id), to: CodeStore, as: :get

  @doc """
  Delete a specific code pattern.

  ## Examples

      :ok = Arbor.Memory.delete_code("agent_001", "code_abc123")
  """
  @spec delete_code(String.t(), String.t()) :: :ok
  defdelegate delete_code(agent_id, entry_id), to: CodeStore, as: :delete

  @doc """
  List all code patterns for an agent.

  ## Options

  - `:language` -- filter by language
  - `:limit` -- max results
  """
  @spec list_code(String.t(), keyword()) :: [map()]
  defdelegate list_code(agent_id, opts \\ []), to: CodeStore, as: :list
end
