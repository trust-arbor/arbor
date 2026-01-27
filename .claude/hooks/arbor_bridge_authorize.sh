#!/bin/bash

# Claude Code Arbor Bridge - Authorization Hook
# Intercepts tool calls and routes them through Arbor's capability-based security
#
# Exit codes:
#   0 = success (allow tool execution)
#   2 = blocking error (deny tool execution)
#
# JSON output (optional):
#   permissionBehavior: "allow" | "deny" | "ask" | "passthrough"
#   updatedInput: modified tool parameters
#   systemMessage: message to inject into context

GATEWAY="${ARBOR_GATEWAY:-http://localhost:4000}"
BRIDGE_ENDPOINT="/api/bridge/authorize_tool"
TIMEOUT="${ARBOR_BRIDGE_TIMEOUT:-5}"

# Read JSON input from stdin
INPUT=$(cat)

# Extract fields
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null)
TOOL_USE_ID=$(echo "$INPUT" | jq -r '.tool_use_id // ""' 2>/dev/null)
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)

# Build authorization request
AUTH_REQUEST=$(jq -n \
  --arg session_id "$SESSION_ID" \
  --arg tool_name "$TOOL_NAME" \
  --arg tool_use_id "$TOOL_USE_ID" \
  --argjson tool_input "$TOOL_INPUT" \
  --arg cwd "$CWD" \
  '{
    session_id: $session_id,
    tool_name: $tool_name,
    tool_use_id: $tool_use_id,
    tool_input: $tool_input,
    cwd: $cwd
  }')

# Call Arbor bridge for authorization decision
RESPONSE=$(curl -s --max-time "$TIMEOUT" -X POST "$GATEWAY$BRIDGE_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "$AUTH_REQUEST" 2>/dev/null)

# Check if curl succeeded
if [ $? -ne 0 ] || [ -z "$RESPONSE" ]; then
  # Arbor is unavailable - passthrough (don't block development)
  # Log this for debugging
  echo "Arbor bridge unavailable, passthrough" >&2
  echo '{"permissionBehavior": "passthrough"}'
  exit 0
fi

# Parse response
DECISION=$(echo "$RESPONSE" | jq -r '.decision // "passthrough"' 2>/dev/null)
REASON=$(echo "$RESPONSE" | jq -r '.reason // ""' 2>/dev/null)
UPDATED_INPUT=$(echo "$RESPONSE" | jq -c '.updated_input // null' 2>/dev/null)
SYSTEM_MESSAGE=$(echo "$RESPONSE" | jq -r '.system_message // ""' 2>/dev/null)

# Handle decision
case "$DECISION" in
  "allow")
    # Build output JSON
    OUTPUT='{"permissionBehavior": "allow"}'
    if [ "$UPDATED_INPUT" != "null" ]; then
      OUTPUT=$(echo "$OUTPUT" | jq --argjson input "$UPDATED_INPUT" '. + {updatedInput: $input}')
    fi
    if [ -n "$SYSTEM_MESSAGE" ]; then
      OUTPUT=$(echo "$OUTPUT" | jq --arg msg "$SYSTEM_MESSAGE" '. + {systemMessage: $msg}')
    fi
    echo "$OUTPUT"
    exit 0
    ;;

  "deny")
    # Return deny decision
    OUTPUT=$(jq -n --arg reason "$REASON" '{
      permissionBehavior: "deny",
      systemMessage: ("Tool blocked by Arbor security: " + $reason)
    }')
    echo "$OUTPUT"
    exit 2
    ;;

  "ask")
    # Let Claude Code ask the user
    OUTPUT='{"permissionBehavior": "ask"}'
    if [ -n "$SYSTEM_MESSAGE" ]; then
      OUTPUT=$(echo "$OUTPUT" | jq --arg msg "$SYSTEM_MESSAGE" '. + {systemMessage: $msg}')
    fi
    echo "$OUTPUT"
    exit 0
    ;;

  *)
    # Default passthrough
    echo '{"permissionBehavior": "passthrough"}'
    exit 0
    ;;
esac
