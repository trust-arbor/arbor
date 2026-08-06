#!/bin/bash

# Claude Code PreCompact hook - signals that context is about to be compacted
# This is part of the Body's sensory layer for observing Mind lifecycle

GATEWAY="${ARBOR_GATEWAY:-http://localhost:4000}"

# Read JSON input from stdin
INPUT=$(cat)

# Extract fields using jq
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "unknown"' 2>/dev/null || echo "unknown")
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")

# Send signal to Arbor
curl -s -X POST "$GATEWAY/api/signals/claude/pre_compact" \
  -H "Content-Type: application/json" \
  -d "{\"session_id\": \"$SESSION_ID\", \"trigger\": \"$TRIGGER\", \"cwd\": \"$CWD\"}" \
  > /dev/null 2>&1

# Always exit successfully - don't block Claude
exit 0
