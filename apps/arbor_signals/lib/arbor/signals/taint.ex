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

  - Propagation returns exactly the maximum input level under the contract ordering
  - `:hostile` input therefore taints the entire output as `:hostile`

  ## Usage Examples

      # Check if taint level can be used in a role
      Arbor.Signals.Taint.can_use_as?(:trusted, :control)   # => true
      Arbor.Signals.Taint.can_use_as?(:untrusted, :control) # => false (BLOCKED)
      Arbor.Signals.Taint.can_use_as?(:untrusted, :data)    # => true

      # Propagate taint through a transformation
      Arbor.Signals.Taint.propagate([:trusted, :untrusted]) # => :untrusted

      # Reduce taint level with justification
      Arbor.Signals.Taint.reduce(:untrusted, :derived, :consensus)
      # => {:ok, :derived}
  """

  @type level :: :trusted | :derived | :untrusted | :hostile
  @type role :: :control | :data
  @type reduction_reason :: :human_review | :consensus | :verified_pipeline

  @valid_roles [:control, :data]
  @taint_struct Arbor.Contracts.Security.Taint
  @taint_envelope Arbor.Contracts.Security.TaintEnvelope

  # =============================================================================
  # Level Predicates
  # =============================================================================

  @doc """
  Returns the ordered list of taint levels from lowest to highest severity.
  """
  @spec levels() :: [level()]
  def levels, do: @taint_struct.levels()

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
  def valid_level?(level), do: level in levels()

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
  def severity(level) do
    case Enum.find_index(levels(), &(&1 == level)) do
      nil -> 3
      rank -> rank
    end
  end

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
    if valid_level?(level_a) and valid_level?(level_b) do
      if severity(level_a) >= severity(level_b), do: level_a, else: level_b
    else
      :hostile
    end
  end

  @doc """
  Propagate taint from a list of input levels to determine output taint.

  The output taint is exactly the maximum of all valid input taints under the
  authoritative contract ordering. Improper or malformed input fails closed as
  `:hostile`.

  ## Examples

      iex> Arbor.Signals.Taint.propagate([:trusted, :trusted])
      :trusted

      iex> Arbor.Signals.Taint.propagate([:trusted, :untrusted])
      :untrusted

      iex> Arbor.Signals.Taint.propagate([:hostile])
      :hostile

      iex> Arbor.Signals.Taint.propagate([])
      :trusted
  """
  @spec propagate([level()]) :: level()
  def propagate([]), do: :trusted

  def propagate(input_levels) when is_list(input_levels),
    do: propagate_levels(input_levels, :trusted, 0)

  def propagate(_input_levels), do: :hostile

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

  # =============================================================================
  # Struct-Aware Functions (Phase 1 Taint Extension)
  # =============================================================================

  # ── Sensitivity ──────────────────────────────────────────────────────

  @doc "Check if a value is a valid sensitivity level."
  @spec valid_sensitivity?(term()) :: boolean()
  def valid_sensitivity?(s), do: s in @taint_struct.sensitivities()

  @doc "Get numeric rank for a sensitivity level (0=public, 3=restricted)."
  @spec sensitivity_severity(atom()) :: non_neg_integer()
  def sensitivity_severity(sensitivity) do
    case Enum.find_index(@taint_struct.sensitivities(), &(&1 == sensitivity)) do
      nil -> 3
      rank -> rank
    end
  end

  @doc "Return the higher sensitivity of two levels."
  @spec max_sensitivity(atom(), atom()) :: atom()
  def max_sensitivity(a, b) do
    if sensitivity_severity(a) >= sensitivity_severity(b), do: a, else: b
  end

  # ── Confidence ───────────────────────────────────────────────────────

  @doc "Check if a value is a valid confidence level."
  @spec valid_confidence?(term()) :: boolean()
  def valid_confidence?(confidence), do: confidence in @taint_struct.confidences()

  @doc "Get numeric rank for a confidence level (0=unverified, 3=verified)."
  @spec confidence_rank(atom()) :: non_neg_integer()
  def confidence_rank(confidence) do
    case Enum.find_index(@taint_struct.confidences(), &(&1 == confidence)) do
      nil -> 0
      rank -> rank
    end
  end

  @doc "Return the lower confidence of two levels (conservative merge)."
  @spec min_confidence(atom(), atom()) :: atom()
  def min_confidence(a, b) do
    if confidence_rank(a) <= confidence_rank(b), do: a, else: b
  end

  # ── Sanitizations (bitmask) ──────────────────────────────────────────

  @doc "Check if a specific sanitization has been applied."
  @spec sanitized?(non_neg_integer(), atom()) :: boolean()
  def sanitized?(bitmask, sanitization_name) when is_integer(bitmask) do
    case @taint_struct.sanitization_bit(sanitization_name) do
      {:ok, bit} -> Bitwise.band(bitmask, bit) != 0
      :error -> false
    end
  end

  @doc "Apply a sanitization to a bitmask."
  @spec apply_sanitization(non_neg_integer(), atom()) :: non_neg_integer()
  def apply_sanitization(bitmask, sanitization_name) when is_integer(bitmask) do
    case @taint_struct.sanitization_bit(sanitization_name) do
      {:ok, bit} -> Bitwise.bor(bitmask, bit)
      :error -> bitmask
    end
  end

  @doc "Intersect two sanitization bitmasks (only keep sanitizations present in BOTH)."
  @spec intersect_sanitizations(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def intersect_sanitizations(a, b) when is_integer(a) and is_integer(b) do
    Bitwise.band(a, b)
  end

  # ── Struct Propagation ───────────────────────────────────────────────

  @doc """
  Propagate taint through a transformation of multiple struct inputs.

  Four-dimensional propagation:
  - level: max(inputs)
  - sensitivity: max(inputs)
  - sanitizations: band(inputs) — only keep sanitizations present in ALL inputs
  - confidence: min(inputs) — conservative

  Provenance is canonicalized by the contract, with the first sorted label in
  `source` and the remaining bounded labels in `chain`.
  """
  @spec propagate_taint([struct()]) :: struct()
  def propagate_taint([]), do: identity_taint()

  def propagate_taint(inputs) when is_list(inputs) do
    case validate_propagation_inputs(inputs, 0) do
      :ok ->
        case @taint_struct.join_many(inputs) do
          {:ok, result} ->
            if invalid_durable_taint?(result),
              do: @taint_struct.invalid_durable_provenance(),
              else: result

          {:error, _reason} ->
            @taint_struct.invalid_durable_provenance()
        end

      {:error, _reason} ->
        @taint_struct.invalid_durable_provenance()
    end
  rescue
    _ -> @taint_struct.invalid_durable_provenance()
  end

  def propagate_taint(_inputs), do: @taint_struct.invalid_durable_provenance()

  # ── Data Hash Binding ──────────────────────────────────────────────

  @doc """
  Compute the legacy SHA-256 Erlang-term hash of arbitrary data.

  This versionless `term_to_binary` hash is retained for compatibility with
  existing records and MUST NOT be used for new durable records. New durable
  provenance must use `bind_durable_provenance/2`.
  """
  @spec data_hash(term()) :: String.t()
  def data_hash(data) do
    data
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Verify a legacy Erlang-term data hash against recomputed hash.

  Returns `:ok` if hashes match, `{:error, :hash_mismatch}` if they differ.
  This versionless compatibility API MUST NOT be used for new durable records;
  use `verify_durable_provenance/2` instead.
  """
  @spec verify_data_hash(term(), String.t()) :: :ok | {:error, :hash_mismatch}
  def verify_data_hash(data, stored_hash) when is_binary(stored_hash) do
    if data_hash(data) == stored_hash do
      :ok
    else
      {:error, :hash_mismatch}
    end
  end

  def verify_data_hash(_data, _stored_hash), do: {:error, :hash_mismatch}

  # ── Serialization (JSONB persistence) ────────────────────────────────

  @doc """
  Convert a Taint struct to the versionless legacy string-keyed map used by
  existing JSONB records.

  Atom fields are converted to strings for safe JSON round-tripping.
  This compatibility format is not payload-bound and MUST NOT be used for new
  durable records; use `bind_durable_provenance/2` instead.

  ## Options

  - `:data_hash` - When provided, includes a `"taint_data_hash"` key in the output.
  """
  @spec to_persistable(struct(), keyword()) :: map()
  def to_persistable(taint, opts \\ []) do
    taint = canonical_or_invalid(taint)

    base = %{
      "taint_level" => Atom.to_string(taint.level),
      "taint_sensitivity" => Atom.to_string(taint.sensitivity),
      "taint_sanitizations" => taint.sanitizations,
      "taint_confidence" => Atom.to_string(taint.confidence),
      "taint_source" => taint.source,
      "taint_chain" => taint.chain
    }

    case legacy_data_hash(opts) do
      {:ok, nil} -> base
      {:ok, hash} -> Map.put(base, "taint_data_hash", hash)
      :error -> base
    end
  rescue
    _ -> legacy_persistable(@taint_struct.invalid_durable_provenance())
  end

  @doc """
  Restore a Taint struct from the versionless legacy persistable map.

  Accepts only the exact legacy string-keyed representation (plus the optional
  legacy data hash). Missing, mixed, corrupt, or unbounded values fail closed as
  the whole `:invalid_durable_provenance` label; fields are never repaired
  independently. This compatibility API MUST NOT be used for new durable
  records; use `resolve_durable_provenance/2` instead.
  """
  @spec from_persistable(map()) :: struct()
  def from_persistable(map) when is_map(map) do
    with {:ok, legacy} <- exact_legacy_persistable(map),
         {:ok, taint} <-
           @taint_struct.canonicalize(%{
             "level" => legacy["taint_level"],
             "sensitivity" => legacy["taint_sensitivity"],
             "sanitizations" => legacy["taint_sanitizations"],
             "confidence" => legacy["taint_confidence"],
             "source" => legacy["taint_source"],
             "chain" => legacy["taint_chain"]
           }) do
      taint
    else
      _ -> @taint_struct.invalid_durable_provenance()
    end
  rescue
    _ -> @taint_struct.invalid_durable_provenance()
  end

  def from_persistable(_map), do: @taint_struct.invalid_durable_provenance()

  @doc "Bind an exact canonical-json-v1 envelope for durable provenance."
  @spec bind_durable_provenance(term(), struct()) :: {:ok, map()} | {:error, atom()}
  def bind_durable_provenance(payload, taint) do
    with {:ok, envelope} <- @taint_envelope.new(payload, taint) do
      @taint_envelope.to_map(envelope)
    end
  rescue
    _ -> {:error, :invalid_envelope}
  end

  @doc "Strictly verify a durable provenance envelope against its payload."
  @spec verify_durable_provenance(term(), term()) :: {:ok, struct()} | {:error, atom()}
  def verify_durable_provenance(persisted, payload) do
    @taint_envelope.verify(persisted, payload)
  rescue
    _ -> {:error, :invalid_envelope}
  end

  @doc "Resolve durable provenance conservatively, including missing legacy data."
  @spec resolve_durable_provenance(:missing | term(), term()) ::
          {:ok, struct(), atom()}
  def resolve_durable_provenance(persisted, payload) do
    @taint_envelope.resolve(persisted, payload)
  rescue
    _ -> {:ok, @taint_struct.invalid_durable_provenance(), :invalid_durable_provenance}
  end

  # ── LLM Output Taint ────────────────────────────────────────────────

  @doc """
  Create taint for LLM output.

  Wipes ALL sanitization bits (council decision #6: LLM output cannot be
  assumed to preserve any input sanitization). The level is floored at
  `:derived`, confidence is capped at `:plausible`, sensitivity is preserved,
  and bounded `llm_output` provenance is added. Malformed or overflowing
  provenance returns the invalid durable-provenance fallback.
  """
  @spec for_llm_output(struct()) :: struct()
  def for_llm_output(input_taint) do
    with {:ok, input} <- @taint_struct.canonicalize(input_taint),
         {:ok, joined} <-
           @taint_struct.join(input, %@taint_struct{
             level: :derived,
             sensitivity: :public,
             sanitizations: 0,
             confidence: :plausible,
             source: "llm_output",
             chain: []
           }),
         {:ok, output} <-
           @taint_struct.new(%{
             level: joined.level,
             sensitivity: joined.sensitivity,
             sanitizations: joined.sanitizations,
             confidence: joined.confidence,
             source: "llm_output",
             chain: input.chain ++ [input.source || "llm"]
           }) do
      output
    else
      _ -> @taint_struct.invalid_durable_provenance()
    end
  rescue
    _ -> @taint_struct.invalid_durable_provenance()
  end

  # ── Bridge: atom → struct ────────────────────────────────────────────

  @doc """
  Upgrade a bare taint level atom to a full Taint struct.

  Used at boundaries where legacy atom-based taint meets the new struct system.
  """
  @spec from_level(level()) :: struct()
  def from_level(level) do
    if valid_level?(level),
      do: struct(@taint_struct, level: level),
      else: @taint_struct.invalid_durable_provenance()
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp identity_taint do
    {:ok, taint} =
      @taint_struct.new(%{
        level: :trusted,
        sensitivity: :public,
        sanitizations: 0,
        confidence: :verified,
        source: nil,
        chain: []
      })

    taint
  end

  defp propagate_levels([], level, _count), do: level

  defp propagate_levels([head | rest], level, count) do
    if count < @taint_struct.max_join_inputs() and valid_level?(head) do
      propagate_levels(rest, max_taint(level, head), count + 1)
    else
      :hostile
    end
  end

  defp propagate_levels(_improper_tail, _level, _count), do: :hostile

  defp validate_propagation_inputs([], _count), do: :ok

  defp validate_propagation_inputs([head | rest], count) do
    if count < @taint_struct.max_join_inputs() do
      with {:ok, taint} <- @taint_struct.canonicalize(head),
           false <- invalid_durable_taint?(taint),
           :ok <- validate_propagation_inputs(rest, count + 1) do
        :ok
      else
        _ -> {:error, :invalid_taint}
      end
    else
      {:error, :taint_join_limit_exceeded}
    end
  end

  defp validate_propagation_inputs(_improper_tail, _count),
    do: {:error, :invalid_taint_list}

  defp invalid_durable_taint?(taint),
    do: taint == @taint_struct.invalid_durable_provenance()

  defp canonical_or_invalid(value) do
    case @taint_struct.canonicalize(value) do
      {:ok, taint} -> taint
      {:error, _reason} -> @taint_struct.invalid_durable_provenance()
    end
  end

  defp legacy_persistable(taint) do
    %{
      "taint_level" => Atom.to_string(taint.level),
      "taint_sensitivity" => Atom.to_string(taint.sensitivity),
      "taint_sanitizations" => taint.sanitizations,
      "taint_confidence" => Atom.to_string(taint.confidence),
      "taint_source" => taint.source,
      "taint_chain" => taint.chain
    }
  end

  defp legacy_data_hash(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get(opts, :data_hash) do
        nil -> {:ok, nil}
        hash when is_binary(hash) -> {:ok, hash}
        _ -> :error
      end
    else
      {:ok, nil}
    end
  end

  defp legacy_data_hash(_opts), do: {:ok, nil}

  defp exact_legacy_persistable(map) do
    required = [
      "taint_level",
      "taint_sensitivity",
      "taint_sanitizations",
      "taint_confidence",
      "taint_source",
      "taint_chain"
    ]

    keys = Map.keys(map)

    allowed = required ++ ["taint_data_hash"]

    cond do
      not Enum.all?(keys, &is_binary/1) ->
        {:error, :invalid_legacy_taint}

      MapSet.equal?(MapSet.new(keys), MapSet.new(required)) ->
        if valid_legacy_values?(map), do: {:ok, map}, else: {:error, :invalid_legacy_taint}

      MapSet.equal?(MapSet.new(keys), MapSet.new(allowed)) and is_binary(map["taint_data_hash"]) ->
        if valid_legacy_values?(map), do: {:ok, map}, else: {:error, :invalid_legacy_taint}

      true ->
        {:error, :invalid_legacy_taint}
    end
  end

  defp valid_legacy_values?(map) do
    is_binary(map["taint_level"]) and
      is_binary(map["taint_sensitivity"]) and
      is_integer(map["taint_sanitizations"]) and
      is_binary(map["taint_confidence"]) and
      (is_nil(map["taint_source"]) or is_binary(map["taint_source"])) and
      valid_legacy_chain?(map["taint_chain"], @taint_struct.max_chain_entries())
  end

  defp valid_legacy_chain?([], _remaining), do: true

  defp valid_legacy_chain?([entry | rest], remaining)
       when remaining > 0 and is_binary(entry),
       do: valid_legacy_chain?(rest, remaining - 1)

  defp valid_legacy_chain?(_chain, _remaining), do: false
end
