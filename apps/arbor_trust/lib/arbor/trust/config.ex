defmodule Arbor.Trust.Config do
  @moduledoc """
  Central configuration reader for the trust system.

  All trust modules call this instead of using hardcoded module attributes.
  Configuration is read from application env with sensible defaults.

  ## Configuration

      # config/config.exs
      config :arbor_trust,
        pubsub: Arbor.Core.PubSub,
        tiers: [:untrusted, :probationary, :trusted, :veteran, :autonomous],
        tier_thresholds: %{
          untrusted: 0,
          probationary: 20,
          trusted: 50,
          veteran: 75,
          autonomous: 90
        },
        score_weights: %{
          success_rate: 0.30,
          uptime: 0.15,
          security: 0.25,
          test_pass: 0.20,
          rollback: 0.10
        },
        points_earned: %{
          proposal_approved: 5,
          installation_successful: 10,
          high_impact_feature: 20,
          bug_fix_passed: 3,
          documentation_improvement: 1
        },
        points_lost: %{
          implementation_failure: 5,
          installation_rolled_back: 10,
          security_violation: 20,
          circuit_breaker_triggered: 15
        },
        points_thresholds: %{
          untrusted: 0,
          probationary: 25,
          trusted: 100,
          veteran: 500,
          autonomous: 2000
        },
        decay: %{
          grace_period_days: 7,
          decay_rate: 1,
          floor_score: 10,
          run_time: ~T[03:00:00]
        },
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

  # Default values
  @default_tiers [:untrusted, :probationary, :trusted, :veteran, :autonomous]

  @default_tier_thresholds %{
    untrusted: 0,
    probationary: 20,
    trusted: 50,
    veteran: 75,
    autonomous: 90
  }

  # Partnership-framed display names from council consultation (2026-02-04)
  @default_tier_definitions %{
    untrusted: %{
      display_name: "New",
      description: "Just getting started together",
      sandbox: :strict,
      actions: [:read, :search, :think]
    },
    probationary: %{
      display_name: "Guided",
      description: "Building our working relationship",
      sandbox: :strict,
      actions: [:read, :search, :think, :write_sandbox]
    },
    trusted: %{
      display_name: "Established",
      description: "Demonstrated reliability",
      sandbox: :standard,
      actions: [:read, :search, :think, :write, :execute_safe]
    },
    veteran: %{
      display_name: "Trusted Partner",
      description: "Proven track record",
      sandbox: :permissive,
      actions: [:read, :search, :think, :write, :execute, :network]
    },
    autonomous: %{
      display_name: "Full Partner",
      description: "Complete partnership",
      sandbox: :none,
      actions: :all
    }
  }

  @default_score_weights %{
    success_rate: 0.30,
    uptime: 0.15,
    security: 0.25,
    test_pass: 0.20,
    rollback: 0.10
  }

  @default_points_earned %{
    proposal_approved: 5,
    installation_successful: 10,
    high_impact_feature: 20,
    bug_fix_passed: 3,
    documentation_improvement: 1
  }

  @default_points_lost %{
    implementation_failure: 5,
    installation_rolled_back: 10,
    security_violation: 20,
    circuit_breaker_triggered: 15
  }

  @default_points_thresholds %{
    untrusted: 0,
    probationary: 25,
    trusted: 100,
    veteran: 500,
    autonomous: 2000
  }

  # Default capability templates by tier
  # URI format: arbor://category/action/target (target can include wildcards like /self/*)
  @default_tier_capabilities %{
    untrusted: [
      %{resource_uri: "arbor://code/read/self/*", constraints: %{}},
      %{resource_uri: "arbor://consensus/propose/self", constraints: %{rate_limit: 10}},
      %{resource_uri: "arbor://agent/profile/self/*", constraints: %{}}
    ],
    probationary: [
      %{resource_uri: "arbor://code/read/self/*", constraints: %{}},
      %{resource_uri: "arbor://code/write/self/sandbox/*", constraints: %{rate_limit: 10}},
      %{resource_uri: "arbor://code/compile/self/sandbox", constraints: %{}},
      %{resource_uri: "arbor://consensus/propose/self", constraints: %{rate_limit: 20}},
      %{resource_uri: "arbor://roadmap/read/self/*", constraints: %{}},
      %{resource_uri: "arbor://roadmap/write/self/brainstorming/*", constraints: %{}},
      %{resource_uri: "arbor://git/read/self/log", constraints: %{}},
      %{resource_uri: "arbor://activity/emit/self", constraints: %{rate_limit: 100}},
      %{resource_uri: "arbor://agent/profile/self/*", constraints: %{}}
    ],
    trusted: [
      %{resource_uri: "arbor://code/read/self/*", constraints: %{}},
      %{resource_uri: "arbor://code/write/self/sandbox/*", constraints: %{rate_limit: 10}},
      %{resource_uri: "arbor://code/compile/self/sandbox", constraints: %{}},
      %{resource_uri: "arbor://code/write/self/impl/*", constraints: %{requires_approval: true}},
      %{resource_uri: "arbor://code/reload/self/*", constraints: %{requires_approval: true}},
      %{resource_uri: "arbor://extension/request/self/*", constraints: %{}},
      %{resource_uri: "arbor://consensus/propose/self", constraints: %{rate_limit: 50}},
      %{resource_uri: "arbor://roadmap/read/self/*", constraints: %{}},
      %{resource_uri: "arbor://roadmap/write/self/*", constraints: %{}},
      %{resource_uri: "arbor://roadmap/move/self/discarded", constraints: %{rate_limit: 20}},
      %{resource_uri: "arbor://roadmap/write/self/discarded/index", constraints: %{rate_limit: 20}},
      %{resource_uri: "arbor://git/read/self/log", constraints: %{}},
      %{resource_uri: "arbor://activity/emit/self", constraints: %{rate_limit: 100}},
      %{resource_uri: "arbor://config/write/self/*", constraints: %{requires_approval: true}},
      %{resource_uri: "arbor://docs/write/self/*", constraints: %{}},
      %{resource_uri: "arbor://test/write/self/*", constraints: %{}},
      %{resource_uri: "arbor://agent/profile/self/*", constraints: %{}}
    ],
    veteran: [
      %{resource_uri: "arbor://code/read/self/*", constraints: %{}},
      %{resource_uri: "arbor://code/write/self/sandbox/*", constraints: %{}},
      %{resource_uri: "arbor://code/compile/self/sandbox", constraints: %{}},
      %{resource_uri: "arbor://code/write/self/impl/*", constraints: %{}},
      %{resource_uri: "arbor://code/reload/self/*", constraints: %{}},
      %{resource_uri: "arbor://code/compile/self/impl", constraints: %{}},
      %{resource_uri: "arbor://extension/request/self/*", constraints: %{}},
      %{resource_uri: "arbor://consensus/propose/self", constraints: %{}},
      %{resource_uri: "arbor://roadmap/read/self/*", constraints: %{}},
      %{resource_uri: "arbor://roadmap/write/self/*", constraints: %{}},
      %{resource_uri: "arbor://roadmap/move/self/discarded", constraints: %{}},
      %{resource_uri: "arbor://roadmap/write/self/discarded/index", constraints: %{}},
      %{resource_uri: "arbor://git/read/self/log", constraints: %{}},
      %{resource_uri: "arbor://activity/emit/self", constraints: %{}},
      %{resource_uri: "arbor://config/write/self/*", constraints: %{}},
      %{resource_uri: "arbor://docs/write/self/*", constraints: %{}},
      %{resource_uri: "arbor://test/write/self/*", constraints: %{}},
      %{resource_uri: "arbor://install/execute/self", constraints: %{requires_approval: true}},
      %{resource_uri: "arbor://agent/profile/self/*", constraints: %{}}
    ],
    autonomous: [
      %{resource_uri: "arbor://code/read/self/*", constraints: %{}},
      %{resource_uri: "arbor://code/write/self/sandbox/*", constraints: %{}},
      %{resource_uri: "arbor://code/compile/self/sandbox", constraints: %{}},
      %{resource_uri: "arbor://code/write/self/impl/*", constraints: %{}},
      %{resource_uri: "arbor://code/reload/self/*", constraints: %{}},
      %{resource_uri: "arbor://code/compile/self/impl", constraints: %{}},
      %{resource_uri: "arbor://extension/request/self/*", constraints: %{}},
      %{resource_uri: "arbor://capability/request/self/*", constraints: %{}},
      %{resource_uri: "arbor://capability/delegate/self/*", constraints: %{}},
      %{resource_uri: "arbor://consensus/propose/self", constraints: %{}},
      %{resource_uri: "arbor://roadmap/read/self/*", constraints: %{}},
      %{resource_uri: "arbor://roadmap/write/self/*", constraints: %{}},
      %{resource_uri: "arbor://roadmap/move/self/discarded", constraints: %{}},
      %{resource_uri: "arbor://roadmap/write/self/discarded/index", constraints: %{}},
      %{resource_uri: "arbor://git/read/self/log", constraints: %{}},
      %{resource_uri: "arbor://activity/emit/self", constraints: %{}},
      %{resource_uri: "arbor://config/write/self/*", constraints: %{}},
      %{resource_uri: "arbor://docs/write/self/*", constraints: %{}},
      %{resource_uri: "arbor://test/write/self/*", constraints: %{}},
      %{resource_uri: "arbor://install/execute/self", constraints: %{}},
      %{resource_uri: "arbor://governance/change/self/*", constraints: %{requires_approval: true}},
      %{resource_uri: "arbor://agent/profile/self/*", constraints: %{}}
    ]
  }

  @default_capability_templates %{}

  @default_decay %{
    grace_period_days: 7,
    decay_rate: 1,
    floor_score: 10,
    run_time: ~T[03:00:00]
  }

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

  @doc "Get the ordered list of trust tiers."
  @spec tiers() :: [atom()]
  def tiers, do: get(:tiers, @default_tiers)

  @doc "Get the score-based tier thresholds."
  @spec tier_thresholds() :: map()
  def tier_thresholds, do: get(:tier_thresholds, @default_tier_thresholds)

  @doc "Get the score component weights."
  @spec score_weights() :: map()
  def score_weights, do: get(:score_weights, @default_score_weights)

  @doc "Get points earned per event type."
  @spec points_earned() :: map()
  def points_earned, do: get(:points_earned, @default_points_earned)

  @doc "Get points lost per event type."
  @spec points_lost() :: map()
  def points_lost, do: get(:points_lost, @default_points_lost)

  @doc "Get points-based tier thresholds."
  @spec points_thresholds() :: map()
  def points_thresholds, do: get(:points_thresholds, @default_points_thresholds)

  @doc "Get capability templates per tier."
  @spec capability_templates() :: map()
  def capability_templates, do: get(:capability_templates, @default_capability_templates)

  @doc "Get decay configuration."
  @spec decay_config() :: map()
  def decay_config, do: get(:decay, @default_decay)

  @doc "Get circuit breaker configuration."
  @spec circuit_breaker_config() :: map()
  def circuit_breaker_config, do: get(:circuit_breaker, @default_circuit_breaker)

  @doc """
  Get tier definitions with display names, descriptions, sandbox levels, and actions.

  Returns a map of tier ID to definition. Each definition includes:
  - `:display_name` - User-facing name (e.g., "New", "Guided", "Established")
  - `:description` - Brief description of the tier
  - `:sandbox` - Sandbox level (:strict, :standard, :permissive, :none)
  - `:actions` - List of allowed action categories, or `:all`

  ## Example

      Config.tier_definitions()
      #=> %{
      #     untrusted: %{display_name: "New", description: "Just getting started together", ...},
      #     ...
      #   }
  """
  @spec tier_definitions() :: map()
  def tier_definitions, do: get(:tier_definitions, @default_tier_definitions)

  @doc """
  Get the display name for a tier.

  Falls back to capitalizing the tier atom if no definition exists.

  ## Examples

      Config.display_name(:untrusted)
      #=> "New"

      Config.display_name(:probationary)
      #=> "Guided"
  """
  @spec display_name(atom()) :: String.t()
  def display_name(tier) do
    definitions = tier_definitions()

    case Map.get(definitions, tier) do
      %{display_name: name} -> name
      nil -> tier |> Atom.to_string() |> String.capitalize()
    end
  end

  @doc """
  Get the description for a tier.

  Returns nil if no definition exists.

  ## Examples

      Config.tier_description(:untrusted)
      #=> "Just getting started together"
  """
  @spec tier_description(atom()) :: String.t() | nil
  def tier_description(tier) do
    definitions = tier_definitions()

    case Map.get(definitions, tier) do
      %{description: desc} -> desc
      nil -> nil
    end
  end

  @doc """
  Get the sandbox level for a tier.

  Falls back to `:strict` if no definition exists.

  ## Examples

      Config.sandbox_for_tier(:trusted)
      #=> :standard
  """
  @spec sandbox_for_tier(atom()) :: atom()
  def sandbox_for_tier(tier) do
    definitions = tier_definitions()

    case Map.get(definitions, tier) do
      %{sandbox: sandbox} -> sandbox
      nil -> :strict
    end
  end

  @doc """
  Get the allowed actions for a tier.

  Falls back to `[:read, :search, :think]` if no definition exists.

  ## Examples

      Config.actions_for_tier(:trusted)
      #=> [:read, :search, :think, :write, :execute_safe]

      Config.actions_for_tier(:autonomous)
      #=> :all
  """
  @spec actions_for_tier(atom()) :: [atom()] | :all
  def actions_for_tier(tier) do
    definitions = tier_definitions()

    case Map.get(definitions, tier) do
      %{actions: actions} -> actions
      nil -> [:read, :search, :think]
    end
  end

  # ===========================================================================
  # Tier Resolution (formerly TierResolver)
  # ===========================================================================

  @type trust_tier :: :untrusted | :probationary | :trusted | :veteran | :autonomous

  @doc """
  Resolve a trust score to a tier.

  ## Examples

      Config.resolve_tier(25)
      #=> :probationary

      Config.resolve_tier(80)
      #=> :veteran
  """
  @spec resolve_tier(0..100) :: trust_tier()
  def resolve_tier(score) when is_integer(score) do
    case Application.get_env(:arbor_trust, :tier_thresholds) do
      nil ->
        # No config override — delegate to the canonical CRC implementation.
        Arbor.Trust.Authority.resolve_tier(score)

      thresholds when is_map(thresholds) ->
        # Custom thresholds configured — use them.
        tiers()
        |> Enum.map(fn tier -> {tier, Map.fetch!(thresholds, tier)} end)
        |> Enum.sort_by(fn {_tier, threshold} -> threshold end, :desc)
        |> Enum.find(fn {_tier, threshold} -> score >= threshold end)
        |> case do
          {tier, _} -> tier
          nil -> List.first(tiers())
        end
    end
  end

  @doc """
  Check if a tier is sufficient for a required tier.

  ## Examples

      Config.tier_sufficient?(:trusted, :probationary)
      #=> true
  """
  @spec tier_sufficient?(trust_tier(), trust_tier()) :: boolean()
  def tier_sufficient?(have_tier, need_tier) do
    tier_index(have_tier) >= tier_index(need_tier)
  end

  @doc """
  Get the numeric index of a tier (0 = lowest).

  ## Examples

      Config.tier_index(:untrusted)
      #=> 0

      Config.tier_index(:autonomous)
      #=> 4
  """
  @spec tier_index(trust_tier()) :: non_neg_integer()
  def tier_index(tier) do
    idx = Enum.find_index(tiers(), &(&1 == tier))
    idx || raise ArgumentError, "unknown tier: #{inspect(tier)}"
  end

  @doc """
  Get the previous tier below the given tier. Returns nil for the lowest.
  """
  @spec previous_tier(trust_tier()) :: trust_tier() | nil
  def previous_tier(tier) do
    all = tiers()
    idx = Enum.find_index(all, &(&1 == tier))

    if idx && idx > 0, do: Enum.at(all, idx - 1), else: nil
  end

  @doc """
  Get the next tier above the given tier. Returns nil for the highest.
  """
  @spec next_tier(trust_tier()) :: trust_tier() | nil
  def next_tier(tier) do
    all = tiers()
    idx = Enum.find_index(all, &(&1 == tier))

    if idx && idx < length(all) - 1, do: Enum.at(all, idx + 1), else: nil
  end

  @doc """
  Get the minimum score required for a tier.
  """
  @spec min_score(trust_tier()) :: non_neg_integer()
  def min_score(tier), do: Map.fetch!(tier_thresholds(), tier)

  @doc """
  Get the maximum score for a tier (exclusive upper bound).
  """
  @spec max_score(trust_tier()) :: non_neg_integer()
  def max_score(tier) do
    all = tiers()
    idx = Enum.find_index(all, &(&1 == tier))

    if idx == length(all) - 1 do
      100
    else
      next = Enum.at(all, idx + 1)
      Map.fetch!(tier_thresholds(), next) - 1
    end
  end

  @doc """
  Compare two tiers, returning :lt, :eq, or :gt.
  """
  @spec compare_tiers(trust_tier(), trust_tier()) :: :lt | :eq | :gt
  def compare_tiers(tier_a, tier_b) do
    a = tier_index(tier_a)
    b = tier_index(tier_b)
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  @doc """
  Human-readable description combining display name and description.
  """
  @spec describe_tier(trust_tier()) :: String.t()
  def describe_tier(tier) do
    name = display_name(tier)

    case tier_description(tier) do
      nil -> name
      desc -> "#{name} - #{desc}"
    end
  end

  # ===========================================================================
  # Capability Templates (formerly CapabilityTemplates)
  # ===========================================================================

  @doc """
  Get all capability templates for a trust tier.

  Checks application config for overrides, falls back to built-in defaults.
  """
  @spec capabilities_for_tier(trust_tier()) :: [map()]
  def capabilities_for_tier(tier) when is_atom(tier) do
    config_overrides = capability_templates()
    all_templates = Map.merge(@default_tier_capabilities, config_overrides)
    Map.get(all_templates, tier, [])
  end

  @doc """
  Get capabilities gained when promoted from one tier to another.
  """
  @spec capabilities_gained(trust_tier(), trust_tier()) :: [map()]
  def capabilities_gained(from_tier, to_tier) do
    from_uris = capabilities_for_tier(from_tier) |> Enum.map(& &1.resource_uri) |> MapSet.new()
    to_caps = capabilities_for_tier(to_tier)
    Enum.reject(to_caps, fn cap -> MapSet.member?(from_uris, cap.resource_uri) end)
  end

  @doc """
  Get capabilities lost when demoted from one tier to another.
  """
  @spec capabilities_lost(trust_tier(), trust_tier()) :: [map()]
  def capabilities_lost(from_tier, to_tier) do
    capabilities_gained(to_tier, from_tier)
  end

  @doc """
  Check if a capability is available at a given tier.
  """
  @spec has_capability?(trust_tier(), String.t()) :: boolean()
  def has_capability?(tier, resource_uri) do
    Enum.any?(capabilities_for_tier(tier), fn cap ->
      matches_capability_uri?(cap.resource_uri, resource_uri)
    end)
  end

  @doc """
  Get the constraint for a capability at a given tier.
  """
  @spec get_capability_constraints(trust_tier(), String.t()) :: map() | nil
  def get_capability_constraints(tier, resource_uri) do
    case Enum.find(capabilities_for_tier(tier), fn cap ->
           matches_capability_uri?(cap.resource_uri, resource_uri)
         end) do
      nil -> nil
      cap -> cap.constraints
    end
  end

  @doc """
  Get the minimum tier required for a capability.
  """
  @spec min_tier_for_capability(String.t()) :: trust_tier() | nil
  def min_tier_for_capability(resource_uri) do
    Enum.find(tiers(), fn tier -> has_capability?(tier, resource_uri) end)
  end

  @doc """
  Check if approval is required for a capability at a tier.
  """
  @spec capability_requires_approval?(trust_tier(), String.t()) :: boolean()
  def capability_requires_approval?(tier, resource_uri) do
    case get_capability_constraints(tier, resource_uri) do
      nil -> false
      constraints -> Map.get(constraints, :requires_approval, false)
    end
  end

  @doc """
  Get rate limit for a capability at a tier.
  """
  @spec capability_rate_limit(trust_tier(), String.t()) :: non_neg_integer() | nil
  def capability_rate_limit(tier, resource_uri) do
    case get_capability_constraints(tier, resource_uri) do
      nil -> nil
      constraints -> Map.get(constraints, :rate_limit)
    end
  end

  @doc """
  Generate capability maps for an agent based on their tier.
  Replaces \"self\" placeholders with the actual agent_id.
  """
  @spec generate_capabilities(String.t(), trust_tier()) :: [map()]
  def generate_capabilities(agent_id, tier) do
    capabilities_for_tier(tier)
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
          source: :trust_tier,
          tier: tier,
          generated_at: DateTime.utc_now()
        }
      }
    end)
  end

  # Private helpers

  defp matches_capability_uri?(pattern, uri) do
    if String.ends_with?(pattern, "/*") do
      prefix = String.trim_trailing(pattern, "*")
      String.starts_with?(uri, prefix)
    else
      pattern == uri
    end
  end

  defp get(key, default), do: Application.get_env(:arbor_trust, key, default)
end
