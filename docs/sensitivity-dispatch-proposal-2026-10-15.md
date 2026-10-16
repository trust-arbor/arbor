# FINDING-011: sensitivity enforcement at outbound model effects

Date: 2026-10-15. Status: **needs decision; finding remains open**.
Source revision: `56e45390ba118ee25fc42890866d911d0b7072c2`.

This is a proposal, not an implemented security gate. The security task's
design-first stop condition applies because the available classifiers disagree
on which content may reach trusted cloud providers. The task also requires a
policy decision before choosing caller exemptions. No production behavior or
tests were changed.

## What fits the current hierarchy

`arbor_llm` (L2) already depends on `arbor_kernel_runtime` (L1), which owns
`Arbor.Common.SensitiveData` and `Arbor.Common.SensitivityClassifier`.
Classification can therefore run locally without adding an application
dependency. `arbor_ai` (L4) owns `BackendTrust` and already exposes
`Arbor.AI.can_handle_sensitivity?/3`, `sensitivity_routing_decision/4`, and
`egress_tier_for/2`. It depends on `arbor_llm`, so adding the reverse dependency
would create a cycle.

A library-owned policy behaviour under `Arbor.LLM.Contracts`, selected by
`Arbor.LLM.Config`, can accept an implementation in `arbor_ai` at runtime.
That is consistent with CONTRACT_RULES sections 2, 8, and 9; it does not need a
new kernel contract or an `arbor_llm -> arbor_ai` Mix dependency. The adapter
must use the AI facade rather than import `Arbor.AI.BackendTrust`.

The ReqLLM adapter's `run_pipeline_call/6` is a useful common point for
`:complete`, `:stream`, `:embed_cloud`, and `:embed_local`. A sensitivity plug
belongs before their real transport effects. This is a viable implementation
slice after the policy below is settled, but it would cover only ReqLLM.

## Why a plug alone does not close the finding

1. `Adapter.OAuthResponses.do_complete/3` calls `OAuth.Responses` directly;
   `Adapter.LmStudio` has its own direct HTTP transport. Neither traverses the
   ReqLLM plug pipeline. Client also accepts custom adapters.
2. `Arbor.AI.Runtime.Acp.execute/3` checks out a CLI session and sends the
   prompt outside ReqLLM. `Arbor.AI.LLM.Adapter.Acp` is another Client adapter
   entry into ACP. Process locality does not establish the CLI's eventual model
   destination.
3. Client resolves the adapter before running completion/stream middleware.
   `complete_streaming/4` and its single-attempt variant bypass that middleware.
   A middleware-only patch cannot establish final transport identity for every
   API. The existing orchestrator-specific owner-bound wrapper addresses these
   details only for classified computes; it is not installed for direct callers.
4. `RateLimitBackoff` can invoke `Plugs.Dispatch` again directly. A policy
   check inserted once before the configured pipeline is not automatically a
   fresh decision for a later effect. A policy refusal must also be terminal
   through provider fallback, including the legacy embedding fallback.
5. `Request` has no sensitivity field; `build_req_opts/2` and embedding option
   construction omit `:sensitivity`. The model tuple at the plug can identify
   Ollama/LM Studio as an OpenAI-compatible transport. A plug must receive the
   original provider, actual endpoint, classification floor, and final model
   through private Call metadata, rather than infer them from that tuple alone.

These are source observations, not a claim that a live cloud request was made.
See `apps/arbor_orchestrator/docs/sensitivity_effect_boundary.md` for the
existing per-compute guarantees and exclusions.

## Decisions required before implementation

