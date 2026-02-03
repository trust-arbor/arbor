#!/bin/bash

# SDLC-specific SessionStart hook - signals that an SDLC session has started
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
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")

# Use SDLC-specific session ID if available
if [ -n "$ARBOR_SDLC_SESSION_ID" ]; then
  SESSION_ID="$ARBOR_SDLC_SESSION_ID"
fi

# Get item path from environment (set by SessionRunner)
ITEM_PATH="${ARBOR_SDLC_ITEM_PATH:-}"

# Send SDLC-specific signal to Arbor
curl -s -X POST "$GATEWAY/api/signals/sdlc/session_started" \
  -H "Content-Type: application/json" \
  -d "{
    \"session_id\": \"$SESSION_ID\",
    \"item_path\": \"$ITEM_PATH\",
    \"cwd\": \"$CWD\",
    \"session_type\": \"${ARBOR_SESSION_TYPE:-sdlc_auto}\"
  }" \
  > /dev/null 2>&1

# Always exit successfully - don't block Claude
exit 0
