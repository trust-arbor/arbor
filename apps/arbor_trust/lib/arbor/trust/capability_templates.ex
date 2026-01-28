defmodule Arbor.Trust.CapabilityTemplates do
  @moduledoc """
  Capability templates for trust-tier-based capabilities.

  This module defines the capability sets available at each trust tier.
  When an agent's trust level changes, these templates determine what
  capabilities should be granted or revoked.

  ## Configuration

  Capability templates can be overridden via application config:

      config :arbor_trust,
        capability_templates: %{
          trusted: [
            %{resource_uri: "arbor://custom/action", constraints: %{}}
          ]
        }

  Config entries take precedence over the built-in defaults. Tiers not
  present in config fall back to the hardcoded defaults below.

  ## Trust Tiers and Capabilities

  | Tier | Capabilities |
  |------|--------------|
  | :untrusted | Read own code only |
  | :probationary | + Sandbox modifications (rate-limited) |
  | :trusted | + Self-modify with approval |
  | :veteran | + Self-modify auto-approved |
  | :autonomous | + Modify own capabilities |

  ## Usage

      # Get capabilities for a tier
      capabilities = CapabilityTemplates.capabilities_for_tier(:trusted)

      # Get new capabilities when promoted
      new_caps = CapabilityTemplates.capabilities_gained(:probationary, :trusted)

      # Get capabilities lost when demoted
      lost_caps = CapabilityTemplates.capabilities_lost(:trusted, :probationary)
  """

  @type trust_tier :: :untrusted | :probationary | :trusted | :veteran | :autonomous
  @type capability_template :: %{
          resource_uri: String.t(),
          constraints: map()
        }

  # Default capability definitions by tier
  # Note: All tiers get arbor://consensus/propose/self - anyone can propose ideas to earn trust
  # URI format: arbor://category/action/target (target can include wildcards like /self/*)
  @default_tier_capabilities %{
    untrusted: [
      %{resource_uri: "arbor://code/read/self/*", constraints: %{}},
      # All agents can propose to consensus (earn trust by having ideas accepted)
      %{resource_uri: "arbor://consensus/propose/self", constraints: %{rate_limit: 10}}
    ],
    probationary: [
      %{resource_uri: "arbor://code/read/self/*", constraints: %{}},
      %{resource_uri: "arbor://code/write/self/sandbox/*", constraints: %{rate_limit: 10}},
      %{resource_uri: "arbor://code/compile/self/sandbox", constraints: %{}},
      %{resource_uri: "arbor://consensus/propose/self", constraints: %{rate_limit: 20}},
      # Roadmap operations - can work on items in sandboxed way
      %{resource_uri: "arbor://roadmap/read/self/*", constraints: %{}},
      %{resource_uri: "arbor://roadmap/write/self/brainstorming/*", constraints: %{}},
      # Git read access (read-only, low risk)
      %{resource_uri: "arbor://git/read/self/log", constraints: %{}},
      # Activity stream logging (observability, low risk)
      %{resource_uri: "arbor://activity/emit/self", constraints: %{rate_limit: 100}}
    ],
    trusted: [
      %{resource_uri: "arbor://code/read/self/*", constraints: %{}},
      %{resource_uri: "arbor://code/write/self/sandbox/*", constraints: %{rate_limit: 10}},
      %{resource_uri: "arbor://code/compile/self/sandbox", constraints: %{}},
      %{resource_uri: "arbor://code/write/self/impl/*", constraints: %{requires_approval: true}},
      %{resource_uri: "arbor://code/reload/self/*", constraints: %{requires_approval: true}},
      # Body extensions (file operations, etc.) - basic abilities, not security capabilities
      %{resource_uri: "arbor://extension/request/self/*", constraints: %{}},
      %{resource_uri: "arbor://consensus/propose/self", constraints: %{rate_limit: 50}},
      # Roadmap operations - can work on planned/in-progress items
      %{resource_uri: "arbor://roadmap/read/self/*", constraints: %{}},
      %{resource_uri: "arbor://roadmap/write/self/*", constraints: %{}},
      # Move to discarded only (for ConsistencyAgent cleanup - constrained write)
      %{resource_uri: "arbor://roadmap/move/self/discarded", constraints: %{rate_limit: 20}},
      # Write to discarded INDEX.md (for recording discard reasons)
      %{
        resource_uri: "arbor://roadmap/write/self/discarded/index",
        constraints: %{rate_limit: 20}
      },
      # Git read access (for staleness checks)
      %{resource_uri: "arbor://git/read/self/log", constraints: %{}},
      # Activity stream logging
      %{resource_uri: "arbor://activity/emit/self", constraints: %{rate_limit: 100}},
      # Configuration changes require approval
      %{resource_uri: "arbor://config/write/self/*", constraints: %{requires_approval: true}},
      # Documentation changes (low risk)
      %{resource_uri: "arbor://docs/write/self/*", constraints: %{}},
      # Test changes (low risk)
      %{resource_uri: "arbor://test/write/self/*", constraints: %{}}
    ],
    veteran: [
      %{resource_uri: "arbor://code/read/self/*", constraints: %{}},
      %{resource_uri: "arbor://code/write/self/sandbox/*", constraints: %{}},
      %{resource_uri: "arbor://code/compile/self/sandbox", constraints: %{}},
      %{resource_uri: "arbor://code/write/self/impl/*", constraints: %{}},
      %{resource_uri: "arbor://code/reload/self/*", constraints: %{}},
      %{resource_uri: "arbor://code/compile/self/impl", constraints: %{}},
      # Body extensions - no approval needed for veterans
      %{resource_uri: "arbor://extension/request/self/*", constraints: %{}},
      %{resource_uri: "arbor://consensus/propose/self", constraints: %{}},
      # Roadmap operations - full access
      %{resource_uri: "arbor://roadmap/read/self/*", constraints: %{}},
      %{resource_uri: "arbor://roadmap/write/self/*", constraints: %{}},
      # Move to discarded (for cleanup operations)
      %{resource_uri: "arbor://roadmap/move/self/discarded", constraints: %{}},
      # Write to discarded INDEX.md (for recording discard reasons)
      %{resource_uri: "arbor://roadmap/write/self/discarded/index", constraints: %{}},
      # Git read access (for staleness checks)
      %{resource_uri: "arbor://git/read/self/log", constraints: %{}},
      # Activity stream logging
      %{resource_uri: "arbor://activity/emit/self", constraints: %{}},
      # Config changes without approval for veterans
      %{resource_uri: "arbor://config/write/self/*", constraints: %{}},
      # Documentation and test changes
      %{resource_uri: "arbor://docs/write/self/*", constraints: %{}},
      %{resource_uri: "arbor://test/write/self/*", constraints: %{}},
      # Installation capability - can install approved changes
      %{resource_uri: "arbor://install/execute/self", constraints: %{requires_approval: true}}
    ],
    autonomous: [
      %{resource_uri: "arbor://code/read/self/*", constraints: %{}},
      %{resource_uri: "arbor://code/write/self/sandbox/*", constraints: %{}},
      %{resource_uri: "arbor://code/compile/self/sandbox", constraints: %{}},
      %{resource_uri: "arbor://code/write/self/impl/*", constraints: %{}},
      %{resource_uri: "arbor://code/reload/self/*", constraints: %{}},
      %{resource_uri: "arbor://code/compile/self/impl", constraints: %{}},
      # Body extensions - autonomous can request freely
      %{resource_uri: "arbor://extension/request/self/*", constraints: %{}},
      # Security capability management - only autonomous tier
      %{resource_uri: "arbor://capability/request/self/*", constraints: %{}},
      %{resource_uri: "arbor://capability/delegate/self/*", constraints: %{}},
      %{resource_uri: "arbor://consensus/propose/self", constraints: %{}},
      # Roadmap operations - full access
      %{resource_uri: "arbor://roadmap/read/self/*", constraints: %{}},
      %{resource_uri: "arbor://roadmap/write/self/*", constraints: %{}},
      # Move to discarded (for cleanup operations)
      %{resource_uri: "arbor://roadmap/move/self/discarded", constraints: %{}},
      # Write to discarded INDEX.md (for recording discard reasons)
      %{resource_uri: "arbor://roadmap/write/self/discarded/index", constraints: %{}},
      # Git read access
      %{resource_uri: "arbor://git/read/self/log", constraints: %{}},
      # Activity stream logging
      %{resource_uri: "arbor://activity/emit/self", constraints: %{}},
      # Config changes
      %{resource_uri: "arbor://config/write/self/*", constraints: %{}},
      # Documentation and test changes
      %{resource_uri: "arbor://docs/write/self/*", constraints: %{}},
      %{resource_uri: "arbor://test/write/self/*", constraints: %{}},
      # Installation capability - can install without approval
      %{resource_uri: "arbor://install/execute/self", constraints: %{}},
      # Governance changes - highest privilege
      %{resource_uri: "arbor://governance/change/self/*", constraints: %{requires_approval: true}}
    ]
  }

  @doc """
  Get all capabilities for a trust tier.

  Checks `Arbor.Trust.Config.capability_templates()` first for overrides,
  then falls back to built-in defaults.

  ## Example

      capabilities = CapabilityTemplates.capabilities_for_tier(:trusted)
      # Returns list of capability templates
  """
  @spec capabilities_for_tier(trust_tier()) :: [capability_template()]
  def capabilities_for_tier(tier) when is_atom(tier) do
    Map.get(tier_capabilities(), tier, [])
  end

  @doc """
  Get capabilities gained when promoted from one tier to another.

  ## Example

      new_caps = CapabilityTemplates.capabilities_gained(:probationary, :trusted)
      # Returns capabilities in :trusted but not in :probationary
  """
  @spec capabilities_gained(trust_tier(), trust_tier()) :: [capability_template()]
  def capabilities_gained(from_tier, to_tier) do
    from_uris = capabilities_for_tier(from_tier) |> Enum.map(& &1.resource_uri) |> MapSet.new()
    to_caps = capabilities_for_tier(to_tier)

    Enum.reject(to_caps, fn cap ->
      MapSet.member?(from_uris, cap.resource_uri)
    end)
  end

  @doc """
  Get capabilities lost when demoted from one tier to another.

  ## Example

      lost_caps = CapabilityTemplates.capabilities_lost(:trusted, :probationary)
      # Returns capabilities in :trusted but not in :probationary
  """
  @spec capabilities_lost(trust_tier(), trust_tier()) :: [capability_template()]
  def capabilities_lost(from_tier, to_tier) do
    capabilities_gained(to_tier, from_tier)
  end

  @doc """
  Check if a capability is available at a given tier.

  ## Example

      CapabilityTemplates.has_capability?(:trusted, "arbor://code/write/self/impl/*")
      # => true
  """
  @spec has_capability?(trust_tier(), String.t()) :: boolean()
  def has_capability?(tier, resource_uri) do
    capabilities_for_tier(tier)
    |> Enum.any?(fn cap ->
      matches_uri?(cap.resource_uri, resource_uri)
    end)
  end

  @doc """
  Get the constraint for a capability at a given tier.

  ## Example

      CapabilityTemplates.get_constraints(:trusted, "arbor://code/write/self/impl/*")
      # => %{requires_approval: true}
  """
  @spec get_constraints(trust_tier(), String.t()) :: map() | nil
  def get_constraints(tier, resource_uri) do
    capabilities_for_tier(tier)
    |> Enum.find(fn cap ->
      matches_uri?(cap.resource_uri, resource_uri)
    end)
    |> case do
      nil -> nil
      cap -> cap.constraints
    end
  end

  @doc """
  Get the minimum tier required for a capability.

  ## Example

      CapabilityTemplates.min_tier_for_capability("arbor://code/write/self/impl/*")
      # => :trusted
  """
  @spec min_tier_for_capability(String.t()) :: trust_tier() | nil
  def min_tier_for_capability(resource_uri) do
    tiers = [:untrusted, :probationary, :trusted, :veteran, :autonomous]

    Enum.find(tiers, fn tier ->
      has_capability?(tier, resource_uri)
    end)
  end

  @doc """
  Check if approval is required for a capability at a tier.

  ## Example

      CapabilityTemplates.requires_approval?(:trusted, "arbor://code/write/self/impl/*")
      # => true

      CapabilityTemplates.requires_approval?(:veteran, "arbor://code/write/self/impl/*")
      # => false
  """
  @spec requires_approval?(trust_tier(), String.t()) :: boolean()
  def requires_approval?(tier, resource_uri) do
    case get_constraints(tier, resource_uri) do
      nil -> false
      constraints -> Map.get(constraints, :requires_approval, false)
    end
  end

  @doc """
  Get rate limit for a capability at a tier.

  ## Example

      CapabilityTemplates.rate_limit(:probationary, "arbor://code/write/self/sandbox/*")
      # => 10
  """
  @spec rate_limit(trust_tier(), String.t()) :: non_neg_integer() | nil
  def rate_limit(tier, resource_uri) do
    case get_constraints(tier, resource_uri) do
      nil -> nil
      constraints -> Map.get(constraints, :rate_limit)
    end
  end

  @doc """
  Generate capabilities for an agent based on their tier.

  This creates actual capability maps that can be stored in the
  capability system.

  ## Example

      caps = CapabilityTemplates.generate_capabilities("agent_123", :trusted)
  """
  @spec generate_capabilities(String.t(), trust_tier()) :: [map()]
  def generate_capabilities(agent_id, tier) do
    capabilities_for_tier(tier)
    |> Enum.map(fn template ->
      # Replace "self" placeholder with actual agent_id
      # Handle both "/self/" in the middle and "/self" at the end
      resource_uri =
        template.resource_uri
        |> String.replace("/self/", "/#{agent_id}/")
        |> String.replace(~r"/self$", "/#{agent_id}")

      %{
        resource_uri: resource_uri,
        principal_id: agent_id,
        constraints: template.constraints,
        metadata: %{
          source: :trust_tier,
          tier: tier,
          generated_at: DateTime.utc_now()
        }
      }
    end)
  end

  @doc """
  Get all tiers in order from lowest to highest.
  """
  @spec all_tiers() :: [:untrusted | :probationary | :trusted | :veteran | :autonomous, ...]
  def all_tiers do
    [:untrusted, :probationary, :trusted, :veteran, :autonomous]
  end

  @doc """
  Get tier description.
  """
  @spec tier_description(trust_tier()) :: String.t()
  def tier_description(:untrusted), do: "Read own code only"
  def tier_description(:probationary), do: "Sandbox modifications (rate-limited)"
  def tier_description(:trusted), do: "Self-modify with approval"
  def tier_description(:veteran), do: "Self-modify auto-approved"
  def tier_description(:autonomous), do: "Full self-modification including capabilities"

  # Private functions

  # Merges default tier capabilities with config overrides.
  # Config entries take precedence over defaults for the same tier.
  defp tier_capabilities do
    config_templates = Arbor.Trust.Config.capability_templates()
    Map.merge(@default_tier_capabilities, config_templates)
  end

  defp matches_uri?(pattern, uri) do
    # Simple wildcard matching
    if String.ends_with?(pattern, "/*") do
      prefix = String.trim_trailing(pattern, "*")
      String.starts_with?(uri, prefix)
    else
      pattern == uri
    end
  end
end
