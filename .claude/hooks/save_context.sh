#!/bin/bash

# Claude Code PreCompact hook to save conversation context
# Receives hook metadata on stdin
# Saves key context to ~/.claude/arbor-personal/context/last_session.md

HOOK_DIR="$(dirname "$0")"
LOG_FILE="$HOME/.claude/arbor-personal/context/hook_log.txt"

mkdir -p "$(dirname "$LOG_FILE")"

echo "$(date -Iseconds) PreCompact hook started" >> "$LOG_FILE"

# Use the compiled Go binary for fast processing
"$HOOK_DIR/save_context" 2>> "$LOG_FILE"
RESULT=$?

echo "$(date -Iseconds) PreCompact hook finished with exit code $RESULT" >> "$LOG_FILE"

exit 0
