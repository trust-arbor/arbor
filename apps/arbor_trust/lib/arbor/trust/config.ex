defmodule Arbor.Trust.Config do
  @moduledoc """
  Central configuration reader for the trust system.

  All trust modules call this instead of using hardcoded module attributes.
  Configuration is read from application env with sensible defaults.

  ## Configuration

      # config/config.exs
      config :arbor_trust,
        pubsub: Arbor.Core.PubSub,
        circuit_breaker: %{
          rapid_failure_threshold: 5,
          rapid_failure_window_seconds: 60,
          security_violation_threshold: 3,
          security_violation_window_seconds: 3600,
          rollback_threshold: 3,
          rollback_window_seconds: 3600,
          test_failure_threshold: 5,
          test_failure_window_seconds: 300,
          freeze_duration_seconds: 86_400,
          half_open_duration_seconds: 3600
        }
  """

  alias Arbor.Contracts.Security.Classification

  # Default anti-spam budget for the A1 proactive notify channel
  # (arbor://comms/notify/session), applied as a :rate_limit constraint on the
  # grant — tokens per rate_limit_refill_period_seconds (1h default). Notify is
  # allow-by-default (Phase 2 trust posture), so every agent gets the capability
  # with this budget. Keep in sync with
  # `Arbor.Actions.Comms.NotifySession.default_rate_limit/0` (the action's declared
  # budget); a drift guard in arbor_agent's lifecycle test asserts they match.
  # (We can't read NotifySession here — arbor_actions is L6, above arbor_trust L4.)
  @notify_session_rate_limit 30

  @egress_mode_defaults Map.new(Classification.egress_tiers(), fn tier ->
                          {tier, if(Classification.external_egress?(tier), do: :ask, else: :allow)}
                        end)

  # The universal baseline capabilities every agent gets at profile creation.
  # Self-scoped (`/self/`) URIs are expanded to the agent's id at grant time.
  # This is the read-only floor preserved across a trust freeze and re-granted on
  # unfreeze — see Arbor.Trust.CapabilitySync.
  @base_capabilities [
    %{resource_uri: "arbor://code/read/self/*", constraints: %{}},
    %{resource_uri: "arbor://consensus/propose/self", constraints: %{rate_limit: 10}},
    %{resource_uri: "arbor://agent/profile/self/*", constraints: %{}},
    %{
      resource_uri: "arbor://comms/notify/session",
      constraints: %{rate_limit: @notify_session_rate_limit}
    }
  ]

  @default_capability_templates %{}

  @default_circuit_breaker %{
    rapid_failure_threshold: 5,
    rapid_failure_window_seconds: 60,
    security_violation_threshold: 3,
    security_violation_window_seconds: 3600,
    rollback_threshold: 3,
    rollback_window_seconds: 3600,
    test_failure_threshold: 5,
    test_failure_window_seconds: 300,
    freeze_duration_seconds: 86_400,
    half_open_duration_seconds: 3600
  }

  @doc "Get the PubSub module to use."
  @spec pubsub() :: module()
  def pubsub, do: get(:pubsub, Arbor.Core.PubSub)

  @doc "Get capability templates."
  @spec capability_templates() :: map()
  def capability_templates, do: get(:capability_templates, @default_capability_templates)

  @doc "Get circuit breaker configuration."
  @spec circuit_breaker_config() :: map()
  def circuit_breaker_config, do: get(:circuit_breaker, @default_circuit_breaker)

  @doc """
  Trust policy module used by policy-layer authorization.
  """
  @spec policy_module() :: module()
  def policy_module do
    get(:policy_module, Arbor.Trust.Policy)
  end

  @doc """
  Whether trust-policy JIT capability minting is enabled.

  During the A1 kernel/policy boundary move this reads the new trust-layer
  key first and falls back to the historical `:arbor_security` key so existing
  dev/prod config keeps its behavior.
  """
  @spec policy_enforcer_enabled?() :: boolean()
  def policy_enforcer_enabled? do
    get(
      :policy_enforcer_enabled,
      Application.get_env(:arbor_security, :policy_enforcer_enabled, true)
    )
  end

  @doc """
  Whether trust-policy approval gating is enabled.

  Reads `:arbor_trust, :approval_guard_enabled` first, then the historical
  `:arbor_security` key for compatibility.
  """
  @spec approval_guard_enabled?() :: boolean()
  def approval_guard_enabled? do
    get(
      :approval_guard_enabled,
      Application.get_env(:arbor_security, :approval_guard_enabled, true)
    )
  end

  @doc """
  Runtime provider for generated action-namespace capability profiles.

  There is no Trust default. Full-profile action contribution is explicit
  and upward-owned. Returns the configured module atom, or `nil` when unset.

  This function only reads application env. Callers other than full-profile
  snapshot projection must not `Code.ensure_loaded?/1` the atom; activation_only
  must neither invoke nor load the provider.
  """
  @spec action_profile_provider() :: module() | nil
  def action_profile_provider do
    case Application.fetch_env(:arbor_trust, :action_profile_provider) do
      {:ok, provider} when is_atom(provider) and not is_nil(provider) -> provider
      _ -> nil
    end
  end

  @doc """
  Library default egress standing used when a profile omits a tier.
  """
  @spec egress_mode_defaults() :: %{atom() => :block | :ask | :allow | :auto}
  def egress_mode_defaults, do: @egress_mode_defaults

  @doc """
  Validated immutable policy snapshot for the given closed start profile.
  """
  @spec startup_policy_snapshot(:full | :activation_only) ::
          {:ok, map()} | {:error, :malformed_policy_snapshot}
  def startup_policy_snapshot(start_profile)
      when start_profile in [:full, :activation_only] do
    include_action_provider? = start_profile == :full and not is_nil(action_profile_provider())

    with {:ok, security_ceilings} <- merge_security_ceilings(),
         {:ok, default_egress_modes} <- merge_egress_defaults() do
      {:ok,
       %{
         start_profile: start_profile,
         security_ceilings: security_ceilings,
         allow_permissive_baseline: get(:allow_permissive_baseline, false) == true,
         default_egress_modes: default_egress_modes,
         capability_profiles:
           Arbor.Trust.CapabilityProfileRegistry.project_profiles(
             include_action_provider: include_action_provider?
           ),
         action_profiles_admitted: include_action_provider?
       }}
    end
  end

  defp merge_security_ceilings do
    case get(:security_ceilings, %{}) || %{} do
      overrides when is_map(overrides) ->
        admit_mode_map(
          Map.merge(Arbor.Trust.Presets.default_security_ceilings(), overrides),
          :binary
        )

      _invalid ->
        {:error, :malformed_policy_snapshot}
    end
  end

  defp merge_egress_defaults do
    case get(:default_egress_modes, %{}) || %{} do
      overrides when is_map(overrides) ->
        Enum.reduce_while(overrides, {:ok, @egress_mode_defaults}, fn {key, value}, {:ok, acc} ->
          case {normalize_egress_key(key), normalize_mode(value)} do
            {tier, mode} when not is_nil(tier) and not is_nil(mode) ->
              {:cont, {:ok, Map.put(acc, tier, mode)}}

            _ ->
              {:halt, {:error, :malformed_policy_snapshot}}
          end
        end)

      _invalid ->
        {:error, :malformed_policy_snapshot}
    end
  end

  defp admit_mode_map(map, key_kind) when is_map(map) do
    valid? =
      Enum.all?(map, fn {key, value} ->
        valid_mode_key?(key, key_kind) and value in [:block, :ask, :allow, :auto]
      end)

    if valid?, do: {:ok, map}, else: {:error, :malformed_policy_snapshot}
  end

  defp admit_mode_map(_map, _key_kind), do: {:error, :malformed_policy_snapshot}

  defp valid_mode_key?(key, :binary), do: is_binary(key) and byte_size(key) > 0
  defp valid_mode_key?(key, :atom), do: is_atom(key) and key != nil

  defp normalize_egress_key(key) when is_atom(key) do
    if key in Classification.egress_tiers(), do: key, else: nil
  end

  defp normalize_egress_key(key) when is_binary(key) do
    Enum.find(Classification.egress_tiers(), &(Atom.to_string(&1) == key))
  end

  defp normalize_egress_key(_key), do: nil

  defp normalize_mode(mode) when mode in [:block, :ask, :allow, :auto], do: mode
  defp normalize_mode("block"), do: :block
  defp normalize_mode("ask"), do: :ask
  defp normalize_mode("allow"), do: :allow
  defp normalize_mode("auto"), do: :auto
  defp normalize_mode(_mode), do: nil

  # ===========================================================================
  # Capabilities
  # ===========================================================================

  @doc """
  Get the universal baseline capabilities granted to every agent at profile
  creation. Self-scoped URIs are expanded to the agent's id by the grant path.
  """
  @spec base_capabilities() :: [map()]
  def base_capabilities, do: @base_capabilities

  @doc """
  Generate the universal baseline capability maps for an agent, expanding
  self-scoped (`/self/`) URIs to the agent's id.
  """
  @spec generate_capabilities(String.t()) :: [map()]
  def generate_capabilities(agent_id) do
    base_capabilities()
    |> Enum.map(fn template ->
      resource_uri =
        template.resource_uri
        |> String.replace("/self/", "/#{agent_id}/")
        |> String.replace(~r"/self$", "/#{agent_id}")

      %{
        resource_uri: resource_uri,
        principal_id: agent_id,
        constraints: template.constraints,
        metadata: %{
          source: :trust_baseline,
          generated_at: DateTime.utc_now()
        }
      }
    end)
  end

  # Private helpers

  defp get(key, default), do: Application.get_env(:arbor_trust, key, default)
end