| Decision | Existing evidence | Recommendation |
| --- | --- | --- |
| Classification authority | Common's `SensitivityClassifier` labels Anthropic/OpenAI API keys, config passwords and JWTs confidential, and SSNs/cards restricted. Orchestrator `TaintCheck` labels the former restricted and the latter confidential. `SensitiveData.scan_all/1` returns labels, not sensitivity. | Admit one conservative mapping: preserve the higher existing classification for each detected category, so both secrets and SSNs/cards are restricted. Reuse a lower-level production owner through DI; do not copy the orchestrator's internal mapping into LLM. This changes policy for some existing cloud calls and needs explicit agreement. |
| Caller-supplied labels | FINDING-011 suggests scanning unless `sensitivity:` is present. A plain `sensitivity: :public` could then suppress detection. Persisted restricted prose may have no recognizable pattern. | Treat valid supplied sensitivity as a floor and join it with scanning and recorded taint; never permit a supplied label to lower the result. Refuse malformed present labels. Missing labels trigger scanning, while callers with recorded classification must propagate it. |
| Scope and exemptions | System callers, evals, OAuth, custom adapters, and ACP currently have different paths; some calls intentionally reach cloud providers. | Require admission for all real outbound model and embedding effects. Grant no request-level opt-out. Keep verified replay/hash-only operations local and explicit. Refuse an unresolvable custom/ACP destination until its host-owned integration supplies evidence. Confirm that this includes eval and system callers. |
| Destination authority | `can_handle_sensitivity?/3` checks provider/model capabilities but accepts no endpoint; `egress_tier_for/2` describes locality, not data clearance. A local endpoint can proxy an Ollama `:cloud` model. | Require both final endpoint classification and provider/model clearance. Loopback alone must not grant restricted clearance to a cloud-proxy model. Define an explicit host policy for on-premises/private-cloud destinations rather than silently equating them to local inference. |

No additional kernel contract is proposed. No new dependency or forbidden
internal import was added. These decisions should be recorded by the integrator
in the separate `.arbor` repository; this worktree does not contain it.

## Options and trade-offs

| Option | Benefit | Limitation |
| --- | --- | --- |
| ReqLLM sensitivity plug only | Smallest transport slice; covers all four ReqLLM operations with an injected policy and local scanner. | OAuth, owned/custom adapters, ACP, dropped record labels, and ungated retries remain. Can only be reported as partially fixed. |
| Shared admission plug plus integration at every effect (recommended) | One classification/admission policy, applied by ReqLLM and other transport/runtime owners; preserves the plug pattern and dependency hierarchy. | Requires the decisions above, metadata propagation, caller migration, and tests for each real transport. Multiple owners must wire the same gate. |
| Move routing ownership into the lower library | Could centralize policy and transport together in a later architectural change. | Relocates existing AI responsibilities/configuration, broadens the patch, and risks creating new shared contracts. Not appropriate for this fix. |

Use refusal as the first transport-level behavior. Keep rerouting in the existing
selection layer, before transport options and credentials are prepared; admit the
replacement independently. A reroute result is not permission to send to the
original provider. Treat policy load/call errors, exits, malformed results, or
unresolved destination evidence as fixed, content-free denials. Never reuse
`maybe_reroute/4`: it returns the original pair on `:blocked`. Also do not accept
`decide/4`'s `:proceed` blindly: without qualified candidates it currently keeps
the original disallowed provider. Final admission must verify clearance itself.

Make admission mandatory at each actual effect, even when a configured pipeline
omits the ordinary default plugs, and repeat it on retries. For ReqLLM, retain a
dedicated sensitivity plug and have Dispatch ensure it has admitted the exact
effect immediately before network execution. This must not turn Dispatch into a
business-policy owner. Bind the resolved transport before middleware can change
provider/model, and recheck final content/model/endpoint rather than trusting an
earlier candidate decision. Private metadata must not become provider JSON,
fixture content, error payloads, or telemetry containing prompt bytes.

## Caller inventory and migration

Counted producer **files**, not raw text matches or individual calls. The census
found **25 ordinary producer files** using the AI/LLM completion or embedding
APIs outside their transport/bridge implementations without a dedicated
sensitivity gate, **one optional configured embedding producer**, and **two
separately local-gated producer files**. Ten eval producer files are listed
separately. This count does not assert all paths are enabled or that every
call currently selects a cloud provider. Capabilities/Trust egress checks are
separate controls and do not establish recorded-content sensitivity routing.

All paths below are relative to the repository root. Line anchors identify
runtime calls at the source revision above.

