defmodule Arbor.Contracts.Trust.Event do
  @moduledoc """
  Trust event data structure for tracking trust score changes.

  Trust events provide an audit trail of all trust-affecting activities.
  They are used for:
  - Debugging trust score calculations
  - Auditing trust progression
  - Detecting gaming or manipulation
  - Circuit breaker triggers

  ## Event Types

  | Type | Effect | Trigger |
  |------|--------|---------|
  | :action_success | +success_rate | Successful action execution |
  | :action_failure | -success_rate | Failed action execution |
  | :test_passed | +test_pass | Test passed |
  | :test_failed | -test_pass | Test failed |
  | :rollback_executed | -rollback_stability | Code rollback |
  | :security_violation | -security (20 pts) | Security policy violated |
  | :improvement_applied | +improvement_count | Self-improvement applied |
  | :trust_frozen | Frozen | Circuit breaker triggered |
  | :trust_unfrozen | Unfrozen | Manual/auto unfreeze |
  | :trust_decayed | -1 point | Daily decay (inactive) |
  | :tier_changed | Tier changed | Score crossed threshold |

  ## Usage

      {:ok, event} = Event.new(
        agent_id: "agent_123",
        event_type: :action_success,
        previous_score: 45,
        new_score: 46,
        metadata: %{action: "sort_list", duration_ms: 42}
      )

  @version "1.0.0"
  """

  use TypedStruct

  @derive Jason.Encoder
  typedstruct enforce: true do
    @typedoc "An immutable trust change event"

    # Event identification
    field(:id, String.t())
    field(:agent_id, String.t())
    field(:event_type, atom())
    field(:timestamp, DateTime.t())

    # Score changes
    field(:previous_score, non_neg_integer(), enforce: false)
    field(:new_score, non_neg_integer(), enforce: false)
    field(:delta, integer(), enforce: false)

    # Tier changes
    field(:previous_tier, atom(), enforce: false)
    field(:new_tier, atom(), enforce: false)

    # Context
    field(:reason, atom() | String.t(), enforce: false)
    field(:metadata, map(), default: %{})
  end

  @valid_event_types [
    :action_success,
    :action_failure,
    :test_passed,
    :test_failed,
    :rollback_executed,
    :security_violation,
    :improvement_applied,
    :trust_frozen,
    :trust_unfrozen,
    :trust_decayed,
    :tier_changed,
    :profile_created,
    :profile_deleted,
    # Council-based trust earning events
    :proposal_submitted,
    :proposal_approved,
    :proposal_rejected,
    :installation_success,
    :installation_rollback,
    :trust_points_awarded,
    :trust_points_deducted
  ]

  @doc """
  Create a new trust event with validation.

  ## Required Fields

  - `:agent_id` - Agent this event is for
  - `:event_type` - Type of trust event

  ## Optional Fields

  - `:previous_score` - Score before the event
  - `:new_score` - Score after the event
  - `:previous_tier` - Tier before (for tier_changed events)
  - `:new_tier` - Tier after (for tier_changed events)
  - `:reason` - Reason for the event
  - `:metadata` - Additional context

  ## Examples

      # Action success event
      {:ok, event} = Event.new(
        agent_id: "agent_123",
        event_type: :action_success,
        previous_score: 45,
        new_score: 46,
        metadata: %{action: "sort_list"}
      )

      # Tier promotion
      {:ok, event} = Event.new(
        agent_id: "agent_123",
        event_type: :tier_changed,
        previous_tier: :probationary,
        new_tier: :trusted,
        previous_score: 49,
        new_score: 50
      )
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    event = %__MODULE__{
      id: attrs[:id] || generate_event_id(),
      agent_id: Keyword.fetch!(attrs, :agent_id),
      event_type: Keyword.fetch!(attrs, :event_type),
      timestamp: attrs[:timestamp] || DateTime.utc_now(),
      previous_score: attrs[:previous_score],
      new_score: attrs[:new_score],
      delta: calculate_delta(attrs[:previous_score], attrs[:new_score]),
      previous_tier: attrs[:previous_tier],
      new_tier: attrs[:new_tier],
      reason: attrs[:reason],
      metadata: attrs[:metadata] || %{}
    }

    case validate_event(event) do
      :ok -> {:ok, event}
      {:error, _} = error -> error
    end
  end

  @doc """
  Create an action result event.
  """
  @spec action_event(String.t(), :success | :failure, keyword()) ::
          {:ok, t()} | {:error, term()}
  def action_event(agent_id, result, opts \\ []) do
    event_type = if result == :success, do: :action_success, else: :action_failure

    new(
      Keyword.merge(opts,
        agent_id: agent_id,
        event_type: event_type
      )
    )
  end

  @doc """
  Create a test result event.
  """
  @spec test_event(String.t(), :passed | :failed, keyword()) ::
          {:ok, t()} | {:error, term()}
  def test_event(agent_id, result, opts \\ []) do
    event_type = if result == :passed, do: :test_passed, else: :test_failed

    new(
      Keyword.merge(opts,
        agent_id: agent_id,
        event_type: event_type
      )
    )
  end

  @doc """
  Create a tier change event.
  """
  @spec tier_change_event(String.t(), atom(), atom(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def tier_change_event(agent_id, from_tier, to_tier, opts \\ []) do
    new(
      Keyword.merge(opts,
        agent_id: agent_id,
        event_type: :tier_changed,
        previous_tier: from_tier,
        new_tier: to_tier
      )
    )
  end

  @doc """
  Create a freeze/unfreeze event.
  """
  @spec freeze_event(String.t(), :frozen | :unfrozen, keyword()) ::
          {:ok, t()} | {:error, term()}
  def freeze_event(agent_id, action, opts \\ []) do
    event_type = if action == :frozen, do: :trust_frozen, else: :trust_unfrozen

    new(
      Keyword.merge(opts,
        agent_id: agent_id,
        event_type: event_type
      )
    )
  end

  @doc """
  Create a proposal event.
  """
  @spec proposal_event(String.t(), :submitted | :approved | :rejected, keyword()) ::
          {:ok, t()} | {:error, term()}
  def proposal_event(agent_id, result, opts \\ []) do
    event_type =
      case result do
        :submitted -> :proposal_submitted
        :approved -> :proposal_approved
        :rejected -> :proposal_rejected
      end

    new(
      Keyword.merge(opts,
        agent_id: agent_id,
        event_type: event_type
      )
    )
  end

  @doc """
  Create an installation event.
  """
  @spec installation_event(String.t(), :success | :rollback, keyword()) ::
          {:ok, t()} | {:error, term()}
  def installation_event(agent_id, result, opts \\ []) do
    event_type =
      case result do
        :success -> :installation_success
        :rollback -> :installation_rollback
      end

    new(
      Keyword.merge(opts,
        agent_id: agent_id,
        event_type: event_type
      )
    )
  end

  @doc """
  Create a trust points event (awarded or deducted).
  """
  @spec trust_points_event(String.t(), :awarded | :deducted, integer(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def trust_points_event(agent_id, action, points, opts \\ []) do
    event_type =
      case action do
        :awarded -> :trust_points_awarded
        :deducted -> :trust_points_deducted
      end

    new(
      Keyword.merge(opts,
        agent_id: agent_id,
        event_type: event_type,
        metadata: Map.put(opts[:metadata] || %{}, :points, points)
      )
    )
  end

  @doc """
  Check if this is a negative trust event.
  """
  @spec negative_event?(t()) :: boolean()
  def negative_event?(%__MODULE__{event_type: type}) do
    type in [
      :action_failure,
      :test_failed,
      :rollback_executed,
      :security_violation,
      :trust_frozen,
      :trust_decayed,
      :proposal_rejected,
      :installation_rollback,
      :trust_points_deducted
    ]
  end

  @doc """
  Check if this event should trigger a circuit breaker check.
  """
  @spec circuit_breaker_relevant?(t()) :: boolean()
  def circuit_breaker_relevant?(%__MODULE__{event_type: type}) do
    type in [
      :action_failure,
      :security_violation,
      :rollback_executed,
      :test_failed
    ]
  end

  @doc """
  Get all valid event types.
  """
  @spec valid_event_types() :: [atom(), ...]
  def valid_event_types, do: @valid_event_types

  @doc """
  Convert event to a map suitable for persistence.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    Map.from_struct(event)
  end

  # Private functions

  defp generate_event_id do
    "trust_evt_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
  end

  defp calculate_delta(nil, _), do: nil
  defp calculate_delta(_, nil), do: nil
  defp calculate_delta(prev, new), do: new - prev

  defp validate_event(%__MODULE__{} = event) do
    with :ok <- validate_event_type(event.event_type) do
      validate_agent_id(event.agent_id)
    end
  end

  defp validate_event_type(type) when type in @valid_event_types, do: :ok

  defp validate_event_type(type) do
    {:error, {:invalid_event_type, type, @valid_event_types}}
  end

  defp validate_agent_id(id) when is_binary(id) and byte_size(id) > 0, do: :ok
  defp validate_agent_id(id), do: {:error, {:invalid_agent_id, id}}
end
