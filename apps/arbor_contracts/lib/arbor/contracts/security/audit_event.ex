defmodule Arbor.Contracts.Security.AuditEvent do
  @moduledoc """
  Security audit event for compliance and monitoring.

  Audit events provide an immutable record of all security-relevant
  activities in the system. They are critical for:
  - Compliance with security policies
  - Forensic analysis after incidents
  - Real-time security monitoring

  ## Event Types

  - `:capability_granted` - New capability created
  - `:capability_revoked` - Capability invalidated
  - `:capability_delegated` - Capability delegated to another agent
  - `:authorization_success` - Operation authorized
  - `:authorization_denied` - Operation denied
  - `:policy_violation` - System policy violated
  - `:security_alert` - Suspicious activity detected
  """

  use TypedStruct

  alias Arbor.Types

  @derive Jason.Encoder
  typedstruct enforce: true do
    @typedoc "An immutable security audit event"

    # Event identification
    field(:id, String.t())
    field(:event_type, atom())
    field(:timestamp, DateTime.t())

    # Security context
    field(:capability_id, Types.capability_id(), enforce: false)
    field(:principal_id, Types.agent_id())
    field(:actor_id, String.t(), enforce: false)
    field(:session_id, Types.session_id(), enforce: false)

    # Operation details
    field(:resource_uri, Types.resource_uri(), enforce: false)
    field(:operation, Types.operation(), enforce: false)
    field(:decision, atom(), enforce: false)
    field(:reason, atom() | String.t(), enforce: false)

    # Additional context
    field(:context, map(), default: %{})
    field(:metadata, map(), default: %{})
  end

  @valid_event_types [
    :capability_granted,
    :capability_revoked,
    :capability_delegated,
    :authorization_success,
    :authorization_denied,
    :policy_violation,
    :security_alert,
    :capability_expired
  ]

  @doc """
  Create a new audit event with validation.

  ## Required Fields

  - `:event_type` - Type of security event
  - `:principal_id` - Agent involved in the event

  ## Optional Fields

  - `:capability_id` - Capability involved (if applicable)
  - `:actor_id` - Agent that triggered the event
  - `:resource_uri` - Resource accessed
  - `:operation` - Operation attempted
  - `:decision` - Security decision made
  - `:reason` - Reason for decision
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    event = %__MODULE__{
      id: attrs[:id] || generate_event_id(),
      event_type: Keyword.fetch!(attrs, :event_type),
      timestamp: attrs[:timestamp] || DateTime.utc_now(),
      capability_id: attrs[:capability_id],
      principal_id: Keyword.fetch!(attrs, :principal_id),
      actor_id: attrs[:actor_id] || attrs[:principal_id],
      session_id: attrs[:session_id],
      resource_uri: attrs[:resource_uri],
      operation: attrs[:operation],
      decision: attrs[:decision],
      reason: attrs[:reason],
      context: attrs[:context] || %{},
      metadata: attrs[:metadata] || %{}
    }

    case validate_event(event) do
      :ok -> {:ok, event}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Create an authorization event.
  """
  @spec authorization(atom(), keyword()) :: {:ok, t()} | {:error, term()}
  def authorization(decision, attrs) when decision in [:authorized, :denied] do
    event_type =
      if decision == :authorized,
        do: :authorization_success,
        else: :authorization_denied

    new(
      attrs
      |> Keyword.put(:event_type, event_type)
      |> Keyword.put(:decision, decision)
    )
  end

  @doc """
  Check if an event represents a security failure.
  """
  @spec security_failure?(t()) :: boolean()
  def security_failure?(%__MODULE__{event_type: type}) do
    type in [:authorization_denied, :policy_violation, :security_alert]
  end

  @doc """
  Convert event to a map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    Map.from_struct(event)
  end

  # Private functions

  defp generate_event_id do
    "audit_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp validate_event(%__MODULE__{} = event) do
    cond do
      event.event_type not in @valid_event_types ->
        {:error, {:invalid_event_type, event.event_type}}

      not is_binary(event.principal_id) or byte_size(event.principal_id) == 0 ->
        {:error, {:invalid_principal_id, event.principal_id}}

      true ->
        :ok
    end
  end
end
