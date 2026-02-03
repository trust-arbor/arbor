#!/bin/bash

# SDLC-specific PostToolUse hook - signals tool activity for heartbeat tracking
# This hook includes the ARBOR_SDLC_ITEM_PATH for correlation with work items
#
# Environment variables set by SessionRunner:
# - ARBOR_SDLC_ITEM_PATH: Path to the work item file
# - ARBOR_SDLC_SESSION_ID: The session ID
# - ARBOR_SESSION_TYPE: "sdlc_auto"

GATEWAY="${ARBOR_GATEWAY:-http://localhost:4000}"

# Read JSON input from stdin
INPUT=$(cat)

# Extract fields using jq
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")
TOOL_USE_ID=$(echo "$INPUT" | jq -r '.tool_use_id // ""' 2>/dev/null || echo "")
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")

# Use SDLC-specific session ID if available
if [ -n "$ARBOR_SDLC_SESSION_ID" ]; then
  SESSION_ID="$ARBOR_SDLC_SESSION_ID"
fi

# Get item path from environment (set by SessionRunner)
ITEM_PATH="${ARBOR_SDLC_ITEM_PATH:-}"

# Send signal to Arbor with SDLC context
curl -s -X POST "$GATEWAY/api/signals/claude/tool_used" \
  -H "Content-Type: application/json" \
  -d "{
    \"session_id\": \"$SESSION_ID\",
    \"tool_name\": \"$TOOL_NAME\",
    \"tool_use_id\": \"$TOOL_USE_ID\",
    \"cwd\": \"$CWD\",
    \"item_path\": \"$ITEM_PATH\",
    \"session_type\": \"${ARBOR_SESSION_TYPE:-sdlc_auto}\"
  }" \
  > /dev/null 2>&1

# Always exit successfully - don't block Claude
exit 0
