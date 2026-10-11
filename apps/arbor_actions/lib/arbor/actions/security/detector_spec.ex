defmodule Arbor.Actions.Security.DetectorSpec do
  @moduledoc """
  A synthesizable security detector specification (Security Sentinel E1.1 / E1.2).

  A `DetectorSpec` is the *only finding-specific* output of synthesis — everything
  around it (the generated module, the AST walk, the violation/Finding shape) is
  template (see `Arbor.Actions.Security.DetectorTemplate`). The spec is derived
  deterministically from a confirmed `Finding` for the known categories, or
  (E1.4) produced by an LLM anchored on the finding's *invariant*.

  ## Shapes

  A spec carries a `shape` discriminator selecting how its predicate is detected:

    * `:s1` (default, E1.1) — a **per-file AST pattern**: walk every `def`/`defp`
      whose name marks it as a target (`name_match`), look at a particular clause
      position (`clause_position`), and flag the clause when it returns a banned
      literal (`target_literals`). The shape the `AuthorizationSmells` check
      pioneered.

    * `:s3` (E1.2) — a **tree-wide AST/literal pattern**: glob every `.ex` file,
      prewalk each file's AST for a parameterized `match_pattern`, and emit a
      `Finding` per match. The generalizable sub-shape of the whole-tree detectors
      (`UriRegistration` et al.): "a forbidden / over-broad pattern present
      anywhere in the tree." Bespoke *correlation* detectors (SignedFieldCoverage's
      struct-field transitive closure, UriRegistration's allowlist coverage) are
      NOT expressible this way and are rejected with `{:unsupported_shape, _}` —
      they stay hand-authored.

  ## S1 fields

    * `name` — string id for the generated detector (its `use Arbor.Eval, name:`)
    * `category` — a `Finding` category atom; MUST be in `s1_categories/0`
    * `invariant` — the human invariant the detector enforces (synthesis anchors
      here so the predicate generalizes past the single seed instance)
    * `name_match` — substrings (strings) and/or exact names (atoms) identifying
      the target functions, mirroring `AuthorizationSmells`'s
      `@auth_name_substrings` / `@auth_name_exact`
    * `target_literals` — the literal return values to flag (the "bad" returns)
    * `exclusions` — literals that look like `target_literals` but are known FPs
      (carved out so the detector doesn't cry wolf)
    * `clause_position` — which clause(s) to inspect:
      `:rescue` (function-level or `try` rescue/catch),
      `:catch_all` (a `case` catch-all `_ ->`), or
      `:rescue_or_catch_all` (both — `AuthorizationSmells`'s behavior)

  ## S3 fields

    * `name`, `category`, `invariant` — as above; `category` MUST be in
      `s3_categories/0`
    * `match_pattern` — the parameterized tree-wide pattern to flag, a map with a
      `:kind` discriminator (reusing the S1 structural-literal vocabulary where it
      fits):
      * `%{kind: :literal, literal: term}` — flag any literal in the tree that
        structurally matches `literal`. The atom `:_` is a one-element wildcard
        (so `{:ok, :_}` matches any `{:ok, _}`), exactly like S1's
        `target_literals`. A *string* literal matches by substring (so the
        pattern `"arbor://"` flags any binary containing it).
      * `%{kind: :call, call: name}` — flag any call to the function `name` (an
        atom for a local/imported call like `:to_atom`, or a `"Mod.fun"` string
        for a remote call like `"String.to_atom"`).
    * `exclusions` — literals (for `:literal` patterns) that look like a match but
      are known FPs, carved out exactly as in S1.
    * `name_match` — optional: when present, only matches inside a `def`/`defp`
      whose name matches are flagged (so a tree-wide pattern can be scoped to
      target functions); empty means "anywhere in the file".

  ## The closed category sets (E1 scope boundary)

  E1.1 (S1) supports `:fail_open_authz`, `:unsafe_atom`, `:path_traversal`,
  `:config_fail_open`. E1.2 (S3) supports `:capability_overmatch` and
  `:serialization_drop` (the generalizable tree-wide-pattern members of the
  whole-tree family). Any other category — or a bespoke-correlation category — is
  rejected with `{:error, {:unsupported_shape, category}}` (a contract/union
  change + human sign-off is required to widen this — deferred to v2).
  """

  use TypedStruct

  @typedoc "Which clause position(s) a generated S1 detector inspects."
  @type clause_position :: :rescue | :catch_all | :rescue_or_catch_all

  @typedoc "The detector shape discriminator."
  @type shape :: :s1 | :s3

  @s1_categories [:fail_open_authz, :unsafe_atom, :path_traversal, :config_fail_open]
  @s3_categories [:capability_overmatch, :serialization_drop]
  @clause_positions [:rescue, :catch_all, :rescue_or_catch_all]

  # Transport-form coercion allowlists (see `coerce_params/1`). Known atom-valued
  # tokens are converted ONLY when they name one of these — never
  # `String.to_atom/1` on model/transport output.
  @known_literal_atoms ~w(ok error true false nil authorized unauthorized verified unverified)
  @known_clause_positions Enum.map(@clause_positions, &Atom.to_string/1)

  typedstruct do
    @typedoc "A synthesizable detector specification (S1 per-file AST or S3 tree-wide)"

    field(:shape, shape(), default: :s1)
    field(:name, String.t(), enforce: true)
    field(:category, atom(), enforce: true)
    field(:invariant, String.t(), enforce: true)
    # S1
    field(:name_match, [String.t() | atom()], default: [])
    field(:target_literals, [term()], default: [])
    field(:exclusions, [term()], default: [])
    field(:clause_position, clause_position(), default: :rescue_or_catch_all)
    # S3
    field(:match_pattern, map() | nil, default: nil)
  end

  @doc "The closed set of known S1 (per-file AST) categories."
  @spec s1_categories() :: [atom()]
  def s1_categories, do: @s1_categories

  @doc "The closed set of known S3 (tree-wide pattern) categories."
  @spec s3_categories() :: [atom()]
  def s3_categories, do: @s3_categories

  @doc "True if `category` is a supported S1 (per-file AST) shape."
  @spec s1_category?(atom()) :: boolean()
  def s1_category?(category), do: category in @s1_categories

  @doc "True if `category` is a supported S3 (tree-wide pattern) shape."
  @spec s3_category?(atom()) :: boolean()
  def s3_category?(category), do: category in @s3_categories

  @doc """
  Returns the shape implied by a category, or `:error` if the category is
  neither a known S1 nor S3 shape (an unsupported/bespoke category).
  """
  @spec shape_for_category(atom()) :: {:ok, shape()} | :error
  def shape_for_category(category) do
    cond do
      category in @s1_categories -> {:ok, :s1}
      category in @s3_categories -> {:ok, :s3}
      true -> :error
    end
  end

  @doc """
  Builds a `DetectorSpec` from a map of params, validating the shape's invariants.

  The `shape` is taken from the params, else inferred from `category`. Returns
  `{:ok, spec}` or `{:error, reason}`.

  Common rejections:

    * a category that is neither a known S1 nor S3 shape (or whose explicitly
      requested shape disagrees with the category) →
      `{:error, {:unsupported_shape, category}}`

  S1 rejections:

    * an unknown `clause_position` → `{:error, {:invalid_clause_position, pos}}`
    * an empty `name_match` (a detector that matches no function is useless) →
      `{:error, :empty_name_match}`
    * an empty `target_literals` (nothing to flag) → `{:error, :empty_target_literals}`

  S3 rejections:

    * a missing/invalid `match_pattern` → `{:error, :invalid_match_pattern}`
  """
  @spec build(map()) :: {:ok, t()} | {:error, term()}
  def build(params) when is_map(params) do
    category = params[:category] || params["category"]

    case resolve_shape(params, category) do
      {:error, _} = err -> err
      :s1 -> build_s1(params, category)
      :s3 -> build_s3(params, category)
    end
  end

  # If a shape is explicitly supplied it must be consistent with the category;
  # otherwise we infer the shape from the category. An unknown category, or an
  # explicit shape that disagrees with the category, is an unsupported shape.
  defp resolve_shape(params, category) do
    requested = coerce_shape(params[:shape] || params["shape"])

    case {requested, shape_for_category(category)} do
      {nil, {:ok, shape}} -> shape
      {nil, :error} -> {:error, {:unsupported_shape, category}}
      {shape, {:ok, shape}} -> shape
      {_shape, _} -> {:error, {:unsupported_shape, category}}
    end
  end

  defp coerce_shape(:s1), do: :s1
  defp coerce_shape(:s3), do: :s3
  defp coerce_shape("s1"), do: :s1
  defp coerce_shape("s3"), do: :s3
  defp coerce_shape(_), do: nil

  defp build_s1(params, category) do
    clause_position =
      params[:clause_position] || params["clause_position"] || :rescue_or_catch_all

    name_match = params[:name_match] || params["name_match"] || []
    target_literals = params[:target_literals] || params["target_literals"] || []

    with :ok <- validate_s1(clause_position, name_match, target_literals) do
      {:ok,
       %__MODULE__{
         shape: :s1,
         name: params[:name] || params["name"] || default_name(category),
         category: category,
         invariant: params[:invariant] || params["invariant"] || "",
         name_match: name_match,
         target_literals: target_literals,
         exclusions: params[:exclusions] || params["exclusions"] || [],
         clause_position: clause_position
       }}
    end
  end

  defp validate_s1(clause_position, _name_match, _target_literals)
       when clause_position not in @clause_positions,
       do: {:error, {:invalid_clause_position, clause_position}}

  defp validate_s1(_clause_position, [], _target_literals), do: {:error, :empty_name_match}
  defp validate_s1(_clause_position, _name_match, []), do: {:error, :empty_target_literals}
  defp validate_s1(_clause_position, _name_match, _target_literals), do: :ok

  defp build_s3(params, category) do
    match_pattern = normalize_match_pattern(params[:match_pattern] || params["match_pattern"])

    case validate_match_pattern(match_pattern) do
      :ok ->
        {:ok,
         %__MODULE__{
           shape: :s3,
           name: params[:name] || params["name"] || default_name(category),
           category: category,
           invariant: params[:invariant] || params["invariant"] || "",
           name_match: params[:name_match] || params["name_match"] || [],
           exclusions: params[:exclusions] || params["exclusions"] || [],
           match_pattern: match_pattern
         }}

      {:error, _} = err ->
        err
    end
  end

  # Accept atom- or string-keyed maps for the match_pattern; normalize to a
  # canonical %{kind: atom, ...} map.
  defp normalize_match_pattern(%{} = mp) do
    case coerce_match_kind(mp[:kind] || mp["kind"]) do
      :literal -> %{kind: :literal, literal: mp[:literal] || mp["literal"]}
      :call -> %{kind: :call, call: mp[:call] || mp["call"]}
      _ -> %{kind: nil}
    end
  end

  defp normalize_match_pattern(_), do: nil

  defp coerce_match_kind(:literal), do: :literal
  defp coerce_match_kind(:call), do: :call
  defp coerce_match_kind("literal"), do: :literal
  defp coerce_match_kind("call"), do: :call
  defp coerce_match_kind(_), do: nil

  defp validate_match_pattern(%{kind: :literal, literal: lit}) when not is_nil(lit), do: :ok
  defp validate_match_pattern(%{kind: :call, call: c}) when is_atom(c) and not is_nil(c), do: :ok
  defp validate_match_pattern(%{kind: :call, call: c}) when is_binary(c) and c != "", do: :ok
  defp validate_match_pattern(_), do: {:error, :invalid_match_pattern}

  defp default_name(category), do: "synthesized_#{category}"

  # ---------------------------------------------------------------------------
  # Transport-form coercion (any representation → validated spec)
  # ---------------------------------------------------------------------------

  @doc """
  Coerce ANY representation of a spec into a validated `%DetectorSpec{}`.

  Accepts:

    * a built `%DetectorSpec{}` — re-validated by round-tripping through
      `build/1`, so a hand-built struct still gets every check;
    * an in-process map (atom or string keys, canonical atom/tuple values);
    * a JSON-clean map (string keys; string/boolean/list values) — the form a
      spec takes after crossing the Engine context / checkpoint boundary, or as
      decoded from the LLM-synthesis node's output.

  Maps go through `coerce_params/1` first, so atom-valued fields are only ever
  produced from allowlists — never `String.to_atom/1` on transport data. `nil`,
  an empty map, or a non-map is `{:error, :invalid_spec}`; a map that coerces
  but fails validation returns `build/1`'s error.

  This is the single entry point `Arbor.Actions.Security.SweepCandidate` trusts:
  it rebuilds the candidate detector from THIS struct, never from caller-supplied
  source (F-008).
  """
  @spec coerce(term()) :: {:ok, t()} | {:error, term()}
  def coerce(%__MODULE__{} = spec), do: build(Map.from_struct(spec))

  def coerce(map) when is_map(map) and not is_struct(map) and map_size(map) > 0,
    do: map |> coerce_params() |> build()

  def coerce(_other), do: {:error, :invalid_spec}

  @doc """
  Normalize a spec map in transport form into `build/1` params.

  Handles the JSON-clean string-keyed/string-valued form (the LLM-synthesis
  node's decoded output, or a spec that crossed the Engine's JSON context
  boundary) AND an in-process atom-keyed map. Known atom-valued fields are
  coerced against allowlists — NEVER `String.to_atom/1` on model/transport
  output. Literals are coerced from JSON tokens: a string token to its
  atom/boolean/nil value, and a 2-element list like `["ok", "_"]` to the tuple
  `{:ok, :_}` (the `{:ok, _}` wildcard form). Values that are already canonical
  atoms/tuples pass through unchanged, so a `Map.from_struct/1`'d spec
  round-trips to an identical struct. `nil`/unrecognized fields are dropped so
  `build/1` applies its defaults.

  Shared by `SynthesizeDetector` (its JSON spec path) and `SweepCandidate` (via
  `coerce/1`), so both stages agree on what a transported spec means.
  """
  @spec coerce_params(map()) :: map()
  def coerce_params(map) when is_map(map) and not is_struct(map) do
    %{
      name: get(map, :name),
      shape: coerce_shape(get(map, :shape)),
      category: coerce_category(get(map, :category)),
      invariant: get(map, :invariant),
      name_match: coerce_name_match(get(map, :name_match)),
      target_literals: coerce_literals(get(map, :target_literals)),
      exclusions: coerce_literals(get(map, :exclusions)),
      clause_position: coerce_clause_position(get(map, :clause_position)),
      match_pattern: coerce_match_pattern(get(map, :match_pattern))
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp get(map, key) when is_atom(key), do: map[key] || map[Atom.to_string(key)]

  defp coerce_category(nil), do: nil

  # A string category is matched against BOTH the S1 and S3 known sets
  # (allowlist only — never String.to_atom on model output). An already-atom
  # category passes through untouched: it exists, and build/1 rejects it if it
  # is not a supported shape.
  defp coerce_category(str) when is_binary(str) do
    Enum.find(@s1_categories ++ @s3_categories, &(Atom.to_string(&1) == str))
  end

  defp coerce_category(atom) when is_atom(atom), do: atom
  defp coerce_category(_), do: nil

  # The S3 match_pattern. `kind` is allowlisted; the call target and literal value
  # are coerced through the SAME hardened coercions as S1 literals/name_match
  # (no String.to_atom on raw model output). A "Mod.fun" call stays a binary.
  defp coerce_match_pattern(%{} = mp) do
    case coerce_match_kind(mp[:kind] || mp["kind"]) do
      :literal -> %{kind: :literal, literal: coerce_literal(mp[:literal] || mp["literal"])}
      :call -> %{kind: :call, call: coerce_call_target(mp[:call] || mp["call"])}
      _ -> nil
    end
  end

  defp coerce_match_pattern(_), do: nil

  # A call target: a remote "Mod.fun" stays a binary (matched textually by the
  # generated detector); a bare "fun" / "@fun" / ":fun" becomes an existing atom
  # when known, else falls back to the binary form (never minting new atoms). An
  # already-atom target passes through.
  defp coerce_call_target(str) when is_binary(str) do
    if String.contains?(str, "."),
      do: str,
      else: to_known_atom_or(strip_colon(strip_at(str)), str)
  end

  defp coerce_call_target(atom) when is_atom(atom) and not is_nil(atom), do: atom
  defp coerce_call_target(_), do: nil

  defp strip_at("@" <> rest), do: rest
  defp strip_at(str), do: str

  defp coerce_clause_position(pos) when pos in @clause_positions, do: pos

  defp coerce_clause_position(str) when is_binary(str) and str in @known_clause_positions do
    String.to_existing_atom(str)
  end

  defp coerce_clause_position(_), do: nil

  # Substring strings pass through; "@name" is an exact-name atom (when it already
  # exists); an already-atom exact name passes through.
  defp coerce_name_match(list) when is_list(list) do
    Enum.flat_map(list, fn
      "@" <> exact -> [to_known_atom_or(exact, exact)]
      bin when is_binary(bin) -> [bin]
      atom when is_atom(atom) and not is_boolean(atom) and not is_nil(atom) -> [atom]
      _ -> []
    end)
  end

  defp coerce_name_match(_), do: nil

  defp coerce_literals(list) when is_list(list), do: Enum.map(list, &coerce_literal/1)
  defp coerce_literals(_), do: nil

  # A single JSON literal token → an Elixir literal. A 2-element list → a tuple
  # (recursively), enabling ["ok", "_"] → {:ok, :_}. Already-canonical terms
  # (atoms, tuples, numbers) pass through.
  defp coerce_literal([a, b]), do: {coerce_literal(a), coerce_literal(b)}
  defp coerce_literal("_"), do: :_
  defp coerce_literal(true), do: true
  defp coerce_literal(false), do: false
  defp coerce_literal(nil), do: nil

  defp coerce_literal(str) when is_binary(str) do
    cond do
      str == "true" -> true
      str == "false" -> false
      str == "nil" -> nil
      str in @known_literal_atoms -> String.to_existing_atom(strip_colon(str))
      String.starts_with?(str, ":") -> to_known_atom_or(strip_colon(str), str)
      true -> str
    end
  end

  defp coerce_literal(other), do: other

  defp strip_colon(":" <> rest), do: rest
  defp strip_colon(str), do: str

  defp to_known_atom_or(name, fallback) do
    if name in @known_literal_atoms do
      String.to_existing_atom(name)
    else
      try do
        String.to_existing_atom(name)
      rescue
        ArgumentError -> fallback
      end
    end
  end
end
