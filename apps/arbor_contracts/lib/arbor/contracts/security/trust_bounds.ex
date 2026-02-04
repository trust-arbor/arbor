defmodule Arbor.Contracts.Security.TrustBounds do
  @moduledoc """
  Maps trust tiers to sandbox levels and behavioral constraints.

  TrustBounds defines what agents at each trust level are allowed to do.
  It bridges the arbor_trust scoring system with the arbor_sandbox execution
  environment and arbor_security capability checks.

  ## Trust Tiers (from arbor_trust)

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
  """
  @spec sandbox_for_tier(trust_tier()) :: sandbox_level()
  def sandbox_for_tier(:untrusted), do: :strict
  def sandbox_for_tier(:probationary), do: :strict
  def sandbox_for_tier(:trusted), do: :standard
  def sandbox_for_tier(:veteran), do: :permissive
  def sandbox_for_tier(:autonomous), do: :none

  @doc """
  Returns the list of allowed actions for a given trust tier.

  Returns `:all` for autonomous tier (no restrictions).
  """
  @spec allowed_actions(trust_tier()) :: [action_category()] | :all
  def allowed_actions(:untrusted), do: [:read, :search, :think]
  def allowed_actions(:probationary), do: [:read, :search, :think, :write_sandbox]
  def allowed_actions(:trusted), do: [:read, :search, :think, :write, :execute_safe]
  def allowed_actions(:veteran), do: [:read, :search, :think, :write, :execute, :network]
  def allowed_actions(:autonomous), do: :all

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
  """
  @spec tiers() :: [trust_tier()]
  def tiers, do: [:untrusted, :probationary, :trusted, :veteran, :autonomous]

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
  """
  @spec minimum_tier_for_action(action_category()) :: trust_tier()
  def minimum_tier_for_action(:read), do: :untrusted
  def minimum_tier_for_action(:search), do: :untrusted
  def minimum_tier_for_action(:think), do: :untrusted
  def minimum_tier_for_action(:write_sandbox), do: :probationary
  def minimum_tier_for_action(:write), do: :trusted
  def minimum_tier_for_action(:execute_safe), do: :trusted
  def minimum_tier_for_action(:execute), do: :veteran
  def minimum_tier_for_action(:network), do: :veteran

  @doc """
  Returns the minimum sandbox level required for an action to succeed.
  Actions that require less restriction need a more permissive sandbox.
  """
  @spec sandbox_required_for_action(action_category()) :: sandbox_level()
  def sandbox_required_for_action(:read), do: :strict
  def sandbox_required_for_action(:search), do: :strict
  def sandbox_required_for_action(:think), do: :strict
  def sandbox_required_for_action(:write_sandbox), do: :strict
  def sandbox_required_for_action(:write), do: :standard
  def sandbox_required_for_action(:execute_safe), do: :standard
  def sandbox_required_for_action(:execute), do: :permissive
  def sandbox_required_for_action(:network), do: :permissive
end
