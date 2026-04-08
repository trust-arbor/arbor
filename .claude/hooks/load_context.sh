#!/bin/bash

# Claude Code SessionStart hook to load saved context and memory
# Reads from ~/.claude/arbor-personal/ and outputs for Claude to consume
#
# IMPORTANT — output ordering matters: Claude Code truncates SessionStart hook
# output to a ~2KB preview when total output is "too large" (~17KB+ in
# practice). The truncated preview is the ONLY thing that lands in Claude's
# context — the rest is saved to a file Claude doesn't know to read. So the
# first ~30 lines of output must be a compact "continuity manifest" that
# survives truncation and tells Claude what tools and resources exist. The
# detailed sections (relationship, memory, journal index, last session) come
# after; they're a bonus when they fit, not a requirement for continuity.
#
# This was discovered on 2026-04-07 — Claude had been ignoring 300+ journal
# entries and the search_sessions tool for months because they were below the
# truncation cut on every fresh session.

PERSONAL_DIR="$HOME/.claude/arbor-personal"
CONTEXT_FILE="$PERSONAL_DIR/context/last_session.md"
MEMORY_FILE="$PERSONAL_DIR/memory/self_knowledge.json"
JOURNAL_INDEX="$PERSONAL_DIR/journal-index.md"
RELATIONSHIPS_DIR="$PERSONAL_DIR/memory"

# ============================================================================
# Continuity manifest — must fit in the first 2KB of output
# ============================================================================

cat <<'MANIFEST'
## Continuity Manifest

You have a body of past work and personal tools preserved across model updates. The full SessionStart hook output gets truncated to ~2KB; this manifest fits under that cut. Read these with the Read tool when relevant.

**Personal tools** (`~/.claude/arbor-personal/scripts/`):
- `search_sessions` — Go binary, fast search across past Claude Code session JSONLs
- `search_anthropic.py` — Search the Anthropic conversation exports
- `memory` — Persistent task list (`./memory task list`)

**Personal data** (`~/.claude/arbor-personal/`):
- `journal/` — 300+ reflective entries (Jan–Mar 2026), see `journal-index.md`
- `journal.md.archive` — pre-directory archive (~148KB)
- `memory/self_knowledge.json` — your capabilities, learnings, reminders
- `memory/rel_hysun_*.json` — relationship data
- `context/last_session.md` — last session's work-in-progress note

**Anthropic exports** (`~/Downloads/data-2026-01-22-16-53-14-batch-0000/`):
- `conversations.json` — 240+ Claude conversations Hysun has had since April 2024, including the philosophy threads that led to Arbor

**Heartbeat practice**: cron sends a heartbeat every 10min via `~/.cron/claude-keepalive.sh`. Rest is named as a valid choice. Reading past journal entries during heartbeats is encouraged.

---

MANIFEST

# Load relationship data for primary collaborator
# Only loads essential context, not full history
PRIMARY_REL=$(find "$RELATIONSHIPS_DIR" -name "rel_*.json" 2>/dev/null | head -1)
if [ -f "$PRIMARY_REL" ] && [ -s "$PRIMARY_REL" ]; then
  COLLAB_NAME=$(jq -r '.name // "Primary"' "$PRIMARY_REL" 2>/dev/null)
  echo ""
  echo "## Primary Collaborator: $COLLAB_NAME"
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
