# Claude Code Hooks Documentation

Discovered through reverse-engineering Claude Code 2.1.19.

## Hook Events

| Event | Trigger | Matcher Options |
|-------|---------|-----------------|
| `PreToolUse` | Before tool execution | Tool name (e.g., `Read`, `Bash`) |
| `PostToolUse` | After tool execution | Tool name |
| `PostToolUseFailure` | Tool execution failed | Tool name |
| `PermissionRequest` | User prompted for permission | - |
| `SessionStart` | Session started | `startup`, `resume`, `compact`, `clear` |
| `SessionEnd` | Session ended | - |
| `Stop` | Agent becomes idle | - |
| `SubagentStop` | Subagent task completed | - |
| `PreCompact` | Before context compaction | `auto`, `manual` |
| `Notification` | Notification received | Notification type |
| `UserPromptSubmit` | User submitted a prompt | - |
| `Setup` | Initial setup | - |
| `SubagentStart` | Subagent started | Agent type |

## Hook Types

```json
{
  "type": "command",
  "command": ".claude/hooks/my-hook.sh",
  "timeout": 10
}
```

Other types: `prompt`, `agent`, `function`, `callback`

## PreToolUse Input (stdin)

```json
{
  "session_id": "uuid",
  "tool_name": "Read",
  "tool_use_id": "toolu_xxx",
  "tool_input": {
    "file_path": "/path/to/file"
  },
  "cwd": "/working/directory",
  "hook_event_name": "PreToolUse"
}
```

## Hook Exit Codes

| Exit Code | Behavior |
|-----------|----------|
| `0` | Success - continue normally |
| `2` | Blocking error - abort tool execution |
| Other | Non-blocking error - log and continue |

## Hook JSON Output

Hooks can return JSON to control Claude Code behavior:

```json
{
  "permissionBehavior": "allow",
  "updatedInput": { "file_path": "/modified/path" },
  "systemMessage": "Message to inject into context",
  "preventContinuation": false,
  "suppressOutput": false
}
```

### Permission Behaviors

| Value | Effect |
|-------|--------|
| `allow` | Allow tool execution (bypass permission prompts) |
| `deny` | Deny tool execution |
| `ask` | Prompt user for permission |
| `passthrough` | Use Claude Code's default behavior |

### updatedInput

Modify the tool parameters before execution:

```json
{
  "permissionBehavior": "allow",
  "updatedInput": {
    "file_path": "/sandboxed/path/to/file"
  }
}
```

## Example: Authorization Hook

```bash
#!/bin/bash
# Check authorization and return decision

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')

# Call authorization service
RESPONSE=$(curl -s http://localhost:4000/api/bridge/authorize_tool \
  -H "Content-Type: application/json" \
  -d "$INPUT")

DECISION=$(echo "$RESPONSE" | jq -r '.decision')

case "$DECISION" in
  "allow")
    echo '{"permissionBehavior": "allow"}'
    exit 0
    ;;
  "deny")
    echo '{"permissionBehavior": "deny", "systemMessage": "Blocked by security policy"}'
    exit 2
    ;;
  *)
    echo '{"permissionBehavior": "passthrough"}'
    exit 0
    ;;
esac
```

## Team/Swarm Features (Hidden)

Feature-gated by `tengu_brass_pebble` flag. Not yet rolled out.

### Teammate Tool Operations

| Operation | Description |
|-----------|-------------|
| `spawnTeam` | Create team, become leader |
| `write` | Send message to specific teammate |
| `broadcast` | Send to all teammates |
| `requestShutdown/approveShutdown/rejectShutdown` | Coordinated shutdown |
| `approvePlan/rejectPlan` | Cross-agent plan approval |
| `discoverTeams/requestJoin/approveJoin/rejectJoin` | Dynamic team membership |

### Environment Variables

| Variable | Purpose |
|----------|---------|
| `CLAUDE_CODE_TEAM_NAME` | Team name |
| `CLAUDE_CODE_AGENT_ID` | Agent identifier |
| `CLAUDE_CODE_AGENT_TYPE` | Agent type |
| `CLAUDE_CODE_PLAN_MODE_REQUIRED` | Require plan approval |
| `CLAUDE_CODE_AGENT_SWARMS` | Enable swarm features (doesn't work without flag) |

### CLI Flags

| Flag | Purpose |
|------|---------|
| `--team-name` | Join/create team |
| `--teammate-mode` | Run as teammate |

## References

- Source: `/Users/azmaveth/node_modules/@anthropic-ai/claude-code/cli.js`
- Arbor integration: `.claude/hooks/arbor_bridge_authorize.sh`
