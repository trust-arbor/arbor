defmodule Arbor.Contracts.Libraries.Security do
  @moduledoc """
  Public API contract for the Arbor.Security library.

  Defines the facade interface for capability-based security.

  ## Quick Start

      case Arbor.Security.authorize("agent_001", "arbor://fs/read/docs", :read) do
        {:ok, :authorized} -> proceed()
        {:error, reason} -> handle_denial(reason)
      end

  ## Trust Tiers

  | Tier | Score | Capabilities |
  |------|-------|--------------|
  | `:untrusted` | 0-19 | Read own code only |
  | `:probationary` | 20-49 | Limited access |
  | `:trusted` | 50-74 | Standard access |
  | `:veteran` | 75-89 | Extended access |
  | `:autonomous` | 90-100 | Self-modification |
  """

  alias Arbor.Types

  @type principal_id :: Types.agent_id()
  @type resource :: Types.resource_uri()
  @type action :: Types.operation()
  @type trust_tier :: :untrusted | :probationary | :trusted | :veteran | :autonomous

  @type authorization_result ::
          {:ok, :authorized}
          | {:ok, :pending_approval, proposal_id :: String.t()}
          | {:error, authorization_error()}

  @type authorization_error ::
          :unauthorized
          | :capability_not_found
          | :capability_expired
          | :insufficient_trust
          | :trust_frozen
          | term()

  @type capability :: map()
  @type trust_profile :: map()

  @type authorize_opts :: [
          context: map(),
          skip_consensus: boolean(),
          trace_id: String.t()
        ]

  @type grant_opts :: [
          principal: principal_id(),
          resource: resource(),
          constraints: map(),
          expires_at: DateTime.t() | nil,
          delegation_depth: non_neg_integer()
        ]

  # Core Authorization

  @doc """
  Authorize an operation on a resource.
  """
  @callback authorize(principal_id(), resource(), action(), authorize_opts()) ::
              authorization_result()

  # Capability Management

  @doc """
  Grant a capability to an agent.
  """
  @callback grant(grant_opts()) :: {:ok, capability()} | {:error, term()}

  @doc """
  Revoke a capability.
  """
  @callback revoke(capability_id :: String.t(), opts :: keyword()) ::
              :ok | {:error, :not_found | term()}

  @doc """
  List capabilities for an agent.
  """
  @callback list_capabilities(principal_id(), opts :: keyword()) ::
              {:ok, [capability()]} | {:error, term()}

  # Trust Management

  @doc """
  Create a trust profile for a new agent.
  """
  @callback create_trust_profile(principal_id()) ::
              {:ok, trust_profile()} | {:error, :already_exists | term()}

  @doc """
  Get the trust profile for an agent.
  """
  @callback get_trust_profile(principal_id()) ::
              {:ok, trust_profile()} | {:error, :not_found}

  @doc """
  Get the current trust tier for an agent.
  """
  @callback get_trust_tier(principal_id()) ::
              {:ok, trust_tier()} | {:error, :not_found}

  @doc """
  Record a trust-affecting event.
  """
  @callback record_trust_event(principal_id(), event_type :: atom(), metadata :: map()) :: :ok

  @doc """
  Freeze an agent's trust progression.
  """
  @callback freeze_trust(principal_id(), reason :: atom()) :: :ok | {:error, term()}

  @doc """
  Unfreeze an agent's trust progression.
  """
  @callback unfreeze_trust(principal_id()) :: :ok | {:error, term()}

  # Fast Authorization

  @doc """
  Fast capability-only check.
  """
  @callback can?(principal_id(), resource_uri :: String.t(), operation :: atom()) :: boolean()

  # Lifecycle

  @doc """
  Start the security system.
  """
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Check if the security system is healthy.
  """
  @callback healthy?() :: boolean()

  @optional_callbacks [
    can?: 3
  ]
end
