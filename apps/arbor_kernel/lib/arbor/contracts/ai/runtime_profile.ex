defmodule Arbor.Contracts.AI.RuntimeProfile do
  @moduledoc """
  Declarative profile of what a runtime adapter supports.

  Each implementation of `Arbor.AI.Runtime` declares its `profile/0` so
  the orchestrator, `mix arbor.doctor`, and the dashboard can answer:
  "if I run this turn on this runtime, what do I get and what do I lose?"

  Adopted verbatim from OpenClaw's eight-question runtime template
  (verified at `docs/concepts/agent-runtimes.md` in `~/code/openclaw`,
  HEAD `b579c0a6`) and restated as boolean fields plus an
  `unsupported_features` escape list.

  ## NOT to be confused with `Arbor.Contracts.AI.RuntimeContract`

  - `RuntimeContract` answers "is this runtime AVAILABLE on this system?"
    (env vars present, CLI binary on PATH, service responding to probes).
    Used by `mix arbor.doctor` for install diagnostics.
  - `RuntimeProfile` (this module) answers "what does this runtime SUPPORT?"
    Loop ownership, Jido actions, history mirroring, etc. Used by the
    runtime selection chain in `Arbor.AI.Runtime.Selector` and by
    operator-facing surfaces that show capability tradeoffs.

  Both are independent: a runtime can be unavailable (`RuntimeContract`
  check fails) but still declare a profile.

  ## The eight questions

  | Field | Question | Why it matters |
  |---|---|---|
  | `owns_model_loop` | Who owns the model loop? | Determines where retries, tool continuation, and final-answer decisions happen. |
  | `owns_thread_history` | Who owns canonical thread history? | Determines whether Session can edit history or only mirrors it. |
  | `supports_jido_actions` | Do Jido actions execute through this runtime? | Memory, sessions, capabilities, and Arbor-native tools depend on this. |
  | `supports_action_hooks` | Do action hooks fire? | Pre/post hooks, taint enforcement, capability checks live here. |
  | `supports_native_tools` | Do native shell/file tools work? | For `:arbor`: via `Arbor.Actions`. For CLI runtimes: depends on harness. |
  | `runs_context_engine` | Does the context engine run? | Memory + compaction depend on this. |
  | `exposes_compaction_data` | What compaction data is exposed? | Some plugins want notifications; others need kept/dropped metadata. |
  | `unsupported_features` | What is intentionally unsupported? | Operators should not assume `:arbor` equivalence where the CLI runtime owns more state. |

  ## Surface

  Returned by `Arbor.AI.Runtime` callback `profile/0`. Aggregated by the
  selector to compare two candidate runtimes, and rendered by
  `mix arbor.doctor` as a comparison table.
  """

  use TypedStruct

  typedstruct enforce: true do
    @typedoc "Capability declaration for one runtime adapter."

    field(:runtime_id, atom())
    field(:display_name, String.t())

    # The eight questions (booleans where the runtime gives a binary
    # answer; the rare structured case goes in `extra_facts`).
    field(:owns_model_loop, boolean())
    field(:owns_thread_history, boolean())
    field(:supports_jido_actions, boolean())
    field(:supports_action_hooks, boolean())
    field(:supports_native_tools, boolean())
    field(:runs_context_engine, boolean())
    field(:exposes_compaction_data, boolean())

    # Free-form atoms naming features this runtime intentionally drops
    # (relative to the `:arbor` baseline). Operators consult this when
    # picking a runtime — `:jido_actions in profile.unsupported_features`
    # is more informative than just `supports_jido_actions: false`.
    field(:unsupported_features, [atom()], default: [])

    # Optional structured facts that don't fit a boolean — e.g.
    # `%{owns_canonical_session: :cli, retry_budget: :owner}`. Reserved
    # for runtime-specific notes the standard fields can't carry.
    field(:extra_facts, map(), default: %{})
  end

  @doc """
  Construct a new `%RuntimeProfile{}`. Validates required fields, defaults
  the optional `unsupported_features` and `extra_facts` collections.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Enum.into(attrs, %{}))

  def new(%{} = attrs) do
    with {:ok, runtime_id} <- fetch_atom(attrs, :runtime_id),
         {:ok, display_name} <- fetch_string(attrs, :display_name),
         {:ok, owns_loop} <- fetch_bool(attrs, :owns_model_loop),
         {:ok, owns_history} <- fetch_bool(attrs, :owns_thread_history),
         {:ok, jido} <- fetch_bool(attrs, :supports_jido_actions),
         {:ok, hooks} <- fetch_bool(attrs, :supports_action_hooks),
         {:ok, native_tools} <- fetch_bool(attrs, :supports_native_tools),
         {:ok, ctx_engine} <- fetch_bool(attrs, :runs_context_engine),
         {:ok, compaction_data} <- fetch_bool(attrs, :exposes_compaction_data) do
      {:ok,
       %__MODULE__{
         runtime_id: runtime_id,
         display_name: display_name,
         owns_model_loop: owns_loop,
         owns_thread_history: owns_history,
         supports_jido_actions: jido,
         supports_action_hooks: hooks,
         supports_native_tools: native_tools,
         runs_context_engine: ctx_engine,
         exposes_compaction_data: compaction_data,
         unsupported_features: pick(attrs, :unsupported_features) || [],
         extra_facts: pick(attrs, :extra_facts) || %{}
       }}
    end
  end

  @doc """
  Boolean: does this profile assert support for `feature`?

  Recognized feature atoms map to the eight questions and their natural
  inverses:

    * `:model_loop` — `owns_model_loop`
    * `:thread_history` — `owns_thread_history`
    * `:jido_actions` — `supports_jido_actions`
    * `:action_hooks` — `supports_action_hooks`
    * `:native_tools` — `supports_native_tools`
    * `:context_engine` — `runs_context_engine`
    * `:compaction_data` — `exposes_compaction_data`

  Returns `false` for unknown features (conservative — callers asking
  about features the profile doesn't model should fail closed).
  """
  @spec supports?(t(), atom()) :: boolean()
  def supports?(%__MODULE__{} = p, feature) do
    cond do
      feature in p.unsupported_features -> false
      feature == :model_loop -> p.owns_model_loop
      feature == :thread_history -> p.owns_thread_history
      feature == :jido_actions -> p.supports_jido_actions
      feature == :action_hooks -> p.supports_action_hooks
      feature == :native_tools -> p.supports_native_tools
      feature == :context_engine -> p.runs_context_engine
      feature == :compaction_data -> p.exposes_compaction_data
      true -> false
    end
  end

  # ---- private helpers ----

  # Look up `key` (atom) and its string equivalent. Uses Map.has_key?
  # rather than `||` so a legitimate `false` value isn't mistaken for
  # "missing key" — important for the boolean question fields.
  defp pick(attrs, key) do
    str_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, str_key) -> Map.get(attrs, str_key)
      true -> nil
    end
  end

  defp fetch_atom(attrs, key) do
    case pick(attrs, key) do
      v when is_atom(v) and not is_nil(v) -> {:ok, v}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp fetch_string(attrs, key) do
    case pick(attrs, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp fetch_bool(attrs, key) do
    case pick(attrs, key) do
      v when is_boolean(v) -> {:ok, v}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end
end
