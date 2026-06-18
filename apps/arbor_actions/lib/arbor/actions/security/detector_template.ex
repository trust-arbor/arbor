defmodule Arbor.Actions.Security.DetectorTemplate do
  @moduledoc """
  Emits **compilable Elixir source** for a synthesized S1 (per-file AST) security
  detector, shaped exactly like `Arbor.Eval.Checks.AuthorizationSmells` but
  parameterized by a `Arbor.Actions.Security.DetectorSpec`.

  This is the "shape template" of the E1 design: a full `use Arbor.Eval` module
  with a hole for the synthesized predicate. The spec's `name_match` /
  `target_literals` / `exclusions` / `clause_position` become module attributes
  and the per-clause matcher inside the generated `run/1`.

  ## What the generated module does

  `run(%{ast: ast})` prewalks every `def`/`defp` whose name matches `name_match`
  (substring strings + exact-name atoms), then — depending on `clause_position` —
  inspects fail-open `rescue`/`catch` clauses and/or `case` catch-all (`_ ->`)
  clauses, and emits a violation when the literal the clause returns is in
  `target_literals` and not in `exclusions`.

  ## Literal matching (the `{:ok, _}` wildcard)

  Target/exclusion literals are matched **structurally** against the AST literal a
  clause returns. The atom `:_` acts as a wildcard for one element, so the spec
  literal `{:ok, :_}` matches any `{:ok, anything}` return (this is how the authz
  shape catches `{:ok, resource}` allows). Plain literals (`:ok`, `true`, `nil`,
  `false`, atoms, etc.) match exactly. `exclusions` are checked first, so
  `{:ok, :verified}` can be carved out of a `{:ok, :_}` target.

  The generated module reuses `Arbor.Actions.Security.Detectors.Common` only where
  relevant; S1 is per-file AST and is fully self-contained, so the template keeps
  the AST walk inline (matching `AuthorizationSmells`).
  """

  alias Arbor.Actions.Security.DetectorSpec

  @doc """
  Returns compilable Elixir source for the S1 detector described by `spec`.

  The module name is derived from `spec.name` (camelized) under
  `Arbor.Eval.Checks.Synthesized`. Pass `:module` to override the generated
  module name explicitly (the synthesis action uses a unique name for the
  in-memory G1 compile so repeated runs don't clash).
  """
  @spec s1_module_source(DetectorSpec.t(), keyword()) :: String.t()
  def s1_module_source(%DetectorSpec{} = spec, opts \\ []) do
    module = opts[:module] || default_module_name(spec)

    """
    defmodule #{module} do
      @moduledoc \"\"\"
      SYNTHESIZED S1 security detector (Security Sentinel E1.1).

      Enforces the invariant: #{escape_doc(spec.invariant)}

      Generated from a confirmed `#{inspect(spec.category)}` finding. Flags a
      function clause that returns a banned literal from a fail-open position.
      \"\"\"

      use Arbor.Eval,
        name: #{inspect(spec.name)},
        category: :security,
        description: #{inspect("Synthesized detector enforcing: " <> spec.invariant)}

      @name_substrings #{inspect(name_substrings(spec))}
      @name_exact #{inspect(name_exact(spec))}
      @target_literals #{literals_source(spec.target_literals)}
      @exclusions #{literals_source(spec.exclusions)}
      @category #{inspect(spec.category)}
      # Which clause positions to inspect — resolved to booleans at generation
      # time so guards compare literals, not an attr against a disjoint set.
      @check_rescue #{inspect(check_rescue?(spec))}
      @check_catch_all #{inspect(check_catch_all?(spec))}

      @doc "The Finding category this synthesized detector enforces."
      def category, do: @category

      @impl Arbor.Eval
      def run(%{ast: ast}) do
        violations =
          ast
          |> target_functions()
          |> Enum.flat_map(&check_function/1)

        %{
          passed: Enum.empty?(Enum.filter(violations, &(&1.severity == :error))),
          violations: violations,
          suggestions: []
        }
      end

      def run(_context) do
        %{
          passed: false,
          violations: [%{type: :no_ast, message: "No AST provided", severity: :error}],
          suggestions: []
        }
      end

      # --- locate target functions -------------------------------------------

      defp target_functions(ast) do
        {_, funs} =
          Macro.prewalk(ast, [], fn
            {def_kw, meta, [head, body_kw]} = node, acc
            when def_kw in [:def, :defp] and is_list(body_kw) ->
              case fun_name(head) do
                {:ok, name} ->
                  if name_match?(name),
                    do: {node, [{name, meta, body_kw} | acc]},
                    else: {node, acc}

                :error ->
                  {node, acc}
              end

            node, acc ->
              {node, acc}
          end)

        Enum.reverse(funs)
      end

      defp fun_name({:when, _, [{name, _, _} | _]}) when is_atom(name), do: {:ok, name}
      defp fun_name({name, _, _}) when is_atom(name), do: {:ok, name}
      defp fun_name(_), do: :error

      defp name_match?(name) when is_atom(name) do
        str = Atom.to_string(name)
        # Enum.member?/2 (not the `in` guard form) so an empty @name_exact/@name_
        # substrings list doesn't trip the "always false" type-checker warning.
        Enum.member?(@name_exact, name) or
          Enum.any?(@name_substrings, &String.contains?(str, &1))
      end

      # --- inspect target clauses --------------------------------------------

      defp check_function({name, _meta, body_kw}) do
        do_body = Keyword.get(body_kw, :do)

        function_level =
          if @check_rescue do
            (Keyword.get(body_kw, :rescue, []) ++ Keyword.get(body_kw, :catch, []))
            |> Enum.filter(&clause_returns_target?/1)
            |> Enum.map(&violation(name, &1, :rescue_returns_target))
          else
            []
          end

        function_level ++ scan_body(name, do_body)
      end

      defp scan_body(_name, nil), do: []

      defp scan_body(name, body) do
        {_, violations} =
          Macro.prewalk(body, [], fn
            {:try, _, [try_kw]} = node, acc
            when is_list(try_kw) and @check_rescue ->
              new =
                (Keyword.get(try_kw, :rescue, []) ++ Keyword.get(try_kw, :catch, []))
                |> Enum.filter(&clause_returns_target?/1)
                |> Enum.map(&violation(name, &1, :rescue_returns_target))

              {node, new ++ acc}

            {:case, _, [_subject, [do: clauses]]} = node, acc
            when is_list(clauses) and @check_catch_all ->
              new =
                clauses
                |> Enum.filter(&catchall_returns_target?/1)
                |> Enum.map(&violation(name, &1, :catchall_returns_target))

              {node, new ++ acc}

            node, acc ->
              {node, acc}
          end)

        Enum.reverse(violations)
      end

      defp clause_returns_target?({:->, _meta, [_pattern, clause_body]}),
        do: target_value?(final_expr(clause_body))

      defp clause_returns_target?(_), do: false

      defp catchall_returns_target?({:->, _meta, [[{:_, _, _}], clause_body]}),
        do: target_value?(final_expr(clause_body))

      defp catchall_returns_target?(_), do: false

      defp final_expr({:__block__, _, stmts}) when stmts != [], do: List.last(stmts)
      defp final_expr(expr), do: expr

      # A returned literal is a target iff it matches a target literal AND no
      # exclusion (exclusions win — that's how known FPs are carved out).
      defp target_value?(value) do
        not Enum.any?(@exclusions, &literal_match?(&1, value)) and
          Enum.any?(@target_literals, &literal_match?(&1, value))
      end

      # Structural match of a spec literal against an AST literal. The atom `:_`
      # is a one-element wildcard, so `{:ok, :_}` matches any `{:ok, _}`.
      defp literal_match?(:_, _value), do: true
      defp literal_match?(same, same), do: true

      defp literal_match?({pa, pb}, {va, vb}),
        do: literal_match?(pa, va) and literal_match?(pb, vb)

      defp literal_match?(pattern, value)
           when is_tuple(pattern) and is_tuple(value) and
                  tuple_size(pattern) == tuple_size(value) do
        pattern
        |> Tuple.to_list()
        |> Enum.zip(Tuple.to_list(value))
        |> Enum.all?(fn {p, v} -> literal_match?(p, v) end)
      end

      defp literal_match?(pattern, value) when is_list(pattern) and is_list(value) and
             length(pattern) == length(value) do
        pattern |> Enum.zip(value) |> Enum.all?(fn {p, v} -> literal_match?(p, v) end)
      end

      defp literal_match?(_pattern, _value), do: false

      # --- violation construction --------------------------------------------

      @invariant_text #{inspect(spec.invariant)}

      defp violation(fun_name, {:->, meta, _} = _clause, type) do
        %{
          type: type,
          message:
            "\#{type}: `\#{fun_name}` returns a banned literal from a fail-open clause — " <>
              "violates: \#{@invariant_text}",
          function: to_string(fun_name),
          line: meta[:line],
          column: meta[:column],
          severity: :warning,
          suggestion:
            "Fail closed in `\#{fun_name}`: return a deny value from the error/fallback path, " <>
              "not one of \#{inspect(@target_literals)}."
        }
      end
    end
    """
  end

  @doc "The default generated module name for a spec (camelized under Synthesized)."
  @spec default_module_name(DetectorSpec.t()) :: String.t()
  def default_module_name(%DetectorSpec{name: name}) do
    "Arbor.Eval.Checks.Synthesized." <> camelize(name)
  end

  # ---------------------------------------------------------------------------
  # Source emission helpers
  # ---------------------------------------------------------------------------

  # Split name_match into substring-strings and exact-name atoms (the two idioms
  # AuthorizationSmells uses).
  defp name_substrings(%DetectorSpec{name_match: matches}),
    do: Enum.filter(matches, &is_binary/1)

  defp name_exact(%DetectorSpec{name_match: matches}),
    do: Enum.filter(matches, &is_atom/1)

  defp check_rescue?(%DetectorSpec{clause_position: pos}),
    do: pos in [:rescue, :rescue_or_catch_all]

  defp check_catch_all?(%DetectorSpec{clause_position: pos}),
    do: pos in [:catch_all, :rescue_or_catch_all]

  # Render a list of literal terms as compilable source. `inspect/2` with
  # `:infinity` limits produces valid Elixir source for the literal terms we
  # support (atoms, booleans, nil, tuples, lists, strings, numbers).
  defp literals_source(literals) do
    inspect(literals, limit: :infinity, printable_limit: :infinity)
  end

  # Neutralize anything that could break OUT of — or inject INTO — the generated
  # module's @moduledoc heredoc. The invariant text can originate from an
  # LLM-supplied spec (finding-derived, possibly adversarial) and the generated
  # source is compiled in-memory via Code.compile_string, so an unescaped
  # interpolation here is arbitrary code execution at synthesis time. We strip
  # the heredoc terminator ("""), quotes, and the interpolation opener (#{...}).
  # (Every other spec value reaches the source via inspect/1, which already
  # escapes #{...}; the @moduledoc is the one raw-interpolation site.)
  defp escape_doc(nil), do: ""

  defp escape_doc(str) when is_binary(str) do
    str
    |> String.replace(~s("""), "'''")
    |> String.replace("\"", "'")
    |> String.replace("\#{", "#_{")
  end

  defp camelize(name) do
    name
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> Macro.camelize()
  end
end
