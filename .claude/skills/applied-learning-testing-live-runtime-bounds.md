# Applied Learning: Bounds, Deadlines, and Wire Contracts

Read this when bounding sizes, retries, deadlines, or output, or when changing a protocol, response, or prompt contract.

## Retained Applied Learning

<!-- applied-learning: structured-terminal-output-needs-a-tool-contract-not-prompt-only-json -->
<a id="applied-learning-structured-terminal-output-needs-a-tool-contract-not-prompt-only-json"></a>
**Enforce structured final output through a bounded terminal-tool contract.** Expose a schema-bounded terminal action, configure its closed name set through terminal_tools, and publish only the accepted terminal action result as final content. Exact-decode reports; malformed JSON, Markdown fences, prose, missing reports, and failed submissions must remain nonaccepting rather than being scraped into a verdict. Reserve at most one terminal-only correction request shared by free-form replies and ordinary tool-round exhaustion. That request exposes only terminal definitions, forces tool choice, and rejects fabricated nonterminal or ambiguous mixed calls before execution; exhaustion after that request fails closed. When no terminal contract is configured, remove tools for the final wrap-up while preserving the conversation's existing output format. Never replace a required structured response with an unconditional plain-text instruction. (Merged 2026-10-16 from 3 entries; first found 2026-07-10, last 2026-07-18.)

<!-- applied-learning: exclude-sentinel-atoms-before-normalizing-optional-protocol-fields -->
<a id="applied-learning-exclude-sentinel-atoms-before-normalizing-optional-protocol-fields"></a>
**Exclude sentinel atoms before normalizing optional protocol fields.** In Elixir,
`nil`, `true`, and `false` are atoms, so a broad `is_atom/1` conversion can turn a
missing value into the valid-looking string `"nil"`. Guard those sentinels before
`Atom.to_string/1`, especially when the result becomes an authorization identity
or URI segment (found 2026-07-17 while normalizing native ACP tool identities).

<!-- applied-learning: match-the-exact-split-shape-when-a-delimiter-proves-structure -->
<a id="applied-learning-match-the-exact-split-shape-when-a-delimiter-proves-structure"></a>
**Match the exact split shape when a delimiter proves structure.** A pattern such
as `[head | _]` also matches a one-element list, so it does not prove that
`String.split/3` found the expected delimiter. Use `[head, rest]` when the second
part is the evidence that an opaque protocol ID embeds a typed prefix (found
2026-07-17 while parsing ACP `toolCallId` values).
Check identifier grammars against the actual producer before tightening a
fixture validator. `Engine.generate_run_id/1` includes `Node.self()`, so a local
run ID contains `nonode@nohost`; the 2026-10-04 control prerequisite rejected
that legitimate `@` before any choice admission. Bind the exact known graph and
current node prefix plus the generated date/time/hex suffix instead of guessing
a generic identifier alphabet or accepting arbitrary path components.

<!-- applied-learning: search-every-direct-wire-shape-match-when-centralizing-a-response-contract -->
<a id="applied-learning-search-every-direct-wire-shape-match-when-centralizing-a-response-contract"></a>
**Search every direct wire-shape match when centralizing a response contract.** Fixing the primary adapter does not cover eval-only or provider-specific HTTP paths that decode the same response independently. Search for structural patterns such as `%{"data" => ...}` and route every caller through one lower-level facade helper. For embeddings, assert indexed ordering before cosine or another symmetric reduction; a reversed pair produces the same cosine score and can hide a silent A/B swap (found 2026-07-11 in the direct embedding-similarity eval HTTP path).

<!-- applied-learning: bounded-prompt-payloads-must-remain-structurally-valid -->
<a id="applied-learning-bounded-prompt-payloads-must-remain-structurally-valid"></a>
**Bounded prompt payloads must remain structurally valid.** Byte-slicing encoded JSON produces an
invalid fragment that downstream workers cannot parse. Bound fields before encoding, then compact
to a smaller valid JSON envelope with an explicit truncation marker if the encoded payload still
exceeds its ceiling (found 2026-07-12 in recovery and review feedback).

Apply aggregate limits after normalization, including added default fields.
Two individually bounded responses do not automatically fit their combined
projection. Before publishing a resume cursor, require the first command's
complete prompt batch to fit; trim disposable previews explicitly or refuse
the observation rather than skip undisplayed prompts. Later pagination must
resume after the last fully read command (2026-10-03 conversation controls).