| App | File and call anchors | Migration |
| --- | --- | --- |
| memory | `apps/arbor_memory/lib/arbor/memory/memory_store.ex:927,1120` | Pass query/record sensitivity and principal to embeddings; keep the floor through async work. |
| memory | `apps/arbor_memory/lib/arbor/memory/summarizer.ex:207` | Carry the maximum record sensitivity into the summary request; current fixed opts discard extra context. Highest-priority generation path. |
| memory | `apps/arbor_memory/lib/arbor/memory/fact_extractor.ex:480` | Extend the option projection to preserve source sensitivity, not only provider/model/timeouts. |
| memory | `apps/arbor_memory/lib/arbor/memory/reflection_processor.ex:589` | Pass sensitivity and real principal; current local `agent_id` used for reporting is absent from `llm_opts`. |
| memory | `apps/arbor_memory/lib/arbor/memory/context_window/compression.ex:431,594` | Join the source labels for both compression generation and embeddings. |
| memory | `apps/arbor_memory/lib/arbor/memory/retrieval.ex:126` | Preserve query sensitivity for embedding. |
| memory | `apps/arbor_memory/lib/arbor/memory/knowledge_graph.ex:1429` | Carry the node's sensitivity to embedding. |
| memory | `apps/arbor_memory/lib/arbor/memory/knowledge_graph/graph_search.ex:863` | Carry query/node sensitivity rather than an empty opts list. |
| memory | `apps/arbor_memory/lib/arbor/memory/action_patterns.ex:357` | Preserve source-pattern classification through the injected client (default AI); current `Keyword.take` drops it. |
| memory | `apps/arbor_memory/lib/arbor/memory/index.ex:2196` | Carry record/query classification through the provider seam (default AI); keep the deterministic local-hash fallback local. |
| agent | `apps/arbor_agent/lib/arbor/agent/heartbeat_llm.ex:131` | Carry heartbeat/goal/memory sensitivity into the AI call. |
| agent | `apps/arbor_agent/lib/arbor/agent/context_summarizer.ex:199` | Join conversation labels and existing-summary sensitivity. |
| agent | `apps/arbor_agent/lib/arbor/agent/context_compactor.ex:1305` | Preserve the classification floor through the injected summarizer and production default. |
| agent | `apps/arbor_agent/lib/arbor/agent/action_cycle_server.ex:759` | Include action context and retrieved-content sensitivity in the closure's opts. |
| agent | `apps/arbor_agent/lib/arbor/agent/api_agent.ex:438` | Carry prompt/history labels into tool-enabled generation and join tool-result labels for every next model attempt. |
| agent | `apps/arbor_agent/lib/arbor/agent/simple_agent.ex:277` | Gate direct `LLM.generate` turns, including messages appended from tool results. It is still a direct caller at HEAD. |
| actions | `apps/arbor_actions/lib/arbor/actions/ai.ex:194,196,338,340` | GenerateText/AnalyzeCode must preserve context taint on both authorized and no-agent system branches. Capability checks alone do not classify content. |
| actions | `apps/arbor_actions/lib/arbor/actions/skill.ex:568` | Carry skill/source sensitivity through the configured AI facade. |
| actions | `apps/arbor_actions/lib/arbor/actions/judge/evaluate.ex:270` | Preserve evaluation-input sensitivity through the production default and injected seam. |
| consensus | `apps/arbor_consensus/lib/arbor/consensus/llm_bridge.ex:226,274` | Preserve the same floor through direct Client and AI/ACP fallback paths. |
| consensus | `apps/arbor_consensus/lib/arbor/consensus/topic_matcher.ex:177` | Join description/context sensitivity before classification generation. |
| consensus | `apps/arbor_consensus/lib/arbor/consensus/evaluator/llm.ex:133` | Propagate proposal/evidence labels through the configured AI module. |
| consensus | `apps/arbor_consensus/lib/arbor/consensus/evaluator/runtime_fix.ex:82` | Propagate diagnostic/proposal labels through the configured AI module. |
| ai | `apps/arbor_ai/lib/arbor/ai/comms_responder.ex:45` | Preserve inbound message/history classification regardless of backend configuration. |
| gateway | `apps/arbor_gateway/lib/arbor/gateway/intent_extractor.ex:131` | Carry ingress classification into intent extraction; gateway classification does not automatically gate this direct call. |
| kernel_runtime (optional) | `apps/arbor_kernel_runtime/lib/arbor/common/skill_library.ex:958` | Configured `:skill_embedding_module` defaults to nil; when enabled, preserve skill sensitivity through `embed/2`. Do not add an upward Mix dependency. |
| memory (already local-gated) | `apps/arbor_memory/lib/arbor/memory/hybrid_search.ex:70,121` | Retain loopback route validation, egress taint authorization and live-pipeline requirements for embedding and selector generation; add classification propagation without relaxing them. |
| orchestrator (already local-gated) | `apps/arbor_orchestrator/lib/arbor/orchestrator/session/private_memory/embedding.ex:57` | Retain loopback/locality, private-memory authorization and live-pipeline guarantees. |

