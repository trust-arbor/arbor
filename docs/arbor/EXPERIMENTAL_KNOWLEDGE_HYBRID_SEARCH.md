# Experimental knowledge hybrid search

Status: opt-in API implementation, 2026-09-09. Semantic model quality has not
been measured. This API has no Action/tool, ordinary turn, or private recall
wiring. Existing substring search and exact entity linking keep their behavior.

## Entry and configuration

Call `Arbor.Memory.authorize_hybrid_search(caller_id, agent_id, query, opts)`.
Current `arbor://memory/search` authority is required. As with the existing
Memory authorization facades, the caller identity must already have been verified
by the invoking boundary; this is not an unauthenticated network endpoint. The existing self-scoped
parent grant permits the caller's own agent graph; a different agent requires
its existing scoped capability. This is agent-global knowledge, with no new
human ownership claim. Private generic Recall remains refused by Actions.

The default is disabled. The operator may set this closed application config:

```elixir
config :arbor_memory, :hybrid_knowledge_search,
  enabled: true,
  provider: "lm_studio",
  model: "operator-selected-768-dimensional-model",
  base_url: "http://127.0.0.1:1234/v1",
  timeout_ms: 10_000,
  min_cosine: 0.7,
  min_score: 0.6,
  semantic_weight: 0.7
```

This is a configuration example, not a deployed model or measured threshold.
The provider must be `"lm_studio"` or `"ollama"`; the selected URL must pass the
existing public LLM endpoint admission and have a literal IPv4 loopback address
(127/8) or IPv6 `::1`. Existing provider defaults or the operator's
`:arbor_llm, :trusted_proxy_endpoints` must admit it. DNS names, including
`localhost`, and nonlocal endpoints are refused. No setting is changed by a call.
There is no cloud, hash, generic embedding, or keyword-only fallback.

The caller may supply only `types`, `min_relevance`, `limit`, `min_cosine`, and
`min_score`. Unknown or duplicate keys and malformed lists are refused. Types
come from the nine current graph node types; a type list may be empty. Numeric
thresholds are in [0, 1]. Caller score/cosine floors can only tighten the operator
floors. The caller cannot select a provider, URL, model, module, embedding,
request hook, credentials, weights, or taint.

Memory joins the authoritative candidate taints with the conservative missing
query taint and calls public `Arbor.Trust.authorize_egress/3`. Only `:allow`
continues. Current Security tier policy intentionally admits `:on_host`; this
packet does not reinterpret a profile's egress mode or claim that profile
`:block` denies loopback. The route and current read capability remain enforced.

## Live transport and consistency

Memory reads the current full authoritative graph inventory and deterministically
sorts eligible nodes by ID. A single public `Arbor.LLM.embed_batch/4` embeds
`[query | candidate_contents]`. The public result must retain association version
1, every exact ordered index, the selected provider/model, finite nonzero vectors,
and the current 768-dimensional VectorRecord contract. No generated vectors
are persisted or used to create links.

An early public LLM composition validator provides diagnostic refusal. The ReqLLM
adapter revalidates `require_live_pipeline: true` at embedding admission and
captures the stock pipeline for the call. It strips the restriction before HTTP.
Caller metadata cannot inject the captured pipeline. A custom, empty, reordered,
Record, Replay, or replacement dispatch composition is refused, never rewritten.
The stock named EvalReplay/EvalRecord plugs are inert for these embedding calls.
Admitted live embeddings reuse the source-owned single-attempt Call assignment:
Req retries are disabled after provider preparation and RateLimitBackoff cannot
redispatch through a configured callback.
Ordinary calls without the restriction retain configurable pipelines. A config
change affects later admissions; it cannot replace an admitted call's sequence.

Memory rechecks the capability immediately before HTTP admission. Before
publishing results, it rechecks the capability and the complete canonical graph
digest. Revocation or graph changes during the HTTP operation
refuse publication. This is a checked snapshot result, not a lock against a
mutation that commits after the final check.

This read does not add content, edges, vectors, or access-count reinforcement.
The existing graph authority's projection/admission bookkeeping and legacy
provenance CAS migration still apply. It does not bypass those recovery semantics
or claim that every possible legacy read has zero persistence effects.

