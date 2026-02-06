defmodule Arbor.Contracts.Security.TrustBounds do
  @moduledoc """
  Maps trust tiers to sandbox levels and behavioral constraints.

  TrustBounds defines what agents at each trust level are allowed to do.
  It bridges the arbor_trust scoring system with the arbor_sandbox execution
  environment and arbor_security capability checks.

  ## Configuration

  Tier policies can be configured via application config. If no config is set,
  hardcoded defaults are used. Configure via `:arbor_trust` application:

      config :arbor_trust, :tier_definitions, %{
        untrusted: %{
          display_name: "New",
          description: "Just getting started together",
          sandbox: :strict,
          actions: [:read, :search, :think]
        },
        # ... other tiers
      }

  ## Trust Tiers (Default Configuration)

  - `:untrusted` - New agent, no track record (score 0-20)
  - `:probationary` - Some positive signals (score 20-50)
  - `:trusted` - Demonstrated reliability (score 50-75)
  - `:veteran` - Proven track record (score 75-90)
  - `:autonomous` - Full partnership (score 90-100)

  ## Sandbox Levels

  - `:strict` - Maximum isolation, no file/network access
  - `:standard` - Safe operations allowed, dangerous patterns blocked
  - `:permissive` - Most operations allowed, audit logging enabled
  - `:none` - No sandbox restrictions (privileged)

  ## Action Categories

  - `:read` - Read files, search, observe
  - `:search` - Search codebase, grep
  - `:think` - Internal reasoning (always allowed)
  - `:write_sandbox` - Write to sandbox directory only
  - `:write` - Write to allowed paths
  - `:execute_safe` - Execute whitelisted commands
  - `:execute` - Execute arbitrary commands
  - `:network` - Make network requests

  ## Usage

      # Get sandbox level for a trust tier
      TrustBounds.sandbox_for_tier(:trusted)  # => :standard

      # Get allowed actions for a trust tier
      TrustBounds.allowed_actions(:probationary)  # => [:read, :search, :think, :write_sandbox]

      # Check if an action is allowed at a tier
      TrustBounds.action_allowed?(:trusted, :execute_safe)  # => true
  """

  # Hardcoded defaults (used when no config is set)
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

  @default_tiers [:untrusted, :probationary, :trusted, :veteran, :autonomous]

  @typedoc "Sandbox isolation level"
  @type sandbox_level :: :strict | :standard | :permissive | :none

  @typedoc "Action category"
  @type action_category ::
          :read | :search | :think | :write_sandbox | :write | :execute_safe | :execute | :network

  # Import trust_tier type from the API contract
  @typedoc "Trust tier from arbor_trust"
  @type trust_tier :: :untrusted | :probationary | :trusted | :veteran | :autonomous

  @doc """
  Returns the sandbox level for a given trust tier.

  Higher trust tiers get less restrictive sandboxes.
  Reads from config with hardcoded defaults as fallback.
  """
  @spec sandbox_for_tier(trust_tier()) :: sandbox_level()
  def sandbox_for_tier(tier) do
    definitions = tier_definitions()

    case Map.get(definitions, tier) do
      %{sandbox: sandbox} -> sandbox
      nil -> :strict
    end
  end

  @doc """
  Returns the list of allowed actions for a given trust tier.

  Returns `:all` for autonomous tier (no restrictions).
  Reads from config with hardcoded defaults as fallback.
  """
  @spec allowed_actions(trust_tier()) :: [action_category()] | :all
  def allowed_actions(tier) do
    definitions = tier_definitions()

    case Map.get(definitions, tier) do
      %{actions: actions} -> actions
      nil -> [:read, :search, :think]
    end
  end

  @doc """
  Checks if an action is allowed at a given trust tier.
  """
  @spec action_allowed?(trust_tier(), action_category()) :: boolean()
  def action_allowed?(tier, action) do
    case allowed_actions(tier) do
      :all -> true
      actions when is_list(actions) -> action in actions
    end
  end

  @doc """
  Returns all trust tiers in order from least to most trusted.
  Reads from config with hardcoded defaults as fallback.
  """
  @spec tiers() :: [trust_tier()]
  def tiers do
    Application.get_env(:arbor_trust, :tiers, @default_tiers)
  end

  @doc """
  Returns all sandbox levels in order from most to least restrictive.
  """
  @spec sandbox_levels() :: [sandbox_level()]
  def sandbox_levels, do: [:strict, :standard, :permissive, :none]

  @doc """
  Compares two tiers. Returns :lt, :eq, or :gt.
  """
  @spec compare_tiers(trust_tier(), trust_tier()) :: :lt | :eq | :gt
  def compare_tiers(tier1, tier2) do
    index1 = Enum.find_index(tiers(), &(&1 == tier1))
    index2 = Enum.find_index(tiers(), &(&1 == tier2))

    cond do
      index1 < index2 -> :lt
      index1 > index2 -> :gt
      true -> :eq
    end
  end

  @doc """
  Returns the minimum tier required for an action.

  Searches through tiers in order (lowest to highest) and returns
  the first tier that allows the action. Reads from config.
  """
  @spec minimum_tier_for_action(action_category()) :: trust_tier()
  def minimum_tier_for_action(action) do
    # Find the first tier that allows this action
    Enum.find(tiers(), List.first(tiers()), fn tier ->
      action_allowed?(tier, action)
    end)
  end

  @doc """
  Returns the minimum sandbox level required for an action to succeed.
  Actions that require less restriction need a more permissive sandbox.
  """
  @spec sandbox_required_for_action(action_category()) :: sandbox_level()
  def sandbox_required_for_action(action) do
    # Find the first tier that allows this action and return its sandbox
    tier = minimum_tier_for_action(action)
    sandbox_for_tier(tier)
  end

  @doc """
  Returns the user-facing display name for a tier.

  Falls back to capitalizing the tier atom if no definition exists.

  ## Examples

      TrustBounds.display_name(:untrusted)
      #=> "New"

      TrustBounds.display_name(:trusted)
      #=> "Established"
  """
  @spec display_name(trust_tier()) :: String.t()
  def display_name(tier) do
    definitions = tier_definitions()

    case Map.get(definitions, tier) do
      %{display_name: name} -> name
      nil -> tier |> Atom.to_string() |> String.capitalize()
    end
  end

  @doc """
  Returns the description for a tier.

  Returns nil if no definition exists.

  ## Examples

      TrustBounds.tier_description(:untrusted)
      #=> "Just getting started together"
  """
  @spec tier_description(trust_tier()) :: String.t() | nil
  def tier_description(tier) do
    definitions = tier_definitions()

    case Map.get(definitions, tier) do
      %{description: desc} -> desc
      nil -> nil
    end
  end

  # Private helper to get tier definitions from config with fallback
  defp tier_definitions do
    Application.get_env(:arbor_trust, :tier_definitions, @default_tier_definitions)
  end
end
