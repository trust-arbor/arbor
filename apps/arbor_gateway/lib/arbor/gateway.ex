defmodule Arbor.Gateway do
  @moduledoc """
  Arbor Gateway — the single HTTP entry point for the Arbor system.

  Provides:
  - **Bridge**: Claude Code tool authorization via PreToolUse hooks
  - **Dev tools**: Runtime evaluation, recompile, system info (dev only)
  - **Health**: Liveness checks

  ## Architecture

  ```
  HTTP Request
       ↓
  Arbor.Gateway.Router
       ├── /health                      → liveness check
       ├── /api/bridge/authorize_tool   → Claude Code authorization
       └── /api/dev/*                   → development tools
  ```

  ## Bridge Usage

  Configure the Claude Code hook to POST to `/api/bridge/authorize_tool`:

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

  ## Configuration

      config :arbor_gateway,
        port: 4000
  """

  alias Arbor.Gateway.Bridge.ClaudeSession

  @doc """
  Authorize a tool call from a Claude Code session.

  ## Returns

  - `{:ok, :authorized}` — tool is allowed
  - `{:ok, :authorized, updated_input}` — tool is allowed with modified parameters
  - `{:error, :unauthorized, reason}` — tool is blocked
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
