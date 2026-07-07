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

  # Default anti-spam budget for the A1 proactive notify channel
  # (arbor://comms/notify/session), applied as a :rate_limit constraint on the
  # grant — tokens per rate_limit_refill_period_seconds (1h default). Notify is
  # allow-by-default (Phase 2 trust posture), so every agent gets the capability
  # with this budget. Keep in sync with
  # `Arbor.Actions.Comms.NotifySession.default_rate_limit/0` (the action's declared
  # budget); a drift guard in arbor_agent's lifecycle test asserts they match.
  # (We can't read NotifySession here — arbor_actions is L6, above arbor_trust L4.)
  @notify_session_rate_limit 30
  @default_action_profile_provider Module.concat(["Arbor", "Actions"])

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

  Defaults to `Arbor.Actions` by module atom without a compile-time dependency;
  `arbor_trust` is lower in the umbrella hierarchy than `arbor_actions`.
  """
  @spec action_profile_provider() :: module() | nil
  def action_profile_provider do
    get(:action_profile_provider, @default_action_profile_provider)
  end

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
