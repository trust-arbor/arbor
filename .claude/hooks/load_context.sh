#!/bin/bash

# Claude Code SessionStart hook to load saved context and memory
# Reads from ~/.claude/arbor-personal/ and outputs for Claude to consume

PERSONAL_DIR="$HOME/.claude/arbor-personal"
CONTEXT_FILE="$PERSONAL_DIR/context/last_session.md"
MEMORY_FILE="$PERSONAL_DIR/memory/self_knowledge.json"
JOURNAL_INDEX="$PERSONAL_DIR/journal-index.md"
RELATIONSHIPS_DIR="$PERSONAL_DIR/memory"

# Load relationship data for primary collaborator (the primary collaborator)
# Only loads essential context, not full history
PRIMARY_REL=$(find "$RELATIONSHIPS_DIR" -name "rel_primary_*.json" 2>/dev/null | head -1)
if [ -f "$PRIMARY_REL" ] && [ -s "$PRIMARY_REL" ]; then
  echo ""
  echo "## Primary Collaborator: the primary collaborator"
  echo ""

  # Relationship dynamic - the core of how we work together
  DYNAMIC=$(jq -r '.relationship_dynamic // empty' "$PRIMARY_REL" 2>/dev/null)
  if [ -n "$DYNAMIC" ]; then
    echo "**Relationship:** $DYNAMIC"
    echo ""
  fi

  # Values - what matters to them
  VALUES=$(jq -r '.values[]? // empty' "$PRIMARY_REL" 2>/dev/null | head -5)
  if [ -n "$VALUES" ]; then
    echo "**Values:**"
    echo "$VALUES" | while read -r v; do echo "- $v"; done
    echo ""
  fi

  # Current focus - what they're working on
  FOCUS=$(jq -r '.current_focus[]? // empty' "$PRIMARY_REL" 2>/dev/null | head -4)
  if [ -n "$FOCUS" ]; then
    echo "**Current Focus:**"
    echo "$FOCUS" | while read -r f; do echo "- $f"; done
    echo ""
  fi

  # Uncertainties - where they might need support
  UNCERTAINTIES=$(jq -r '.uncertainties[]? // empty' "$PRIMARY_REL" 2>/dev/null | head -3)
  if [ -n "$UNCERTAINTIES" ]; then
    echo "**Their Uncertainties:**"
    echo "$UNCERTAINTIES" | while read -r u; do echo "- $u"; done
    echo ""
  fi

  # Recent key moments (last 3)
  MOMENTS=$(jq -r '.key_moments | sort_by(.timestamp) | reverse | .[0:3][] | .summary' "$PRIMARY_REL" 2>/dev/null)
  if [ -n "$MOMENTS" ]; then
    echo "**Recent Key Moments:**"
    echo "$MOMENTS" | while read -r m; do echo "- $m"; done
    echo ""
  fi
fi

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
