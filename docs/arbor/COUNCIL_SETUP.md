# Council Setup

Operator guide for the binding code-review council used by factory
`coding_change` runs, and the separate advisory council. Created 2026-08-19.

A factory plan with `review_profile: "binding"` (the default) does not merge
on worker say-so. After implement → validate → commit-gate, Arbor runs the
reviewed `code-review-council.dot` graph: ten parallel reviewer seats, then
a deterministic ledger reduce. The council recommends; blast-radius policy
still decides whether a person must look.

This is **not** configured by `ARBOR_COUNCIL_MODEL` /
`ARBOR_COUNCIL_PERSPECTIVE_MODELS`. Those env vars belong to the *advisory*
council (`council_consult`). Mixing the two is the usual first-run miss.

Related: [SOFTWARE_FACTORY.md](./SOFTWARE_FACTORY.md),
[CODING_TASK_DISPATCH.md](./CODING_TASK_DISPATCH.md).

## Two councils

| | Binding code-review council | Advisory council |
| --- | --- | --- |
| Used by | Factory `review_profile: "binding"` via `council_review_change` | `council_consult` / `council_consult_one`, design questions |
| Source of seats | `apps/arbor_actions/priv/pipelines/code-review-council.dot` | `Arbor.Consensus.Evaluators.AdvisoryLLM` |
| Seat count | 10 compute nodes | 13 perspectives |
| How models are chosen | `llm_provider` + `llm_model` on each DOT node | `provider:model` map, overridable |
| How a new user remaps | Edit that reviewed DOT (or add a `model_stylesheet`) and restart | Env / Application config; no DOT edit |
| Vote contract | One `coding_submit_review_report` tool call per seat; prose is an abstention | Free-form evaluations collected by Consult |
| Override env | None | `ARBOR_COUNCIL_MODEL`, `ARBOR_COUNCIL_PERSPECTIVE_MODELS` |

If you only care about factory reviews, ignore the advisory column until
you want `mix arbor.consult`.

## Binding council: stock seats

The packaged graph (`max_parallel="10"`) as of 2026-08-19:

| Node id | Perspective | `llm_provider` | `llm_model` |
| --- | --- | --- | --- |
| `correctness` | Logic, control flow, concurrency | `openai_oauth` | `gpt-5.6-sol` |
| `security` | Gates, FileGuard, fail-closed auth, egress | `openai_oauth` | `gpt-5.6-sol` |
| `regression_test_coverage` | Focused tests, security regressions | `ollama` | `kimi-k2.7-code:cloud` |
| `edge_cases_error_handling` | Nil, timeouts, partial failure | `ollama` | `kimi-k2.7-code:cloud` |
| `simplicity_yagni_scope` | Minimal surface, no speculative work | `xai_oauth` | `grok-4.6` |
| `readability_maintainability` | Naming, placement, comments | `xai_oauth` | `grok-4.6` |
| `contract_api_compat` | Facades, contracts, CLI/API | `ollama` | `glm-5.2:cloud` |
| `architecture_grain_fit` | DOT vs CRC vs action vs handler | `ollama` | `glm-5.2:cloud` |
| `performance_resource` | Hot path, memory, GenServer blocking | `ollama` | `minimax-m3:cloud` |
| `docs_naming` | Docs drift, absolute dates | `ollama` | `minimax-m3:cloud` |

That is five models across three providers. Diversity is a quality choice
baked into the reviewed graph, not a hard requirement of the reducer. A
new host that only has one working provider should remap every seat to
that provider rather than shipping half-abstaining reviews.

Each seat has `use_tools=true` and must finish by calling
`coding_submit_review_report` exactly once (`vote`, `finding_updates`,
`new_findings`). `consensus_decide_review` exact-decodes that JSON.
Missing, failed, malformed, or unknown-branch reports stay abstentions.

Vote policy (from the node system prompts):

- Record majors; a single major from one owner is non-binding.
- Exact same-issue corroborated majors (`corroborated_major`) block.
- Active majors from two distinct owners require rework even when issue
  keys differ.
- Reject only for a supported blocking / architectural finding (security
  may also emit a security veto).
- Minor / nit never reject.

After the ledger reduce, `Arbor.Actions.Council.BlastRadius` still routes:

| `tier_decision` | Meaning |
| --- | --- |
| `auto_proceed` | Council accept, not high-blast-radius, no security veto |
| `human_review` | Person must look (high-risk paths, authority-surface files, or `human_required`) |
| `rework` | Same-session worker rework |
| `stop` | Reject / security veto |

