defmodule Arbor.Contracts.Healing.AnomalyQueue do
  @moduledoc """
  Behaviour for anomaly queue implementations.

  The anomaly queue is the central coordination point for self-healing:
  - Receives anomalies from Monitor
  - Deduplicates using fingerprints
  - Provides lease-based work claiming for DebugAgents
  - Tracks outcomes for verification

  ## Lease Semantics

  When an agent claims work via `claim_next/1`, it receives a lease token.
  The lease has a timeout (default 60 seconds). If the agent doesn't call
  `complete/2` or `release/1` before the timeout, the work is automatically
  reclaimed and made available to other agents.

  ## States

  An anomaly progresses through states:
  - `:pending` - waiting to be claimed
  - `:claimed` - being worked on by an agent
  - `:verifying` - fix applied, waiting for soak period
  - `:resolved` - fix verified, no recurrence
  - `:ineffective` - fix failed, recurrence detected
  - `:escalated` - exceeded retry limit, needs human attention
  """

  alias Arbor.Contracts.Healing.Fingerprint

  @type anomaly_id :: integer()
  @type agent_id :: String.t()
  @type lease_token :: {anomaly_id(), agent_id(), expires_at :: integer()}

  @type anomaly_state :: :pending | :claimed | :verifying | :resolved | :ineffective | :escalated

  @type outcome ::
          :fixed
          | :escalated
          | {:retry, reason :: term()}
          | {:ineffective, reason :: term()}

  @type stats :: %{
          pending: non_neg_integer(),
          claimed: non_neg_integer(),
          verifying: non_neg_integer(),
          resolved_24h: non_neg_integer(),
          escalated_24h: non_neg_integer()
        }

  @type queued_anomaly :: %{
          id: anomaly_id(),
          anomaly: map(),
          fingerprint: Fingerprint.t(),
          state: anomaly_state(),
          enqueued_at: integer(),
          claimed_by: agent_id() | nil,
          lease_expires: integer() | nil,
          attempt_count: non_neg_integer()
        }

  @doc """
  Enqueue an anomaly for processing.

  Returns `{:ok, :enqueued}` if this is a new anomaly, or
  `{:ok, :deduplicated}` if an anomaly with the same fingerprint
  is already in the queue (extends its window).
  """
  @callback enqueue(anomaly :: map()) :: {:ok, :enqueued | :deduplicated} | {:error, term()}

  @doc """
  Claim the next available anomaly for processing.

  Returns a lease token and the anomaly. The agent must call
  `complete/2` or `release/1` before the lease expires.
  """
  @callback claim_next(agent_id()) :: {:ok, {lease_token(), map()}} | {:error, :empty}

  @doc """
  Release a claimed anomaly without completing it.

  Use when the agent encounters an error and wants to make
  the anomaly available for retry by another agent.
  """
  @callback release(lease_token()) :: :ok | {:error, :invalid_lease}

  @doc """
  Mark an anomaly as complete with an outcome.

  Outcomes:
  - `:fixed` - start verification soak period
  - `:escalated` - exceeded retries, needs human attention
  - `{:retry, reason}` - return to pending for another attempt
  - `{:ineffective, reason}` - fix didn't work
  """
  @callback complete(lease_token(), outcome()) :: :ok | {:error, term()}

  @doc """
  List all pending anomalies (for dashboard display).
  """
  @callback list_pending() :: [queued_anomaly()]

  @doc """
  List all anomalies in a given state.
  """
  @callback list_by_state(anomaly_state()) :: [queued_anomaly()]

  @doc """
  Get queue statistics.
  """
  @callback stats() :: stats()

  @doc """
  Check if a fingerprint is currently suppressed (exceeded retry limit).
  """
  @callback suppressed?(Fingerprint.t()) :: boolean()

  @doc """
  Manually suppress a fingerprint (for human intervention).
  """
  @callback suppress(Fingerprint.t(), reason :: String.t(), ttl_minutes :: pos_integer()) :: :ok
end
