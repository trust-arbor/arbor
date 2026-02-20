defmodule Arbor.Orchestrator.Engine.Condition do
  @moduledoc false

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

  defp resolve(_key, _outcome, _context), do: ""

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

  defp valid_clause?(clause) do
    cond do
      String.contains?(clause, "!=") ->
        [left, right] = String.split(clause, "!=", parts: 2)
        valid_key?(String.trim(left)) and String.trim(right) != ""

      String.contains?(clause, "=") ->
        [left, right] = String.split(clause, "=", parts: 2)
        valid_key?(String.trim(left)) and String.trim(right) != ""

      true ->
        false
    end
  end

  defp valid_key?(key) when key in @allowed_simple_keys, do: true

  defp valid_key?("context." <> rest),
    do: rest != "" and Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_.]*$/, rest)

  defp valid_key?(_), do: false
end
