defmodule Arbor.Contracts.Commands.Context do
  @moduledoc """
  Read-only input context for slash commands.

  A `Context` is built once per command invocation by an entry-point
  constructor (e.g. `Context.from_session/2` or `Context.from_arbor_comms/2`)
  and passed to the command's pure `execute/2` callback. Commands MUST NOT
  perform side effects — they read fields from the Context and return a
  `%Arbor.Contracts.Commands.Result{}` describing what to display and
  optionally what action the caller should perform.

  ## Why a struct, not a map

  The previous design passed a plain map with mystery keys (some data, some
  callback functions). It crashed silently when fields were missing and made
  the commands impossible to test in isolation. A typed struct with explicit
  optional fields fixes both problems.

  ## Agent-bound vs system-wide commands

  Most existing commands need a current agent (`/status`, `/model`, `/clear`).
  Some future commands won't (`/agents`, `/spawn`, `/help`). The Context
  supports both by making the agent fields *optional* — present when an
  entry point has a current agent in scope, `nil` otherwise. Each command's
  `available?/1` callback decides whether it can run given what's populated.

  This means there is exactly ONE Context type, ONE CommandRouter, and ONE
  execution path — even though some commands can only run in some situations.

  ## Field categories

  ### Always present
  - `:origin` — which entry point built this Context (`:dashboard`,
    `:arbor_comms`, `:acp`, `:cli`). Commands can use this for entry-point-
    specific availability or messaging.
  - `:user_id` — the principal sending the command, if known.

  ### Agent-bound (nil when no current agent)
  - `:agent_id`, `:session_id`, `:session_pid`, `:display_name`
  - `:model`, `:provider`
  - `:trust_tier`, `:trust_profile`
  - `:turn_count`, `:tools`, `:session_started`

  ### System-wide (always available, may be nil if not loaded)
  - `:all_agents` — snapshot of registered agents, populated for `/agents`
  - `:user_principal` — for `/whoami`, `/users`
  """

  use TypedStruct

  @type origin :: :dashboard | :arbor_comms | :acp | :cli | :test

  typedstruct do
    @typedoc "Read-only context for slash command execution"

    # Always present
    field(:origin, origin(), enforce: true)
    field(:user_id, String.t() | nil)

    # Agent-bound fields (nil when no current agent)
    field(:agent_id, String.t() | nil)
    field(:session_id, String.t() | nil)
    field(:session_pid, pid() | nil)
    field(:display_name, String.t() | nil)
    field(:model, String.t() | nil)
    field(:provider, atom() | String.t() | nil)
    field(:trust_tier, atom() | nil)
    field(:trust_profile, map() | nil)
    field(:turn_count, non_neg_integer() | nil)
    field(:tools, [String.t()], default: [])
    field(:session_started, DateTime.t() | nil)
    # Precomputed working memory summary (populated by from_session when
    # working memory is loaded). /memory just renders this — it doesn't fetch.
    field(:working_memory_summary, map() | nil)

    # System-wide fields
    field(:all_agents, [map()] | nil)
    field(:user_principal, map() | nil)
  end

  @doc """
  Construct a Context from a keyword list. The minimum required fields are
  `:origin`. Everything else defaults to nil/empty.

  Used by tests and by entry points that don't have a dedicated `from_*`
  constructor yet.
  """
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    origin = Keyword.fetch!(attrs, :origin)

    %__MODULE__{
      origin: origin,
      user_id: Keyword.get(attrs, :user_id),
      agent_id: Keyword.get(attrs, :agent_id),
      session_id: Keyword.get(attrs, :session_id),
      session_pid: Keyword.get(attrs, :session_pid),
      display_name: Keyword.get(attrs, :display_name),
      model: Keyword.get(attrs, :model),
      provider: Keyword.get(attrs, :provider),
      trust_tier: Keyword.get(attrs, :trust_tier),
      trust_profile: Keyword.get(attrs, :trust_profile),
      turn_count: Keyword.get(attrs, :turn_count),
      tools: Keyword.get(attrs, :tools, []),
      session_started: Keyword.get(attrs, :session_started),
      working_memory_summary: Keyword.get(attrs, :working_memory_summary),
      all_agents: Keyword.get(attrs, :all_agents),
      user_principal: Keyword.get(attrs, :user_principal)
    }
  end

  @doc """
  Returns true if the Context has a current agent in scope (i.e. agent-bound
  commands can run). Equivalent to `not is_nil(ctx.agent_id)`.
  """
  @spec has_agent?(t()) :: boolean()
  def has_agent?(%__MODULE__{agent_id: nil}), do: false
  def has_agent?(%__MODULE__{}), do: true

  @doc """
  Returns true if the Context has a session_pid (i.e. session-mutation
  commands like /clear and /compact can route their actions back).
  """
  @spec has_session?(t()) :: boolean()
  def has_session?(%__MODULE__{session_pid: nil}), do: false
  def has_session?(%__MODULE__{session_pid: pid}) when is_pid(pid), do: true
  def has_session?(_), do: false
end
