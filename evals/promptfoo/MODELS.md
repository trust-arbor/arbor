# Local model footprint — picking a small model that fits

These evals exist to find the **smallest local model** that does the preprocessor
jobs (needs_tools, complexity) well enough — so Arbor runs on hardware without a
big GPU. Accuracy is only half the decision; the other half is **what the model
costs to run**. This is how to measure that.

## Quick commands (LM Studio)

| Want | Command |
|---|---|
| Which models are **loaded in memory** (+ footprint) | `lms ps` |
| All **downloaded** models (+ disk size, `✓ LOADED`) | `lms ls` |
| Loaded vs not, programmatically | `curl -s localhost:1234/api/v0/models` → each has `state: loaded\|not-loaded` |
| JSON for scripts | `lms ps --json`, `lms ls --json` (`sizeBytes`, `quantization`, `paramsString`, `maxContextLength`) |
| **This repo's helper** (disk + loaded + footprint + quant, one table) | `./footprint.sh` (or `./footprint.sh gemma granite` to filter) |

`/v1/models` (the OpenAI-compatible endpoint) lists *available* models but does
**not** tell you which are loaded — use `lms ps` or `/api/v0/models` for that.

## The footprint has two parts — and context usually dominates

**In-memory footprint = model weights (set by quant) + KV cache (set by context
length).** The KV cache is **pre-allocated at load time** from the model's
context length, so a model loaded at a huge context reserves a lot of memory it
may never use.

Example (measured 2026-06-25): `gemma-4-e4b-it` is only ~7.5B params but loads at
**10.62 GB** because it's resident at the full **131072-token** context. The
preprocessor classifiers see a *single short prompt* (see below), so most of that
cache is wasted.

**→ For these classifiers, loading at a small context is often a bigger VRAM win
than the quant choice.** Load with an explicit small context:

```bash
lms load gemma-4-e4b-it --context-length 2048    # then re-check: lms ps
lms unload gemma-4-e4b-it
```

## How much context do the classifiers actually need?

The preprocessor sends the model **only the current user message** (one turn, no
conversation history — see `apps/arbor_orchestrator/lib/arbor/orchestrator/preprocessor.ex`).
On the 145-prompt corpus the message sizes are:

| | tokens (~chars/4) |
|---|---|
| median | ~49 |
| p95 | ~360 |
| max | ~1287 |

So **a 2048-token context covers the entire single-turn corpus** (longest message
+ ~150-token system prompt + tiny JSON answer) with headroom. There's no accuracy
reason to load bigger — above the prompt length, extra context is just reserved,
unused cache. (If we later feed the classifier conversation history — an open
question, see the preprocessor doc — bump the budget, e.g. 4096.)

Sweeping context purely for **footprint** comparison means reloading per size
(`lms load --context-length N`); accuracy doesn't change above the floor, so the
dataset max (above) is the cheaper way to pick the size.

## Reading it as accuracy-per-GB

Run the eval (`../needs-tools`, `../complexity`) for the accuracy/FN numbers, then
`./footprint.sh` for disk + loaded memory, and pick the smallest model that clears
the accuracy bar AND fits the target hardware. A future helper could merge the
two (eval `results.json` + `lms --json`) into a single accuracy-per-GB table.
