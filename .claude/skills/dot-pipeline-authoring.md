# DOT Pipeline Authoring

Write or modify Arbor's `.dot` orchestration pipelines. For a syntax-only reference, see [`docs/arbor/DOT_PIPELINE_GUIDE.md`](../../docs/arbor/DOT_PIPELINE_GUIDE.md). For invoking and running already-written pipelines from code, see [`dot-pipeline-execution.md`](./dot-pipeline-execution.md).

For the coding-change workflow, read [`docs/arbor/CODING_TASK_DISPATCH.md`](../../docs/arbor/CODING_TASK_DISPATCH.md).
It owns Grok 4.5 runtime isolation, attested native-tool profiles, immutable
MCP/workspace binding, provider-versus-workspace continuity, and
owner-observed approval/cancellation behavior. Keep those operational rules
there; this skill covers DOT authoring and generic execution semantics.

## When to write a new pipeline

Reach for a new `.dot` when you need to compose multiple steps with explicit gating, parallelism, or routing — and the policy should be visible to humans reviewing the work, not buried in code. Reach for plain Elixir when the work is a single function call, or when control flow depends on runtime values that don't compose into a graph cleanly (e.g. tight inner loops).

Before writing a new pipeline, search `apps/arbor_orchestrator/specs/pipelines/stdlib/` — there's already `retry-escalate.dot` (LLM-model escalation), `feedback-loop.dot` (generate / critique / revise), `propose-approve.dot`, `synthesize.dot`, and several others. If one fits with `pass_context` parameterization, invoke it rather than copy.

## Authoring invariants

- Treat the graph, compiled execution manifest, and `RunAuthorization` as
  immutable after preflight. Let the executor bind the caller's principal;
  do not use node attributes or context to impersonate another principal.
- Keep context JSON-clean because the Engine checkpoints it after nodes. Pass
  identifiers and bounded data, then reconstruct typed runtime values at the
  action or handler boundary.
- Use graph validation for structure and declared placement, capability
  middleware for runtime authority, and Jido actions for capability-gated side
  effects. Do not move business policy into a generic handler.
- For reviewable changes, make commit/tree identity and owner-observed
  workspace state explicit in the action contracts. Worker prose is not a
  substitute for inspection or a review-bound tree snapshot.

## Canonical node types (15)

The Arbor engine resolves all node `type=` strings to **15 canonical handlers**. Other type strings are aliases that resolve to one of these:

| Domain | Types |
|---|---|
| Control flow | `start`, `exit`, `branch`, `parallel`, `fan_in` |
| Computation | `compute`, `transform`, `exec` |
| State | `read`, `write` |
| Composition | `compose`, `map`, `adapt` |
| Coordination | `wait` |
| Governance | `gate` |

You'll most often reach for `exec` (call an Action), `compute` (LLM call), `transform` (rewrite context), `gate` (pass/fail check), `compose` (invoke a sub-pipeline). `start` and `exit` are inferred from `shape=Mdiamond` / `shape=Msquare`.

## Calling an Action from a DOT

This is the bread-and-butter pattern — the engine reaches into the Action registry, executes the action, flows its return map into context:

```dot
run_test [
  type="exec",
  target="action",
  action="mix_test",
  agent_id="agent_test_mix",
  param.path="/abs/path/to/project",
  param.tags="fast"
]
```

Rules:

- `action="<name>"` must match a registered Action's `name:` field. Discover names via `mix arbor.actions list` or by reading `Arbor.Actions.list_actions/0`. Both dot-form (`mix.test`) and Jido form (`mix_test`) resolve.
- `param.<key>="<value>"` becomes `action_args[<key>]`. Attribute names must NOT be quoted — `"param.path"="..."` breaks DOT parsing; use bare `param.path="..."`.
- `agent_id="agent_<id>"` is the principal that owns the call. The capability check fires on this. Principal IDs MUST start with `agent_` — bare `"system"` is rejected by `CapabilityStore`.
- The action's return map flows into context as `exec.<node_id>.<key>`. E.g. `Mix.Test` returns `%{passed: true, exit_code: 0, stdout: "..."}` so the next nodes can read `context.exec.run_test.passed`, `context.exec.run_test.exit_code`, etc.

## Context flow

