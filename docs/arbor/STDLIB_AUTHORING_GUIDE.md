# Stdlib DOT Pipelines — Using and Authoring Guide

Stdlib DOTs are reusable graph compositions built from the 15 core handlers,
invokable via `compose` nodes or semantic aliases. They live in
`apps/arbor_orchestrator/specs/pipelines/stdlib/`. This guide covers how to
use them and — more importantly — how to author them correctly, because the
most common authoring mistake produces a graph that parses, lints clean, and
does nothing.

See also: `docs/arbor/DOT_PIPELINE_GUIDE.md` (full syntax + handler
reference) and `AGENT_TEMPLATE_REFERENCE.md` (a different kind of DOT-adjacent
artifact).

## The #1 rule: a node runs on ATTRS, not on prose

Every handler reads a **fixed set of attributes**. Text that isn't one of
those attributes is ignored. A `transform` node does not "read its `prompt`
and figure out what to do" — there is no LLM behind it. Write programs for
the actual opcodes, not instructions for an imagined smart interpreter.

**WRONG** — this executes as an identity copy; nothing after it works:

```dot
init [
  type="transform",
  prompt="Initialize retry.count=0, parse model_list CSV into retry.models,
          set retry.current_model to the first model."
]
```

`TransformHandler` reads `transform` (default `identity`), `source_key`,
`output_key`, `expression`. It never reads `prompt`. `retry.count`,
`retry.models`, `retry.current_model` are never written — every downstream
gate that reads them sees nothing.

**RIGHT** — do state setup with an attribute the handler actually honors
(an `expression`/`template` transform, or an `exec` action that returns the
keys), and set values the engine can route on:

```dot
init [
  type="transform",
  transform="template",
  source_key="model_list",
  output_key="retry.models",
  expression="{value}"     // real transform; writes a real key
]
```

If the logic is more than a value shuffle, it belongs in a Jido **action**
(`type="exec", target="action", action="..."`) that returns a map of
context keys — not in transform prose.

## Handler attr cheat-sheet (what each opcode actually reads)

| Handler | Honors | Ignores (common mistakes) |
|---|---|---|
| `transform` | `transform`, `source_key`, `output_key`, `expression` | `prompt` |
| `compute` | `prompt`, `system_prompt_context_key`, `prompt_context_key`, `messages_context_key`, `use_tools`, `llm_model`/`model`, `simulate` | model named in prose (use `llm_model=` or `session.llm_model`) |
| `exec` | `target`, `action`/`tool`, `context_keys`, `param.*`, `output_prefix` | free-text descriptions |
| `gate` (diamond) | `condition_key`, `predicate`, `expression` | — |
| edges | `condition="context.key=value"` | `$var` interpolation (attrs don't interpolate) |

(Confirm against the handler source before authoring — this table is a
snapshot; `DOT_PIPELINE_GUIDE.md` is the reference.)

Two traps worth stating explicitly:

- **No variable interpolation in attrs.** `timeout="$timeout_ms"` reaches
  the handler as the literal string `$timeout_ms` and is discarded. Thread
  runtime values via context keys the handler reads, or via the invoking
  compose node's session config.
- **Model selection is not contextual by prose.** `LlmHandler` picks the
  model from the node's `llm_model=` attr or `session.llm_model` — writing
  "use retry.current_model" in a prompt does nothing. Model-from-context
  requires either handler support (a `model_key=` attr) or restructuring
  into explicit per-model attempt nodes.

## Every context key read must be written upstream

If a gate expression, edge condition, or `source_key` names
`context.retry.score_ok`, some upstream node on every path to that reader
must write `retry.score_ok`. An unwritten key reads as nil/false and
silently mis-routes (often into an infinite loop when it's a
loop-termination flag). Trace every key from reader back to a writer before
committing. Tier-0 lint (below) automates this check.

## Declare the contract (required for stdlib)

Stdlib DOTs carry their I/O contract as **machine-readable graph attrs**, not
just comment headers:

```dot
digraph RetryEscalate {
  graph [
    goal="Retry an LLM call with progressive model escalation",
    input_keys="prompt,model_list,max_retries",
    output_keys="result,model_used,retry.count,retry.exhausted"
  ]
  ...
}
```

Keep the human-readable `// Context in: / Context out:` comment block too —
but the attrs are what the test harness and (eventually) the signing
registry read. A stdlib DOT without declared `input_keys`/`output_keys` is
not admissible.

## Using a stdlib DOT

Two ways:

1. **Compose node** — explicit invocation from a parent graph:

   ```dot
   retry [
     type="compose", mode="invoke",
     graph_file="specs/pipelines/stdlib/retry-escalate.dot"
   ]
   ```

   Declared `input_keys` must be present in the parent context at the
   compose node; declared `output_keys` are available downstream.

2. **Semantic alias** — `stdlib/aliases.ex` maps alias types (e.g.
   `retry.escalate`) to the compose invocation. Using the alias type in a
   node invokes the stdlib graph. (Caveat: an alias is only as good as the
   graph it points at — see the audit; don't trust an alias whose target
   hasn't passed its contract test.)

## Testing your stdlib DOT (three tiers)

Ordered from cheapest/mandatory to richest/nightly:

**Tier 0 — validity (automatic, must pass).** The shipped-DOT sweep parses,
IR-compiles, and lints every .dot, including the unknown-attr and dataflow
rules. You get this for free; just don't break it. If your node uses an
attr the handler doesn't honor, or reads a key nothing writes, this fails.

**Tier 1 — contract (write one per stdlib DOT).** Add your `input_keys` /
`output_keys` and the generic harness does the rest: runs your graph in
simulate mode with stub inputs, asserts declared outputs exist, the run
terminates within a node budget, and the happy path is visited. Adding a
stdlib DOT = adding a contract, not authoring a bespoke test.

**Tier 2 — behavioral (for LLM-bearing patterns).** Record LLM-plug
cassettes and assert the pattern's actual promise: escalation switches
models between attempts; a feedback loop's second prompt differs from the
first; validate-retry only retries on invalid output. Tag `:llm`, run
nightly.

## Authoring checklist

- [ ] Every node uses only attrs its handler honors (cheat-sheet above).
- [ ] No `prompt=` on a `transform` node.
- [ ] No `$var` interpolation in attrs.
- [ ] Every read context key is written by an upstream node on every path.
- [ ] Loop-termination flags are actually set by a node in the loop body.
- [ ] `input_keys` / `output_keys` graph attrs declared.
- [ ] Comment header (Context in/out) matches the declared attrs.
- [ ] Model selection uses `llm_model=`/`session.llm_model`, not prose.
- [ ] Tier-1 contract test added; Tier-2 if LLM-bearing.
- [ ] Runs clean in simulate mode before any live-LLM run.
