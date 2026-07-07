defmodule Arbor.Trust do
  @moduledoc """
  Public API facade for the Arbor Trust system.

  This module implements the `Arbor.Contracts.API.Trust` behaviour,
  providing a unified entry point for all trust operations:

  - **Trust Profiles** - Create and manage agent trust profiles
  - **Trust Events** - Record trust-affecting events
  - **Trust Freezing** - Freeze/unfreeze trust progression
  - **Trust Policy** - Resolve effective modes from baseline + rules

  Authorization runs on the granular `baseline` + `rules` + capability checks.
  There is no trust-tier band.

  ## Quick Start

      # Start the trust system (usually via Application supervisor)
      {:ok, _} = Arbor.Trust.start_link()

      # Create a trust profile for an agent
      {:ok, profile} = Arbor.Trust.create_trust_profile("agent_001")

      # Record trust events
      :ok = Arbor.Trust.record_trust_event("agent_001", :action_success, %{action: "sort"})

      # Freeze trust on security incident
      :ok = Arbor.Trust.freeze_trust("agent_001", :security_violation)

  ## Architecture

  This facade delegates to specialized modules:
  - `Arbor.Trust.Manager` - Trust profiles and lifecycle
  - `Arbor.Trust.Store` - In-memory trust profile storage
  - `Arbor.Trust.EventStore` - Durable event persistence
  - `Arbor.Trust.Config` - Configuration and capability baseline
  """

  @behaviour Arbor.Contracts.API.Trust

  alias Arbor.Trust.{ApprovalGuard, Manager, PolicyEnforcer}

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @doc """
  Start the trust system supervisor.

  This is typically called by the application supervisor, but can be called
  directly for testing or manual startup.

  ## Options

  - `:circuit_breaker` - Enable circuit breaker (default: true)
  - `:decay` - Enable automatic trust decay (default: true)
  - `:event_store` - Enable durable event persistence (default: true)
  """
  @impl true
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Arbor.Trust.Supervisor.start_link(opts)
  end

  @doc """
  Check if the trust system is running and healthy.

  Returns `true` if the trust manager process is alive.
  """
  @impl true
  @spec healthy?() :: boolean()
  def healthy? do
    Process.whereis(Manager) != nil
  end

  # ===========================================================================
  # Public API — short, human-friendly names
  # ===========================================================================

  @doc """
  Create a trust profile for a new agent.

  ## Examples

      {:ok, profile} = Arbor.Trust.create_trust_profile("agent_001")
  """
  @spec create_trust_profile(String.t()) ::
          {:ok, Arbor.Contracts.Trust.Profile.t()} | {:error, term()}
  defdelegate create_trust_profile(agent_id), to: Manager

  @doc """
  Get the trust profile for an agent.

  ## Examples

      {:ok, profile} = Arbor.Trust.get_trust_profile("agent_001")
  """
  @spec get_trust_profile(String.t()) ::
          {:ok, Arbor.Contracts.Trust.Profile.t()} | {:error, :not_found | term()}
  defdelegate get_trust_profile(agent_id), to: Manager

  @doc """
  Record a trust-affecting event.

  ## Examples

      :ok = Arbor.Trust.record_trust_event("agent_001", :action_success, %{action: "sort"})
  """
  @spec record_trust_event(String.t(), atom(), map()) :: :ok
  def record_trust_event(agent_id, event_type, metadata \\ %{}),
    do: Manager.record_trust_event(agent_id, event_type, metadata)

  @doc "Freeze an agent's trust progression."
  @spec freeze_trust(String.t(), atom()) :: :ok | {:error, term()}
  defdelegate freeze_trust(agent_id, reason), to: Manager

  @doc "Unfreeze an agent's trust progression."
  @spec unfreeze_trust(String.t()) :: :ok | {:error, term()}
  defdelegate unfreeze_trust(agent_id), to: Manager

  # ===========================================================================
  # Contract implementations — verbose names delegated to Manager
  # ===========================================================================

  @impl true
  defdelegate create_trust_profile_for_principal(agent_id), to: Manager, as: :create_trust_profile

  @impl true
  defdelegate get_trust_profile_for_principal(agent_id), to: Manager, as: :get_trust_profile

  @impl true
  def record_trust_event_for_principal_with_metadata(agent_id, event_type, metadata),
    do: Manager.record_trust_event(agent_id, event_type, metadata)

  @impl true
  defdelegate freeze_trust_progression_for_principal_with_reason(agent_id, reason),
    to: Manager,
    as: :freeze_trust

  @impl true
  defdelegate unfreeze_trust_progression_for_principal(agent_id), to: Manager, as: :unfreeze_trust

  # ===========================================================================
  # Administration
  # ===========================================================================

  @doc """
  List all trust profiles.

  ## Options

  - `:limit` - Maximum number of profiles to return

  ## Examples

      {:ok, profiles} = Arbor.Trust.list_profiles()
  """
  @spec list_profiles(keyword()) :: {:ok, [Arbor.Contracts.Trust.Profile.t()]}
  def list_profiles(opts \\ []) do
    Manager.list_profiles(opts)
  end

  @doc """
  Get recent trust events for an agent.

  ## Options

  - `:limit` - Maximum number of events to return (default: 50)

  ## Examples

      {:ok, events} = Arbor.Trust.get_events("agent_001")
      {:ok, events} = Arbor.Trust.get_events("agent_001", limit: 10)
  """
  @spec get_events(String.t(), keyword()) :: {:ok, [Arbor.Contracts.Trust.Event.t()]}
  def get_events(agent_id, opts \\ []) do
    Manager.get_events(agent_id, opts)
  end

  @doc """
  Trigger trust decay check for all profiles.

  Should be called periodically (e.g., daily) to apply inactivity decay.
  Trust decays 1 point per day after 7 days of inactivity, with a floor of 10.

  ## Examples

      :ok = Arbor.Trust.run_decay_check()
  """
  @spec run_decay_check() :: :ok
  def run_decay_check do
    Manager.run_decay_check()
  end

  # ===========================================================================
  # Policy — Trust ↔ Capability Bridge
  # ===========================================================================

  @doc "Get the effective trust mode for an agent and resource URI."
  @spec effective_mode(String.t(), String.t(), keyword()) :: :block | :ask | :allow | :auto
  defdelegate effective_mode(agent_id, resource_uri, opts \\ []), to: Arbor.Trust.Policy

  @doc "Explain the trust resolution chain for debugging."
  @spec explain(String.t(), String.t(), keyword()) :: map()
  defdelegate explain(agent_id, resource_uri, opts \\ []), to: Arbor.Trust.Policy

  @doc "Check if agent's trust profile allows a resource URI."
  @spec policy_allowed?(String.t(), String.t()) :: boolean()
  defdelegate policy_allowed?(agent_id, resource_uri), to: Arbor.Trust.Policy, as: :allowed?

  @doc "Get confirmation mode for a resource at agent's current trust level."
  @spec confirmation_mode(String.t(), String.t()) :: :auto | :gated | :deny
  defdelegate confirmation_mode(agent_id, resource_uri), to: Arbor.Trust.Policy

  @doc """
  Enumerate held and profile-mintable authority for a finite URI surface.

  Returns a read-only snapshot combining currently held capabilities with
  candidate URIs the trust profile would JIT-mint. This is the safe
  self-inspection/tool-exposure API: it does not call `authorize/4`, grant
  capabilities, or submit approval proposals.
  """
  @spec enumerate_authority(String.t(), [String.t()], keyword()) ::
          {:ok, Arbor.Trust.AuthorityEnumeration.snapshot()} | {:error, term()}
  defdelegate enumerate_authority(agent_id, candidate_uris, opts \\ []),
    to: Arbor.Trust.AuthorityEnumeration,
    as: :enumerate

  @doc "Return true when an authority snapshot entry is usable through trust-layer authorization."
  @spec effective_authority_entry?(map()) :: boolean()
  defdelegate effective_authority_entry?(entry),
    to: Arbor.Trust.AuthorityEnumeration,
    as: :effective_entry?

  @doc """
  Authorize an operation through the policy layer.

  This is the A1 boundary-move entry point for callers that want trust profiles
  to modulate capability use. It may mint explicit policy-derived reach before
  delegating to the security kernel, then applies approval policy to the held
  capability.

  Call `Arbor.Security.authorize/4` directly when the caller wants a pure
  capability check with no trust-policy minting.
  """
  @spec authorize(String.t(), String.t(), atom(), keyword()) ::
          {:ok, :authorized}
          | {:ok, :pending_approval, String.t()}
          | {:error, term()}
  def authorize(agent_id, resource_uri, action \\ nil, opts \\ []) do
    with {:ok, effective_uri} <-
           Arbor.Security.normalize_authorization_resource_uri(resource_uri, opts),
         {:ok, cap} <- PolicyEnforcer.ensure_capability(agent_id, effective_uri, opts),
         {:ok, authorized_result} <- security_authorize(agent_id, resource_uri, action, opts) do
      case ApprovalGuard.check(cap, agent_id, effective_uri) do
        :ok -> authorized_result
        {:ok, :pending_approval, proposal_id} -> {:ok, :pending_approval, proposal_id}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp security_authorize(agent_id, resource_uri, action, opts) do
    case Arbor.Security.authorize(agent_id, resource_uri, action, opts) do
      {:ok, :authorized} = result -> {:ok, result}
      {:ok, :pending_approval, proposal_id} -> {:error, {:pending_approval, proposal_id}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_auth_result, other}}
    end
  end

  # -- ConfirmationTracker (confirm-then-automate) --

  @doc "Record a successful approval for an agent's capability use."
  @spec record_approval(String.t(), String.t()) :: :ok | {:graduation_suggested, String.t()}
  defdelegate record_approval(agent_id, resource_uri), to: Arbor.Trust.ConfirmationTracker

  @doc "Record a rejection for an agent's capability use."
  @spec record_rejection(String.t(), String.t()) :: :ok
  defdelegate record_rejection(agent_id, resource_uri), to: Arbor.Trust.ConfirmationTracker

  @doc """
  Whether a graduation suggestion has been emitted for an agent's URI prefix
  (the approval streak reached the threshold).

  ADVISORY ONLY — this does NOT grant authorization. Earned autonomy is
  suggestion-only (TRUST-6, 2026-06-14): a human must accept a suggestion via
  `accept_graduation/2`, which records it as a persisted profile rule.
  Authorization reads the profile (`Policy.effective_mode/3`), never this flag.
  """
  @spec graduated?(String.t(), String.t()) :: boolean()
  defdelegate graduated?(agent_id, resource_uri), to: Arbor.Trust.ConfirmationTracker

  @doc """
  Accept a graduation suggestion: promote a URI prefix to auto-approve for the
  agent by recording it as a profile rule (`rules[prefix] => :auto`). This is the
  human-in-the-loop acceptance — earned autonomy is NEVER applied without it.

  Persists via the trust profile (survives restarts). The security ceiling still
  caps the effective mode, so accepting a graduation on an always-locked or egress
  URI does NOT bypass it — `effective_mode` takes the most restrictive of
  rule/ceiling/model.
  """
  @spec accept_graduation(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def accept_graduation(agent_id, uri_prefix)
      when is_binary(agent_id) and is_binary(uri_prefix) do
    Arbor.Trust.Store.update_profile(agent_id, fn profile ->
      %{profile | rules: Map.put(profile.rules || %{}, uri_prefix, :auto)}
    end)
  end

  @doc """
  Revoke an accepted graduation: remove the auto rule for a URI prefix (reverting
  to the profile baseline / gated). Use for demotion or expiry.
  """
  @spec revoke_graduation(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def revoke_graduation(agent_id, uri_prefix)
      when is_binary(agent_id) and is_binary(uri_prefix) do
    Arbor.Trust.Store.update_profile(agent_id, fn profile ->
      %{profile | rules: Map.delete(profile.rules || %{}, uri_prefix)}
    end)
  end
end