High-blast-radius includes `apps/arbor_security/`, `apps/arbor_trust/`,
`apps/arbor_kernel/`, the Engine, the `coding_agent` manifest, and the
council DOT / blast-radius module themselves. Editing the council graph
to remap models is therefore itself an authority-surface change.

## Prerequisites for the stock graph

You need a live Arbor node (`./bin/mix arbor.start`) plus credentials for
every provider that still appears in the DOT.

### `openai_oauth` (`gpt-5.6-sol`)

Arbor-owned OpenAI loopback login on the live node. The pending handle
never appears in `inspect/1`; opening the URL completes the flow.

```elixir
{:ok, prompt} = Arbor.LLM.start_openai_loopback_login()
Arbor.LLM.OAuth.Login.LoopbackPrompt.authorize_url(prompt)
```

A ChatGPT / Codex subscription that can call `gpt-5.6-sol` is required.
An `OPENAI_API_KEY` is a different route (`openai`) and will not satisfy
`llm_provider="openai_oauth"` unless you change the DOT.

### `xai_oauth` (`grok-4.6`)

Same Arbor-owned xAI device login as the factory worker. See
[SOFTWARE_FACTORY.md](./SOFTWARE_FACTORY.md). Do not copy `~/.grok` login
state into the BEAM. SuperGrok Heavy can still fail as
`xai_oauth_tier_denied` on some accounts.

### `ollama` (three cloud model ids)

Text generation uses `config :arbor_orchestrator, :ollama, base_url`,
default `http://localhost:11434/v1`. Override with
`ARBOR_OLLAMA_BASE_URL` (bare URL; runtime appends `/v1` for chat).

The stock ids are Ollama *cloud* model names:

```text
kimi-k2.7-code:cloud
glm-5.2:cloud
minimax-m3:cloud
```

They must resolve on that Ollama instance (pulled / entitled). A local
llama.cpp or LM Studio on `:1234` is `lm_studio`, not `ollama`. Pointing
`ARBOR_OLLAMA_BASE_URL` at a host that does not serve those names produces
failed seats, which the reducer records as abstentions.

### Capabilities

The factory caller must already hold the review horizon (see
[CODING_TASK_DISPATCH.md](./CODING_TASK_DISPATCH.md)). Binding review
adds at least:

- `arbor://action/council/review`
- `arbor://action/consensus/decide_review`
- `arbor://orchestrator/execute/parallel`
- `arbor://orchestrator/execute/llm_query`

Derive the exact set from the compiled graph; do not infer
`.../compute` from node names.

The coordinator started from `coding_agent` already requests the council
action URIs. Seats also need `coding_review_tree_read` /
`coding_review_tree_search` / `coding_submit_review_report` on the
execution principal.

## Remap seats for a new host

There is no `ARBOR_CODE_REVIEW_*` env overlay. The factory loads the
packaged reviewed pipeline:

```elixir
{:ok, pipeline} = Arbor.Actions.reviewed_pipeline("code_review_council")
pipeline.path
# .../priv/pipelines/code-review-council.dot
```

### Option A — keep the ten seats, change provider/model pairs

Edit `apps/arbor_actions/priv/pipelines/code-review-council.dot`. On each
compute node set `llm_provider` and `llm_model` to a pair this host can
actually call. Examples that work without the stock OAuth trio:

```dot
llm_provider="openrouter"
llm_model="anthropic/claude-sonnet-4.6"
```

```dot
llm_provider="ollama"
llm_model="qwen3:32b"
```

```dot
llm_provider="lm_studio"
llm_model="local-model-id"
```

Keep `use_tools`, `terminal_tools`, `prompt_is_data`, and the
`coding_submit_review_report` contract. Changing the vote schema or
dropping the terminal tool is a protocol break, not a provider remap.

Recompile / restart the live node so `reviewed_pipeline/1` rereads the
file. `ReviewChange` accepts a `graph` path override for one-off tests;
the factory coding graph uses the packaged artifact.

### Option B — one stylesheet for every compute node

The orchestrator applies a graph-level `model_stylesheet` (`*`,
`#node_id`, `.class`, `shape`) with properties `llm_provider`,
`llm_model`, and `reasoning_effort`. Adding this to the reviewed DOT
remaps every seat without touching ten system prompts:

```dot
digraph code_review_council {
  model_stylesheet="* { llm_provider: \"openrouter\"; llm_model: \"google/gemini-3.7-flash\"; }"
  ...
}
```

Node-level attributes still win over `*` if you leave them in place —
delete or change the per-node `llm_provider` / `llm_model` lines, or
target `#correctness { ... }` for a single seat.

### What not to change

