defmodule Arbor.Trust.Policy do
  @moduledoc """
  Bridges trust profiles to capability authorization.

  The Policy module is the glue between `Arbor.Trust` (trust profiles) and
  `Arbor.Security` (capability-based authorization). It answers: given an
  agent's trust profile, what behavioral mode (block/ask/allow/auto) applies
  for a resource URI?

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

      # Grant the universal baseline capabilities
      {:ok, count} = Policy.grant_base_capabilities("agent_123")
  """

  alias Arbor.Contracts.Security.Classification
  alias Arbor.Trust.{Config, PolicyHost, ProfileResolver}

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

  Returns `:block` if the policy host is unavailable (fail closed).

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
    with :ok <- admit_public_opts(opts),
         {:ok, snapshot} <- PolicyHost.snapshot() do
      profile = profile_or_stub(agent_id)
      host_opts = public_host_opts(opts, snapshot)
      host_result = ProfileResolver.effective_mode(profile, resource_uri, host_opts)

      ProfileResolver.most_restrictive([
        host_result,
        caller_ceiling_mode(opts, resource_uri)
      ])
    else
      _ -> :block
    end
  end

  @doc """
  Check if an agent's trust profile allows a resource URI.

  Returns `true` if the effective mode is anything other than `:block`.
  Returns `false` if the policy host is unavailable (fail closed).

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
  @spec confirmation_mode(String.t(), String.t(), keyword()) :: confirmation()
  def confirmation_mode(agent_id, resource_uri, opts \\ []) do
    mode_to_confirmation(effective_mode(agent_id, resource_uri, opts))
  end

  @doc """
  Get the agent's egress mode for a resolved egress tier (2026-06-14
  URI-addressing-vs-classification decision).

  Keyed by `Arbor.Contracts.Security.Classification` egress_tier — NOT by URI.
  Reads the agent's profile `egress_modes` map (explicit per profile, per the
  tiers→custom-profiles direction). Falls back to a
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
    case PolicyHost.snapshot() do
      {:ok, snapshot} ->
        defaults = snapshot.default_egress_modes

        case get_profile(agent_id) do
          {:ok, profile} -> lookup_egress_mode(Map.get(profile, :egress_modes), tier, defaults)
          {:error, _} -> default_egress_mode(tier, defaults)
        end

      {:error, _} ->
        :ask
    end
  end

  defp lookup_egress_mode(modes, tier, defaults) when is_map(modes) do
    raw = Map.get(modes, tier) || Map.get(modes, Atom.to_string(tier))

    case normalize_egress_mode(raw) do
      nil -> default_egress_mode(tier, defaults)
      mode -> mode
    end
  end

  defp lookup_egress_mode(_modes, tier, defaults), do: default_egress_mode(tier, defaults)

  defp default_egress_mode(tier, defaults) when is_map(defaults) do
    case normalize_egress_mode(Map.get(defaults, tier) || Map.get(defaults, Atom.to_string(tier))) do
      nil -> Map.get(Config.egress_mode_defaults(), tier, :ask)
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
    with :ok <- admit_public_opts(opts),
         {:ok, snapshot} <- PolicyHost.snapshot() do
      profile = profile_or_stub(agent_id)
      host_opts = public_host_opts(opts, snapshot)
      result = ProfileResolver.explain(profile, resource_uri, host_opts)
      caller_mode = caller_ceiling_mode(opts, resource_uri)
      effective = ProfileResolver.most_restrictive([result.effective_mode, caller_mode])
      ceiling = ProfileResolver.most_restrictive([result.security_ceiling, caller_mode])
      %{result | effective_mode: effective, security_ceiling: ceiling}
    else
      :error ->
        %{resource_uri: resource_uri, error: :malformed_policy_opts, effective_mode: :block}

      {:error, reason} ->
        %{resource_uri: resource_uri, error: reason, effective_mode: :block}
    end
  end

  # ===========================================================================
  # Trust Profile Management
  # ===========================================================================

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
  Grant the universal baseline capabilities to an agent.
  Self-scoped (`/self/`) URIs are resolved to the agent's id. Returns
  `{:ok, count}` or `{:error, reason}` if the security infrastructure is down.
  """
  @spec grant_base_capabilities(String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def grant_base_capabilities(agent_id) do
    templates = Config.base_capabilities()

    with :ok <- ensure_security_available() do
      results =
        Enum.map(templates, fn template ->
          resource_uri = resolve_uri(template.resource_uri, agent_id)

          Arbor.Security.grant(
            principal: agent_id,
            resource: resource_uri,
            constraints: template.constraints,
            metadata: %{source: :trust_baseline}
          )
        end)

      granted = Enum.count(results, &match?({:ok, _}, &1))
      errors = Enum.filter(results, &match?({:error, _}, &1))

      if errors != [] do
        Logger.warning(
          "[Policy] #{length(errors)} baseline capability grants failed for #{agent_id}: #{inspect(Enum.take(errors, 3))}"
        )
      end

      safe_emit(:capabilities_granted, %{
        agent_id: agent_id,
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

  @doc false
  @spec tighten_public_opts(String.t(), keyword()) ::
          {:ok, keyword()} | {:error, :malformed_policy_opts}
  def tighten_public_opts(agent_id, opts) when is_binary(agent_id) and is_list(opts) do
    with :ok <- admit_public_opts(opts) do
      case Keyword.fetch(opts, :egress_tier) do
        :error ->
          {:ok, opts}

        {:ok, tier} ->
          host_mode = egress_mode(agent_id, tier)
          caller_mode = caller_egress_mode(opts)
          tightened = ProfileResolver.most_restrictive([host_mode, caller_mode])
          {:ok, Keyword.put(opts, :egress_mode, tightened)}
      end
    else
      :error -> {:error, :malformed_policy_opts}
    end
  end

  def tighten_public_opts(_agent_id, _opts), do: {:error, :malformed_policy_opts}

  defp profile_or_stub(agent_id) do
    case get_profile(agent_id) do
      {:ok, profile} -> profile
      {:error, _} -> missing_profile_stub(agent_id)
    end
  end

  defp missing_profile_stub(agent_id) when is_binary(agent_id) do
    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(agent_id)
    profile
  end

  defp public_host_opts(opts, snapshot) do
    opts
    |> Keyword.delete(:security_ceilings)
    |> Keyword.put(:security_ceilings, snapshot.security_ceilings)
    |> Keyword.put(:allow_permissive_baseline, permissive_flag(opts, snapshot))
  end

  defp permissive_flag(opts, snapshot) do
    host? = snapshot.allow_permissive_baseline == true

    case Keyword.fetch(opts, :allow_permissive_baseline) do
      {:ok, false} -> false
      {:ok, true} -> host?
      _ -> host?
    end
  end

  defp caller_ceiling_mode(opts, resource_uri) do
    case Keyword.fetch(opts, :security_ceilings) do
      {:ok, ceilings} when is_map(ceilings) ->
        ProfileResolver.resolve_prefix(ceilings, resource_uri, :auto)

      :error ->
        :auto
    end
  end

  defp caller_egress_mode(opts) do
    case Keyword.fetch(opts, :egress_mode) do
      {:ok, mode} when mode in [:block, :ask, :allow, :auto] -> mode
      :error -> :auto
    end
  end

  # Option presence is Keyword.fetch/2; a supplied value is never treated as omitted.
  defp admit_public_opts(opts) do
    if Keyword.keyword?(opts) do
      with :ok <- admit_optional_ceiling_map(Keyword.fetch(opts, :security_ceilings)),
           :ok <- admit_optional_boolean(Keyword.fetch(opts, :allow_permissive_baseline)),
           :ok <- admit_optional_mode(Keyword.fetch(opts, :egress_mode)),
           :ok <- admit_optional_egress_tier(Keyword.fetch(opts, :egress_tier)) do
        :ok
      end
    else
      :error
    end
  end

  defp admit_optional_ceiling_map(:error), do: :ok

  defp admit_optional_ceiling_map({:ok, map}) when is_map(map) do
    valid? =
      Enum.all?(map, fn {key, value} ->
        is_binary(key) and byte_size(key) > 0 and value in [:block, :ask, :allow, :auto]
      end)

    if valid?, do: :ok, else: :error
  end

  defp admit_optional_ceiling_map(_fetched), do: :error

  defp admit_optional_boolean(:error), do: :ok
  defp admit_optional_boolean({:ok, value}) when is_boolean(value), do: :ok
  defp admit_optional_boolean(_fetched), do: :error

  defp admit_optional_mode(:error), do: :ok
  defp admit_optional_mode({:ok, mode}) when mode in [:block, :ask, :allow, :auto], do: :ok
  defp admit_optional_mode(_fetched), do: :error

  defp admit_optional_egress_tier(:error), do: :ok

  defp admit_optional_egress_tier({:ok, tier}) do
    if tier in Classification.egress_tiers(), do: :ok, else: :error
  end

  defp admit_optional_egress_tier(_fetched), do: :error

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
    Arbor.Signals.emit(:trust, type, data)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
