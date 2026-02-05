defmodule Credo.Check.Security.UnsafeSystemCmd do
  @moduledoc false

  use Credo.Check,
    id: "EX9004",
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      System command execution with untrusted input can lead to command injection
      vulnerabilities, allowing attackers to execute arbitrary system commands.

      The following functions are flagged when called with non-literal arguments:
      - `System.cmd/2,3` - executes a system command
      - `:os.cmd/1` - Erlang's command execution

      ## Safe Patterns

      `System.cmd/3` with a literal command and list of arguments is generally safe
      because arguments are passed directly without shell interpretation:

          # Safe - arguments passed as list, no shell interpretation
          System.cmd("ls", ["-la", user_provided_path])

          # Unsafe - command built from user input
          System.cmd(user_command, [])

          # Very unsafe - shell interpretation
          :os.cmd(String.to_charlist("ls " <> user_input))

      ## Arbor Pattern

      Use `Arbor.Shell` for command execution - it provides sandboxing and
      capability-based access control.

      If you need direct system access, add a `# credo:disable-for-next-line` comment
      with justification.
      """
    ]

  @doc false
  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  # System.cmd(command, args) or System.cmd(command, args, opts)
  defp traverse(
         {{:., _, [{:__aliases__, _, [:System]}, :cmd]}, meta, [command | _rest]} = ast,
         issues,
         issue_meta
       ) do
    if literal?(command) do
      {ast, issues}
    else
      issue = issue_for(issue_meta, meta[:line], "System.cmd")
      {ast, [issue | issues]}
    end
  end

  # :os.cmd(command)
  defp traverse(
         {{:., _, [:os, :cmd]}, meta, [_command]} = ast,
         issues,
         issue_meta
       ) do
    # :os.cmd always uses shell interpretation, so it's always risky
    issue = issue_for(issue_meta, meta[:line], ":os.cmd")
    {ast, [issue | issues]}
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp literal?(ast) do
    case ast do
      value when is_binary(value) -> true
      value when is_atom(value) -> true
      _ -> false
    end
  end

  defp issue_for(issue_meta, line_no, function) do
    format_issue(
      issue_meta,
      message:
        "#{function} with dynamic input risks command injection. Use Arbor.Shell or ensure input is trusted.",
      trigger: function,
      line_no: line_no
    )
  end
end
