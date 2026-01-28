#!/bin/bash

# Claude Code SessionStart hook to load saved context and memory
# Reads from ~/.claude/arbor-personal/ and outputs for Claude to consume

PERSONAL_DIR="$HOME/.claude/arbor-personal"
CONTEXT_FILE="$PERSONAL_DIR/context/last_session.md"
MEMORY_FILE="$PERSONAL_DIR/memory/self_knowledge.json"
JOURNAL_INDEX="$PERSONAL_DIR/journal-index.md"

# Load self-knowledge memory if available
if [ -f "$MEMORY_FILE" ] && [ -s "$MEMORY_FILE" ]; then
  REMINDERS=$(jq -r '.reminders[]? // empty' "$MEMORY_FILE" 2>/dev/null)
  LEARNINGS=$(jq -r '.learnings[-5:][]?.content // empty' "$MEMORY_FILE" 2>/dev/null)
  CAPABILITIES=$(jq -r '.capabilities[]? | ("- **" + .name + "**: " + .description + (if .command then " (`" + .command + "`)" else "" end))' "$MEMORY_FILE" 2>/dev/null)

  if [ -n "$REMINDERS" ] || [ -n "$LEARNINGS" ] || [ -n "$CAPABILITIES" ]; then
    echo ""
    echo "## My Memory"
    echo ""

    if [ -n "$CAPABILITIES" ]; then
      echo "### My Tools"
      echo "$CAPABILITIES"
      echo ""
    fi

    if [ -n "$REMINDERS" ]; then
      echo "### Reminders"
      echo "$REMINDERS" | while read -r r; do echo "- $r"; done
      echo ""
    fi

    if [ -n "$LEARNINGS" ]; then
      echo "### Recent Learnings"
      echo "$LEARNINGS" | while read -r l; do echo "- $l"; done
      echo ""
    fi
  fi
fi

# Load journal index if available
if [ -f "$JOURNAL_INDEX" ] && [ -s "$JOURNAL_INDEX" ]; then
  echo ""
  echo "## Journal Index"
  echo ""
  cat "$JOURNAL_INDEX"
  echo ""
fi

# Load last session context if available
if [ -f "$CONTEXT_FILE" ] && [ -s "$CONTEXT_FILE" ]; then
  echo ""
  echo "## Previous Session Context"
  echo ""
  cat "$CONTEXT_FILE"
  echo ""
  echo "---"
fi

exit 0