- Do not shrink the ten node ids unless you also change
  `consensus_decide_review`'s complete-perspective vote set. Missing
  seats become abstentions and the ledger looks "empty" rather than
  "smaller council."
- Do not point `review_profile` at `"none"` to skip a missing provider.
  That disables review, it does not remap it.
- Do not set `ARBOR_COUNCIL_PERSPECTIVE_MODELS` and expect factory
  reviews to move. They will not.

## Verify before the first factory review

On the live node (Tidewave `project_eval` or `./bin/mix arbor.rpc`):

```elixir
# 1. Packaged graph is readable and still has ten reviewer nodes.
{:ok, pipeline} = Arbor.Actions.reviewed_pipeline("code_review_council")
{:ok, graph} = Arbor.Orchestrator.parse(File.read!(pipeline.path))

reviewers =
  graph.nodes
  |> Enum.filter(fn {_id, node} -> node.attrs["type"] == "compute" end)
  |> Enum.map(fn {id, node} ->
    {id, node.attrs["llm_provider"], node.attrs["llm_model"]}
  end)

# 2. Each provider you kept can complete a tiny generate.
#    Use the same provider/model strings as the DOT.
{:ok, _} = Arbor.LLM.generate(
  provider: :openrouter,
  model: "google/gemini-3.7-flash",
  messages: [%{role: "user", content: "Reply with the single word pong."}],
  max_tokens: 16
)
```

OAuth routes use the Arbor-owned sessions from the login helpers above,
not a raw API key. If generate fails, fix credentials before dispatching
a binding review — a failed seat is an abstention, and a council of
abstentions is not a pass.

Smoke the advisory path only if you care about Consult:

```bash
./bin/mix arbor.consult "Is ETS or Redis the right cache for session tokens?"
```

That exercises AdvisoryLLM, not `code-review-council.dot`.

## Reading a factory council verdict

Sharp edges already documented in
[CODING_TASK_DISPATCH.md](./CODING_TASK_DISPATCH.md):

- Aggregate confidence may read `0.0` when it is unavailable. Treat that
  as missing evidence, not measured zero. Check per-perspective
  `reason_code`.
- A reviewer that makes more than one non-terminal tool call can abstain
  with `call_shape=multiple_non_terminal`. That is a lost seat, not a
  judgement on the diff.
- `security_app` / authority-widening paths often terminate
  `human_review_required` even on an 8–0–2 accept. Independently inspect;
  merge only when there is no blocking finding and no `security_veto`.

## Advisory council (optional)

Thirteen perspectives: `brainstorming`, `user_experience`, `security`,
`privacy`, `stability`, `capability`, `emergence`, `vision`,
`performance`, `generalization`, `resource_usage`, `consistency`,
`adversarial`.

Portable defaults are OpenRouter-only so a fresh install needs one key:

- Gemini Flash — most seats
- DeepSeek — security, stability, performance, generalization,
  consistency, adversarial

Resolution, lowest to highest:

1. Compiled defaults in `AdvisoryLLM`
2. Uniform `ARBOR_COUNCIL_MODEL=openrouter:google/gemini-3.7-flash`
3. `ARBOR_COUNCIL_PERSPECTIVE_MODELS` JSON (names must be those 13)
4. `config :arbor_consensus, :perspective_models, %{...}`
5. Per-call override

```bash
# .env — one model for every advisory seat
ARBOR_COUNCIL_MODEL=openrouter:google/gemini-3.7-flash

# or per-seat
ARBOR_COUNCIL_PERSPECTIVE_MODELS='{"security":"openai_oauth:gpt-5.6-sol","adversarial":"xai_oauth:grok-4.6"}'
```

```elixir
Arbor.Consensus.Evaluators.AdvisoryLLM.configure_perspective(
  :security,
  "ollama:kimi-k2.7-code:cloud"
)

Arbor.Consensus.Evaluators.AdvisoryLLM.provider_map()
```

`inspect` on OAuth login prompts is redacted. Use the accessors. Restart
is not required for `configure_perspective/2`; it is required after
editing `.env`.

## Related

- `apps/arbor_actions/priv/pipelines/code-review-council.dot` — binding seats
- `Arbor.Actions.Council.ReviewChange` — factory review action
- `Arbor.Actions.Council.BlastRadius` — post-verdict routing
- `Arbor.Consensus.Evaluators.AdvisoryLLM` — advisory map
- [SOFTWARE_FACTORY.md](./SOFTWARE_FACTORY.md) — first factory run
- [CODING_TASK_DISPATCH.md](./CODING_TASK_DISPATCH.md) — horizon, budgets,
  how to read a verdict
