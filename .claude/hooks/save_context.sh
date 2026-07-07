#!/bin/bash

# Claude Code PreCompact hook to save conversation context
# Receives hook metadata on stdin
# Saves key context to ~/.claude/arbor-personal/context/last_session.md

HOOK_DIR="$(dirname "$0")"
LOG_FILE="$HOME/.claude/arbor-personal/context/hook_log.txt"

mkdir -p "$(dirname "$LOG_FILE")"

echo "$(date -Iseconds) PreCompact hook started" >> "$LOG_FILE"

# Drift guard: the behavior lives in the COMPILED binary, not save_context.go.
# If the source is newer than the binary (someone edited .go without rebuilding),
# the running behavior is stale and lies about what it does. Rebuild if possible,
# warn loudly if not. (Same discipline as the library-hierarchy drift guard.)
if [ "$HOOK_DIR/save_context.go" -nt "$HOOK_DIR/save_context" ]; then
  echo "$(date -Iseconds) WARN: save_context.go is newer than the binary — rebuilding" >> "$LOG_FILE"
  if command -v go >/dev/null 2>&1; then
    ( cd "$HOOK_DIR" && go build -o save_context save_context.go ) 2>> "$LOG_FILE" \
      && echo "$(date -Iseconds) rebuilt save_context" >> "$LOG_FILE" \
      || echo "$(date -Iseconds) ERROR: rebuild failed — running STALE binary" >> "$LOG_FILE"
  else
    echo "$(date -Iseconds) ERROR: go not found — running STALE binary (run: cd $HOOK_DIR && go build -o save_context save_context.go)" >> "$LOG_FILE"
  fi
fi

# Use the compiled Go binary for fast processing
"$HOOK_DIR/save_context" 2>> "$LOG_FILE"
RESULT=$?

echo "$(date -Iseconds) PreCompact hook finished with exit code $RESULT" >> "$LOG_FILE"

exit 0
