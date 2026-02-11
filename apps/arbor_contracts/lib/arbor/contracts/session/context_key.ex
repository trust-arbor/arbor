defmodule Arbor.Contracts.Session.ContextKey do
  @moduledoc """
  Namespace conventions for Engine context keys used in Session-as-DOT execution.

  Context keys are dot-separated strings that prevent typo bugs and ensure
  DOT condition routing matches handler output. Use these functions instead
  of raw strings in handlers and condition edges.

  ## Namespaces

  - `session.*` - Session state (input, output, agent identity, memory)
  - `llm.*` - LLM response data (content, tool calls, response type)
  - `system.*` - System/infrastructure concerns (reserved for future use)

  ## Usage

      # In a handler:
      alias Arbor.Contracts.Session.ContextKey

      def handle(context, _node) do
        agent_id = Map.get(context, ContextKey.agent_id())
        # ... process ...
        Map.put(context, ContextKey.response(), response)
      end

      # In condition edge validation:
      ContextKey.valid_namespace?("session.input")  # => true
      ContextKey.valid_namespace?("foo.bar")         # => false
  """

  # ============================================================================
  # Namespace Prefixes
  # ============================================================================

  @session_ns "session"
  @llm_ns "llm"
  @system_ns "system"

  @valid_namespaces [@session_ns, @llm_ns, @system_ns]

  # ============================================================================
  # Session Keys — Identity & Configuration
  # ============================================================================

  @doc "Unique session identifier."
  @spec session_id() :: String.t()
  def session_id, do: "#{@session_ns}.id"

  @doc "Agent identifier owning this session."
  @spec agent_id() :: String.t()
  def agent_id, do: "#{@session_ns}.agent_id"

  @doc "Trust tier of the agent (e.g., :established, :trusted_partner)."
  @spec trust_tier() :: String.t()
  def trust_tier, do: "#{@session_ns}.trust_tier"

  @doc "Session type (e.g., :chat, :heartbeat, :query)."
  @spec session_type() :: String.t()
  def session_type, do: "#{@session_ns}.session_type"

  @doc "Distributed trace identifier for observability."
  @spec trace_id() :: String.t()
  def trace_id, do: "#{@session_ns}.trace_id"

  @doc "Session configuration map."
  @spec config() :: String.t()
  def config, do: "#{@session_ns}.config"

  @doc "Signal topic for session-scoped signal emission."
  @spec signal_topic() :: String.t()
  def signal_topic, do: "#{@session_ns}.signal_topic"

  @doc "Current session phase (e.g., :initializing, :processing, :finalizing)."
  @spec phase() :: String.t()
  def phase, do: "#{@session_ns}.phase"

  # ============================================================================
  # Session Keys — Input & Turn State
  # ============================================================================

  @doc "User input for the current turn."
  @spec input() :: String.t()
  def input, do: "#{@session_ns}.input"

  @doc "Input type discriminator (e.g., :text, :tool_result, :system)."
  @spec input_type() :: String.t()
  def input_type, do: "#{@session_ns}.input_type"

  @doc "Accumulated message history."
  @spec messages() :: String.t()
  def messages, do: "#{@session_ns}.messages"

  @doc "Number of completed turns in this session."
  @spec turn_count() :: String.t()
  def turn_count, do: "#{@session_ns}.turn_count"

  @doc "Current cognitive mode (e.g., :conversational, :goal_pursuit, :consolidation)."
  @spec cognitive_mode() :: String.t()
  def cognitive_mode, do: "#{@session_ns}.cognitive_mode"

  @doc "Aggregated turn data for the current turn."
  @spec turn_data() :: String.t()
  def turn_data, do: "#{@session_ns}.turn_data"

  # ============================================================================
  # Session Keys — Memory Context
  # ============================================================================

  @doc "Current working memory snapshot."
  @spec working_memory() :: String.t()
  def working_memory, do: "#{@session_ns}.working_memory"

  @doc "Active goals for the agent."
  @spec goals() :: String.t()
  def goals, do: "#{@session_ns}.goals"

  @doc "Memories recalled for the current turn."
  @spec recalled_memories() :: String.t()
  def recalled_memories, do: "#{@session_ns}.recalled_memories"

  # ============================================================================
  # Session Keys — Output & Results
  # ============================================================================

  @doc "Final response from the session turn."
  @spec response() :: String.t()
  def response, do: "#{@session_ns}.response"

  @doc "Actions extracted from LLM response."
  @spec actions() :: String.t()
  def actions, do: "#{@session_ns}.actions"

  @doc "Goal updates extracted from LLM response."
  @spec goal_updates() :: String.t()
  def goal_updates, do: "#{@session_ns}.goal_updates"

  @doc "New goals extracted from LLM response."
  @spec new_goals() :: String.t()
  def new_goals, do: "#{@session_ns}.new_goals"

  @doc "Memory notes extracted from LLM response."
  @spec memory_notes() :: String.t()
  def memory_notes, do: "#{@session_ns}.memory_notes"

  @doc "Results from tool executions in this turn."
  @spec tool_results() :: String.t()
  def tool_results, do: "#{@session_ns}.tool_results"

  # ============================================================================
  # Session Keys — Processing State
  # ============================================================================

  @doc "Last checkpoint identifier for crash recovery."
  @spec last_checkpoint() :: String.t()
  def last_checkpoint, do: "#{@session_ns}.last_checkpoint"

  @doc "Whether actions have been routed to the executor."
  @spec actions_routed() :: String.t()
  def actions_routed, do: "#{@session_ns}.actions_routed"

  @doc "Whether goals have been updated in the goal store."
  @spec goals_updated() :: String.t()
  def goals_updated, do: "#{@session_ns}.goals_updated"

  @doc "Results from background checks (memory health, consolidation)."
  @spec background_check_results() :: String.t()
  def background_check_results, do: "#{@session_ns}.background_check_results"

  @doc "Whether the session turn is blocked (e.g., by reflex or capability denial)."
  @spec blocked() :: String.t()
  def blocked, do: "#{@session_ns}.blocked"

  # ============================================================================
  # LLM Keys
  # ============================================================================

  @doc "LLM response type (e.g., :text, :tool_use, :mixed)."
  @spec llm_response_type() :: String.t()
  def llm_response_type, do: "#{@llm_ns}.response_type"

  @doc "Text content from LLM response."
  @spec llm_content() :: String.t()
  def llm_content, do: "#{@llm_ns}.content"

  @doc "Tool call requests from LLM response."
  @spec llm_tool_calls() :: String.t()
  def llm_tool_calls, do: "#{@llm_ns}.tool_calls"

  # ============================================================================
  # All Keys (for validation and introspection)
  # ============================================================================

  @all_keys [
    "session.id",
    "session.agent_id",
    "session.trust_tier",
    "session.input",
    "session.input_type",
    "session.messages",
    "session.turn_count",
    "session.working_memory",
    "session.goals",
    "session.cognitive_mode",
    "session.phase",
    "session.session_type",
    "session.trace_id",
    "session.config",
    "session.signal_topic",
    "session.response",
    "session.recalled_memories",
    "session.actions",
    "session.goal_updates",
    "session.new_goals",
    "session.memory_notes",
    "session.tool_results",
    "session.last_checkpoint",
    "session.actions_routed",
    "session.goals_updated",
    "session.background_check_results",
    "session.blocked",
    "session.turn_data",
    "llm.response_type",
    "llm.content",
    "llm.tool_calls"
  ]

  @doc """
  Returns a list of all defined context keys.

  Useful for validation, documentation, and introspection.
  """
  @spec all_keys() :: [String.t()]
  def all_keys, do: @all_keys

  # ============================================================================
  # Validation
  # ============================================================================

  @doc """
  Checks whether a key uses a recognized namespace prefix.

  ## Examples

      iex> Arbor.Contracts.Session.ContextKey.valid_namespace?("session.input")
      true

      iex> Arbor.Contracts.Session.ContextKey.valid_namespace?("llm.content")
      true

      iex> Arbor.Contracts.Session.ContextKey.valid_namespace?("unknown.key")
      false

      iex> Arbor.Contracts.Session.ContextKey.valid_namespace?("no_dot")
      false
  """
  @spec valid_namespace?(String.t()) :: boolean()
  def valid_namespace?(key) when is_binary(key) do
    case String.split(key, ".", parts: 2) do
      [namespace, _rest] -> namespace in @valid_namespaces
      _ -> false
    end
  end

  def valid_namespace?(_), do: false

  @doc """
  Validates that a key uses a recognized namespace prefix.

  Returns `{:ok, key}` if the namespace is valid, `{:error, :unknown_namespace}` otherwise.

  ## Examples

      iex> Arbor.Contracts.Session.ContextKey.validate_key("session.input")
      {:ok, "session.input"}

      iex> Arbor.Contracts.Session.ContextKey.validate_key("bad.key")
      {:error, :unknown_namespace}
  """
  @spec validate_key(String.t()) :: {:ok, String.t()} | {:error, :unknown_namespace}
  def validate_key(key) when is_binary(key) do
    if valid_namespace?(key) do
      {:ok, key}
    else
      {:error, :unknown_namespace}
    end
  end

  def validate_key(_), do: {:error, :unknown_namespace}
end