Embedding defaults currently choose the first configured provider in
`Arbor.AI.snapshot_embedding_config/1`. The finding reports that provider as local
in the reviewed deployment. This is a deployment mitigation, not a per-request
sensitivity guarantee, and the explicit provider can override the default.

Eval producers also need the agreed policy, rather than an implicit exemption:

- `apps/arbor_agent/lib/arbor/agent/eval/agent_task_judge.ex:52`
- `apps/arbor_agent/lib/arbor/agent/eval/effective_window_eval.ex:240`
- `apps/arbor_agent/lib/arbor/agent/eval/summarization_eval.ex:632`
- `apps/arbor_agent/lib/arbor/agent/eval/corpus_generator.ex:580`
- `apps/arbor_agent/lib/arbor/agent/eval/trial_runner.ex:188`
- `apps/arbor_agent/lib/arbor/agent/eval/opencode_zen_live.ex:129`
- `apps/arbor_agent/lib/arbor/agent/eval/security_review/runner.ex:252`
- `apps/arbor_ai/lib/arbor/ai/eval/graders/intent_conformance.ex:232`
- `apps/arbor_orchestrator/lib/arbor/orchestrator/eval/subjects/spec_to_dot.ex:99`
- `apps/arbor_llm/lib/arbor/llm/eval/subject.ex:657`

Two entries in the original finding are documentation examples rather than
concrete production API calls: `Common.LazyLoader` and
`Authoring.DotGenerator`. DotGenerator actually invokes a supplied closure;
that caller must propagate conversation sensitivity when supplying an AI
backend. The diagnostic Mix task `arbor/eval_stream_check.ex:41,45` invokes AI
over RPC and belongs to the same policy when used. Transport/bridge modules
(`UnifiedBridge`, runtime adapters, embedding backend wrappers) are enforcement
integration points, not extra producer files in the count above.

## Implementation and regression sequence after decision

1. Commit a behavioral failing regression in `arbor_llm` first, then implement
   the plug and private metadata transport with a library-owned injected policy.
   The principal test must call `Arbor.LLM.generate/1` with restricted content
   and an external route, exercise the production policy implementation through
   DI, and prove zero request receipt at the local transport fixture. Do not
   replace the policy itself with a double for the only proof.
2. Cover automatic scanning of the system prompt, history, tool results,
   arguments/schema/descriptions, and embedding batches; cover recorded
   restricted prose with no detectable pattern and `sensitivity: :public`
   alongside detected secrets. Refuse invalid present labels and unavailable,
   throwing, exiting or malformed policies. Include trusted local success.
3. Prove streaming callback/lazy-stream paths and both single-attempt variants,
   policy changes during retry, custom configured pipelines, changed
   provider/model/endpoint, remote overrides of local providers, and loopback
   cloud-proxy models. A denial must not be retried as transient failure or
   converted into a fallback cloud request.
4. Apply the shared admission plug at OAuth/owned-adapter and ACP/runtime
   effects, including fallback attempts. Preserve exact route identity and
   existing egress authorization. A Client middleware alone is insufficient.
   Test each real implementation through its public facade with local fixtures.
5. Migrate memory generation first (summarizer, compression, reflection,
   extraction), then embeddings, agent context/tool loops, actions, consensus,
   communications/ingress, optional integrations and evals. For each app, commit
   its regression alone and observe red before its implementation commit.
6. Verify compile with warnings as errors, format, and full touched-app suites
   through the security wrappers. Keep the live daemon and `.arbor` repo alone.

The report accompanying this proposal records validation actually run. No
red-to-green proof exists for this proposal, and FINDING-011 must not be closed
or downgraded on the strength of this document.
