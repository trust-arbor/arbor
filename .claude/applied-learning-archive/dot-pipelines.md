# Applied Learning archive: dot-pipelines

Retired entries, kept for history and revival. Not loaded by default.

<!-- applied-learning: opaque-authority-must-stay-outside-every-action-visible-context-including-nested-option-maps -->
<a id="applied-learning-opaque-authority-must-stay-outside-every-action-visible-context-including-nested-option-maps"></a>
**Opaque authority must stay outside every action-visible context, including nested option maps.**
Removing a top-level `:signing_authority` key is insufficient if `nested_engine_opts` is
passed through `Arbor.Actions.authorize_and_execute/4`. Keep the bearer token at the
orchestrator boundary, project only a fresh exact-resource `SignedRequest` into the
action, and retain a process-local resign path for post-approval retries.

<!-- applied-learning: a-grapheme-count-limit-is-not-a-byte-or-work-limit -->
<a id="applied-learning-a-grapheme-count-limit-is-not-a-byte-or-work-limit"></a>
**A grapheme-count limit is not a byte or work limit.** One valid Unicode grapheme can contain arbitrarily many combining codepoints, so `String.slice(text, 0, 512)` can retain and traverse many kilobytes while claiming a 512-character bound. Resource ceilings for prompts, diagnostics, and persisted output must check bytes first and truncate on a valid UTF-8 byte boundary; add combining-sequence regressions that assert `byte_size/1` (found 2026-07-11 reviewing AI eval output bounds).

<!-- applied-learning: a-reachable-distributed-node-is-not-an-application-ready-arbor-server -->
<a id="applied-learning-a-reachable-distributed-node-is-not-an-application-ready-arbor-server"></a>
**A reachable distributed node is not an application-ready Arbor server.** `mix arbor.start` can answer RPC while the umbrella is still starting sequentially, so a process lookup or action call may return `:noproc` / `:registry_unavailable` after the CLI already printed success. Readiness must positively verify the required application boundary (or a dedicated boot sentinel), not only `net_adm` reachability. A 2026-07-17 cold boot took about 296 seconds, so a 300-second application deadline had no operational margin; keep the short node-ping deadline separate from a measured, conservatively larger application deadline (found 2026-07-16 and remeasured 2026-07-17 after rebuilding the startup-pinned Shell launcher).

<!-- applied-learning: schema-negative-tests-must-target-attributes-the-compiler-does-not-intentionally-normalize -->
<a id="applied-learning-schema-negative-tests-must-target-attributes-the-compiler-does-not-intentionally-normalize"></a>
**Schema-negative tests must target attributes the compiler does not intentionally normalize.** A reviewed-template compiler may restore mandatory parameters before schema validation, so injecting a bad value into one of those parameters proves normalization rather than rejection. Test the restored invariant separately, and use an untouched action parameter to exercise the generic schema failure path (found 2026-07-10 after making default validation warnings mandatory).

<!-- applied-learning: dot-constant-transforms-emit-strings-even-when-the-expression-looks-numeric-or-boolean -->
<a id="applied-learning-dot-constant-transforms-emit-strings-even-when-the-expression-looks-numeric-or-boolean"></a>
**DOT `constant` transforms emit strings, even when the expression looks numeric or boolean.** If
the context or downstream contract requires a typed JSON value, put it in a JSON object and extract
it with `json_extract`, or normalize it at the action boundary. A fake executor that accepts the
serialized string can hide a production constructor failure, so executable pipeline fixtures must
exercise the real request/contract constructor for typed action inputs (found 2026-07-12 with
`review_cycle`).

<!-- applied-learning: execution-identity-belongs-in-immutable-run-authority-never-mutable-graph-context -->
<a id="applied-learning-execution-identity-belongs-in-immutable-run-authority-never-mutable-graph-context"></a>
**Execution identity belongs in immutable run authority, never mutable graph context.** `session.agent_id` is useful context provenance, but if middleware or handlers derive the principal from it, a graph, nested run, or initial-values merge can spoof or lose authority while the signer comes from unrelated opts. Bind execution principal, caller/author provenance, task/session scope, graph hash, and fixed workdir in trusted Engine state; context may mirror those fields but must not drive authorization (found 2026-07-10 tracing direct, nested, parallel, and remote DOT execution).

<!-- applied-learning: closed-json-schemas-need-exact-scalar-types-not-only-keys-and-loose-equality -->
<a id="applied-learning-closed-json-schemas-need-exact-scalar-types-not-only-keys-and-loose-equality"></a>
**Closed JSON schemas need exact scalar types, not only keys and loose equality.** Elixir considers `1 == 1.0`, so a summary cross-check using `!=` can accept float aliases for integer counters. Validate bounded integer fields explicitly and use type-strict comparisons (`!==`) when the serialized contract distinguishes numeric representations (found 2026-07-11 reviewing coding benchmark summary validation).

<!-- applied-learning: pipeline-traversal-authority-is-not-resource-authority -->
<a id="applied-learning-pipeline-traversal-authority-is-not-resource-authority"></a>
**Pipeline traversal authority is not resource authority.** A grant such as `arbor://orchestrator/execute/**` may authorize pure graph opcodes, but it must never satisfy bare IR requirements such as `file_write` or `shell_exec`: normalizing those names under the traversal subtree turns a lobby pass into host filesystem and process authority. Map side-effecting handlers to their canonical `arbor://fs/...`, `arbor://shell/...`, or action resource and carry concrete path/task scope into Security (found 2026-07-10 during the DOT coding Phase 5 authorship audit).

<!-- applied-learning: an-engine-ok-run-result-is-an-execution-envelope-not-a-success-verdict -->
<a id="applied-learning-an-engine-ok-run-result-is-an-execution-envelope-not-a-success-verdict"></a>
**An Engine `{:ok, run_result}` is an execution envelope, not a success verdict.** Nested consumers such as council adapters must inspect `final_outcome` before reading decision keys from context. When a non-nil outcome is present, admit only the explicitly supported success statuses; reject `:fail`, `:retry`, `:skipped`, unknown, and malformed outcomes before stale context can escape (found 2026-07-18 when an all-failed council fan-in was masked as `:no_decision_in_result`).
