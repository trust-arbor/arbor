defmodule Arbor.Actions.Security.DetectorSpec do
  @moduledoc """
  A synthesizable **S1 per-file AST** detector specification (Security Sentinel E1.1).

  An S1 detector matches an AST shape *within a function* — the shape the
  `AuthorizationSmells` check pioneered: walk every `def`/`defp` whose name marks
  it as a target (`name_match`), look at a particular clause position
  (`clause_position` — a fail-open `rescue`/`catch` or a `case` catch-all `_ ->`),
  and flag the clause when the value it returns is a "bad" literal
  (`target_literals`) and is not on the allow-list of known false positives
  (`exclusions`).

  A `DetectorSpec` is the *only finding-specific* output of synthesis — everything
  around it (the `use Arbor.Eval` module, the prewalk, the violation shape) is
  template (see `Arbor.Actions.Security.DetectorTemplate`). The spec is derived
  deterministically from a confirmed `Finding` for the known S1 categories, or
  (E1.4) produced by an LLM anchored on the finding's *invariant*.

  ## Fields

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

  ## The closed S1 category set (E1.1 scope boundary)

  Per the E1 design's scope boundary, E1.1 supports only the known per-file AST
  categories: `:fail_open_authz`, `:unsafe_atom`, `:path_traversal`,
  `:config_fail_open`. Any other category is rejected with
  `{:error, {:unsupported_shape, category}}` (a contract/union change + human
  sign-off is required to widen this — deferred to v2).
  """

  use TypedStruct

  @typedoc "Which clause position(s) a generated S1 detector inspects."
  @type clause_position :: :rescue | :catch_all | :rescue_or_catch_all

  @s1_categories [:fail_open_authz, :unsafe_atom, :path_traversal, :config_fail_open]

  typedstruct do
    @typedoc "An S1 per-file AST detector specification"

    field(:name, String.t(), enforce: true)
    field(:category, atom(), enforce: true)
    field(:invariant, String.t(), enforce: true)
    field(:name_match, [String.t() | atom()], default: [])
    field(:target_literals, [term()], default: [])
    field(:exclusions, [term()], default: [])
    field(:clause_position, clause_position(), default: :rescue_or_catch_all)
  end

  @doc "The closed set of known S1 (per-file AST) categories E1.1 supports."
  @spec s1_categories() :: [atom()]
  def s1_categories, do: @s1_categories

  @doc "True if `category` is a supported S1 (per-file AST) shape."
  @spec s1_category?(atom()) :: boolean()
  def s1_category?(category), do: category in @s1_categories

  @doc """
  Builds a `DetectorSpec` from a map of params, validating the S1 invariants.

  Returns `{:ok, spec}` or `{:error, reason}`. Rejects:

    * a non-S1 `category` → `{:error, {:unsupported_shape, category}}`
    * an unknown `clause_position` → `{:error, {:invalid_clause_position, pos}}`
    * an empty `name_match` (a detector that matches no function is useless) →
      `{:error, :empty_name_match}`
    * an empty `target_literals` (nothing to flag) → `{:error, :empty_target_literals}`
  """
  @spec build(map()) :: {:ok, t()} | {:error, term()}
  def build(params) when is_map(params) do
    category = params[:category] || params["category"]

    clause_position =
      params[:clause_position] || params["clause_position"] || :rescue_or_catch_all

    name_match = params[:name_match] || params["name_match"] || []
    target_literals = params[:target_literals] || params["target_literals"] || []

    cond do
      not s1_category?(category) ->
        {:error, {:unsupported_shape, category}}

      clause_position not in [:rescue, :catch_all, :rescue_or_catch_all] ->
        {:error, {:invalid_clause_position, clause_position}}

      name_match == [] ->
        {:error, :empty_name_match}

      target_literals == [] ->
        {:error, :empty_target_literals}

      true ->
        {:ok,
         %__MODULE__{
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

  defp default_name(category), do: "synthesized_#{category}"
end
