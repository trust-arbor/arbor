defmodule Arbor.Orchestrator.Engine.Condition do
  @moduledoc false

  require Logger

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  @allowed_simple_keys ~w(outcome preferred_label)

  @spec eval(String.t(), Outcome.t(), Context.t()) :: boolean()
  def eval(condition, _outcome, _context) when condition in [nil, ""], do: true

  def eval(condition, %Outcome{} = outcome, %Context{} = context) when is_binary(condition) do
    condition
    |> String.split("&&")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.all?(fn clause -> eval_clause(clause, outcome, context) end)
  end

  defp eval_clause(clause, outcome, context) do
    cond do
      String.contains?(clause, "!=") ->
        [left, right] = String.split(clause, "!=", parts: 2)
        resolve(String.trim(left), outcome, context) != parse_literal(String.trim(right))

      String.contains?(clause, ">=") ->
        [left, right] = String.split(clause, ">=", parts: 2)

        to_number(resolve(String.trim(left), outcome, context)) >=
          to_number(parse_literal(String.trim(right)))

      String.contains?(clause, "<=") ->
        [left, right] = String.split(clause, "<=", parts: 2)

        to_number(resolve(String.trim(left), outcome, context)) <=
          to_number(parse_literal(String.trim(right)))

      String.contains?(clause, ">") ->
        [left, right] = String.split(clause, ">", parts: 2)

        to_number(resolve(String.trim(left), outcome, context)) >
          to_number(parse_literal(String.trim(right)))

      String.contains?(clause, "<") ->
        [left, right] = String.split(clause, "<", parts: 2)

        to_number(resolve(String.trim(left), outcome, context)) <
          to_number(parse_literal(String.trim(right)))

      String.contains?(clause, "=") ->
        [left, right] = String.split(clause, "=", parts: 2)
        resolve(String.trim(left), outcome, context) == parse_literal(String.trim(right))

      true ->
        false
    end
  end

  defp resolve("outcome", %Outcome{status: status}, _context), do: to_string(status)
  defp resolve("preferred_label", %Outcome{preferred_label: label}, _context), do: label || ""

  defp resolve("context." <> path, _outcome, %Context{} = context) do
    Context.get(context, "context." <> path, Context.get(context, path, ""))
    |> to_string()
  end

  defp resolve(key, _outcome, _context) when is_binary(key) do
    cond do
      # Numeric literal — e.g. "0", "1.5", "-3" — resolves to itself.
      # Lets authors write `[condition="0=0"]` for always-true edges
      # without needing to stash a known-value context key first.
      numeric_literal?(key) ->
        key

      # Quoted literal — e.g. `"red"` — resolves to the unquoted value.
      # Lets authors compare against literal strings on the LHS too.
      quoted_literal?(key) ->
        unquote_literal(key)

      true ->
        # Defense-in-depth: validation (`mix arbor.pipeline.validate`)
        # rejects bareword LHS that isn't a recognized field, but
        # validation is opt-in. If we reach here at runtime, the author
        # likely typo'd a field name (`preffered_label`) or referenced
        # a field the runtime doesn't expose. Warn loudly so it's
        # visible in logs rather than silently evaluating to false.
        Logger.warning(
          "[Condition] unknown LHS \"#{key}\" silently resolved to empty string; " <>
            "use a known field (outcome / preferred_label / context.*), or a " <>
            "numeric / quoted literal. Run `mix arbor.pipeline.validate` to " <>
            "catch these at compile time."
        )

        ""
    end
  end

  defp resolve(_key, _outcome, _context), do: ""

  defp numeric_literal?(s) when is_binary(s) do
    Regex.match?(~r/^-?\d+(?:\.\d+)?$/, s)
  end

  defp quoted_literal?(s) when is_binary(s) do
    byte_size(s) >= 2 and String.starts_with?(s, "\"") and String.ends_with?(s, "\"")
  end

  defp unquote_literal(s) do
    s
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
  end

  defp parse_literal(value) do
    value
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
  end

  @doc """
  Evaluate a pre-parsed condition tuple against outcome and context.

  Used by the Router when edges have been compiled with `Edge.parse_condition/1`.
  Falls back to string-based `eval/3` on `:parse_error`.
  """
  @spec eval_parsed(term(), Outcome.t(), Context.t()) :: boolean()
  def eval_parsed(nil, _outcome, _context), do: true
  def eval_parsed({:always, true}, _outcome, _context), do: true

  def eval_parsed({:eq, field, value}, outcome, context) do
    resolve(field, outcome, context) == parse_literal(value)
  end

  def eval_parsed({:neq, field, value}, outcome, context) do
    resolve(field, outcome, context) != parse_literal(value)
  end

  def eval_parsed({:gt, field, value}, outcome, context) do
    to_number(resolve(field, outcome, context)) > to_number(parse_literal(value))
  end

  def eval_parsed({:gte, field, value}, outcome, context) do
    to_number(resolve(field, outcome, context)) >= to_number(parse_literal(value))
  end

  def eval_parsed({:lt, field, value}, outcome, context) do
    to_number(resolve(field, outcome, context)) < to_number(parse_literal(value))
  end

  def eval_parsed({:lte, field, value}, outcome, context) do
    to_number(resolve(field, outcome, context)) <= to_number(parse_literal(value))
  end

  def eval_parsed({:contains, field, value}, outcome, context) do
    String.contains?(to_string(resolve(field, outcome, context)), parse_literal(value))
  end

  def eval_parsed({:and, clauses}, outcome, context) do
    Enum.all?(clauses, &eval_parsed(&1, outcome, context))
  end

  def eval_parsed({:parse_error, raw}, outcome, context) do
    eval(raw, outcome, context)
  end

  defp to_number(val) when is_number(val), do: val

  defp to_number(val) when is_binary(val) do
    case Float.parse(val) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_number(_), do: 0

  @spec valid_syntax?(String.t()) :: boolean()
  def valid_syntax?(condition) when condition in [nil, ""], do: true

  def valid_syntax?(condition) when is_binary(condition) do
    condition
    |> String.split("&&")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.all?(&valid_clause?/1)
  end

  def valid_syntax?(_), do: false

  # Supported operators in order of precedence (multi-char before single-char).
  @operators ["!=", ">=", "<=", ">", "<", "="]

  defp valid_clause?(clause) do
    case find_operator(clause) do
      {op, left, right} ->
        valid_key?(String.trim(left)) and valid_rhs?(String.trim(right), op)

      nil ->
        false
    end
  end

  defp find_operator(clause) do
    Enum.find_value(@operators, fn op ->
      if String.contains?(clause, op) do
        [left, right] = String.split(clause, op, parts: 2)
        {op, left, right}
      end
    end)
  end

  # Right-hand side must be non-empty and not start with an operator character
  # (prevents "outcome>>success" from validating via ">" split)
  defp valid_rhs?(rhs, _op) do
    rhs != "" and not String.starts_with?(rhs, [">", "<", "=", "!"])
  end

  defp valid_key?(key) when key in @allowed_simple_keys, do: true

  defp valid_key?("context." <> rest),
    do: rest != "" and Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_.]*$/, rest)

  # Numeric / quoted literals on the LHS are valid — `0=0`, `"red"="red"`.
  # Bareword identifiers that aren't recognized fields are rejected (typos
  # like `preffered_label` fail validation rather than silently resolving
  # to "" at runtime).
  defp valid_key?(key) when is_binary(key) do
    numeric_literal?(key) or quoted_literal?(key)
  end

  defp valid_key?(_), do: false
end
