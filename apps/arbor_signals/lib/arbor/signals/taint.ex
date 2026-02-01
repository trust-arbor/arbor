defmodule Arbor.Signals.Taint do
  @moduledoc """
  Taint level definitions and propagation logic for information flow control.

  This module provides the foundation for tracking data provenance (taint) through
  the Arbor signal system. Taint tracking helps prevent prompt injection attacks
  by distinguishing between trusted and untrusted data sources.

  ## Taint Levels

  Taint levels are ordered by severity (lowest to highest):

  - `:trusted` - Data from known, verified sources (human input, internal systems)
  - `:derived` - Data derived from processing that included untrusted context
  - `:untrusted` - Data from external sources that hasn't been verified
  - `:hostile` - Data actively identified as malicious (quarantined)

  ## Roles

  Parameters in actions are classified by role:

  - `:control` - Parameters that affect execution flow (paths, commands, modules)
  - `:data` - Parameters that are processed but don't affect control flow (content)

  ## Propagation Rules

  - Output taint is at least as severe as the most severe input
  - If any input is `:untrusted`, output is at least `:derived`
  - `:hostile` input taints the entire output as `:hostile`

  ## Usage Examples

      # Check if taint level can be used in a role
      Arbor.Signals.Taint.can_use_as?(:trusted, :control)   # => true
      Arbor.Signals.Taint.can_use_as?(:untrusted, :control) # => false (BLOCKED)
      Arbor.Signals.Taint.can_use_as?(:untrusted, :data)    # => true

      # Propagate taint through a transformation
      Arbor.Signals.Taint.propagate([:trusted, :untrusted]) # => :derived

      # Reduce taint level with justification
      Arbor.Signals.Taint.reduce(:untrusted, :derived, :consensus)
      # => {:ok, :derived}
  """

  @type level :: :trusted | :derived | :untrusted | :hostile
  @type role :: :control | :data
  @type reduction_reason :: :human_review | :consensus | :verified_pipeline

  @levels_ordered [:trusted, :derived, :untrusted, :hostile]
  @valid_roles [:control, :data]

  # =============================================================================
  # Level Predicates
  # =============================================================================

  @doc """
  Returns the ordered list of taint levels from lowest to highest severity.
  """
  @spec levels() :: [level()]
  def levels, do: @levels_ordered

  @doc """
  Returns the list of valid taint roles.
  """
  @spec roles() :: [role()]
  def roles, do: @valid_roles

  @doc """
  Check if a value is a valid taint level.

  ## Examples

      iex> Arbor.Signals.Taint.valid_level?(:trusted)
      true

      iex> Arbor.Signals.Taint.valid_level?(:unknown)
      false
  """
  @spec valid_level?(term()) :: boolean()
  def valid_level?(level) when level in @levels_ordered, do: true
  def valid_level?(_), do: false

  @doc """
  Check if a value is a valid taint role.

  ## Examples

      iex> Arbor.Signals.Taint.valid_role?(:control)
      true

      iex> Arbor.Signals.Taint.valid_role?(:unknown)
      false
  """
  @spec valid_role?(term()) :: boolean()
  def valid_role?(role) when role in @valid_roles, do: true
  def valid_role?(_), do: false

  @doc """
  Get the severity index of a taint level (0=trusted, 3=hostile).

  ## Examples

      iex> Arbor.Signals.Taint.severity(:trusted)
      0

      iex> Arbor.Signals.Taint.severity(:hostile)
      3
  """
  @spec severity(level()) :: non_neg_integer()
  def severity(:trusted), do: 0
  def severity(:derived), do: 1
  def severity(:untrusted), do: 2
  def severity(:hostile), do: 3

  # =============================================================================
  # Comparison / Propagation
  # =============================================================================

  @doc """
  Returns the higher severity taint level of two levels.

  ## Examples

      iex> Arbor.Signals.Taint.max_taint(:trusted, :untrusted)
      :untrusted

      iex> Arbor.Signals.Taint.max_taint(:derived, :trusted)
      :derived
  """
  @spec max_taint(level(), level()) :: level()
  def max_taint(level_a, level_b) do
    if severity(level_a) >= severity(level_b), do: level_a, else: level_b
  end

  @doc """
  Propagate taint from a list of input levels to determine output taint.

  The output taint is the maximum of all input taints, with the additional rule
  that if any input is `:untrusted` or higher, the output is at least `:derived`.

  ## Examples

      iex> Arbor.Signals.Taint.propagate([:trusted, :trusted])
      :trusted

      iex> Arbor.Signals.Taint.propagate([:trusted, :untrusted])
      :derived

      iex> Arbor.Signals.Taint.propagate([:hostile])
      :hostile

      iex> Arbor.Signals.Taint.propagate([])
      :trusted
  """
  @spec propagate([level()]) :: level()
  def propagate([]), do: :trusted

  def propagate(input_levels) when is_list(input_levels) do
    max_level = Enum.reduce(input_levels, :trusted, &max_taint/2)

    # If any input was untrusted but max isn't hostile, output is at least derived
    has_untrusted = Enum.any?(input_levels, fn level -> severity(level) >= severity(:untrusted) end)

    cond do
      max_level == :hostile -> :hostile
      has_untrusted and max_level == :untrusted -> :derived
      true -> max_level
    end
  end

  # =============================================================================
  # Role Enforcement
  # =============================================================================

  @doc """
  Check if a taint level can be used in a given role.

  Truth table:
  - `:trusted` + `:control` → `true`
  - `:trusted` + `:data` → `true`
  - `:derived` + `:control` → `true` (audited, not blocked)
  - `:derived` + `:data` → `true`
  - `:untrusted` + `:control` → `false` (BLOCKED)
  - `:untrusted` + `:data` → `true`
  - `:hostile` + `:control` → `false`
  - `:hostile` + `:data` → `false`

  ## Examples

      iex> Arbor.Signals.Taint.can_use_as?(:trusted, :control)
      true

      iex> Arbor.Signals.Taint.can_use_as?(:untrusted, :control)
      false

      iex> Arbor.Signals.Taint.can_use_as?(:untrusted, :data)
      true

      iex> Arbor.Signals.Taint.can_use_as?(:hostile, :data)
      false
  """
  @spec can_use_as?(level(), role()) :: boolean()
  # Trusted can be used anywhere
  def can_use_as?(:trusted, :control), do: true
  def can_use_as?(:trusted, :data), do: true

  # Derived can be used anywhere (but control usage is audited in enforcement layer)
  def can_use_as?(:derived, :control), do: true
  def can_use_as?(:derived, :data), do: true

  # Untrusted can only be used as data, never as control
  def can_use_as?(:untrusted, :control), do: false
  def can_use_as?(:untrusted, :data), do: true

  # Hostile cannot be used anywhere
  def can_use_as?(:hostile, :control), do: false
  def can_use_as?(:hostile, :data), do: false

  # =============================================================================
  # Taint Reduction
  # =============================================================================

  @doc """
  Attempt to reduce taint level with a justification reason.

  Allowed reductions:
  - `:human_review` → any level can become `:trusted`
  - `:consensus` → `:untrusted` can become `:derived` (never `:trusted`)
  - `:verified_pipeline` → `:untrusted` can become `:derived`

  Returns `{:ok, target}` if reduction is allowed, `{:error, :reduction_not_allowed}` otherwise.

  ## Examples

      iex> Arbor.Signals.Taint.reduce(:untrusted, :derived, :consensus)
      {:ok, :derived}

      iex> Arbor.Signals.Taint.reduce(:untrusted, :trusted, :consensus)
      {:error, :reduction_not_allowed}

      iex> Arbor.Signals.Taint.reduce(:hostile, :trusted, :human_review)
      {:ok, :trusted}
  """
  @spec reduce(level(), level(), reduction_reason()) ::
          {:ok, level()} | {:error, :reduction_not_allowed}

  # Human review can reduce anything to trusted
  def reduce(_current, :trusted, :human_review), do: {:ok, :trusted}
  def reduce(_current, target, :human_review), do: {:ok, target}

  # Consensus can reduce untrusted to derived, but not to trusted
  def reduce(:untrusted, :derived, :consensus), do: {:ok, :derived}
  def reduce(:untrusted, :trusted, :consensus), do: {:error, :reduction_not_allowed}
  def reduce(:hostile, :derived, :consensus), do: {:ok, :derived}
  def reduce(:hostile, :trusted, :consensus), do: {:error, :reduction_not_allowed}

  # Verified pipeline can reduce untrusted to derived
  def reduce(:untrusted, :derived, :verified_pipeline), do: {:ok, :derived}
  def reduce(:untrusted, :trusted, :verified_pipeline), do: {:error, :reduction_not_allowed}
  def reduce(:hostile, :derived, :verified_pipeline), do: {:ok, :derived}
  def reduce(:hostile, :trusted, :verified_pipeline), do: {:error, :reduction_not_allowed}

  # Reduction to same or higher severity is always allowed
  def reduce(current, target, _reason) do
    if severity(target) >= severity(current) do
      {:ok, target}
    else
      {:error, :reduction_not_allowed}
    end
  end

  # =============================================================================
  # Metadata Helpers
  # =============================================================================

  @doc """
  Extract taint information from signal metadata.

  Returns a map with `:taint`, `:taint_source`, and `:taint_chain` keys.
  Missing fields default to `:trusted`, `nil`, and `[]` respectively.

  ## Examples

      iex> Arbor.Signals.Taint.from_metadata(%{taint: :untrusted, taint_source: "external"})
      %{taint: :untrusted, taint_source: "external", taint_chain: []}

      iex> Arbor.Signals.Taint.from_metadata(%{})
      %{taint: :trusted, taint_source: nil, taint_chain: []}
  """
  @spec from_metadata(map()) :: %{taint: level(), taint_source: term(), taint_chain: list()}
  def from_metadata(metadata) when is_map(metadata) do
    %{
      taint: Map.get(metadata, :taint, :trusted),
      taint_source: Map.get(metadata, :taint_source),
      taint_chain: Map.get(metadata, :taint_chain, [])
    }
  end

  @doc """
  Build taint metadata map from components.

  ## Examples

      iex> Arbor.Signals.Taint.to_metadata(:untrusted, "external_api")
      %{taint: :untrusted, taint_source: "external_api", taint_chain: []}

      iex> Arbor.Signals.Taint.to_metadata(:derived, "llm_output", ["sig_123"])
      %{taint: :derived, taint_source: "llm_output", taint_chain: ["sig_123"]}
  """
  @spec to_metadata(level(), term(), list()) :: map()
  def to_metadata(level, source, chain \\ []) do
    %{
      taint: level,
      taint_source: source,
      taint_chain: chain
    }
  end

  @doc """
  Merge taint metadata into an existing metadata map.

  Taint fields override any existing values with the same keys.

  ## Examples

      iex> base = %{agent_id: "agent_001", custom: "value"}
      iex> taint = %{taint: :untrusted, taint_source: "external"}
      iex> Arbor.Signals.Taint.merge_metadata(base, taint)
      %{agent_id: "agent_001", custom: "value", taint: :untrusted, taint_source: "external"}
  """
  @spec merge_metadata(map(), map()) :: map()
  def merge_metadata(base_meta, taint_meta) when is_map(base_meta) and is_map(taint_meta) do
    Map.merge(base_meta, taint_meta)
  end
end