The engine passes a key-value context through every node. Nodes read with `context.<dotted.key>` and write via their return value.

| Node type | Where its output lands |
|---|---|
| `exec target=action` | `exec.<node_id>.<each-return-map-key>` |
| `compute` (LLM) | `last_response` + node-specific keys (`exec.<node_id>.result`) |
| `transform` | freeform — the prompt describes what context keys to write |
| `gate` | `gate.<node_id>.passed` (boolean) |
| `compose mode=invoke` | `subgraph.<node_id>.<each-child-context-key>` |

Pass values into action params via `param.foo="bar"` (static) or via `context_keys="key1,key2"` (pull from current context). There is NO `$var` interpolation in attributes — values must be literal at compile time.

## Routing with `branch` / `gate` / conditional edges

`branch` is the routing primitive: "the engine picks the outgoing edge whose condition evaluates true." It does NOT execute anything itself — the work happens in surrounding nodes.

`gate` is the pass/fail primitive: it evaluates a predicate and writes a `gate.<node_id>.passed` boolean; the engine then routes via edge conditions.

Edge condition syntax (parsed by `Arbor.Orchestrator.Engine.Condition`):

```dot
check -> mark_pass [condition="context.exec.run_test.passed=true"]
check -> mark_fail [condition="context.exec.run_test.passed!=true"]
```

Rules:

- Operators: `=`, `!=`, `>=`, `<=`, `>`, `<`, `~` (contains). Note `=`, not `==`.
- Keys: `context.<dotted.path>` or a fixed `outcome`/`status` shortcut. **Regex `^[A-Za-z_][A-Za-z0-9_.]*$`** — no `?` in keys. (So name your Action return fields `passed`, not `passed?`.)
- Combine clauses with ` && `.
- Always cover BOTH outcomes on a branching diamond. An unreachable node with no matching condition silently freezes the pipeline.

## Sub-pipeline composition

Two patterns:

**Invoke a named or file-referenced child:**

```dot
merge [
  type="graph.invoke",
  graph_file="apps/arbor_orchestrator/specs/pipelines/stdlib/synthesize.dot",
  pass_context="synthesize.input,synthesize.instructions,session.llm_provider"
]
```

- `type` is `graph.invoke` (the alias) — NOT bare `invoke`. The alias resolves to `compose mode=invoke`.
- The child starts with an EMPTY context unless `pass_context` (CSV of keys) or `pass_all_context="true"` lifts values in. No implicit inheritance.
- Child results land at `subgraph.<invoke_node_id>.<key>`. Override via `result_prefix=` or remap via `result_mapping="child_key:parent_key,..."`.

**Compose inline (DOT-as-data):**

```dot
inline [
  type="graph.compose",
  source_key="generated_dot",
  pass_context="x,y"
]
```

The child DOT string is read from `context.generated_dot`. Use this when an upstream node produces a DOT dynamically.

## Anti-patterns

| Don't | Do |
|---|---|
| `"param.foo"="bar"` (quoted attr name) | `param.foo="bar"` |
| Multiple `shape=Msquare` exits | One `done [shape=Msquare]`; converge branches to it |
| `?` in context keys (e.g. `passed?`) | Plain names (`passed`) |
| `type="invoke"` | `type="graph.invoke"` |
| `$repo_path` in attrs | Set the literal value, or read via `context_keys="..."` |
| Reach for raw `Shell.Execute` for a recurring tool (`git`, `mix`) | Wrap as a Jido Action (`Arbor.Actions.Git.*`, `Arbor.Actions.Mix.*`) — capability URIs become precise, taint roles get declared once |
| Write a whole new handler module | First check whether a stdlib DOT + the 15 canonical types can express it. Handlers are a heavy primitive; most "new node types" are subgraph compositions |

## Common traps (the ones that bit me when wiring real pipelines)

### LLM compute nodes REQUIRE an explicit `simulate=` (no default)

