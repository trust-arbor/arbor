defmodule Arbor.Bridge do
  @moduledoc """
  Claude Code <-> Arbor Bridge.

  This library provides integration between Claude Code's hook system and
  Arbor's capability-based security. It intercepts tool calls from Claude Code
  and routes them through Arbor's authorization system.

  ## Architecture

  ```
  Claude Code → PreToolUse Hook → HTTP Request → Arbor.Bridge.Router
                                                       ↓
                                               Arbor.Bridge.ClaudeSession
                                                       ↓
                                               Arbor.Security (authorization)
                                                       ↓
                                               Decision (allow/deny/ask)
  ```

  ## Usage

  1. Configure the hook in `.claude/settings.json`:

      ```json
      {
        "hooks": {
          "PreToolUse": [{
            "hooks": [{
              "type": "command",
              "command": ".claude/hooks/arbor_bridge_authorize.sh",
              "timeout": 10
            }]
          }]
        }
      }
      ```

  2. Start the bridge HTTP server:

      ```bash
      mix run --no-halt
      ```

  3. Claude Code tool calls will now be authorized through Arbor.

  ## Configuration

  Configure in `config/config.exs`:

      config :arbor_bridge,
        port: 4000

  ## Session Management

  Claude Code sessions are automatically registered as Arbor agents when they
  first make a tool call. See `Arbor.Bridge.ClaudeSession` for details.
  """

  alias Arbor.Bridge.ClaudeSession

  @doc """
  Authorize a tool call from a Claude Code session.

  ## Parameters

  - `session_id` - Claude Code session UUID
  - `tool_name` - Tool name (Read, Write, Bash, etc.)
  - `tool_input` - Tool parameters
  - `cwd` - Current working directory

  ## Returns

  - `{:ok, :authorized}` - Tool is allowed
  - `{:ok, :authorized, updated_input}` - Tool is allowed with modified parameters
  - `{:error, :unauthorized, reason}` - Tool is blocked
  """
  defdelegate authorize(session_id, tool_name, tool_input, cwd),
    to: ClaudeSession,
    as: :authorize_tool

  @doc """
  Ensure a Claude session is registered as an Arbor agent.

  Sessions are automatically registered on first tool call, but this can be
  called explicitly to pre-register a session.
  """
  defdelegate register_session(session_id, cwd), to: ClaudeSession, as: :ensure_registered

  @doc """
  Get the Arbor agent ID for a Claude session.
  """
  defdelegate agent_id(session_id), to: ClaudeSession, as: :to_agent_id
end
