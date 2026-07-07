defmodule Arbor.Eval.Checks.AuthorizationSmells do
  @moduledoc """
  Detects **fail-open** patterns in authorization / verification code.

  An authorization gate must *fail closed*: on an exception, an unknown case, or
  any unexpected input it must DENY, never allow. The dominant bug class in the
  2026-06-09 runtime security review (H1, M1, M2, L1, C10) was exactly the
  opposite — a gate that returned an allow value (`:ok`, `true`, `:authorized`,
  `{:ok, ...}`) from an error or catch-all path, so a failure silently granted
  access.

  This check is the first L0 detector of the Security Sentinel. It is
  deliberately conservative to keep false positives low:

  1. It only inspects functions whose name marks them as security-sensitive
     (see `@auth_name_substrings` and `@auth_name_exact`).
  2. Within those, it only flags a clause that returns a **literal** allow value
     from a fail-open position:
     - a `rescue` / `catch` clause (function-level or inside a `try`), or
     - a catch-all `_ ->` clause in a `case`.

  A clause that returns a deny value (`{:error, _}`, `false`, `nil`) or calls a
  function (which we can't statically prove allows) is NOT flagged. This is why
  C10's `registration_authorized` — which rescues to `{:error, ...}` — passes.

  Findings are `:warning` severity (advisory) in this first phase. The Sentinel
  promotes them to structured `Arbor.Contracts.Security.Finding`s via the
  `RunStaticDetectors` action.

  ## Known limitations (future tuning, the L3 synthesis loop)

  - Name heuristic only; doesn't yet use module name (`*.Security.*`) as a signal.
  - Doesn't follow a `rescue` that delegates to a helper which itself fails open.
  - `cond` with a `true ->` allow branch is intentionally not flagged (it's the
    normal path, not a fallback).
  - **Restriction predicates are excluded** (see `restriction_predicate?/1`):
    a `*_gates?` / `restricted?` / `requires_*` function returns `true` to mean
    "more restrictive", so `true` there is fail-CLOSED, not fail-open. Catching
    the inverted bug (a restriction predicate that fails to `false`) is deferred.
    This exclusion was added 2026-06-09 after the first real-code scan flagged
    a restriction predicate whose `rescue _ -> true` was an H1 fail-closed fix.
  - Side-effect functions (persist/emit/sync) are deliberately NOT matched —
    their `:ok` return is "done", not an authorization grant.
  """

  use Arbor.Eval,
    name: "authorization_smells",
    category: :security,
    description: "Detects fail-open patterns in authorization/verification code"

  # Substrings that mark a function name as an authorization *gate*. Kept tight
  # to avoid matching capability storage/sync/signal side-effects (which contain
  # "capability" but make no authz decision). `check_*` auth helpers are listed
  # by their specific noun rather than a bare `check_`.
  @auth_name_substrings ~w(
    authoriz authentic verif permit acceptable
    delegation_chain check_approval check_capabilit
  )

  # Exact function names that are "may I?" permission gates (true = allow).
  @auth_name_exact ~w(can? allowed? allow? grant?)a

  @impl Arbor.Eval
  def run(%{ast: ast}) do
    violations =
      ast
      |> auth_functions()
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

  # ===========================================================================
  # Locate security-sensitive functions
  # ===========================================================================

  # Returns `[{name, def_meta, body_kw}]` for every def/defp whose name marks it
  # as an authorization gate. `body_kw` is the keyword body (`[do:, rescue:, ...]`).
  defp auth_functions(ast) do
    {_, funs} =
      Macro.prewalk(ast, [], fn
        {def_kw, meta, [head, body_kw]} = node, acc
        when def_kw in [:def, :defp] and is_list(body_kw) ->
          case fun_name(head) do
            {:ok, name} ->
              if auth_name?(name), do: {node, [{name, meta, body_kw} | acc]}, else: {node, acc}

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

  # Side-effect verbs: a function that emits/persists/logs/etc. is not a gate,
  # even if its name carries an auth noun (e.g. `emit_tool_authorization_denied`,
  # `persist_capability`). Its `:ok` return means "done", not "allowed".
  @side_effect_prefixes ~w(
    emit_ persist_ log_ record_ store_ save_ delete_ sync_ do_sync_
    broadcast_ publish_ notify_ write_ track_ audit_
  )

  defp auth_name?(name) when is_atom(name) do
    str = Atom.to_string(name)

    not side_effect_name?(str) and not restriction_predicate?(str) and
      (name in @auth_name_exact or Enum.any?(@auth_name_substrings, &String.contains?(str, &1)))
  end

  defp side_effect_name?(str), do: String.starts_with?(str, @side_effect_prefixes)

  # A restriction predicate answers "is this MORE restricted?" — `true` means
  # deny/gate, so a `rescue _ -> true` is fail-closed, not fail-open. Excluded
  # to avoid misreading the polarity.
  defp restriction_predicate?(str) do
    String.ends_with?(str, ["gates?", "gated?", "restricted?", "blocked?", "denied?"]) or
      String.starts_with?(str, "requires_")
  end

  # ===========================================================================
  # Inspect a security-sensitive function for fail-open clauses
  # ===========================================================================

  defp check_function({name, _meta, body_kw}) do
    do_body = Keyword.get(body_kw, :do)

    function_level =
      (Keyword.get(body_kw, :rescue, []) ++ Keyword.get(body_kw, :catch, []))
      |> Enum.filter(&clause_returns_allow?/1)
      |> Enum.map(&violation(name, &1, :rescue_returns_allow))

    function_level ++ scan_body(name, do_body)
  end

  # Walk a function body for `try` rescue/catch clauses and `case` catch-alls
  # that return a literal allow value.
  defp scan_body(_name, nil), do: []

  defp scan_body(name, body) do
    {_, violations} =
      Macro.prewalk(body, [], fn
        {:try, _, [try_kw]} = node, acc when is_list(try_kw) ->
          new =
            (Keyword.get(try_kw, :rescue, []) ++ Keyword.get(try_kw, :catch, []))
            |> Enum.filter(&clause_returns_allow?/1)
            |> Enum.map(&violation(name, &1, :rescue_returns_allow))

          {node, new ++ acc}

        {:case, _, [_subject, [do: clauses]]} = node, acc when is_list(clauses) ->
          new =
            clauses
            |> Enum.filter(&catchall_returns_allow?/1)
            |> Enum.map(&violation(name, &1, :catchall_returns_allow))

          {node, new ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(violations)
  end

  # A rescue/catch clause: `{:->, meta, [pattern_list, clause_body]}`. We don't
  # care about the pattern — any rescue/catch that yields an allow value is
  # fail-open.
  defp clause_returns_allow?({:->, _meta, [_pattern, clause_body]}),
    do: allow_value?(final_expr(clause_body))

  defp clause_returns_allow?(_), do: false

  # A catch-all clause is `_ ->` (single underscore pattern) returning an allow.
  defp catchall_returns_allow?({:->, _meta, [[{:_, _, _}], clause_body]}),
    do: allow_value?(final_expr(clause_body))

  defp catchall_returns_allow?(_), do: false

  # The value a body evaluates to is the last statement of a block, or the
  # expression itself.
  defp final_expr({:__block__, _, stmts}) when stmts != [], do: List.last(stmts)
  defp final_expr(expr), do: expr

  # Literal allow values. Only literals are flagged — a function call in the
  # error path can't be statically proven to allow, so it's left alone.
  #
  # `{:ok, :verified}` / `{:ok, :unverified}` are an OPERATIONAL status vocabulary
  # (e.g. "did this self-healing action take effect?"), NOT an authorization
  # grant — a security gate signals allow with `:authorized` or a resource, never
  # `:verified`. Excluding them drops the `verify_action`/`verify_condition`
  # false positives the first scan surfaced (2026-06-09) while keeping the
  # generic `{:ok, resource}` allow (e.g. `authorize_file_op` returning a path).
  defp allow_value?(:ok), do: true
  defp allow_value?(true), do: true
  defp allow_value?(:authorized), do: true
  defp allow_value?({:ok, :verified}), do: false
  defp allow_value?({:ok, :unverified}), do: false
  defp allow_value?({:ok, _}), do: true
  defp allow_value?(_), do: false

  # ===========================================================================
  # Violation construction
  # ===========================================================================

  defp violation(fun_name, {:->, meta, _} = _clause, type) do
    %{
      type: type,
      message: message_for(type, fun_name),
      function: to_string(fun_name),
      line: meta[:line],
      column: meta[:column],
      severity: :warning,
      suggestion:
        "Fail closed: return a deny value (`{:error, reason}` / `false`) from the " <>
          "error/fallback path in `#{fun_name}`, not an allow value."
    }
  end

  defp message_for(:rescue_returns_allow, fun_name) do
    "Fail-open: `#{fun_name}` returns an allow value from a rescue/catch clause — " <>
      "an exception during authorization would grant access."
  end

  defp message_for(:catchall_returns_allow, fun_name) do
    "Fail-open: `#{fun_name}` returns an allow value from a catch-all `_ ->` clause — " <>
      "an unknown/unexpected case would grant access."
  end
end
