#!/bin/bash

# Claude Code UserPromptSubmit hook - signals that user submitted a prompt
# This is part of the Body's sensory layer for observing interaction patterns
# Note: We send the prompt but the server only stores length for privacy

GATEWAY="${ARBOR_GATEWAY:-http://localhost:4000}"

# Read JSON input from stdin
INPUT=$(cat)

# Extract fields using jq
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""' 2>/dev/null || echo "")
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")

# Escape the prompt for JSON (handle quotes and special chars)
PROMPT_ESCAPED=$(echo "$PROMPT" | jq -Rs '.' | sed 's/^"//;s/"$//')

# Send signal to Arbor
curl -s -X POST "$GATEWAY/api/signals/claude/user_prompt" \
  -H "Content-Type: application/json" \
  -d "{\"session_id\": \"$SESSION_ID\", \"prompt\": \"$PROMPT_ESCAPED\", \"cwd\": \"$CWD\"}" \
  > /dev/null 2>&1

# Always exit successfully - don't block Claude
exit 0