## Bounds and result contract

| Quantity | Hard maximum or rule |
| --- | --- |
| Agent/caller labels | 256 UTF-8 bytes, nonblank |
| Query | 4,096 UTF-8 bytes, nonblank |
| Authoritative graph inventory | 64 nodes, matching the current durable codec ceiling |
| One eligible node content | 8,192 UTF-8 bytes, nonblank |
| Query plus all eligible content | 262,144 bytes |
| Batch | One query plus every eligible node, with exact indexed association |
| Provider response | 2,097,152 bytes; existing LLM structural bounds also apply |
| Result count | 10; caller may reduce to 1–10 |
| Complete result | 65,536 encoded JSON bytes plus bounded structural validation |
| Configured timeout | 1–30,000 ms, default 10,000 |

Overlarge inventories or content cause a refusal; the corpus is never silently
sampled or truncated to fit. Explicit type/relevance filters define eligibility.
An empty eligible inventory returns an empty measured result without HTTP.
The remaining budget is passed into the existing owned LLM deadline, with retries
and redirects disabled. Elapsed time is checked between phases and before
success. Existing graph authority waits retain their ownership/recovery semantics;
this is not a new hard wall-clock cancellation contract for a blocked graph read.

Success is `{:ok, %{strategy: :experimental_hybrid, results: [...],
measurement: ...}}`. Each entry contains the exact node `id`, durable JSON
`payload` projection, original provenance label (`taint` and `status`), and
`semantic`, `keyword`, and `combined` scores. Encoded metadata retains existing
codec tags. Source confidence and taint are not replaced by similarity scores.

Scoring is deliberately experimental. Semantic score is cosine similarity,
clamped to [-1, 1]; keyword score is the fraction of whitespace-separated query
terms appearing as case-insensitive substrings. The combined score is
`semantic_weight * semantic + (1 - semantic_weight) * keyword`. The default
weight is 0.7 (keyword 0.3); operator configuration may choose [0, 1]. Both the
cosine and combined floors must pass. Results sort by combined score descending,
then ID. Measurements record selected model/provider, dimensions, both weights,
applied floors, corpus digest, eligible count, input bytes, elapsed milliseconds,
and actual bounded provider usage. No defaults constitute a quality claim.

## Qualification and model-quality protocol

The committed `apps/arbor_memory/priv/eval_datasets/knowledge_hybrid/corpus.json`
contains synthetic agent-global records, three paraphrase labels, an irrelevant
query, and an Ann/Anna false-match control. Its deterministic basis vectors test
wiring through real prepared HTTP under Req.Test; they are not model embeddings
or semantic-quality measurements. The public tests also compare the unchanged
durable record before and after search, verify its provenance bindings, and
exercise byte limits, malformed responses, current authority, and stale results.
The Codec's conservative JSON size reservation is stricter than the aggregate
embedding ceiling for current durable graphs. That defensive aggregate branch
is tested as a pure decision; a valid durable corpus separately proves that a
result limit does not truncate embedding inputs. The actual HTTP 429 test is a
transport control: the pinned provider returns a ReqLLM error before Backoff's
recognized error forms, so it does not establish historical callback execution.

Genuine measurement still requires the operator-provided private local endpoint
or exported embedding results with model identity and exact input association.
For an endpoint, run this explicit facade on the synthetic corpus only, retain
its returned measurements and corpus digest, and compare top-1 accuracy, recall
at 3, reciprocal rank, and irrelevant/false-name acceptance with the substring
baseline. Record exact model revision, weights, floors, latency, usage, and every
query result. An export can qualify ranking separately but cannot prove HTTP,
egress, or runtime route wiring. Do not expose a tool until that review selects
acceptable thresholds. No live capture or endpoint call is part of this packet.

Memory declares direct LLM (L2) and Trust (L4) dependencies for their public
facades. Memory remains L5; no Orchestrator/M2 dependency or internal cross-library
import is introduced. Qualification includes the committed dependency hierarchy
guard in addition to owning Memory/LLM behavior and surrounding controls.