<!-- applied-learning: a-semantic-retry-ceiling-must-pin-the-whole-counter-dataflow -->
<a id="applied-learning-a-semantic-retry-ceiling-must-pin-the-whole-counter-dataflow"></a>
**A semantic retry ceiling must pin the whole counter dataflow.** Checking only category/total gate
conditions does not prove that an admitted retry increments the shared total: a rewired edge or
mutated transform can skip the total counter and preserve every gate node. Pin counter
initialization and writer attributes, exact category-to-total increment chains, and prompt/dispatch
routing; mutation tests must remove or bypass each increment and fail before execution (found
2026-07-12 in coding review convergence preflight).

<!-- applied-learning: prompt-data-fencing-must-reuse-one-nonce-across-the-system-preamble-and-every-tool-result -->
<a id="applied-learning-prompt-data-fencing-must-reuse-one-nonce-across-the-system-preamble-and-every-tool-result"></a>
**Prompt-data fencing must reuse one nonce across the system preamble and every tool result.** Wrapping a later tool result with a fresh nonce that the system prompt never introduced gives the model delimiters without the instruction that makes them meaningful. Generate the nonce at the LLM-handler boundary, put its preamble in the system message, and thread that exact nonce through every tool-loop round and error path (found 2026-07-10 while enabling commit-tree evidence for binding reviewers).

<!-- applied-learning: bound-producer-output-before-it-enters-application-memory -->
<a id="applied-learning-bound-producer-output-before-it-enters-application-memory"></a>
**Bound producer output before it enters application memory.** Running `System.cmd/3` and truncating the returned binary still lets an untrusted command allocate its entire output first. For Git search or similar evidence tools, consume a Port incrementally, enforce a byte ceiling while receiving, and close the producer once the bound is reached; regression tests should keep the producer alive long enough to prove it was terminated before later side effects (found 2026-07-10 in `coding_review_tree_search`).

<!-- applied-learning: caller-configurable-resource-bounds-need-a-system-enforced-ceiling -->
<a id="applied-learning-caller-configurable-resource-bounds-need-a-system-enforced-ceiling"></a>
**Caller-configurable resource bounds need a system-enforced ceiling.** Adding `max_output_bytes`, `max_rows`, or a similar positive option does not make execution bounded if an agent can pass an arbitrarily large integer. Define a conservative default and a non-bypassable hard maximum at the enforcing layer, clamp or reject larger values consistently, mirror the maximum in schema-bounded adapters, and classify the parameter as control when it governs termination or resource use (found 2026-07-11 reviewing bounded shell output).

<!-- applied-learning: when-work-moves-into-a-shared-loader-remove-obsolete-outer-processing-passes -->
<a id="applied-learning-when-work-moves-into-a-shared-loader-remove-obsolete-outer-processing-passes"></a>
**When work moves into a shared loader, remove obsolete outer processing passes.** `ensure_graph/2` was changed to perform IR compilation, but public `compile/2` retained its old `IR.Compiler.compile/1` call. The second pass was merely wasteful for untouched graphs but recompiled post-IR custom transforms, restoring alias defaults and changing capability/taint/schema analysis contrary to the documented boundary. Trace the full facade path after centralizing work and add a regression whose transform/output distinguishes one pass from two (found 2026-07-11 while fixing authorized graph loaders).

<!-- applied-learning: process-output-is-arbitrary-bytes-until-proven-otherwise -->
<a id="applied-learning-process-output-is-arbitrary-bytes-until-proven-otherwise"></a>
**Bound raw output bytes and the work needed to retain diagnostics.** Treat process output as arbitrary bytes until validated; hash the original stream and sanitize only bounded retained windows before JSON serialization. Apply byte ceilings to prompts, diagnostics, and persisted output, cutting on valid UTF-8 boundaries and counting replacement expansion within the retained budget. A grapheme limit cannot bound bytes or traversal because one grapheme can contain arbitrarily many combining codepoints. Avoid whole-stream codepoint lists, grapheme slicing, and recursive binary concatenation merely to produce a small excerpt; use bounded head, tail, or failure windows with linear iodata accumulation and a small boundary allowance. Regress invalid UTF-8 and long combining sequences with byte-size assertions. (Merged 2026-10-16 from 3 entries; first found 2026-07-11, last 2026-07-11.)

<!-- applied-learning: a-struct-pattern-is-not-hostile-term-shape-validation -->
<a id="applied-learning-a-struct-pattern-is-not-hostile-term-shape-validation"></a>
**A `%Struct{}` pattern is not hostile-term shape validation.** A map carrying only `__struct__` and a subset of fields can satisfy the pattern, then raise on dot access or reach a shared broker with malformed data. Reconstruct opaque security references through their validating `new/1` factory using `Map.get/2` before reading fields or calling a broker, and return a shaped fail-closed error for partial struct-tagged maps (found 2026-07-11 reviewing SigningAuthority Engine propagation).

