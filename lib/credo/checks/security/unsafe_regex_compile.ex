defmodule Credo.Check.Security.UnsafeRegexCompile do
  @moduledoc false

  use Credo.Check,
    id: "EX9005",
    base_priority: :normal,
    category: :warning,
    explanations: [
      check: """
      Compiling regex patterns from untrusted input can lead to Regular Expression
      Denial of Service (ReDoS) attacks. Malicious patterns can cause catastrophic
      backtracking, consuming CPU for minutes or hours on small inputs.

      ## Vulnerable Patterns

      Patterns with nested quantifiers are especially dangerous:
      - `(a+)+` - nested plus
      - `(a*)*` - nested star
      - `(a|aa)+` - overlapping alternatives

      ## Safe Patterns

          # Safe - literal regex at compile time
          ~r/hello \\w+/

          # Risky - regex from user input
          Regex.compile(user_pattern)

      ## Mitigation

      If you must compile dynamic patterns:
      1. Validate the pattern structure before compiling
      2. Set a timeout on regex operations
      3. Limit pattern complexity (length, nesting depth)
      4. Consider using a ReDoS-safe regex engine

      Use `# credo:disable-for-next-line` with justification if you've implemented
      appropriate safeguards.
      """
    ]

  @doc false
  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  # Regex.compile(pattern) or Regex.compile(pattern, opts)
  defp traverse(
         {{:., _, [{:__aliases__, _, [:Regex]}, :compile]}, meta, [pattern | _rest]} = ast,
         issues,
         issue_meta
       ) do
    if literal?(pattern) do
      {ast, issues}
    else
      issue = issue_for(issue_meta, meta[:line], "Regex.compile")
      {ast, [issue | issues]}
    end
  end

  # Regex.compile!(pattern) or Regex.compile!(pattern, opts)
  defp traverse(
         {{:., _, [{:__aliases__, _, [:Regex]}, :compile!]}, meta, [pattern | _rest]} = ast,
         issues,
         issue_meta
       ) do
    if literal?(pattern) do
      {ast, issues}
    else
      issue = issue_for(issue_meta, meta[:line], "Regex.compile!")
      {ast, [issue | issues]}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp literal?(ast) do
    case ast do
      value when is_binary(value) -> true
      {:sigil_r, _, _} -> true
      {:sigil_R, _, _} -> true
      _ -> false
    end
  end

  defp issue_for(issue_meta, line_no, function) do
    format_issue(
      issue_meta,
      message: "#{function} with dynamic pattern risks ReDoS attacks. Validate pattern complexity or use literal regex.",
      trigger: function,
      line_no: line_no
    )
  end
end
