defmodule Arbor.Security.Events do
  @moduledoc """
  Permanent event logging for security operations.

  Writes durable events to EventLog via arbor_persistence AND emits telemetry.
  The `arbor_signals` application may bridge selected telemetry events onto the
  signal bus for real-time notification.

  Uses `apply/3` for runtime module resolution since arbor_persistence
  depends on arbor_security (adding the reverse would create a cycle).

  ## Event Types

  | Event Type | Purpose |
  |------------|---------|
  | `:authorization_granted` | Agent was authorized for a resource |
  | `:authorization_denied` | Agent was denied access to a resource |
  | `:authorization_pending` | Authorization escalated to consensus |
  | `:approval_answered` | Human/operator answered an approval request |
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

  # Write to the Historian's EventLog inside Arbor so security events are
  # queryable via Arbor.Historian.for_category(:security), etc. These defaults
  # are module atoms built without aliases so a standalone kernel package can
  # inject its own reader/backend without compiling against Arbor.Historian or
  # Arbor.Persistence.
  @default_event_log_name Module.concat(["Arbor", "Historian", "EventLog", "ETS"])
  @default_event_log_backend Module.concat(["Arbor", "Persistence", "EventLog", "ETS"])
  @default_event_log_reader Module.concat(["Arbor", "Persistence"])
  @default_event_module Module.concat(["Arbor", "Persistence", "Event"])
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

  @doc "Record a human/operator answer to a pending approval request."
  @spec record_approval_answered(String.t(), String.t(), atom(), atom(), keyword()) ::
          :ok | {:error, term()}
  def record_approval_answered(actor_id, approval_id, source, decision, opts \\ []) do
    dual_emit(:approval_answered, %{
      actor_id: actor_id,
      approval_id: approval_id,
      source: source,
      decision: decision,
      resource_uri: Keyword.get(opts, :resource_uri),
      agent_id: Keyword.get(opts, :agent_id),
      principal_id: Keyword.get(opts, :principal_id),
      note: Keyword.get(opts, :note),
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
  # Invocation Receipt Events
  # ============================================================================

  @doc "Record a signed invocation receipt."
  @spec record_invocation_receipt(map()) :: :ok | {:error, term()}
  def record_invocation_receipt(receipt) do
    dual_emit(:invocation_receipt, %{
      receipt_id: receipt.id,
      capability_id: receipt.capability_id,
      principal_id: receipt.principal_id,
      resource_uri: receipt.resource_uri,
      result: receipt.result,
      delegation_chain_length: length(receipt.delegation_chain),
      session_id: receipt.session_id,
      task_id: receipt.task_id
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
  @spec record_identity_verification_succeeded(String.t(), keyword()) :: :ok | {:error, term()}
  def record_identity_verification_succeeded(agent_id, opts \\ []) do
    dual_emit(:identity_verification_succeeded, %{
      agent_id: agent_id,
      trace_id: Keyword.get(opts, :trace_id),
      signature: Keyword.get(opts, :signature),
      payload_hash: Keyword.get(opts, :payload_hash),
      nonce: Keyword.get(opts, :nonce),
      signed_at: Keyword.get(opts, :signed_at)
    })
  end

  @doc "Record a failed identity verification."
  @spec record_identity_verification_failed(String.t(), term(), keyword()) ::
          :ok | {:error, term()}
  def record_identity_verification_failed(agent_id, reason, opts \\ []) do
    dual_emit(:identity_verification_failed, %{
      agent_id: agent_id,
      reason: inspect(reason),
      trace_id: Keyword.get(opts, :trace_id),
      nonce: Keyword.get(opts, :nonce),
      signed_at: Keyword.get(opts, :signed_at)
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
  # Reflex Events
  # ============================================================================

  @doc "Record a reflex being triggered (blocked or warned)."
  @spec record_reflex_triggered(String.t(), map(), String.t(), atom(), atom()) ::
          :ok | {:error, term()}
  def record_reflex_triggered(agent_id, reflex, resource, action, response) do
    dual_emit(:reflex_triggered, %{
      agent_id: agent_id,
      reflex_id: reflex.id,
      reflex_name: reflex.name,
      resource: resource,
      action: action,
      response: response
    })
  end

  @doc "Record a reflex warning (action allowed but logged)."
  @spec record_reflex_warning(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def record_reflex_warning(agent_id, reflex_id, message) do
    dual_emit(:reflex_warning, %{
      agent_id: agent_id,
      reflex_id: reflex_id,
      message: message
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
    reader = event_log_reader()

    if Code.ensure_loaded?(reader) and function_exported?(reader, :read_stream, 4) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(reader, :read_stream, [
        event_log_name(),
        event_log_backend(),
        @stream_id,
        opts
      ])
    else
      {:error, :event_log_unavailable}
    end
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

  # Security operations must not fail because the audit log is unavailable.
  defp dual_emit(event_type, data) do
    persist_event(event_type, data)

    Arbor.Security.Telemetry.emit(event_type, data,
      signal_data: Map.put(data, :permanent, true),
      stream_id: @stream_id
    )

    :ok
  end

  defp persist_event(event_type, data) do
    event_module = event_module()
    persistence = event_log_reader()

    if Code.ensure_loaded?(event_module) &&
         Code.ensure_loaded?(persistence) &&
         function_exported?(persistence, :append, 4) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      event =
        apply(event_module, :new, [
          @stream_id,
          to_string(event_type),
          Map.put(data, :timestamp, DateTime.utc_now()),
          [metadata: %{source_node: node()}]
        ])

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(persistence, :append, [event_log_name(), event_log_backend(), @stream_id, event])
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp event_log_name do
    Application.get_env(:arbor_security, :event_log_name, @default_event_log_name)
  end

  defp event_log_backend do
    Application.get_env(:arbor_security, :event_log_backend, @default_event_log_backend)
  end

  defp event_log_reader do
    Application.get_env(:arbor_security, :event_log_reader, @default_event_log_reader)
  end

  defp event_module do
    Application.get_env(:arbor_security, :event_module, @default_event_module)
  end
end