Every node that calls a model — `compute purpose=llm` (the default), a bare-prompt `codergen` node, or `type="llm"` — **must** declare `simulate`. There is no default: omit it and `mix arbor.pipeline.validate` flags it as an error (`compute/llm node must declare an explicit simulate= attribute`), and at runtime the node **fails loud** instead of silently mocking. (This used to default to silent simulation — the node returned a deterministic mock string and the pipeline "succeeded" with plausible-but-totally-fake output; it had 9 of 13 stdlib pipelines silently mocking. Declaring intent is now mandatory so you — or an agent composing a DOT — can't accidentally ship a fake-output pipeline.)

- `simulate="false"` → real LLM call (fails loudly if no provider configured)
- `simulate="true"` → deterministic mock string (tests / dry runs)

```dot
generate [type="compute", purpose="llm", simulate="false", llm_provider="...", llm_model="...", prompt_context_key="..."]
```

Non-LLM compute purposes (e.g. `purpose="routing"`) do **not** require `simulate`.

### Don't hardcode `agent_id="…"` on a single exec node

It looks like a harmless override. But the signer you thread through `Orchestrator.run/2` signs as agent X, and the auth path on this node checks agent Y — capability check fails with `:unauthorized`. Let `agent_id` fall through to `session.agent_id` from context unless you actually mean "this node runs as a different identity than the rest of the pipeline."

### `mix arbor.pipeline.validate` passing ≠ runtime success

Validation is a *syntax* checker — terminal-node, edge-condition syntax, prompt presence on compute nodes, and `simulate=` presence on LLM nodes. It does NOT catch: missing capabilities, unstarted services (NonceCache, IdentityRegistry, ExecutionRegistry), unregistered identities, missing LLM providers, missing action registrations. Treat validate-pass as "the graph parses," nothing more.

### `arbor://fs/<op>/<root>` — the URI encodes the path scope

Capability URIs aren't just opaque tokens passed to a matcher. For `arbor://fs/*` URIs, **FileGuard parses the URI to extract the allowed root path**. So:

- `arbor://fs/write` alone is malformed for FileGuard's purposes — no root component → no path validation can run.
- `arbor://fs/write/workspace/project` grants write under `/workspace/project`.
- `arbor://fs/**` is the explicit wildcard literal — recognized as "all paths."

Generalize the lesson: capability URI granularity is part of the design surface, not just a security knob. Sketch the URIs alongside the DOT, not after.

### `transform=identity` is the canonical "rename a context key"

When the next node's action schema wants `content` but the upstream produced `last_response`, you don't need to modify either — drop in:

```dot
prepare_content [type="transform", transform="identity", source_key="last_response", output_key="content"]
```

Pure rename, no LLM call, no side effects. The unstructured `transform` with a freeform `prompt=` is for LLM-driven transformation — different tool.

### No variable interpolation in attrs

`$language` in a node attribute is literal — it does not get substituted. To parameterize a node by runtime context:

- Set the value in `initial_values` when invoking `Orchestrator.run/2`.
- Reference it via `context_keys="key1,key2"` on the consuming node (which pulls those context values into the action's args).
- For string-template substitution into a generated prompt, use `transform="template"` with a `{value}` placeholder.

If you find yourself wanting interpolation, you almost always want a transform stage between the source and the consumer.

### Bypasses belong in Elixir, not in CLI flags

`Arbor.Orchestrator.run/2` accepts `authorization: false` to skip the mandatory capability check — useful in tests and operator scripts. **Do not surface this opt as a flag on a public mix task.** A `--no-auth` CLI flag converts mix into a privilege-escalation primitive: any agent capable of invoking shell now can also bypass capability checks on any pipeline. The Elixir-API opt is fine because the calling code is itself the trust boundary; the CLI flag isn't because the shell isn't.

Same principle: keep auth-relaxation primitives behind API surfaces that already require code-edit access.

### `authorization: false` only bypasses the engine — not action-layer caps

Important nuance, surfaced by the HITL example pipeline. `authorization: false` on `Orchestrator.run/2` turns off the **engine-level** per-node capability middleware (the `CapabilityCheck` that runs before each handler — `arbor://orchestrator/execute/<node_type>`). It does NOT turn off the **action-layer** capability check that `Arbor.Actions.authorize_and_execute/4` does for every `exec target=action` invocation.

So a pipeline running with `authorization: false` will still hit `{:error, :unauthorized}` from `file_write`, `mix_test`, `git_commit`, or any other Action whose canonical URI the calling principal hasn't been granted. The two checks are independent layers.

For tests that need to skip BOTH:
- Use `authorization: false` to silence the engine layer.
- Grant the action URIs (e.g. `arbor://fs/**`) to your test principal via `CapabilityStore.put/1` to satisfy the action layer.
- The HITL example test (`deployment_decision_gate_example_test.exs`) shows the canonical pattern.

## Validating before running

```bash
mix arbor.pipeline.validate path/to/pipeline.dot
```

Catches: invalid edge condition syntax, multiple terminal nodes, unknown handler types in strict mode, missing prompts on compute/codergen nodes. Does NOT catch the runtime issues listed above — see "Common traps."

## See also

- [`docs/arbor/DOT_PIPELINE_GUIDE.md`](../../docs/arbor/DOT_PIPELINE_GUIDE.md) — full attribute reference
- [`apps/arbor_orchestrator/lib/arbor/orchestrator/stdlib/aliases.ex`](../../apps/arbor_orchestrator/lib/arbor/orchestrator/stdlib/aliases.ex) — the alias map (all known type strings → 15 canonical)
- [`apps/arbor_orchestrator/specs/pipelines/stdlib/`](../../apps/arbor_orchestrator/specs/pipelines/stdlib/) — reference subpipelines (read before writing similar)
- [`dot-pipeline-execution.md`](./dot-pipeline-execution.md) — running pipelines from code

## Applied Learning: DOT Pipelines

Read this when authoring or changing DOT graphs, Engine execution, action bindings, context flow, or handler contracts.

<!-- applied-learning: dot-comment-stripping-must-be-quote-aware -->
<a id="applied-learning-dot-comment-stripping-must-be-quote-aware"></a>
**DOT comment stripping must be quote-aware.** Compiler-generated attributes
legitimately embed JSON, URLs, and capability URIs. A regex that removes `//`
or `/* ... */` without tracking double-quoted strings truncates values such as
`https://...` and `arbor://...`, then makes a valid generated graph fail strict
canonical round-trip validation. Preserve comment-marker-like text inside
quoted values, honor escaped quotes and backslashes, retain comment newlines
for diagnostics, and fail closed on an unterminated block comment. Regress both
the parser and a real compiler packet containing URI-shaped text (found
2026-07-28 while replaying the first Phase F reconciliation dispatch).

<!-- applied-learning: a-jido-action-schema-is-not-automatic-runtime-validation-for-direct-arbor-execution -->
<a id="applied-learning-a-jido-action-schema-is-not-automatic-runtime-validation-for-direct-arbor-execution"></a>
**A Jido action schema is not automatic runtime validation for direct Arbor execution.**
`Arbor.Actions.execute_action/3` invokes `action_module.run/2`; the Zoi schema shapes
the model-facing tool definition but does not enforce its length, encoding, or
duplicate-key constraints on that public path. Security- and protocol-sensitive
actions must repeat their closed bounds behaviorally in `run/2`, reject atom/string
aliases for the same logical key, and test the direct facade path (found 2026-07-17
hardening the binding council terminal report action).

<!-- applied-learning: dot-context-keys-must-match-the-exact-context-keys-producers-emit -->
<a id="applied-learning-dot-context-keys-must-match-the-exact-context-keys-producers-emit"></a>
**DOT `context_keys` must match the exact context keys producers emit.** The
code-review council DOT used `review.review_cycle` while
`CodeReviewRequest.to_context/1` only emitted `review.cycle` / `review_cycle`,
so ExecHandler silently dropped the param and `DecideReview` failed with
`invalid_review_cycle`. Mirror the production dotted key on both sides
(`review.finding_ledger`-style), accept the dotted form in the action param
lookup, and regress with the exact DOT-produced parameter map (found
2026-07-17 when binding council reducers returned invalid_review_cycle).

<!-- applied-learning: node-action-inventory-checks-do-not-prove-graph-policy -->
<a id="applied-learning-node-action-inventory-checks-do-not-prove-graph-policy"></a>
**Node/action inventory checks do not prove graph policy.** A graph can retain every mandatory node and action name while rewiring conditions to bypass them. Inventory is useful Phase 4 template drift detection; publish/review/validation dominance and edge-order invariants require semantic preflight before custom or agent-authored DOT is executable (confirmed 2026-07-10 in the CodingPlan compiler review).

<!-- applied-learning: static-dot-action-parameters-arrive-as-strings -->
<a id="applied-learning-static-dot-action-parameters-arrive-as-strings"></a>
**Quoted DOT parameters and constant transforms arrive as strings.** `Arbor.Orchestrator.Dot.Parser` keeps a double-quoted attribute as a string and types an unquoted `true`, `false`, or number. A `constant` transform in `Arbor.Orchestrator.Handlers.TransformHandler` returns the expression string unchanged. Use an unquoted literal when the action requires that JSON scalar, or normalize only where the action contract says so. A fake that accepts both the typed value and the string hides a dead production branch. Exercise the real constructor in pipeline fixtures. (Merged 2026-10-16 from 2 entries; first found 2026-07-10, last 2026-07-12.)

<!-- applied-learning: hot-loading-an-action-does-not-refresh-a-core-locked-actionregistry -->
<a id="applied-learning-hot-loading-an-action-does-not-refresh-a-core-locked-actionregistry"></a>
**Hot-loading an action does not refresh a core-locked `ActionRegistry`.** The action facade can expose a newly compiled module while the boot-populated registry still lacks it, causing CodingPlan compilation to reject the action as unknown even though runtime execution has a facade fallback. Production action-catalog discovery must reconcile dynamic/plugin registry entries with the current `Arbor.Actions.list_actions/0` core facade; treating any running registry as the sole inventory makes hot reload require a full node restart (found 2026-07-10 while dogfooding the `cross_app` coding profile).

<!-- applied-learning: jido-map-schemas-do-not-accept-dynamic-string-keyed-json-maps-and-any-is-not-an-honest-tool-schema-fallback -->
<a id="applied-learning-jido-map-schemas-do-not-accept-dynamic-string-keyed-json-maps-and-any-is-not-an-honest-tool-schema-fallback"></a>
**Jido `:map` schemas do not accept dynamic string-keyed JSON maps, and `:any` is not an honest
tool-schema fallback.** Path-keyed values such as `%{"lib/a.ex" => [[1, 2]]}` fail Nimble schema
validation because Jido expects atom map keys, while Jido's JSON-schema converter publishes
Nimble `:any` as `type=string`. Use a terminating Zoi object/array schema with dynamic string-keyed
maps; when strict conversion would close those nested maps, publish the non-strict schema and close
only the fixed root object. Exercise `validate_params/1` with atom top-level keys because string
top-level keys are treated as unknown passthrough fields, and assert both malformed outer types and
the emitted `to_tool/0` schema (found 2026-07-12 with review `delta_ranges` and finding ledgers).

<!-- applied-learning: mutating-actions-must-declare-their-conservative-static-effect-class -->
<a id="applied-learning-mutating-actions-must-declare-their-conservative-static-effect-class"></a>
**Mutating actions must declare their conservative static `effect_class`.** `Arbor.Actions.Egress` intentionally defaults an undeclared action to `:read`; that made `git.commit` approval records claim `risk_hints.effect_class=read` even though the trust gate still asked. Declare `:local_write` for actions whose maximum mode mutates local state, including mixed read/write actions such as `Git.Branch`, and regress through the public `Egress.effect_class_for/1` projection (found 2026-07-10 during live approval inspection).

<!-- applied-learning: multi-module-hot-reload-is-not-a-transactional-deployment-boundary -->
<a id="applied-learning-multi-module-hot-reload-is-not-a-transactional-deployment-boundary"></a>
**Multi-module hot reload is not a transactional deployment boundary.** A compiler, profile registry, semantic validator, and template can be individually current while one request still crosses a mixed old/new call path at the end of a reload window. After reloading a policy bundle, run one live compile/authorization probe that exercises the whole bundle before dispatching durable work; retry only tasks that failed before acquiring resources (found 2026-07-11 when the first post-reload security-profile dispatch saw new attestation nodes with old topology expectations).

<!-- applied-learning: do-not-put-workflow-specific-result-policy-in-a-generic-engine-handler -->
<a id="applied-learning-do-not-put-workflow-specific-result-policy-in-a-generic-engine-handler"></a>
**Do not put workflow-specific result policy in a generic Engine handler.** Teaching `ExecHandler` that a `git_commit` denial can become branchable success violates the handler-as-opcode invariant and creates an author-controlled denial-bypass surface. Put commit approval/deny/rework semantics in a capability-gated Jido action and let the reviewed graph branch on ordinary action data; keep handler schemas generic (found 2026-07-11 reviewing commit-approval rework).

<!-- applied-learning: a-bearer-stripped-from-public-views-can-still-leak-through-action-results -->
<a id="applied-learning-a-bearer-stripped-from-public-views-can-still-leak-through-action-results"></a>
**A bearer stripped from public views can still leak through action results.** Returning a lease credential from a Jido action puts it into Engine context, checkpoints, and node status even if `public_view/1`, receipts, and signals redact it. Keep compatibility credentials inside the owning registry boundary; graph actions should use authenticated task/principal authority and return only non-authority descriptors (found 2026-07-11 reviewing workspace cleanup R2).

<!-- applied-learning: a-nested-map-inside-action-context-is-still-action-visible-authority -->
<a id="applied-learning-a-nested-map-inside-action-context-is-still-action-visible-authority"></a>
**No action-visible context may carry a signing bearer, including a nested option map.** Removing a top-level signing key is not enough when `nested_engine_opts` is passed into the action. Every action that receives that context can inspect, return, or log the bearer. Keep the bearer at the orchestrator boundary, project only a fresh exact-resource proof into the action, and keep post-approval resign on a process-local path. Nesting the bearer does not make it process-private. (Merged 2026-10-16 from 2 entries; first found 2026-07-11, last 2026-07-12.)

<!-- applied-learning: every-engine-handler-must-derive-principal-identity-from-runauthorization-not-node-attributes -->
<a id="applied-learning-every-engine-handler-must-derive-principal-identity-from-runauthorization-not-node-attributes"></a>
**Derive the execution principal only from RunAuthorization.** Every handler and middleware takes the immutable `Arbor.Orchestrator.Engine.RunAuthorization` execution principal. Do not take it from `session.agent_id`, node attributes, graph context, or a `system` fallback. `Arbor.Orchestrator.Handlers.ShellHandler` rejects principals `system` and `agent_system`. Fixing one handler is not enough if another side-effecting handler still prefers an author-controlled agent id. Context may mirror provenance, but those fields must not drive authorization. Reject absent authority on agent-authored runs. (Merged 2026-10-16 from 2 entries; first found 2026-07-10, last 2026-07-11.)

<!-- applied-learning: a-generic-engine-node-capability-does-not-replace-the-syscall-s-exact-capability-gate -->
<a id="applied-learning-a-generic-engine-node-capability-does-not-replace-the-syscall-s-exact-capability-gate"></a>
**A generic engine capability does not replace a syscall's exact capability gate.** `arbor://orchestrator/execute` authorizes graph traversal. It does not satisfy `arbor://fs/...`, `arbor://shell/...`, or an action capability, and normalizing a filesystem or shell requirement under that prefix would turn traversal into host authority. A tool-node branch that calls the shell or filesystem executor directly skips the exact gate. Map the effect to the canonical resource, carry the concrete path or command scope, and call that subsystem's authorized facade with the immutable run principal. (Merged 2026-10-16 from 2 entries; first found 2026-07-10, last 2026-07-11.)

<!-- applied-learning: an-action-cannot-self-declare-access-to-private-nested-authority -->
<a id="applied-learning-an-action-cannot-self-declare-access-to-private-nested-authority"></a>
**An action cannot self-declare access to private nested authority.** A callback such as `nested_engine_context_keys/0` is implemented by the action module itself, so treating it as an allowlist lets any newly loaded action request signer, permit, or private-key material. Keep the permitted module/operation set in the trusted facade, expose exact closed methods for those operations, and never insert a generic credential bag into action context (found 2026-07-11 stealing nested signing authority from a test action).

<!-- applied-learning: do-not-let-a-diagnostic-output-pipeline-hide-the-command-under-test-s-exit-status -->
<a id="applied-learning-do-not-let-a-diagnostic-output-pipeline-hide-the-command-under-test-s-exit-status"></a>
**Do not let a diagnostic output pipeline hide the command under test's exit status.** Shell pipelines such as `mix test ... | tail` or `... | rg` normally report the final filter's status, so a failed Mix startup can appear as exit code 0. Enable `pipefail`, capture the producer status explicitly, or run the producer without a filter when validation success is load-bearing (found 2026-07-16 when an umbrella `:eaddrinuse` failure was masked by `tail`).

<!-- applied-learning: nested-actions-that-mint-fresh-exact-resource-proofs-must-consume-the-process-local-signing-boundary -->
<a id="applied-learning-nested-actions-that-mint-fresh-exact-resource-proofs-must-consume-the-process-local-signing-boundary"></a>
**Nested actions that mint fresh exact-resource proofs must consume the process-local signing boundary.** An authority-signed outer action does not give a composite action the fresh nonce/signature needed for its inner syscall, and the bearer `SigningAuthority` must never enter JSON Engine context. Project an ephemeral signer only to explicitly trusted nested actions, consume it from owner-only `nested_engine_opts`, preserve malformed direct-credential fail-closed precedence, and pin the action BEAM in the execution manifest so an in-flight reload fails closed (found 2026-07-17 when `coding_reviewed_commit` validation passed but clean-HEAD adoption could not sign its nested Git resource).

<!-- applied-learning: composite-actions-must-declare-every-nested-action-as-an-execution-dependency -->
<a id="applied-learning-composite-actions-must-declare-every-nested-action-as-an-execution-dependency"></a>
**Composite actions must declare every nested action as an execution dependency.** Pinning only the outer action BEAM lets reviewed code call a different inner syscall implementation than the compiled graph bound. Expose module-valued dependency metadata through the owning library facade, bind it into the catalog digest, expand a deterministic cycle-safe transitive closure, and strip catalog-only metadata from the final backward-compatible manifest shape; missing dependencies must fail before execution (found 2026-07-17 when `coding_reviewed_commit` invoked unbound `git_commit`).

<!-- applied-learning: validate-trusted-compiler-output-at-the-final-execution-boundary -->
<a id="applied-learning-validate-trusted-compiler-output-at-the-final-execution-boundary"></a>
**Validate compiler output at the execution boundary with the same validator preflight uses.** Immediately before archiving or running a compiled graph, bind every compiler-produced path, provider, model, test selector, and provenance field back to the normalized authorized plan. A readiness check that accepts a binding the executor does not recheck, or an executor that accepts a binding preflight rejects, is not a gate. Keep narrower checks only as diagnostics. Add a public-boundary regression for every new provenance binding. (Merged 2026-10-16 from 2 entries; first found 2026-07-10, last 2026-07-22.)

<!-- applied-learning: reuse-the-engine-for-behavior-extensions-not-as-their-own-trust-boundary -->
<a id="applied-learning-reuse-the-engine-for-behavior-extensions-not-as-their-own-trust-boundary"></a>
**Reuse the Engine for behavior extensions, not as their own trust boundary.**
Prefer admitted DOT plus declarative assets for composed behavior, direct gated
actions for atomic contributions, and contained providers only for genuinely new
executable primitives. Reuse composition/checkpoints/ownership with a narrow
content/version admission boundary; mutable GraphRegistry discovery is not approval,
and plugin ingress must use caller-bound execution rather than legacy trusted
`run/2`. The graph cannot grant itself authority or make sensitive-data consent and
cleanup optional by omitting their nodes. Pin transitive content and active-run
versions; keep effect gates and emergency recovery host-owned. Checkpoints do not
provide universal transactions, and packaging behavior does not itself shrink the
TCB (learned 2026-09-07 while refining the plugin plan around existing DOT programs).

<!-- applied-learning: use-strict-value-equality-when-carrying-provenance-evidence -->
<a id="applied-learning-use-strict-value-equality-when-carrying-provenance-evidence"></a>
**Use strict equality for closed counters and provenance evidence.** Elixir `==` treats `1` and `1.0` as equal, including inside lists and maps. Use `===` and `!==` when a closed schema distinguishes numeric representations and when inherited sanitization or confidence is bound to producer values. A cross-check that uses `!=` can accept a float alias for an integer counter, so validate bounded integer fields explicitly. Retain worst risk across declared inputs, but derive evidence only from strictly matching inputs. (Merged 2026-10-16 from 2 entries; first found 2026-07-11, last 2026-10-06.)
