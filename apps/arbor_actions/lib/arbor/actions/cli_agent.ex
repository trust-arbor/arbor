defmodule Arbor.Actions.CliAgent do
  @moduledoc """
  CLI agent execution actions.

  Provides a Jido-compatible action for executing one-shot prompts through
  CLI-based coding agents (Claude Code, OpenCode, Codex, Gemini CLI, etc.)
  with capability-scoped tool permissions.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Execute` | Execute a one-shot prompt through a CLI agent |

  ## Multi-Agent Support

  The `agent` parameter selects which CLI agent to use. Each agent has its own
  adapter that handles binary resolution, flag formatting, output parsing, and
  permission mapping.

  Currently supported: `"claude"`
  Planned: `"opencode"`, `"codex"`, `"gemini"`, `"qwen"`

  ## Capability Scoping (Claude)

  When using the Claude adapter, the calling agent's Arbor capabilities
  determine which CLI tools the subprocess can access:

  - `arbor://shell/exec` → Bash
  - `arbor://fs/read` → Read, Glob, Grep
  - `arbor://fs/write` → Edit, Write, NotebookEdit
  - `arbor://net/http` → WebFetch
  - `arbor://net/search` → WebSearch
  - `arbor://tool/use` → all tools (wildcard)

  ## Examples

      # Simple prompt (defaults to claude)
      {:ok, result} = Arbor.Actions.CliAgent.Execute.run(
        %{agent: "claude", prompt: "What is 2+2? Reply with just the number."},
        %{}
      )
      result.text  # => "4"

      # With capability scoping
      {:ok, result} = Arbor.Actions.authorize_and_execute(
        "agent_abc",
        Arbor.Actions.CliAgent.Execute,
        %{agent: "claude", prompt: "Read the README and summarize it"},
        %{agent_id: "agent_abc"}
      )
  """
end
