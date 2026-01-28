#!/bin/bash

# Claude Code SessionEnd hook - signals that a Mind session has ended
# This is part of the Body's sensory layer for observing Mind lifecycle

GATEWAY="${ARBOR_GATEWAY:-http://localhost:4000}"

# Read JSON input from stdin
INPUT=$(cat)

# Extract fields using jq
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")
REASON=$(echo "$INPUT" | jq -r '.reason // "unknown"' 2>/dev/null || echo "unknown")

# Send signal to Arbor
curl -s -X POST "$GATEWAY/api/signals/claude/session_end" \
  -H "Content-Type: application/json" \
  -d "{\"session_id\": \"$SESSION_ID\", \"cwd\": \"$CWD\", \"reason\": \"$REASON\"}" \
  > /dev/null 2>&1

# Always exit successfully - don't block Claude
exit 0
