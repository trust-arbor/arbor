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

  @doc """
  Returns compilable Elixir source for the S3 (tree-wide pattern) detector
  described by `spec`.

  The generated module exposes `detect(opts) :: [Finding.t()]` — exactly the
  shape of the hand-authored whole-tree detectors
  (`Arbor.Actions.Security.Detectors.UriRegistration` et al.). It:

    1. globs `Common.elixir_source_files(opts[:root] || "apps")`,
    2. parses each file with `Common.parse(file, columns: true)`,
    3. prewalks each file's AST for the spec's `match_pattern` (scoped to
       `name_match` functions when present, else anywhere), and
    4. builds one `Finding` per match (category / location {file,line,function} /
       invariant_violated / evidence / detector provenance) via `Finding.new/1`.

  The module name defaults to `Arbor.Actions.Security.Detectors.Synthesized.<Name>`.
  Pass `:module` to override (the synthesis action uses a unique name for the
  in-memory G1 compile so repeated runs don't clash).

  ## Injection-safety

  Identical discipline to `s1_module_source/2`: every spec value reaches the
  generated source through `inspect/1` (the `match_pattern` map, `name_match`,
  `exclusions`, `name`, `category`) — which escapes `\#{...}`, quotes, and
  newlines — EXCEPT the `@moduledoc` / `@invariant_text` invariant text, which is
  the one human-readable interpolation site and is run through the hardened
  `escape_doc/1` (neutralizing `\#{}`, `\"\"\"`, and quotes). There is NO raw
  interpolation site. The source is `Code.compile_string`'d at synthesis time, so
  this is mandatory — do not introduce a `\#{spec.field}`-style hole.
  """
  @spec s3_module_source(DetectorSpec.t(), keyword()) :: String.t()
  def s3_module_source(%DetectorSpec{shape: :s3} = spec, opts \\ []) do
    module = opts[:module] || default_s3_module_name(spec)

    """
    defmodule #{module} do
      @moduledoc \"\"\"
      SYNTHESIZED S3 (tree-wide pattern) security detector (Security Sentinel E1.2).

      Enforces the invariant: #{escape_doc(spec.invariant)}

      Generated from a confirmed `#{inspect(spec.category)}` finding. Globs the
      tree and flags every site matching a forbidden/over-broad pattern.
      \"\"\"

      alias Arbor.Actions.Security.Detectors.Common
      alias Arbor.Contracts.Security.Finding

      @category #{inspect(spec.category)}
      @detector_name #{inspect(spec.name)}
      @invariant_text #{inspect(spec.invariant)}
      @match_pattern #{inspect(spec.match_pattern, limit: :infinity, printable_limit: :infinity)}
      @exclusions #{literals_source(spec.exclusions)}
      @name_substrings #{inspect(name_substrings(spec))}
      @name_exact #{inspect(name_exact(spec))}

      @doc "The Finding category this synthesized detector enforces."
      def category, do: @category

      @doc \"\"\"
      Run the detector over `.ex` files under `opts[:root]` (default `"apps"`),
      returning one `Finding` per matched site.
      \"\"\"
      @spec detect(keyword()) :: [Finding.t()]
      def detect(opts \\\\ []) do
        root = Keyword.get(opts, :root, "apps")
        git_sha = Keyword.get(opts, :git_sha)

        root
        |> Common.elixir_source_files()
        |> Enum.flat_map(&analyze_file(&1, git_sha))
      end

      # --- per-file analysis -------------------------------------------------

      defp analyze_file(file, git_sha) do
        case Common.parse(file, columns: true) do
          {:ok, ast} ->
            ast
            |> matches()
            |> Enum.map(fn {fun, line} -> finding(file, fun, line, git_sha) end)

          _ ->
            []
        end
      end

      # Collect [{function_name | nil, line}] for every site in `ast` matching the
      # pattern. When @name_substrings/@name_exact are non-empty, only sites inside
      # a matching def/defp are reported (the function-scoping option); otherwise
      # any matching site anywhere in the file is reported.
      defp matches(ast) do
        if scoped?() do
          ast
          |> target_functions()
          |> Enum.flat_map(fn {name, body} ->
            body |> pattern_hits() |> Enum.map(fn line -> {to_string(name), norm_line(line)} end)
          end)
        else
          ast |> pattern_hits() |> Enum.map(fn line -> {nil, norm_line(line)} end)
        end
      end

      # A leaf-literal match carries no line (the :__matched__ sentinel) → nil.
      defp norm_line(:__matched__), do: nil
      defp norm_line(line), do: line

      defp scoped?, do: @name_substrings != [] or @name_exact != []

      # --- locate target functions (scoped mode) -----------------------------

      defp target_functions(ast) do
        {_, funs} =
          Macro.prewalk(ast, [], fn
            {def_kw, _meta, [head, body_kw]} = node, acc
            when def_kw in [:def, :defp] and is_list(body_kw) ->
              case fun_name(head) do
                {:ok, name} ->
                  if name_match?(name),
                    do: {node, [{name, Keyword.get(body_kw, :do)} | acc]},
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

        Enum.member?(@name_exact, name) or
          Enum.any?(@name_substrings, &String.contains?(str, &1))
      end

      # --- pattern matching --------------------------------------------------

      # Every line in `ast` where the @match_pattern matches. nil bodies (e.g. a
      # function head without a do-block) contribute nothing.
      defp pattern_hits(nil), do: []

      defp pattern_hits(ast) do
        {_, lines} =
          Macro.prewalk(ast, [], fn node, acc ->
            case match_line(node) do
              nil -> {node, acc}
              line -> {node, [line | acc]}
            end
          end)

        lines |> Enum.reverse() |> Enum.uniq()
      end

      # Returns the line of a matching node, or nil. The %{kind: ...} dispatch is
      # resolved against the inlined @match_pattern literal.
      defp match_line(node) do
        case @match_pattern do
          %{kind: :literal, literal: lit} -> literal_match_line(node, lit)
          %{kind: :call, call: call} -> call_match_line(node, call)
          _ -> nil
        end
      end

      # -- :literal kind --
      # A bare literal node (string/atom/number) or a structural literal (tuple/
      # list AST) that matches the pattern and is not excluded. Returns the line
      # from the nearest enclosing node's meta when available.
      # A leaf literal (string/atom/number) carries no line metadata, so a match
      # reports `:__matched__` (a non-nil sentinel meaning "matched, no line"),
      # distinct from `nil` (no match). pattern_hits/1 maps the sentinel to a
      # nil line in the finding location (matching the line-less whole-tree
      # detectors like UriRegistration).
      defp literal_match_line({_, meta, _} = node, lit) when is_list(meta) do
        if literal_node_matches?(node, lit), do: meta[:line], else: nil
      end

      defp literal_match_line(node, lit) do
        if literal_node_matches?(node, lit), do: :__matched__, else: nil
      end

      defp literal_node_matches?(node, lit) do
        value = literal_value(node)

        value != :__no_literal__ and
          not Enum.any?(@exclusions, &literal_match?(&1, value)) and
          literal_match?(lit, value)
      end

      # Reduce an AST node to the literal term it denotes, or :__no_literal__.
      # Strings/atoms/numbers are literals as-is; a 2-tuple AST `{:{}, _, elems}`
      # or a plain 2-tuple, and a list, are reconstructed structurally so a
      # pattern like `{:ok, :_}` or `["arbor://", :_]` can match.
      defp literal_value(s) when is_binary(s), do: s
      defp literal_value(a) when is_atom(a), do: a
      defp literal_value(n) when is_number(n), do: n

      defp literal_value({:{}, _, elems}) when is_list(elems) do
        vals = Enum.map(elems, &literal_value/1)
        if Enum.any?(vals, &(&1 == :__no_literal__)), do: :__no_literal__, else: List.to_tuple(vals)
      end

      defp literal_value({a, b}) do
        va = literal_value(a)
        vb = literal_value(b)
        if va == :__no_literal__ or vb == :__no_literal__, do: :__no_literal__, else: {va, vb}
      end

      defp literal_value(list) when is_list(list) do
        vals = Enum.map(list, &literal_value/1)
        if Enum.any?(vals, &(&1 == :__no_literal__)), do: :__no_literal__, else: vals
      end

      defp literal_value(_), do: :__no_literal__

      # -- :call kind --
      # A local call `fun(...)` (atom pattern) or a remote call `Mod.fun(...)`
      # ("Mod.fun" string pattern).
      defp call_match_line({{:., _, [mod_ast, fun]}, meta, _args}, call)
           when is_atom(fun) and is_list(meta) do
        if is_binary(call) and remote_name(mod_ast, fun) == call, do: meta[:line], else: nil
      end

      defp call_match_line({fun, meta, args}, call)
           when is_atom(fun) and is_list(args) and is_list(meta) do
        if is_atom(call) and fun == call, do: meta[:line], else: nil
      end

      defp call_match_line(_node, _call), do: nil

      defp remote_name({:__aliases__, _, parts}, fun) when is_list(parts) do
        (Enum.map_join(parts, ".", &to_string/1)) <> "." <> Atom.to_string(fun)
      end

      defp remote_name(mod, fun) when is_atom(mod) do
        Atom.to_string(mod) <> "." <> Atom.to_string(fun)
      end

      defp remote_name(_mod, _fun), do: nil

      # --- structural literal match (the {:ok, _} / :_ wildcard, shared w/ S1) -

      defp literal_match?(:_, _value), do: true
      defp literal_match?(same, same), do: true

      defp literal_match?(pattern, value) when is_binary(pattern) and is_binary(value),
        do: String.contains?(value, pattern)

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

      defp literal_match?(pattern, value)
           when is_list(pattern) and is_list(value) and length(pattern) == length(value) do
        pattern |> Enum.zip(value) |> Enum.all?(fn {p, v} -> literal_match?(p, v) end)
      end

      defp literal_match?(_pattern, _value), do: false

      # --- finding construction ----------------------------------------------

      defp finding(file, fun, line, git_sha) do
        Finding.new(
          category: @category,
          title: "Tree-wide pattern violates: \#{@invariant_text}",
          git_sha: git_sha,
          detector: %{layer: "L0b", name: @detector_name, version: "1", synthesized: true},
          severity: %{level: :medium},
          confidence: %{score: 0.6, rationale: "synthesized tree-wide pattern match"},
          location: location_map(file, fun, line),
          invariant_violated: @invariant_text,
          evidence: %{smell_match: @match_pattern},
          recommendation: %{
            approach:
              "Review this site against the invariant — the synthesized detector " <>
                "flagged it as matching a forbidden/over-broad pattern."
          },
          actionability: %{auto_fixable: false, risk_class: :medium},
          verification: %{must_fail_on_revert: true}
        )
      end

      defp location_map(file, nil, line),
        do: %{library: Common.library_of(file), file: file, line: line}

      defp location_map(file, fun, line),
        do: %{library: Common.library_of(file), file: file, line: line, function: fun}
    end
    """
  end

  @doc "The default generated module name for a spec (camelized under Synthesized)."
  @spec default_module_name(DetectorSpec.t()) :: String.t()
  def default_module_name(%DetectorSpec{name: name}) do
    "Arbor.Eval.Checks.Synthesized." <> camelize(name)
  end

  @doc "The default generated module name for an S3 detector spec."
  @spec default_s3_module_name(DetectorSpec.t()) :: String.t()
  def default_s3_module_name(%DetectorSpec{name: name}) do
    "Arbor.Actions.Security.Detectors.Synthesized." <> camelize(name)
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
