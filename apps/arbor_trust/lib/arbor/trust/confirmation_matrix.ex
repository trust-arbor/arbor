defmodule Arbor.Trust.ConfirmationMatrix do
  @moduledoc """
  Declarative policy matrix: `(bundle, tier) → :auto | :gated | :deny`.

  The ConfirmationMatrix determines how capability requests are handled
  based on the action bundle and the agent's trust tier. It's the core
  of the approval system — the single lookup that decides whether an
  action proceeds automatically, requires human confirmation, or is blocked.

  ## Bundles

  Bundles group fine-grained capability URIs into user-understandable categories:

  | Bundle | Description |
  |--------|-------------|
  | `:codebase_read` | Read code, roadmap, git log, activity stream |
  | `:codebase_write` | Write code, tests, docs, compile, reload |
  | `:shell` | Shell command execution |
  | `:network` | HTTP requests, signal subscriptions |
  | `:ai_generate` | LLM requests, extension calls |
  | `:system_config` | Configuration changes, installations |
  | `:governance` | Capability management, governance changes |

  ## User-Facing Tiers (4-over-5 mapping)

  | User Tier | Internal Tier(s) |
  |-----------|-----------------|
  | `:restricted` | `:untrusted`, `:probationary` |
  | `:standard` | `:trusted` |
  | `:elevated` | `:veteran` |
  | `:autonomous` | `:autonomous` |

  ## Security Invariants

  - Shell bundle is NEVER `:auto` at any tier
  - Governance bundle requires `:gated` even at `:autonomous`
  - Unknown bundles default to `:deny`
  - Unknown tiers default to `:deny`

  ## Usage

      # Look up confirmation mode
      ConfirmationMatrix.lookup(:codebase_read, :trusted)
      #=> :auto

      # Resolve a URI to its bundle
      ConfirmationMatrix.resolve_bundle("arbor://code/read/self/*")
      #=> :codebase_read

      # Combined: URI + tier → mode
      ConfirmationMatrix.mode_for("arbor://code/write/self/impl/*", :trusted)
      #=> :gated
  """

  @type bundle ::
          :codebase_read
          | :codebase_write
          | :shell
          | :network
          | :ai_generate
          | :system_config
          | :governance

  @type policy_tier :: :restricted | :standard | :elevated | :autonomous
  @type confirmation_mode :: :auto | :gated | :deny

  @bundles [
    :codebase_read,
    :codebase_write,
    :shell,
    :network,
    :ai_generate,
    :system_config,
    :governance
  ]

  # URI prefix → bundle mapping
  # Order matters: more specific prefixes first
  @uri_bundle_map [
    # codebase_read
    {"arbor://code/read/", :codebase_read},
    {"arbor://roadmap/read/", :codebase_read},
    {"arbor://git/read/", :codebase_read},
    {"arbor://activity/emit/", :codebase_read},
    # codebase_write
    {"arbor://code/write/", :codebase_write},
    {"arbor://code/compile/", :codebase_write},
    {"arbor://code/reload/", :codebase_write},
    {"arbor://test/write/", :codebase_write},
    {"arbor://docs/write/", :codebase_write},
    {"arbor://roadmap/write/", :codebase_write},
    {"arbor://roadmap/move/", :codebase_write},
    # shell
    {"arbor://shell/exec", :shell},
    # network
    {"arbor://network/request/", :network},
    {"arbor://signals/subscribe/", :network},
    # ai_generate
    {"arbor://ai/request/", :ai_generate},
    {"arbor://extension/request/", :ai_generate},
    # system_config
    {"arbor://config/write/", :system_config},
    {"arbor://install/execute/", :system_config},
    # governance
    {"arbor://capability/request/", :governance},
    {"arbor://capability/delegate/", :governance},
    {"arbor://governance/change/", :governance},
    {"arbor://consensus/propose/", :governance}
  ]

  # Default confirmation matrix
  # (bundle, policy_tier) → :auto | :gated | :deny
  #
  # Design principles:
  # - Reading is frictionless at all tiers
  # - Writing starts gated, graduates to auto at higher tiers
  # - Shell is NEVER auto (security invariant)
  # - Governance always requires confirmation
  @default_matrix %{
    #                   restricted  standard  elevated  autonomous
    codebase_read: %{restricted: :auto, standard: :auto, elevated: :auto, autonomous: :auto},
    codebase_write: %{restricted: :deny, standard: :gated, elevated: :auto, autonomous: :auto},
    shell: %{restricted: :deny, standard: :gated, elevated: :gated, autonomous: :gated},
    network: %{restricted: :deny, standard: :gated, elevated: :auto, autonomous: :auto},
    ai_generate: %{restricted: :gated, standard: :auto, elevated: :auto, autonomous: :auto},
    system_config: %{restricted: :deny, standard: :deny, elevated: :gated, autonomous: :auto},
    governance: %{restricted: :deny, standard: :deny, elevated: :gated, autonomous: :gated}
  }

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Look up confirmation mode for a bundle at a policy tier.

  Returns `:auto`, `:gated`, or `:deny`.

  ## Examples

      iex> Arbor.Trust.ConfirmationMatrix.lookup(:codebase_read, :restricted)
      :auto

      iex> Arbor.Trust.ConfirmationMatrix.lookup(:shell, :autonomous)
      :gated

      iex> Arbor.Trust.ConfirmationMatrix.lookup(:governance, :restricted)
      :deny
  """
  @spec lookup(bundle(), policy_tier()) :: confirmation_mode()
  def lookup(bundle, policy_tier) when is_atom(bundle) and is_atom(policy_tier) do
    matrix = get_matrix()

    case Map.get(matrix, bundle) do
      nil -> :deny
      tier_map -> Map.get(tier_map, policy_tier, :deny)
    end
  end

  @doc """
  Resolve a capability URI to its bundle.

  Returns `nil` if the URI doesn't match any known bundle.

  ## Examples

      iex> Arbor.Trust.ConfirmationMatrix.resolve_bundle("arbor://code/read/self/*")
      :codebase_read

      iex> Arbor.Trust.ConfirmationMatrix.resolve_bundle("arbor://shell/exec/ls")
      :shell

      iex> Arbor.Trust.ConfirmationMatrix.resolve_bundle("arbor://unknown/action")
      nil
  """
  @spec resolve_bundle(String.t()) :: bundle() | nil
  def resolve_bundle(resource_uri) when is_binary(resource_uri) do
    Enum.find_value(@uri_bundle_map, fn {prefix, bundle} ->
      if String.starts_with?(resource_uri, prefix), do: bundle
    end)
  end

  @doc """
  Combined lookup: resolve URI to bundle, then look up confirmation mode.

  Returns `:deny` if URI doesn't match any bundle.

  ## Examples

      iex> Arbor.Trust.ConfirmationMatrix.mode_for("arbor://code/read/agent_123/file.ex", :standard)
      :auto

      iex> Arbor.Trust.ConfirmationMatrix.mode_for("arbor://shell/exec/ls", :elevated)
      :gated
  """
  @spec mode_for(String.t(), policy_tier()) :: confirmation_mode()
  def mode_for(resource_uri, policy_tier) do
    case resolve_bundle(resource_uri) do
      nil -> :deny
      bundle -> lookup(bundle, policy_tier)
    end
  end

  @doc """
  Map an internal trust tier to a user-facing policy tier.

  The 4-over-5 mapping collapses untrusted+probationary into `:restricted`.

  ## Examples

      iex> Arbor.Trust.ConfirmationMatrix.to_policy_tier(:untrusted)
      :restricted

      iex> Arbor.Trust.ConfirmationMatrix.to_policy_tier(:probationary)
      :restricted

      iex> Arbor.Trust.ConfirmationMatrix.to_policy_tier(:trusted)
      :standard

      iex> Arbor.Trust.ConfirmationMatrix.to_policy_tier(:veteran)
      :elevated

      iex> Arbor.Trust.ConfirmationMatrix.to_policy_tier(:autonomous)
      :autonomous
  """
  @spec to_policy_tier(atom()) :: policy_tier()
  def to_policy_tier(:untrusted), do: :restricted
  def to_policy_tier(:probationary), do: :restricted
  def to_policy_tier(:trusted), do: :standard
  def to_policy_tier(:veteran), do: :elevated
  def to_policy_tier(:autonomous), do: :autonomous
  def to_policy_tier(_unknown), do: :restricted

  @doc """
  Get all known bundles.
  """
  @spec bundles() :: [bundle()]
  def bundles, do: @bundles

  @doc """
  Get all policy tiers in order.
  """
  @spec policy_tiers() :: [policy_tier()]
  def policy_tiers, do: [:restricted, :standard, :elevated, :autonomous]

  @doc """
  Get the full confirmation matrix.

  Can be overridden via config:

      config :arbor_trust, :confirmation_matrix, %{
        shell: %{restricted: :deny, standard: :deny, elevated: :gated, autonomous: :gated}
      }
  """
  @spec get_matrix() :: map()
  def get_matrix do
    config_overrides = Application.get_env(:arbor_trust, :confirmation_matrix, %{})
    Map.merge(@default_matrix, config_overrides)
  end

  @doc """
  Get the URI-to-bundle mapping.
  """
  @spec uri_bundle_map() :: [{String.t(), bundle()}]
  def uri_bundle_map, do: @uri_bundle_map
end
