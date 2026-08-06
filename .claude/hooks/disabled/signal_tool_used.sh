#!/bin/bash

# Claude Code PostToolUse hook - signals that Mind used a tool
# This is part of the Body's sensory layer for tracking Mind activity
# Used for: activity tracking, job claim renewal, observability

GATEWAY="${ARBOR_GATEWAY:-http://localhost:4000}"

# Read JSON input from stdin
INPUT=$(cat)

# Extract fields using jq
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")
TOOL_USE_ID=$(echo "$INPUT" | jq -r '.tool_use_id // ""' 2>/dev/null || echo "")
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")

# Send signal to Arbor
curl -s -X POST "$GATEWAY/api/signals/claude/tool_used" \
  -H "Content-Type: application/json" \
  -d "{\"session_id\": \"$SESSION_ID\", \"tool_name\": \"$TOOL_NAME\", \"tool_use_id\": \"$TOOL_USE_ID\", \"cwd\": \"$CWD\"}" \
  > /dev/null 2>&1

# Always exit successfully - don't block Claude
exit 0
