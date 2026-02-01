defmodule Arbor.Security.Events do
  @moduledoc """
  Permanent event logging for security operations.

  Writes durable events to EventLog via arbor_persistence AND emits on the
  signal bus for real-time notification (dual-emit pattern).

  Uses `apply/3` for runtime module resolution since arbor_persistence
  depends on arbor_security (adding the reverse would create a cycle).

  ## Event Types

  | Event Type | Purpose |
  |------------|---------|
  | `:authorization_granted` | Agent was authorized for a resource |
  | `:authorization_denied` | Agent was denied access to a resource |
  | `:authorization_pending` | Authorization escalated to consensus |
  | `:capability_granted` | Capability token granted to agent |
  | `:capability_revoked` | Capability token revoked |
  | `:identity_registered` | Agent identity registered in registry |
  | `:identity_verification_succeeded` | Agent identity verification passed |
  | `:identity_verification_failed` | Agent identity verification failed |

  ## Examples

      # Query security event history
      {:ok, events} = Arbor.Security.Events.get_history(limit: 50)

      # Get denied authorization events
      {:ok, denied} = Arbor.Security.Events.get_by_type(:authorization_denied)
  """

  @event_log_name :security_events
  @event_log_backend Arbor.Persistence.EventLog.ETS
  @stream_id "security:events"

  # ============================================================================
  # Authorization Events
  # ============================================================================

  @doc "Record a successful authorization."
  @spec record_authorization_granted(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def record_authorization_granted(principal_id, resource_uri, opts \\ []) do
    dual_emit(:authorization_granted, %{
      principal_id: principal_id,
      resource_uri: resource_uri,
      trace_id: Keyword.get(opts, :trace_id)
    })
  end

  @doc "Record authorization escalated to consensus."
  @spec record_authorization_pending(String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def record_authorization_pending(principal_id, resource_uri, proposal_id, opts \\ []) do
    dual_emit(:authorization_pending, %{
      principal_id: principal_id,
      resource_uri: resource_uri,
      proposal_id: proposal_id,
      trace_id: Keyword.get(opts, :trace_id)
    })
  end

  @doc "Record a denied authorization."
  @spec record_authorization_denied(String.t(), String.t(), term(), keyword()) ::
          :ok | {:error, term()}
  def record_authorization_denied(principal_id, resource_uri, reason, opts \\ []) do
    dual_emit(:authorization_denied, %{
      principal_id: principal_id,
      resource_uri: resource_uri,
      reason: inspect(reason),
      trace_id: Keyword.get(opts, :trace_id)
    })
  end

  # ============================================================================
  # Capability Events
  # ============================================================================

  @doc "Record a capability being granted."
  @spec record_capability_granted(map()) :: :ok | {:error, term()}
  def record_capability_granted(cap) do
    dual_emit(:capability_granted, %{
      capability_id: cap.id,
      principal_id: cap.principal_id,
      resource_uri: cap.resource_uri
    })
  end

  @doc "Record a capability being revoked."
  @spec record_capability_revoked(String.t()) :: :ok | {:error, term()}
  def record_capability_revoked(capability_id) do
    dual_emit(:capability_revoked, %{
      capability_id: capability_id
    })
  end

  # ============================================================================
  # Identity Events
  # ============================================================================

  @doc "Record an agent identity being registered."
  @spec record_identity_registered(String.t()) :: :ok | {:error, term()}
  def record_identity_registered(agent_id) do
    dual_emit(:identity_registered, %{
      agent_id: agent_id
    })
  end

  @doc "Record a successful identity verification."
  @spec record_identity_verification_succeeded(String.t()) :: :ok | {:error, term()}
  def record_identity_verification_succeeded(agent_id) do
    dual_emit(:identity_verification_succeeded, %{
      agent_id: agent_id
    })
  end

  @doc "Record a failed identity verification."
  @spec record_identity_verification_failed(String.t(), term()) :: :ok | {:error, term()}
  def record_identity_verification_failed(agent_id, reason) do
    dual_emit(:identity_verification_failed, %{
      agent_id: agent_id,
      reason: inspect(reason)
    })
  end

  # ============================================================================
  # Identity Lifecycle Events
  # ============================================================================

  @doc "Record an identity suspension."
  @spec record_identity_suspended(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def record_identity_suspended(agent_id, reason) do
    dual_emit(:identity_suspended, %{
      agent_id: agent_id,
      reason: reason
    })
  end

  @doc "Record an identity resumption."
  @spec record_identity_resumed(String.t()) :: :ok | {:error, term()}
  def record_identity_resumed(agent_id) do
    dual_emit(:identity_resumed, %{
      agent_id: agent_id
    })
  end

  @doc "Record an identity revocation."
  @spec record_identity_revoked(String.t(), String.t() | nil, non_neg_integer()) ::
          :ok | {:error, term()}
  def record_identity_revoked(agent_id, reason, cascade_count) do
    dual_emit(:identity_revoked, %{
      agent_id: agent_id,
      reason: reason,
      cascade_count: cascade_count
    })
  end

  # ============================================================================
  # Delegation Events
  # ============================================================================

  @doc "Record a capability delegation."
  @spec record_delegation_created(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def record_delegation_created(delegator_id, recipient_id, capability_id) do
    dual_emit(:delegation_created, %{
      delegator_id: delegator_id,
      recipient_id: recipient_id,
      capability_id: capability_id
    })
  end

  @doc "Record a cascade revocation of capabilities."
  @spec record_cascade_revocation(String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def record_cascade_revocation(root_capability_id, count_revoked) do
    dual_emit(:cascade_revocation, %{
      root_capability_id: root_capability_id,
      count_revoked: count_revoked
    })
  end

  # ============================================================================
  # Query Helpers
  # ============================================================================

  @doc """
  Get security event history.

  ## Options

  - `:limit` - Maximum events to return
  - `:from` - Start from this event number
  - `:direction` - `:forward` (oldest first) or `:backward` (newest first)
  """
  @spec get_history(keyword()) :: {:ok, list()} | {:error, term()}
  def get_history(opts \\ []) do
    apply(Arbor.Persistence, :read_stream, [
      @event_log_name,
      @event_log_backend,
      @stream_id,
      opts
    ])
  end

  @doc """
  Get events of a specific type.

  ## Examples

      {:ok, denied} = Arbor.Security.Events.get_by_type(:authorization_denied)
  """
  @spec get_by_type(atom(), keyword()) :: {:ok, list()} | {:error, term()}
  def get_by_type(event_type, opts \\ []) do
    type_string = to_string(event_type)

    case get_history(opts) do
      {:ok, events} ->
        filtered =
          Enum.filter(events, fn event ->
            to_string(Map.get(event, :type)) == type_string
          end)

        {:ok, filtered}

      error ->
        error
    end
  end

  @doc """
  Get events for a specific principal (agent).
  """
  @spec get_for_principal(String.t(), keyword()) :: {:ok, list()} | {:error, term()}
  def get_for_principal(principal_id, opts \\ []) do
    case get_history(opts) do
      {:ok, events} ->
        filtered =
          Enum.filter(events, fn event ->
            data = Map.get(event, :data, %{})

            Map.get(data, :principal_id) == principal_id or
              Map.get(data, :agent_id) == principal_id
          end)

        {:ok, filtered}

      error ->
        error
    end
  end

  @doc """
  Get the most recent security events.
  """
  @spec get_recent(non_neg_integer()) :: {:ok, list()} | {:error, term()}
  def get_recent(limit \\ 20) do
    case get_history(direction: :backward, limit: limit) do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Dual-emit: write to EventLog AND emit on signal bus.
  # Uses apply/3 for Persistence calls since arbor_persistence depends on
  # arbor_security — adding the reverse would create a dependency cycle.
  #
  # Persistence is best-effort: if the EventLog backend isn't started,
  # the signal still emits. Security operations must not fail because
  # the audit log is unavailable.
  defp dual_emit(event_type, data) do
    # Write to EventLog (durable, best-effort)
    persist_event(event_type, data)

    # Emit on signal bus (real-time notification)
    Arbor.Signals.emit(
      :security,
      event_type,
      Map.put(data, :permanent, true)
    )

    :ok
  end

  # credo:disable-for-this-file Credo.Check.Refactor.Apply
  # apply/3 is intentional: arbor_persistence depends on arbor_security,
  # so we use runtime resolution to avoid a dependency cycle.
  defp persist_event(event_type, data) do
    event =
      apply(Arbor.Persistence.Event, :new, [
        @stream_id,
        to_string(event_type),
        Map.put(data, :timestamp, DateTime.utc_now())
      ])

    apply(Arbor.Persistence, :append, [
      @event_log_name,
      @event_log_backend,
      @stream_id,
      event
    ])
  rescue
    # EventLog backend not started — log and continue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
