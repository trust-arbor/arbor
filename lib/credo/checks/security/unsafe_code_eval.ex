defmodule Credo.Check.Security.UnsafeCodeEval do
  @moduledoc false

  use Credo.Check,
    id: "EX9003",
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Dynamic code evaluation functions can execute arbitrary code, making them
      extremely dangerous when used with untrusted input.

      The following functions are flagged:
      - `Code.eval_string/1,2,3` - evaluates arbitrary Elixir code
      - `Code.eval_file/1,2` - evaluates code from a file
      - `Code.eval_quoted/1,2,3` - evaluates quoted expressions
      - `Code.compile_string/1,2` - compiles code into modules
      - `Code.compile_file/1,2` - compiles a file

      ## Legitimate Uses

      These functions have legitimate uses in:
      - Development tools (IEx, Mix tasks)
      - Build-time code generation
      - Testing frameworks

      If you have a legitimate use case, add a `# credo:disable-for-next-line` comment
      with an explanation of why it's safe.

      ## Example

          # Bad - remote code execution vulnerability
          Code.eval_string(user_provided_code)

          # If truly necessary, document why:
          # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
          # Safe: code is from trusted config file loaded at compile time
          Code.eval_string(trusted_compile_time_code)
      """
    ]

  @doc false
  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  @dangerous_functions [
    :eval_string,
    :eval_file,
    :eval_quoted,
    :compile_string,
    :compile_file
  ]

  # Code.eval_string(...) etc.
  defp traverse(
         {{:., _, [{:__aliases__, _, [:Code]}, func]}, meta, _args} = ast,
         issues,
         issue_meta
       )
       when func in @dangerous_functions do
    issue = issue_for(issue_meta, meta[:line], "Code.#{func}")
    {ast, [issue | issues]}
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp issue_for(issue_meta, line_no, function) do
    format_issue(
      issue_meta,
      message: "#{function} can execute arbitrary code. Ensure input is trusted or disable with explanation.",
      trigger: function,
      line_no: line_no
    )
  end
end
