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
end