<!-- applied-learning: resource-bounds-belong-at-the-public-facade-not-only-one-adapter -->
<a id="applied-learning-resource-bounds-belong-at-the-public-facade-not-only-one-adapter"></a>
**Enforce resource ceilings across every public dispatch path.** Trace each facade operation through primary and alternate adapters, structured generation, tool-argument decoding, OAuth transports, injected clients, and backend selection by syntax or authorization mode. Apply nonbypassable structural-decode, aggregate-retention, absolute-deadline, and owned-stream-teardown limits at every public entry; adapters may tighten that floor but cannot bypass it. An action-schema option or bounded primary collector does not protect a branch that never consumes it. Enforce equivalent bounds on alternate branches or disable them by default. Inspect transport callbacks that run before ordinary response collectors: a DNS-pinning Finch callback must stream, count bytes, debit the shared deadline, and terminate owned work itself rather than relying on request.into or inactivity timeouts. (Merged 2026-10-16 from 2 entries; first found 2026-07-11, last 2026-07-11.)

<!-- applied-learning: a-userspace-deadline-check-cannot-hard-bound-a-later-blocking-kernel-commit -->
<a id="applied-learning-a-userspace-deadline-check-cannot-hard-bound-a-later-blocking-kernel-commit"></a>
**A userspace deadline check cannot hard-bound a later blocking kernel commit.** Checking `CLOCK_MONOTONIC` immediately before `rename`, `fsync`, ref-CAS, or another syscall still leaves a scheduling/blocking interval before the kernel linearization point; an interposed or stalled syscall can commit after the deadline. Do not respond by adding ever-closer prechecks and claiming a hard guarantee. Either use an OS primitive whose transaction is deadline/cancellation-bound, isolate the operation behind an owner the kernel can terminate before linearization, or define the public result as indeterminate with exact reconciliation/compensation. If none is available, record an assurance-layer architecture blocker rather than repeatedly rejecting otherwise correct local patches (found 2026-07-12 after benchmark R5 passed conservative BEAM/native deadline mapping but a delayed `renameatx_np` still published late).

<!-- applied-learning: separate-source-of-truth-commit-from-derived-state-synchronization -->
<a id="applied-learning-separate-source-of-truth-commit-from-derived-state-synchronization"></a>
**Separate source-of-truth commit from derived-state synchronization.** Git ref publication and real-index update are two independent durable resources; no ordinary Git primitive atomically commits both. Pick the authoritative commit, report an indeterminate/reconciliation-required result if the derived update fails, and make repair idempotent. Never return unconditional success after a best-effort derived update, but also do not demand impossible cross-resource atomicity from another local retry loop (clarified 2026-07-12 during reviewed-commit provenance R3).

<!-- applied-learning: enforce-the-narrowest-byte-limit-before-calling-a-broader-hashing-helper -->
<a id="applied-learning-enforce-the-narrowest-byte-limit-before-calling-a-broader-hashing-helper"></a>
**Enforce the narrowest byte limit before calling a broader hashing helper.** `TrustedPath.pin_root_owned_regular_file/2` intentionally permits and hashes files up to its generic 512 MiB ceiling; checking a manifest-specific 32 MiB limit only after that pin still performs the expensive read. Preflight the exact file with `lstat`, reject its type, link count, mode, and size first, then require the pinned identity to match that observation so the early bound does not create a TOCTOU gap (found 2026-07-14 reviewing the Linux dependency-baseline source verifier).

<!-- applied-learning: prove-resource-absence-positively-do-not-reinterpret-an-arbitrary-lookup-failure-as-absence -->
<a id="applied-learning-prove-resource-absence-positively-do-not-reinterpret-an-arbitrary-lookup-failure-as-absence"></a>
**Prove resource absence through an authoritative successful observation.** Release ownership or output only after a successful complete bounded inventory excludes the exact owned identifier, or a precisely specified not-found outcome proves absence. Preserve unknown on transport, permission, timeout, parse, or owner failures; a missing supervisor, failed snapshot, child DOWN, or restart is never an empty inventory. Reconstruct ownership from durable records and use an independent recovery transport when the original owner disappears. For OS probes, distinguish permission denial from confirmed nonexistence. For Git refs, parse structured exact-full-ref records, reject warnings and malformed output, and reread after compare-and-delete failure: absent is idempotent success, a changed OID is a compare-and-swap mismatch, and the unchanged OID is an operational failure. Bound inventory time as well as output, account for cancellation, and use the cheapest source-owned projection that proves the needed fact. (Merged 2026-10-16 from 4 entries; first found 2026-07-11, last 2026-07-20.)

