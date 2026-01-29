defmodule Credo.Check.Security.UnsafeAtomConversion do
  @moduledoc false

  use Credo.Check,
    id: "EX9001",
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      The BEAM atom table is limited (~1M atoms) and never garbage collected.
      Using `String.to_atom/1` with untrusted input enables resource exhaustion
      DoS attacks.

      Use `Arbor.Common.SafeAtom` instead:
      - `SafeAtom.to_existing/1` - only converts if atom already exists
      - `SafeAtom.to_allowed/2` - only converts if in explicit allowlist
      - `SafeAtom.to_existing!/1` - raising version for internal APIs

      ## Example

          # Bad - vulnerable to DoS
          action = String.to_atom(user_input)

          # Good - safe conversion
          {:ok, action} = SafeAtom.to_existing(user_input)
          {:ok, action} = SafeAtom.to_allowed(user_input, [:read, :write])
      """
    ]

  @doc false
  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  # String.to_atom(arg) where arg is not a literal
  defp traverse(
         {{:., _, [{:__aliases__, _, [:String]}, :to_atom]}, meta, [arg]} = ast,
         issues,
         issue_meta
       ) do
    if literal?(arg) do
      {ast, issues}
    else
      issue = issue_for(issue_meta, meta[:line], "String.to_atom/1")
      {ast, [issue | issues]}
    end
  end

  # :erlang.list_to_atom(arg) - less common but same risk
  defp traverse(
         {{:., _, [:erlang, :list_to_atom]}, meta, [arg]} = ast,
         issues,
         issue_meta
       ) do
    if literal?(arg) do
      {ast, issues}
    else
      issue = issue_for(issue_meta, meta[:line], ":erlang.list_to_atom/1")
      {ast, [issue | issues]}
    end
  end

  # :erlang.binary_to_atom(arg, encoding) - also risky
  defp traverse(
         {{:., _, [:erlang, :binary_to_atom]}, meta, [arg, _encoding]} = ast,
         issues,
         issue_meta
       ) do
    if literal?(arg) do
      {ast, issues}
    else
      issue = issue_for(issue_meta, meta[:line], ":erlang.binary_to_atom/2")
      {ast, [issue | issues]}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp literal?(ast) do
    case ast do
      value when is_binary(value) -> true
      value when is_atom(value) -> true
      value when is_number(value) -> true
      {:<<>>, _, parts} -> Enum.all?(parts, &literal?/1)
      _ -> false
    end
  end

  defp issue_for(issue_meta, line_no, function) do
    format_issue(
      issue_meta,
      message:
        "#{function} with non-literal argument is vulnerable to atom exhaustion DoS. Use Arbor.Common.SafeAtom instead.",
      trigger: function,
      line_no: line_no
    )
  end
end
