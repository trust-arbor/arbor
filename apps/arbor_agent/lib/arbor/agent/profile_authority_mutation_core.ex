defmodule Arbor.Agent.ProfileAuthorityMutationCore do
  @moduledoc """
  Pure CRC core for Phase 4C C3B1 authoritative profile authority mutation.

  Owns three pure decisions with NO IO, clock, randomness, Process,
  Application, store, File, or GenServer access, and no `String.to_atom`:

    * `prepare/2`         — overlay a closed governed authority update onto an
                             observed raw serialized profile map, preserving
                             every unrelated top-level and nested field.
    * `envelope_stable?/2` — pre-CAS stability predicate comparing two
                             structured Records on
                             id/key/data/metadata/generation/revision.
    * `classify/3`        — classify an ambiguous CAS outcome by authoritative
                             reobservation as
                             not_applied/already_applied/conflict/outcome_unknown.

  The core operates on raw string-keyed JSON maps (the form persisted in
  `Record.data`) and on `Arbor.Contracts.Persistence.Record` structs. It never
  deserializes through `Profile`, never normalizes missing/nil authority into
  defaults, and never atomizes untrusted keys.
  """

  alias Arbor.Contracts.Persistence.Record

  # The closed set of governed authority keys C3B1 may overwrite.
  @governed_top_keys MapSet.new(["template", "initial_capabilities", "metadata"])
  @governed_meta_keys MapSet.new(["exact_template_policy"])

  # Atom aliases of governed keys — presence (atom-only) is itself an alias.
  @governed_top_atoms [:template, :initial_capabilities, :metadata]
  @governed_meta_atoms [:exact_template_policy]
  @cap_item_atoms [:resource, :constraints]

  @max_template_bytes 256
  @max_resource_bytes 1024
  @max_capabilities 256

  @type outcome :: :not_applied | :already_applied | :conflict | :outcome_unknown
  @type reobserved :: {:ok, Record.t()} | :not_found | {:error, term()}

  @doc """
  Prepare the closed raw authority update.

  Overlays `governed` onto a copy of `observed_data` (the raw string-keyed map
  taken verbatim from `Record.data`), writing ONLY the governed keys:
  top-level `"template"`, `"initial_capabilities"`, and nested
  `metadata["exact_template_policy"]`. Every other top-level key and every
  other metadata key is preserved untouched.

  ## Rejection rules (fail closed; never normalizes or defaults)

    * `observed_data` must be a plain map (`is_map/1` and not a struct).
    * `observed_data["metadata"]` must be present and a plain map — missing,
      nil, scalar, or struct metadata is `:malformed_container` (never
      synthesized as `%{}`).
    * `governed` must be a plain map with EXACTLY the string keys
      `template`, `initial_capabilities`, `metadata`; `governed["metadata"]`
      must be a plain map with EXACTLY the string key `exact_template_policy`.
    * Any atom key that aliases a governed key (top-level, nested, or a
      capability item's `resource`/`constraints`) — including atom-ONLY
      presence — is `:ambiguous_keys`. Untrusted keys are never atomized.
    * Governed values must be well-formed: nonempty valid-UTF-8 `template`,
      a bounded proper list of capability maps for `initial_capabilities`,
      and a plain map for `exact_template_policy`. Missing/nil/oversized/
      non-UTF-8 values are rejected, never coerced to defaults.

  Values are stored verbatim — no normalization, no field stripping.
  """
  @spec prepare(map(), map()) :: {:ok, map()} | {:error, atom()}
  def prepare(observed_data, governed) do
    with :ok <- require_plain_map(observed_data, :observed_not_map),
         :ok <- reject_governed_atom_keys(observed_data, @governed_top_atoms),
         {:ok, observed_meta} <- require_observed_metadata(observed_data),
         :ok <- reject_governed_atom_keys(observed_meta, @governed_meta_atoms),
         :ok <- require_plain_map(governed, :governed_shape),
         :ok <- reject_any_atom_key(governed),
         :ok <- closed_keyset(governed, @governed_top_keys, :governed_shape),
         {:ok, governed_meta} <- require_governed_metadata(governed),
         {:ok, template} <- require_template(governed["template"]),
         {:ok, capabilities} <- require_capabilities(governed["initial_capabilities"]),
         :ok <-
           require_plain_map(governed_meta["exact_template_policy"], :policy_invalid) do
      policy = governed_meta["exact_template_policy"]

      intended =
        observed_data
        |> Map.put("template", template)
        |> Map.put("initial_capabilities", capabilities)
        |> Map.put("metadata", Map.put(observed_meta, "exact_template_policy", policy))

      {:ok, intended}
    end
  end

  @doc """
  Pre-CAS envelope-stability predicate.

  True iff `observed` and `current` are both `%Record{}` and their
  id/key/data/metadata/generation/revision are ALL equal. Timestamps are
  backend-owned and excluded. Used by the shell before CAS: Record CAS fences
  on generation+revision ONLY, so this full-envelope precondition refuses any
  drift since observation — including a caller that tampered observed
  data/id/metadata while preserving its tokens.
  """
  @spec envelope_stable?(Record.t(), term()) :: boolean()
  def envelope_stable?(%Record{} = observed, %Record{} = current) do
    observed.id == current.id and
      observed.key == current.key and
      observed.data == current.data and
      observed.metadata == current.metadata and
      observed.generation == current.generation and
      observed.revision == current.revision
  end

  def envelope_stable?(_observed, _current), do: false

  @doc """
  Classify an ambiguous CAS outcome by authoritative reobservation.

  Compares id/key/data/metadata/generation/revision only (timestamps excluded):

    * reobserved == observed anchor             -> `:not_applied`
    * reobserved == exact one-revision successor -> `:already_applied`
    * valid same-key divergent Record           -> `:conflict`
    * slot absent (`:not_found`)                -> `:conflict`
    * malformed occupant / wrong key            -> `:outcome_unknown`
    * unreadable (`{:error, _}`)                -> `:outcome_unknown`

  `already_applied` is STRICT: later revisions, equal-authority-but-different
  data, and ABA equal-data under a new generation are all `:conflict`.
  """
  @spec classify(Record.t(), map(), reobserved()) :: outcome()
  def classify(%Record{} = observed, intended_data, reobserved) do
    case reobserved do
      {:ok, %Record{} = r} ->
        cond do
          r.key != observed.key -> :outcome_unknown
          envelope_stable?(observed, r) -> :not_applied
          intended_successor?(observed, intended_data, r) -> :already_applied
          true -> :conflict
        end

      {:ok, _malformed} ->
        :outcome_unknown

      :not_found ->
        :conflict

      {:error, _reason} ->
        :outcome_unknown
    end
  end

  defp intended_successor?(observed, intended_data, r) do
    r.id == observed.id and
      r.key == observed.key and
      r.generation == observed.generation and
      r.revision == observed.revision + 1 and
      r.data == intended_data and
      r.metadata == observed.metadata
  end

  # ---------------------------------------------------------------------------
  # Container / keyset helpers
  # ---------------------------------------------------------------------------

  defp require_plain_map(value, reason) do
    if is_map(value) and not is_struct(value), do: :ok, else: {:error, reason}
  end

  # Reject if the map contains the atom form of any governed key
  # (atom-only presence counts as an alias).
  defp reject_governed_atom_keys(map, atoms) do
    if Enum.any?(atoms, &Map.has_key?(map, &1)) do
      {:error, :ambiguous_keys}
    else
      :ok
    end
  end

  # Reject if the map contains ANY atom key at all.
  defp reject_any_atom_key(map) do
    if Enum.any?(map, fn {k, _} -> is_atom(k) end) do
      {:error, :ambiguous_keys}
    else
      :ok
    end
  end

  defp closed_keyset(map, allowed, reason) do
    if MapSet.equal?(MapSet.new(Map.keys(map)), allowed), do: :ok, else: {:error, reason}
  end

  defp require_observed_metadata(observed_data) do
    case Map.fetch(observed_data, "metadata") do
      {:ok, value} when is_map(value) and not is_struct(value) ->
        {:ok, value}

      _ ->
        {:error, :malformed_container}
    end
  end

  defp require_governed_metadata(governed) do
    case Map.fetch(governed, "metadata") do
      {:ok, value} ->
        with :ok <- require_plain_map(value, :governed_shape),
             :ok <- reject_any_atom_key(value),
             :ok <- closed_keyset(value, @governed_meta_keys, :governed_shape) do
          {:ok, value}
        end

      :error ->
        {:error, :governed_shape}
    end
  end

  defp require_template(value) do
    cond do
      not is_binary(value) -> {:error, :template_invalid}
      not String.valid?(value) -> {:error, :template_invalid}
      byte_size(value) == 0 -> {:error, :template_invalid}
      byte_size(value) > @max_template_bytes -> {:error, :template_invalid}
      String.contains?(value, <<0>>) -> {:error, :template_invalid}
      true -> {:ok, value}
    end
  end

  defp require_capabilities(value) do
    with :ok <- require_proper_list(value),
         :ok <- validate_each_capability(value, 0) do
      # Values are validated but never normalized — return the original list
      # verbatim so capability items keep every field untouched.
      {:ok, value}
    end
  end

  defp validate_each_capability([], _n), do: :ok

  defp validate_each_capability([item | rest], n) do
    if n >= @max_capabilities do
      {:error, :capabilities_invalid}
    else
      with :ok <- require_capability(item) do
        validate_each_capability(rest, n + 1)
      end
    end
  end

  defp require_capability(item) do
    with :ok <- require_plain_map(item, :capabilities_invalid),
         :ok <- reject_governed_atom_keys(item, @cap_item_atoms),
         :ok <- require_present_string(item, "resource", @max_resource_bytes) do
      require_present_plain_map(item, "constraints")
    end
  end

  defp require_present_string(map, key, max_bytes) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        if String.valid?(value) and byte_size(value) > 0 and
             byte_size(value) <= max_bytes and not String.contains?(value, <<0>>) do
          :ok
        else
          {:error, :capabilities_invalid}
        end

      _ ->
        {:error, :capabilities_invalid}
    end
  end

  defp require_present_plain_map(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) and not is_struct(value) -> :ok
      _ -> {:error, :capabilities_invalid}
    end
  end

  # Bounded proper-list validation without calling length/1 or Enum on an
  # improper tail (which would raise). Recursion is bounded so a pathologically
  # long list cannot loop forever.
  defp require_proper_list(value) when is_list(value) do
    if improper?(value, 0), do: {:error, :capabilities_invalid}, else: :ok
  end

  defp require_proper_list(_), do: {:error, :capabilities_invalid}

  defp improper?([], _n), do: false

  defp improper?([_ | rest], n) when n <= @max_capabilities,
    do: improper?(rest, n + 1)

  defp improper?([_ | _], n) when n > @max_capabilities, do: false
  defp improper?(_, _), do: true
end
