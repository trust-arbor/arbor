defmodule Arbor.Contracts.Session.Adapter do
  @moduledoc """
  Behaviour for Session adapters — pluggable functions bridging Session graph
  execution to real infrastructure.

  Each adapter implements a single responsibility (LLM calls, tool dispatch,
  memory operations, etc.) and declares its context key dependencies so the
  Session graph engine can validate wiring at startup rather than at runtime.

  ## Adapter Keys

  - `:llm_call` — invoke the LLM with messages and tools
  - `:tool_dispatch` — execute a tool action through the Executor
  - `:memory_recall` — retrieve relevant memories for context
  - `:memory_update` — persist new memories from the turn
  - `:checkpoint` — save/restore session state for crash recovery
  - `:route_actions` — dispatch extracted actions to the Executor
  - `:update_goals` — persist goal changes to the GoalStore
  - `:background_checks` — run memory health and consolidation checks
  - `:trust_tier_resolver` — resolve the agent's current trust tier

  ## Callbacks

  Required:
  - `key/0` — which adapter slot this module fills
  - `execute/2` — perform the adapter's operation
  - `required_context_keys/0` — context keys that must be present before execution
  - `produced_context_keys/0` — context keys this adapter writes after execution

  Optional:
  - `validate_config/1` — validate adapter-specific configuration at startup
  - `idempotent?/0` — whether `execute/2` is safe to retry (default: `false`)

  ## Example

      defmodule MyApp.Session.LLMAdapter do
        @behaviour Arbor.Contracts.Session.Adapter

        @impl true
        def key, do: :llm_call

        @impl true
        def execute(args, context) do
          messages = Map.fetch!(args, :messages)
          tools = Map.get(args, :tools, [])
          # ... call LLM provider ...
          {:ok, %{content: response, tool_calls: tool_calls}}
        end

        @impl true
        def required_context_keys do
          ["session.agent_id", "session.messages", "session.config"]
        end

        @impl true
        def produced_context_keys do
          ["llm.content", "llm.tool_calls", "llm.response_type"]
        end

        @impl true
        def validate_config(config) do
          if Map.has_key?(config, :provider), do: :ok, else: {:error, :missing_provider}
        end

        @impl true
        def idempotent?, do: false
      end
  """

  # ============================================================================
  # Types
  # ============================================================================

  @typedoc "Identifies which adapter slot a module fills."
  @type adapter_key ::
          :llm_call
          | :tool_dispatch
          | :memory_recall
          | :memory_update
          | :checkpoint
          | :route_actions
          | :update_goals
          | :background_checks
          | :trust_tier_resolver

  @typedoc "Map from adapter keys to adapter functions or modules."
  @type adapter_map :: %{optional(adapter_key()) => function()}

  @valid_adapter_keys [
    :llm_call,
    :tool_dispatch,
    :memory_recall,
    :memory_update,
    :checkpoint,
    :route_actions,
    :update_goals,
    :background_checks,
    :trust_tier_resolver
  ]

  # ============================================================================
  # Required Callbacks
  # ============================================================================

  @doc "Which adapter slot this module fills."
  @callback key() :: adapter_key()

  @doc """
  Execute the adapter's operation.

  Receives adapter-specific args and the current session context map.
  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @callback execute(args :: term(), context :: map()) :: {:ok, term()} | {:error, term()}

  @doc """
  Context keys that must be present before this adapter executes.

  Used by the Session graph engine to validate wiring at startup.
  Keys should use `Arbor.Contracts.Session.ContextKey` conventions.
  """
  @callback required_context_keys() :: [String.t()]

  @doc """
  Context keys this adapter writes after successful execution.

  Used by the Session graph engine to validate that downstream nodes
  will have the data they need.
  """
  @callback produced_context_keys() :: [String.t()]

  # ============================================================================
  # Optional Callbacks
  # ============================================================================

  @doc """
  Validate adapter-specific configuration at startup.

  Called during Session initialization so misconfigurations fail fast
  rather than at runtime during a turn.
  """
  @callback validate_config(config :: map()) :: :ok | {:error, term()}

  @doc """
  Whether `execute/2` is safe to retry on failure.

  Defaults to `false`. Adapters like `:checkpoint` and `:memory_recall`
  that perform pure reads can return `true` to enable automatic retry.
  """
  @callback idempotent?() :: boolean()

  @optional_callbacks [validate_config: 1, idempotent?: 0]

  # ============================================================================
  # Helpers
  # ============================================================================

  @doc """
  Returns the list of valid adapter keys.
  """
  @spec valid_adapter_keys() :: [adapter_key()]
  def valid_adapter_keys, do: @valid_adapter_keys

  @doc """
  Validates an adapter map, checking that all keys are valid adapter keys
  and all values are functions.

  Returns `{:ok, adapter_map}` if valid, or `{:error, errors}` with a list
  of error tuples describing each problem.

  ## Examples

      iex> Arbor.Contracts.Session.Adapter.validate_adapter_map(%{
      ...>   llm_call: &MyApp.llm/2,
      ...>   checkpoint: &MyApp.checkpoint/2
      ...> })
      {:ok, %{llm_call: &MyApp.llm/2, checkpoint: &MyApp.checkpoint/2}}

      iex> Arbor.Contracts.Session.Adapter.validate_adapter_map(%{llm_call: "not_a_function"})
      {:error, [{:not_a_function, :llm_call, "not_a_function"}]}

      iex> Arbor.Contracts.Session.Adapter.validate_adapter_map(%{bad_key: &Function.identity/1})
      {:error, [{:invalid_adapter_key, :bad_key}]}
  """
  @spec validate_adapter_map(adapter_map()) :: {:ok, adapter_map()} | {:error, [term()]}
  def validate_adapter_map(adapter_map) when is_map(adapter_map) do
    errors =
      Enum.reduce(adapter_map, [], fn {key, value}, acc ->
        cond do
          key not in @valid_adapter_keys ->
            [{:invalid_adapter_key, key} | acc]

          not is_function(value) ->
            [{:not_a_function, key, value} | acc]

          true ->
            acc
        end
      end)

    case errors do
      [] -> {:ok, adapter_map}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  def validate_adapter_map(not_a_map) do
    {:error, [{:not_a_map, not_a_map}]}
  end
end
