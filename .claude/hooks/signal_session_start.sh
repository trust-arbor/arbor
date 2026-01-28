#!/bin/bash

# Claude Code SessionStart hook - signals that a Mind session has begun
# This is part of the Body's sensory layer for observing Mind lifecycle

GATEWAY="${ARBOR_GATEWAY:-http://localhost:4000}"

# Read JSON input from stdin
INPUT=$(cat)

# Extract fields using jq
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")
MATCHER=$(echo "$INPUT" | jq -r '.source // "unknown"' 2>/dev/null || echo "unknown")

# Send signal to Arbor
curl -s -X POST "$GATEWAY/api/signals/claude/session_start" \
  -H "Content-Type: application/json" \
  -d "{\"session_id\": \"$SESSION_ID\", \"cwd\": \"$CWD\", \"matcher\": \"$MATCHER\"}" \
  > /dev/null 2>&1

# Always exit successfully - don't block Claude
exit 0
