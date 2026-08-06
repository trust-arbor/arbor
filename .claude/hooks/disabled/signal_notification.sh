#!/bin/bash

# Claude Code Notification hook - signals notifications (idle_prompt, permission_prompt, etc.)
# This is part of the Body's sensory layer for observing Mind state

GATEWAY="${ARBOR_GATEWAY:-http://localhost:4000}"

# Read JSON input from stdin
INPUT=$(cat)

# Extract fields using jq
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")
NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // "unknown"' 2>/dev/null || echo "unknown")
MESSAGE=$(echo "$INPUT" | jq -r '.message // ""' 2>/dev/null || echo "")
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")

# Send signal to Arbor
curl -s -X POST "$GATEWAY/api/signals/claude/notification" \
  -H "Content-Type: application/json" \
  -d "{\"session_id\": \"$SESSION_ID\", \"notification_type\": \"$NOTIFICATION_TYPE\", \"message\": \"$MESSAGE\", \"cwd\": \"$CWD\"}" \
  > /dev/null 2>&1

# Always exit successfully - don't block Claude
exit 0
