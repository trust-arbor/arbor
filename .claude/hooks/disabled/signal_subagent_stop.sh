#!/bin/bash

# Claude Code SubagentStop hook - signals that a subagent (Hand) has stopped
# This is part of the Body's sensory layer for observing Hand lifecycle

GATEWAY="${ARBOR_GATEWAY:-http://localhost:4000}"

# Read JSON input from stdin
INPUT=$(cat)

# Extract fields using jq
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")

# Send signal to Arbor
curl -s -X POST "$GATEWAY/api/signals/claude/subagent_stop" \
  -H "Content-Type: application/json" \
  -d "{\"session_id\": \"$SESSION_ID\", \"stop_hook_active\": $STOP_HOOK_ACTIVE, \"cwd\": \"$CWD\"}" \
  > /dev/null 2>&1

# Always exit successfully - don't block Claude
exit 0
