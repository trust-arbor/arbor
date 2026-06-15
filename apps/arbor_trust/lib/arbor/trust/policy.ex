defmodule Arbor.Trust.Policy do
  @moduledoc """
  Bridges trust profiles to capability authorization.

  The Policy module is the glue between `Arbor.Trust` (behavioral scoring,
  trust profiles) and `Arbor.Security` (capability-based authorization).
  It answers two questions:

  1. **What mode applies?** — Given an agent's trust profile, what
     behavioral mode (block/ask/allow/auto) applies for a resource URI?
  2. **How do capabilities change on tier transitions?** — When an agent
     is promoted or demoted, what capabilities are granted or revoked?

  ## Trust Modes

  Four behavioral modes describe what happens when an agent tries to
  use a capability:

  - `:block` — hard deny, agent cannot use this capability
  - `:ask` — agent must get user confirmation each time
  - `:allow` — permitted, but user is notified
  - `:auto` — silent, just do it

  ## Resolution

  `effective_mode/3` resolves the mode using three layers:

  1. User preference — longest-prefix match in the agent's profile rules
  2. Security ceiling — system-enforced maximums (shell/governance → :ask)
  3. Model constraint — optional per-model-class ceiling

  The effective mode is the most restrictive of all three.

  ## Backward Compatibility

  `confirmation_mode/2` maps the 4-mode result to the 3-mode vocabulary
  that `ApprovalGuard` and `AcpSession.Handler` expect:

  - `:block` → `:deny`
  - `:ask` → `:gated`
  - `:allow` → `:auto` (proceed, notification handled elsewhere)
  - `:auto` → `:auto`

  ## Usage

      # New primary API — returns 4-mode result
      Policy.effective_mode("agent_123", "arbor://shell/exec/git")
      #=> :ask

      # Legacy API — returns 3-mode result for ApprovalGuard
      Policy.confirmation_mode("agent_123", "arbor://shell/exec/git")
      #=> :gated

      # Check if agent's profile allows a resource
      Policy.allowed?("agent_123", "arbor://code/read/self/*")
      #=> true

      # Grant all capabilities for a tier
      {:ok, caps} = Policy.grant_tier_capabilities("agent_123", :trusted)
  """

  alias Arbor.Trust.{Config, ProfileResolver}

  require Logger

  @type mode :: :block | :ask | :allow | :auto
  @type confirmation :: :auto | :gated | :deny

  # ===========================================================================
  # Query API — Trust Profile Resolution
  # ===========================================================================

  @doc """
  Get the effective trust mode for an agent and resource URI.

  This is the primary API. Returns the 4-mode result from the agent's
  trust profile, constrained by security ceilings and model constraints.

  Returns `:ask` if the trust system is unavailable (fail closed to gated).

  ## Options

  - `:model_class` — atom identifying the model class (e.g., `:frontier_cloud`)

  ## Examples

      Policy.effective_mode("agent_123", "arbor://code/read/self/*")
      #=> :auto

      Policy.effective_mode("agent_123", "arbor://shell/exec/rm")
      #=> :ask  (security ceiling enforced)

      Policy.effective_mode("agent_123", "arbor://shell")
      #=> :block  (if profile blocks shell)
  """
  @spec effective_mode(String.t(), String.t(), keyword()) :: mode()
  def effective_mode(agent_id, resource_uri, opts \\ []) do
    case get_profile(agent_id) do
      {:ok, profile} ->
        ProfileResolver.effective_mode(profile, resource_uri, opts)

      {:error, _} ->
        # Trust system unavailable — fail closed to :ask
        :ask
    end
  end

  @doc """
  Check if an agent's trust profile allows a resource URI.

  Returns `true` if the effective mode is anything other than `:block`.
  Returns `false` if the trust system is unavailable (fail closed).

  ## Examples

      Policy.allowed?("agent_123", "arbor://code/read/self/*")
      #=> true

      Policy.allowed?("agent_123", "arbor://shell/exec/rm")
      #=> true  (allowed, but may require confirmation)

      Policy.allowed?("agent_123", "arbor://governance/change/self/*")
      #=> false  (if profile blocks governance)
  """
  @spec allowed?(String.t(), String.t()) :: boolean()
  def allowed?(agent_id, resource_uri) do
    effective_mode(agent_id, resource_uri) != :block
  end

  @doc """
  Get the confirmation mode for a capability at the agent's trust level.

  This is the backward-compatible API for `ApprovalGuard` and
  `AcpSession.Handler`. Maps the 4-mode result to the 3-mode vocabulary:

  - `:block` → `:deny`
  - `:ask` → `:gated`
  - `:allow` → `:auto`
  - `:auto` → `:auto`

  ## Examples

      Policy.confirmation_mode("agent_123", "arbor://code/read/self/*")
      #=> :auto

      Policy.confirmation_mode("agent_123", "arbor://shell/exec/*")
      #=> :gated  (security ceiling enforced)
  """
  @spec confirmation_mode(String.t(), String.t()) :: confirmation()
  def confirmation_mode(agent_id, resource_uri) do
    mode_to_confirmation(effective_mode(agent_id, resource_uri))
  end

  # Conservative defaults when a profile does not declare an egress mode for a
  # tier. External egress asks (fail closed); on-host/on-premises/none proceed.
  # (On-premises is additionally gated by a separate config flag in the auth
  # path; the profile default here is the un-flagged baseline.)
  @egress_mode_defaults %{
    on_host: :allow,
    on_premises: :allow,
    external_provider: :ask,
    external_peer: :ask,
    none: :allow
  }

  @doc """
  Get the agent's egress mode for a resolved egress tier (2026-06-14
  URI-addressing-vs-classification decision).

  Keyed by `Arbor.Contracts.Security.Classification` egress_tier — NOT by URI.
  Reads the agent's profile `egress_modes` map (explicit per profile, NOT derived
  from trust_score, per the tiers→custom-profiles direction). Falls back to a
  conservative default for unset tiers, and fails closed (`:ask` for external)
  when the trust system is unavailable. Tolerant of string keys/values from JSON
  profile round-trips.

  ## Examples

      Policy.egress_mode("agent_trusted", :external_provider)   #=> :allow  (if profile sets it)
      Policy.egress_mode("agent_new", :external_provider)       #=> :ask    (default)
      Policy.egress_mode("agent_new", :on_host)                 #=> :allow
  """
  @spec egress_mode(String.t(), atom()) :: mode()
  def egress_mode(agent_id, tier) when is_binary(agent_id) and is_atom(tier) do
    case get_profile(agent_id) do
      {:ok, profile} -> lookup_egress_mode(Map.get(profile, :egress_modes), tier)
      {:error, _} -> default_egress_mode(tier)
    end
  end

  defp lookup_egress_mode(modes, tier) when is_map(modes) do
    raw = Map.get(modes, tier) || Map.get(modes, Atom.to_string(tier))

    case normalize_egress_mode(raw) do
      nil -> default_egress_mode(tier)
      mode -> mode
    end
  end

  defp lookup_egress_mode(_modes, tier), do: default_egress_mode(tier)

  # The fallback egress mode for a tier when the agent's profile does not declare
  # one. The library default is conservative (external -> :ask), but a deployment
  # can set a system-wide posture via `config :arbor_trust, :default_egress_modes`
  # — e.g. a single-operator deployment may default `external_provider: :allow`
  # so enabling enforcement activates the taint-exfil block + per-agent tightening
  # without gating every agent's normal cloud egress.
  defp default_egress_mode(tier) do
    overrides = Application.get_env(:arbor_trust, :default_egress_modes, %{})

    case normalize_egress_mode(
           Map.get(overrides, tier) || Map.get(overrides, Atom.to_string(tier))
         ) do
      nil -> Map.get(@egress_mode_defaults, tier, :ask)
      mode -> mode
    end
  end

  defp normalize_egress_mode(m) when m in [:allow, :ask, :block, :auto], do: m
  defp normalize_egress_mode("allow"), do: :allow
  defp normalize_egress_mode("ask"), do: :ask
  defp normalize_egress_mode("block"), do: :block
  defp normalize_egress_mode("auto"), do: :auto
  defp normalize_egress_mode(_), do: nil

  @doc """
  Map a 4-mode trust mode to the 3-mode confirmation vocabulary.

  ## Examples

      Policy.mode_to_confirmation(:block)
      #=> :deny

      Policy.mode_to_confirmation(:ask)
      #=> :gated

      Policy.mode_to_confirmation(:allow)
      #=> :auto

      Policy.mode_to_confirmation(:auto)
      #=> :auto
  """
  @spec mode_to_confirmation(mode()) :: confirmation()
  def mode_to_confirmation(:block), do: :deny
  def mode_to_confirmation(:ask), do: :gated
  def mode_to_confirmation(:allow), do: :auto
  def mode_to_confirmation(:auto), do: :auto

  @doc """
  Check if a resource requires approval at the agent's current trust level.

  Returns `true` if the effective mode is `:ask` (requires confirmation),
  `false` if `:allow` or `:auto` (no confirmation needed),
  and `{:error, :denied}` if `:block`.

  ## Examples

      Policy.requires_approval?("agent_123", "arbor://code/write/self/impl/*")
      #=> true  (mode is :ask)

      Policy.requires_approval?("agent_123", "arbor://code/read/self/*")
      #=> false  (mode is :auto)
  """
  @spec requires_approval?(String.t(), String.t()) :: boolean() | {:error, :denied | term()}
  def requires_approval?(agent_id, resource_uri) do
    case effective_mode(agent_id, resource_uri) do
      :block -> {:error, :denied}
      :ask -> true
      :allow -> false
      :auto -> false
    end
  end

  @doc """
  Explain the trust resolution chain for debugging.

  Returns a map showing how the effective mode was determined.

  ## Examples

      Policy.explain("agent_123", "arbor://shell/exec/git")
      #=> %{resource_uri: "arbor://shell/exec/git", user_mode: :block,
      #     security_ceiling: :ask, effective_mode: :ask, ...}
  """
  @spec explain(String.t(), String.t(), keyword()) :: map()
  def explain(agent_id, resource_uri, opts \\ []) do
    case get_profile(agent_id) do
      {:ok, profile} ->
        ProfileResolver.explain(profile, resource_uri, opts)

      {:error, reason} ->
        %{
          resource_uri: resource_uri,
          error: reason,
          effective_mode: :ask
        }
    end
  end

  @doc """
  Get the minimum tier required for a resource URI.

  Delegates to `Config.min_tier_for_capability/1`.

  ## Examples

      Policy.min_tier_for("arbor://code/write/self/impl/*")
      #=> :trusted

      Policy.min_tier_for("arbor://capability/request/self/*")
      #=> :autonomous
  """
  @spec min_tier_for(String.t()) :: Config.trust_tier() | nil
  def min_tier_for(resource_uri) do
    Config.min_tier_for_capability(resource_uri)
  end

  # ===========================================================================
  # Trust Profile Management
  # ===========================================================================

  @doc """
  Derive trust profile rules from a tier.

  Used to initialize rules for profiles that were created before
  the trust profiles redesign (they have a tier but no rules).

  Maps tiers to presets:
  - `:untrusted`, `:probationary` → `:cautious`
  - `:trusted` → `:balanced`
  - `:veteran` → `:hands_off`
  - `:autonomous` → `:full_trust`

  ## Examples

      Policy.tier_to_preset(:trusted)
      #=> :balanced
  """
  @spec tier_to_preset(atom()) :: atom()
  defdelegate tier_to_preset(tier), to: Arbor.Trust.Authority

  @doc """
  Initialize trust profile rules from a preset.

  Returns `{baseline, rules}` for the given preset name.
  Used during profile creation and migration.

  ## Examples

      {baseline, rules} = Policy.preset_rules(:balanced)
      #=> {:ask, %{"arbor://fs/read" => :auto, ...}}
  """
  @spec preset_rules(atom()) :: {mode(), map()}
  def preset_rules(preset_name) do
    preset = ProfileResolver.preset(preset_name)
    {preset.baseline, preset.rules}
  end

  # ===========================================================================
  # Capability Provisioning
  # ===========================================================================

  @doc """
  Grant all capabilities for a tier to an agent.

  Creates capability entries in the CapabilityStore for each capability
  template defined at the given tier. Uses `Security.grant/1` which
  signs capabilities via SystemAuthority.

  Returns `{:ok, count}` with the number of capabilities granted,
  or `{:error, reason}` if the security infrastructure is unavailable.

  ## Examples

      {:ok, 12} = Policy.grant_tier_capabilities("agent_123", :trusted)
  """
  @spec grant_tier_capabilities(String.t(), Config.trust_tier()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def grant_tier_capabilities(agent_id, tier) do
    templates = Config.capabilities_for_tier(tier)

    with :ok <- ensure_security_available() do
      results =
        Enum.map(templates, fn template ->
          resource_uri = resolve_uri(template.resource_uri, agent_id)

          Arbor.Security.grant(
            principal: agent_id,
            resource: resource_uri,
            constraints: template.constraints,
            metadata: %{source: :trust_tier, tier: tier}
          )
        end)

      granted = Enum.count(results, &match?({:ok, _}, &1))
      errors = Enum.filter(results, &match?({:error, _}, &1))

      if errors != [] do
        Logger.warning(
          "[Policy] #{length(errors)} capability grants failed for #{agent_id}: #{inspect(Enum.take(errors, 3))}"
        )
      end

      safe_emit(:capabilities_granted, %{
        agent_id: agent_id,
        tier: tier,
        granted: granted,
        failed: length(errors)
      })

      {:ok, granted}
    end
  end

  @doc """
  Revoke all capabilities for an agent.

  Calls `CapabilityStore.revoke_all/1` directly since the Security facade
  doesn't expose bulk revocation.

  ## Examples

      {:ok, 12} = Policy.revoke_agent_capabilities("agent_123")
  """
  @spec revoke_agent_capabilities(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoke_agent_capabilities(agent_id) do
    with :ok <- ensure_security_available() do
      Arbor.Security.CapabilityStore.revoke_all(agent_id)
    end
  rescue
    e ->
      Logger.error("[Policy] Failed to revoke capabilities for #{agent_id}: #{inspect(e)}")
      {:error, :revoke_failed}
  end

  # ===========================================================================
  # Internals
  # ===========================================================================

  defp get_profile(agent_id) do
    if trust_available?() do
      Arbor.Trust.get_trust_profile(agent_id)
    else
      {:error, :trust_unavailable}
    end
  end

  defp resolve_uri(template_uri, agent_id) do
    template_uri
    |> String.replace("/self/", "/#{agent_id}/")
    |> String.replace(~r"/self$", "/#{agent_id}")
  end

  defp trust_available? do
    Process.whereis(Arbor.Trust.Manager) != nil
  end

  defp ensure_security_available do
    if Process.whereis(Arbor.Security.CapabilityStore) != nil do
      :ok
    else
      {:error, :security_unavailable}
    end
  end

  defp safe_emit(type, data) do
    if Code.ensure_loaded?(Arbor.Signals) and
         function_exported?(Arbor.Signals, :emit, 3) do
      Arbor.Signals.emit(:trust, type, data)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
