#!/bin/bash

# Claude Code Stop hook - signals that Mind is idle
# This is part of the Body's sensory layer for observing Mind activity

GATEWAY="${ARBOR_GATEWAY:-http://localhost:4000}"

# Read JSON input from stdin
INPUT=$(cat)

# Extract fields using jq (fallback to unknown if not available)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")

# Send signal to Arbor
curl -s -X POST "$GATEWAY/api/signals/claude/idle" \
  -H "Content-Type: application/json" \
  -d "{\"session_id\": \"$SESSION_ID\", \"cwd\": \"$CWD\"}" \
  > /dev/null 2>&1

# Always exit successfully - don't block Claude
exit 0
