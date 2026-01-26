defmodule Arbor.Contracts.Core.Session do
  @moduledoc """
  Session structure for multi-agent coordination.

  Sessions are the primary coordination context for multi-agent interactions
  in Arbor. They provide:
  - Shared security context for all agents
  - Resource lifecycle management
  - Audit trail for all activities

  ## Session States

  - `:initializing` - Session being created
  - `:active` - Normal operating state
  - `:suspended` - Temporarily paused
  - `:terminating` - Graceful shutdown in progress
  - `:terminated` - Session ended
  - `:error` - Session in error state

  ## Usage

      {:ok, session} = Session.new(
        user_id: "user_123",
        principal_id: "principal_456",
        purpose: "Analyze and refactor codebase",
        metadata: %{project_id: "proj_789"}
      )
  """

  use TypedStruct

  alias Arbor.Contracts.Core.Capability
  alias Arbor.Identifiers
  alias Arbor.Types

  @derive {Jason.Encoder, except: [:capabilities]}
  typedstruct enforce: true do
    @typedoc "A session coordinating multiple agents"

    # Identity
    field(:id, Types.session_id())
    field(:user_id, String.t())
    field(:principal_id, String.t())
    field(:purpose, String.t())

    # State management
    field(:status, atom(), default: :initializing)
    field(:context, map(), default: %{})
    field(:capabilities, [Capability.t()], default: [])

    # Agent management
    field(:agents, map(), default: %{})
    field(:max_agents, pos_integer(), default: 10)
    field(:agent_count, non_neg_integer(), default: 0)

    # Lifecycle
    field(:created_at, DateTime.t())
    field(:updated_at, DateTime.t())
    field(:expires_at, DateTime.t(), enforce: false)
    field(:terminated_at, DateTime.t(), enforce: false)

    # Configuration
    field(:timeout, pos_integer(), enforce: false)
    field(:cleanup_policy, atom(), default: :graceful)
    field(:metadata, map(), default: %{})
  end

  @valid_statuses [:initializing, :active, :suspended, :terminating, :terminated, :error]
  @valid_cleanup_policies [:graceful, :immediate, :force]

  @doc """
  Create a new session with validation.

  ## Required Fields

  - `:user_id` - ID of user/client creating the session
  - `:principal_id` - Security principal identifier for the session
  - `:purpose` - Descriptive purpose of the session

  ## Optional Fields

  - `:capabilities` - Initial capabilities for the session
  - `:metadata` - Additional session metadata
  - `:timeout` - Session timeout in milliseconds
  - `:max_agents` - Maximum agents allowed (default: 10)
  - `:expires_at` - When session expires
  - `:cleanup_policy` - How to handle termination (default: :graceful)

  ## Examples

      {:ok, session} = Session.new(
        user_id: "user_123",
        principal_id: "principal_456",
        purpose: "Code analysis"
      )
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    now = DateTime.utc_now()

    session = %__MODULE__{
      id: attrs[:id] || Identifiers.generate_session_id(),
      user_id: Keyword.fetch!(attrs, :user_id),
      principal_id: Keyword.fetch!(attrs, :principal_id),
      purpose: Keyword.fetch!(attrs, :purpose),
      status: attrs[:status] || :initializing,
      context: attrs[:context] || %{},
      capabilities: attrs[:capabilities] || [],
      agents: attrs[:agents] || %{},
      max_agents: attrs[:max_agents] || 10,
      agent_count: attrs[:agent_count] || 0,
      created_at: attrs[:created_at] || now,
      updated_at: attrs[:updated_at] || now,
      expires_at: calculate_expiration(now, attrs[:timeout]),
      terminated_at: attrs[:terminated_at],
      timeout: attrs[:timeout],
      cleanup_policy: attrs[:cleanup_policy] || :graceful,
      metadata: attrs[:metadata] || %{}
    }

    case validate_session(session) do
      :ok -> {:ok, session}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Transition session to a new status.

  Validates state transitions according to the allowed flow.
  """
  @spec transition_status(t(), atom()) :: {:ok, t()} | {:error, :invalid_transition}
  def transition_status(%__MODULE__{status: current} = session, new_status) do
    if valid_transition?(current, new_status) do
      updated = %{session | status: new_status, updated_at: DateTime.utc_now()}

      updated =
        if new_status == :terminated do
          %{updated | terminated_at: DateTime.utc_now()}
        else
          updated
        end

      {:ok, updated}
    else
      {:error, :invalid_transition}
    end
  end

  @doc """
  Check if session has expired.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  @doc """
  Check if session is in a terminal state.
  """
  @spec terminal_state?(t()) :: boolean()
  def terminal_state?(%__MODULE__{status: status}) do
    status in [:terminated, :error]
  end

  # Private functions

  defp calculate_expiration(_now, nil), do: nil

  defp calculate_expiration(now, timeout) when is_integer(timeout) do
    DateTime.add(now, timeout, :millisecond)
  end

  defp validate_session(%__MODULE__{} = session) do
    validators = [
      &validate_user_id/1,
      &validate_purpose/1,
      &validate_status/1,
      &validate_cleanup_policy/1,
      &validate_max_agents/1
    ]

    Enum.reduce_while(validators, :ok, fn validator, :ok ->
      case validator.(session) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_user_id(%{user_id: id}) when is_binary(id) and byte_size(id) > 0, do: :ok
  defp validate_user_id(%{user_id: id}), do: {:error, {:invalid_user_id, id}}

  defp validate_purpose(%{purpose: purpose}) when is_binary(purpose) and byte_size(purpose) > 0,
    do: :ok

  defp validate_purpose(%{purpose: purpose}), do: {:error, {:invalid_purpose, purpose}}

  defp validate_status(%{status: status}) when status in @valid_statuses, do: :ok
  defp validate_status(%{status: status}), do: {:error, {:invalid_status, status}}

  defp validate_cleanup_policy(%{cleanup_policy: policy}) when policy in @valid_cleanup_policies,
    do: :ok

  defp validate_cleanup_policy(%{cleanup_policy: policy}),
    do: {:error, {:invalid_cleanup_policy, policy}}

  defp validate_max_agents(%{max_agents: max}) when is_integer(max) and max > 0, do: :ok
  defp validate_max_agents(%{max_agents: max}), do: {:error, {:invalid_max_agents, max}}

  defp valid_transition?(:initializing, :active), do: true
  defp valid_transition?(:active, :suspended), do: true
  defp valid_transition?(:active, :terminating), do: true
  defp valid_transition?(:suspended, :active), do: true
  defp valid_transition?(:terminating, :terminated), do: true
  defp valid_transition?(_, :error), do: true
  defp valid_transition?(_, _), do: false
end
