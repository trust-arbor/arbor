#!/usr/bin/env bash
# Overnight LLM Evaluation Suite
# Runs eval jobs across multiple models, domains, and providers.
# Results stored in Postgres — check with: mix arbor.eval --stats --domain <domain>
#
# Usage: nohup bash scripts/overnight_eval.sh > .arbor/eval_runs/overnight.log 2>&1 &

set -e
cd "$(dirname "$0")/.."

echo "╔══════════════════════════════════════════════════"
echo "║ Arbor Overnight Eval Suite"
echo "║ Started: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "╚══════════════════════════════════════════════════"
echo ""

RUNS=10
CODING_RUNS=5
CHAT_RUNS=5

# ─────────────────────────────────────────────────────
# PHASE 1: Heartbeat (JSON compliance) — most critical
# The heartbeat LLM runs every 30s and MUST return valid JSON.
# ─────────────────────────────────────────────────────
echo "═══ PHASE 1: Heartbeat JSON Compliance ═══"
echo ""

# Small/fast local models
echo "--- Local small models ---"
mix arbor.eval --domain heartbeat --model "llama3.2:1b" --provider ollama --runs $RUNS --timeout 30000
mix arbor.eval --domain heartbeat --model "liquid/lfm2.5-1.2b" --provider lm_studio --runs $RUNS --timeout 30000
mix arbor.eval --domain heartbeat --model "qwen3-4b-instruct-2507" --provider lm_studio --runs $RUNS --timeout 30000

# Medium local models
echo "--- Local medium models ---"
mix arbor.eval --domain heartbeat --model "mistralai/devstral-small-2-2512" --provider lm_studio --runs $RUNS --timeout 60000
mix arbor.eval --domain heartbeat --model "openai/gpt-oss-20b" --provider lm_studio --runs $RUNS --timeout 60000

# Cloud models via Ollama (free tier)
echo "--- Cloud models (Ollama-routed) ---"
mix arbor.eval --domain heartbeat --model "glm-5:cloud" --provider ollama --runs $RUNS --timeout 90000
mix arbor.eval --domain heartbeat --model "kimi-k2.5:cloud" --provider ollama --runs $RUNS --timeout 90000
mix arbor.eval --domain heartbeat --model "deepseek-v3.2:cloud" --provider ollama --runs $RUNS --timeout 90000

# Free OpenRouter models
echo "--- Free OpenRouter models ---"
mix arbor.eval --domain heartbeat --model "google/gemma-3-4b-it:free" --provider openrouter --runs $RUNS --timeout 60000
mix arbor.eval --domain heartbeat --model "microsoft/phi-4-mini:free" --provider openrouter --runs $RUNS --timeout 60000
mix arbor.eval --domain heartbeat --model "qwen/qwen3-8b:free" --provider openrouter --runs $RUNS --timeout 60000
mix arbor.eval --domain heartbeat --model "meta-llama/llama-3.1-8b-instruct:free" --provider openrouter --runs $RUNS --timeout 60000

echo ""
echo "Heartbeat phase complete: $(date -u '+%H:%M:%S UTC')"
echo ""

# ─────────────────────────────────────────────────────
# PHASE 2: Coding (Elixir generation)
# Compile + functional test grading. Slower per sample.
# ─────────────────────────────────────────────────────
echo "═══ PHASE 2: Coding (Elixir) ═══"
echo ""

# Local small — can they code at all?
echo "--- Local small models ---"
mix arbor.eval --domain coding --model "qwen3-4b-instruct-2507" --provider lm_studio --runs $CODING_RUNS --timeout 90000
mix arbor.eval --domain coding --model "mistralai/devstral-small-2-2512" --provider lm_studio --runs $CODING_RUNS --timeout 90000

# Cloud models — the contenders
echo "--- Cloud models ---"
mix arbor.eval --domain coding --model "kimi-k2.5:cloud" --provider ollama --runs $CODING_RUNS --timeout 120000
mix arbor.eval --domain coding --model "qwen3-coder:480b-cloud" --provider ollama --runs $CODING_RUNS --timeout 120000
mix arbor.eval --domain coding --model "deepseek-v3.2:cloud" --provider ollama --runs $CODING_RUNS --timeout 120000

# Free OpenRouter
echo "--- Free OpenRouter models ---"
mix arbor.eval --domain coding --model "qwen/qwen3-8b:free" --provider openrouter --runs $CODING_RUNS --timeout 90000

echo ""
echo "Coding phase complete: $(date -u '+%H:%M:%S UTC')"
echo ""

# ─────────────────────────────────────────────────────
# PHASE 3: Chat Quality
# Conversational quality for the main chat interface.
# ─────────────────────────────────────────────────────
echo "═══ PHASE 3: Chat Quality ═══"
echo ""

# Cloud models
mix arbor.eval --domain chat --model "kimi-k2.5:cloud" --provider ollama --runs $CHAT_RUNS --timeout 120000
mix arbor.eval --domain chat --model "deepseek-v3.2:cloud" --provider ollama --runs $CHAT_RUNS --timeout 120000
mix arbor.eval --domain chat --model "glm-5:cloud" --provider ollama --runs $CHAT_RUNS --timeout 120000

# Free OpenRouter
mix arbor.eval --domain chat --model "qwen/qwen3-8b:free" --provider openrouter --runs $CHAT_RUNS --timeout 90000
mix arbor.eval --domain chat --model "meta-llama/llama-3.1-8b-instruct:free" --provider openrouter --runs $CHAT_RUNS --timeout 90000

echo ""
echo "Chat phase complete: $(date -u '+%H:%M:%S UTC')"
echo ""

# ─────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════"
echo "║ Overnight Eval Complete!"
echo "║ Finished: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "║"
echo "║ View results:"
echo "║   mix arbor.eval --stats --domain heartbeat"
echo "║   mix arbor.eval --stats --domain coding"
echo "║   mix arbor.eval --stats --domain chat"
echo "║   mix arbor.eval --list"
echo "╚══════════════════════════════════════════════════"