<!-- applied-learning: keyset-pagination-must-bound-the-base-relation-before-expensive-joins-or-sorts -->
<a id="applied-learning-keyset-pagination-must-bound-the-base-relation-before-expensive-joins-or-sorts"></a>
**Keyset pagination must bound the base relation before expensive joins or sorts.** A joined query with `WHERE id > cursor ORDER BY id LIMIT n` can still scan and sort the entire remaining relation, especially after bulk staging with stale statistics. Materialize the exact cursor page first, index and analyze its cursor columns, then join that bounded page; validate the full-scale plan with `EXPLAIN (ANALYZE, BUFFERS)` and inspect temporary I/O. The EventLog identity preflight spilled about 190 GiB before mutation until this was fixed (found 2026-07-15 during the EventLog cutover).

<!-- applied-learning: a-fixed-internal-operation-that-needs-a-generically-blocked-flag-belongs-behind-a-closed-facade-primitive -->
<a id="applied-learning-a-fixed-internal-operation-that-needs-a-generically-blocked-flag-belongs-behind-a-closed-facade-primitive"></a>
**A fixed internal operation that needs a generically blocked flag belongs behind a closed facade primitive.** Do not make a business module call `Arbor.Shell.execute_direct(..., sandbox: :none)` because a generic facade correctly rejects `--force` or a similar flag. Add an exact operation to the owning facade, retain its executable/config/storage hardening there, expose no caller-controlled argv, and keep the generic dispatch surface restricted (found 2026-07-16 reviewing Git worktree cleanup).

<!-- applied-learning: a-per-command-timeout-is-not-an-overall-operation-deadline -->
<a id="applied-learning-a-per-command-timeout-is-not-an-overall-operation-deadline"></a>
**Propagate one absolute deadline through each semantic operation phase.** Start timing before runner setup, pass only the remaining monotonic budget to nested calls, and recheck after every child, including the final nominally successful child; reject observations at or beyond expiry. Reusing a full timeout for each command permits total work to grow with command count. Keep setup, worker execution, cancellation, and cleanup budgets distinct so a short worker budget does not accidentally govern unrelated reconstruction. Derive admission-probe subdeadlines as the minimum of operation remaining time and the reviewed 300,000 ms probe maximum, without clamping the whole operation deadline to that probe ceiling or renewing elapsed time afterward. Inject the same clock seam in boundary tests so scheduling cannot manufacture budget mismatches. (Merged 2026-10-16 from 3 entries; first found 2026-07-11, last 2026-07-17.)

<!-- applied-learning: optional-deadline-controls-must-preserve-legacy-clock-sampling-order -->
<a id="applied-learning-optional-deadline-controls-must-preserve-legacy-clock-sampling-order"></a>
**Optional deadline controls must preserve legacy clock sampling order.** Adding an
earlier monotonic-clock read only for a new optional whole-operation deadline can
consume an injected test sample and change the established stage deadline. The
result is a behavioral regression even when the new option is absent, such as
moving a CrossApp capacity failure from runtime handoff to structural admission.
Derive optional deadlines without perturbing legacy samples when the option is
unset, and regress the nil/default path with the exact existing clock sequence
(found 2026-07-27 while adding terminal-gate budget projection).

<!-- applied-learning: receipt-encoding-must-preserve-authoritative-policy-identity -->
<a id="applied-learning-receipt-encoding-must-preserve-authoritative-policy-identity"></a>
**Keep receipt encoding separate from authoritative policy identity.** Project recognized tagged structs explicitly with `Map.from_struct/1` before recursive JSON encoding; `is_map/1` does not establish `Enumerable` support. Refuse unknown struct types rather than silently flattening them. Preserve the original raw policy term for its authoritative fingerprint instead of fingerprinting the receipt representation. Exercise receipt encoding against the actual public snapshot before acceptance effects. (Extracted 2026-10-16 from test-facades-must-observe-production-ownership-not-reimplement-it; first found 2026-09-24.)

<!-- applied-learning: separate-jido-action-names-from-plugin-registry-aliases -->
<a id="applied-learning-separate-jido-action-names-from-plugin-registry-aliases"></a>
**Separate Jido action names from plugin registry aliases.** Jido validates
action names as letters, digits, and underscores; the locked ActionRegistry
requires dotted plugin names. Keep the module's `name` valid for Jido and
register it under a dotted alias, then use that alias in execution bindings
and DOT fixtures (found 2026-10-08 while fixing provenance test registration).

<!-- applied-learning: derive-loop-counters-from-their-prior-control-value -->
<a id="applied-learning-derive-loop-counters-from-their-prior-control-value"></a>
**Derive loop counters from their prior control value.** An action that reads
both a trusted counter and untrusted model or test output gives its whole result
the combined untrusted provenance. Hoisting its returned counter into the next
action's control parameter then fails closed on the second retry. Use a pure
`increment` transform from the prior counter for loop control, while keeping
the action's model and test feedback as data (found 2026-10-09 in the LM Studio
TDD RLE example).
