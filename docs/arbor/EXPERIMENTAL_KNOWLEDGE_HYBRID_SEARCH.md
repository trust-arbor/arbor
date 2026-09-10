# Experimental knowledge hybrid search

Status: opt-in API implementation with local selector measurement, 2026-09-10.
The [measured model report](evals/local-hybrid-selector-2026-09-10.md) records
positive retrieval, abstention, one missed passage and one timeout. This API has no Action/tool, ordinary turn, or private recall
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
clamped to [-1, 1]. Keyword score is the fraction of distinct query tokens also
present as whole tokens in the content. Both sides use Unicode lowercase and NFC
normalization. A token begins with a Unicode letter or number and continues
through letters, numbers and combining marks. Punctuation, including hyphens,
underscores and apostrophes, separates tokens. Repeating a query token cannot
increase its weight; a query with no tokens has keyword score zero. There is no
stemming, stopword list, language-specific segmentation or name inference.
The combined score is
`semantic_weight * semantic + (1 - semantic_weight) * keyword`. The default
weight is 0.7 (keyword 0.3); operator configuration may choose [0, 1]. Both the
cosine and combined floors must pass. Results sort by combined score descending,
then ID. Measurements record selected model/provider, dimensions, both weights,
applied floors, corpus digest, eligible count, input bytes, elapsed milliseconds,
and actual bounded provider usage. No defaults constitute a quality claim.

The whole-token correction prevents incidental keyword boosts such as `Ann`
matching `Anna`, `channel` or `cannot`. It changes only this explicit hybrid
score; legacy substring recall, legacy semantic search and exact name/alias
resolution retain their contracts. It does not establish a relevance cutoff or
make semantic similarity an entity-identity check. The
[2026-09-10 local model comparison](evals/ollama-embedding-comparison-2026-09-10.md)
measured the earlier substring keyword formula; its cosine rankings remain
applicable, but its hybrid scores describe that recorded revision. Even without
the erroneous keyword boost, the measured false-name cosine exceeds the intended
transaction passage's cosine. Topical-negative abstention therefore requires an additional acceptance
selector and independent validation; lowering global cutoffs
or relabeling every result as a candidate does not complete that work.

## Optional local relevance selection

The operator may add a closed `selector` configuration. This is an additional
acceptance stage; the existing score floors and caller tightening still apply.
The following explicit evaluation configuration lets low-scoring paraphrases
reach the selector. It is not an activation or a claim that these models have
passed the acceptance corpus:

```elixir
config :arbor_memory, :hybrid_knowledge_search,
  enabled: true,
  provider: "ollama",
  model: "embeddinggemma:latest",
  base_url: "http://127.0.0.1:11434/v1",
  timeout_ms: 30_000,
  min_cosine: 0.0,
  min_score: 0.0,
  semantic_weight: 0.7,
  selector: [
    provider: "lm_studio",
    model: "gemma-4-12b-it-qat",
    base_url: "http://127.0.0.1:1234/v1",
    candidate_limit: 8,
    timeout_ms: 20_000
  ]
```

The persistent dev/prod environment bridge can project this same route after a
managed restart. Every model and endpoint is explicitly selected by the operator:

```dotenv
ARBOR_HYBRID_MEMORY_ENABLED=true
ARBOR_HYBRID_MEMORY_PROVIDER=ollama
ARBOR_HYBRID_MEMORY_MODEL=embeddinggemma:latest
ARBOR_HYBRID_MEMORY_BASE_URL=http://127.0.0.1:11434/v1
ARBOR_HYBRID_MEMORY_TIMEOUT_MS=30000
ARBOR_HYBRID_MEMORY_MIN_COSINE=0
ARBOR_HYBRID_MEMORY_MIN_SCORE=0
ARBOR_HYBRID_MEMORY_SEMANTIC_WEIGHT=0.7
ARBOR_HYBRID_MEMORY_SELECTOR_PROVIDER=lm_studio
ARBOR_HYBRID_MEMORY_SELECTOR_MODEL=gemma-4-12b-it-qat
ARBOR_HYBRID_MEMORY_SELECTOR_BASE_URL=http://127.0.0.1:1234/v1
ARBOR_HYBRID_MEMORY_SELECTOR_TIMEOUT_MS=20000
ARBOR_HYBRID_MEMORY_CANDIDATE_LIMIT=8
ARBOR_OLLAMA_CHAT_BASE_URL=http://127.0.0.1:11434/v1
ARBOR_LM_STUDIO_BASE_URL=http://127.0.0.1:1234/v1
```

An unset enable flag preserves programmatic configuration. Exact `false` disables
hybrid search and ignores companion variables. Exact `true` requires the embedding
provider/model/URL and the LM Studio selector provider/model/URL. Numeric omissions
retain the source defaults (total timeout 10,000 ms, cosine 0.7, score 0.6, semantic
weight 0.7, selector timeout 20,000 ms, shortlist 8); the zero floors above are an
explicit measured configuration, not new defaults. Invalid values fail config
loading with key-only errors. Test configuration ignores hybrid and LM Studio
endpoint activation. Existing dotenv loading remains unchanged.

The final two variables configure the existing trusted provider endpoints
separately. A hybrid search URL does not silently confer endpoint trust. An unset
`ARBOR_LM_STUDIO_BASE_URL` preserves that provider's programmatic configuration;
its ordinary default remains `http://localhost:1234/v1`. Endpoint admission and
literal-loopback checks still run in the owners. Different installed embedding
models must satisfy the current 768-dimensional contract. No loader starts a
provider, loads a model, changes capabilities, or enables an Action/tool.

Selection is opt-in and the existing default remains disabled. Omitting
`selector` retains threshold-only experimental behavior. The first selector
route supports LM Studio with an explicit literal-loopback endpoint and model;
embedding providers remain configurable. A loopback Ollama server may proxy a
cloud-model tag, so this slice does not admit Ollama selector models solely
because their server address is local. The operator must own and trust the
selected local inference server; an HTTP address is not remote-code attestation.

The complete eligible inventory is still embedded. At most eight ranked records
passing the configured/caller floors enter selection, independent of the caller's
output limit. Candidate contents are complete JSON data, with a fixed versioned
system instruction. The encoded data, constrained response format and that
instruction must together fit 32,768 bytes;
excess causes refusal instead of silently truncating text or dropping records.
A lower `candidate_limit` (1–8) is an explicit retrieval tradeoff and its shortlist
recall must be measured. The output limit is applied after validating the entire
selection, including IDs beyond that output limit.

The only accepted decision is a single JSON object with one `selected_ids` array:
unique exact IDs from this call's shortlist, in relevance order. Empty means
abstention and is never backfilled from embedding results. Duplicate keys,
unknown/duplicate IDs, extra fields, prose, code fences, incomplete responses and
oversized decisions are errors. An error is distinct from a successful empty
result. The selector can select records; it cannot create text, change payloads,
upgrade taint/provenance, write links or confer ownership/authority. These bounds
do not prove semantic relevance or immunity to prompt injection.

The selector uses one source-owned, tool-free public LLM completion through a
captured stock pipeline. It sends a strict JSON-schema response format with
`selected_ids` restricted to the exact candidate IDs. This constrains provider
generation; it never replaces validation of the original assistant text. The
restricted LLM mode admits only this option class through a closed format wrapper
and a bounded schema subset: objects with explicit required properties and no
additional properties, bounded arrays, string enums and primitive types. Schema
references, dynamic keywords, extensions and other provider options are refused.
Supplied Clients, tools, nested provider overrides, named eval fixtures, streaming,
and custom/replay pipelines are refused in this restricted mode. Existing single-attempt dispatch disables retries, and redirects are
refused after provider preparation. The provider must report an explicit normal
stop before legacy finish-reason normalization. Ordinary LLM calls retain their
existing compatibility. No `max_tokens` cap is guessed; supported output budgets
remain unchanged until measured. The provider response is bounded at 65,536 bytes
and decision text at 4,096 bytes. The selector LLM call receives at most 20
seconds and the remaining portion of the existing total deadline, whose maximum
is 30 seconds. Existing synchronous graph-authority waits retain the ownership
and blocked-read limitation described above; this does not make the whole
selection phase a hard wall-clock cancellation boundary.

Memory joins taints and reauthorizes local egress for the selector's actual model
and endpoint. Current read authority and the entire graph digest are rechecked
before the second dispatch and before publishing its result. A mutation or
revocation during selection refuses publication. Successful measurements add
`selection` with its provider/model, prompt version, shortlist IDs, returned IDs,
actual usage and elapsed milliseconds. Similarity scores remain diagnostic values,
not relevance probabilities.

The independent `selector_holdout.json` has 12 synthetic documents and 24 queries
(12 positive, 12 negative), frozen before any selector output was observed. It
covers absent similar-name entities, unrelated topics, relevant negated facts,
a relevant passage missing a requested detail, and quoted malicious instructions.
All positive queries remain in the denominator even when shortlisting loses the
relevant document. Evaluate shortlist recall, final relevant retrieval, incorrect
accepted records, negative-query false acceptance, successful abstention, errors,
usage and cold/warm latency separately. Do not relabel known cases after model
results or count transport failure as successful abstention.

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

Further model measurement requires the operator-provided local endpoint or
exported embedding results with model identity and exact input association.
For an endpoint, run this explicit facade on the synthetic corpus only, retain
its returned measurements and corpus digest, and compare top-1 accuracy, recall
at 3, reciprocal rank, and irrelevant/false-name acceptance with the substring
baseline. Record exact model revision, weights, floors, latency, usage, and every
query result. An export can qualify ranking separately but cannot prove HTTP,
egress, or runtime route wiring. Do not expose a tool until that review selects
acceptable policy. The recorded synthetic model evaluation and a deployed
public-facade canary are separate evidence from offline admission tests.

Memory declares direct LLM (L2) and Trust (L4) dependencies for their public
facades. Memory remains L5; no Orchestrator/M2 dependency or internal cross-library
import is introduced. Qualification includes the committed dependency hierarchy
guard in addition to owning Memory/LLM behavior and surrounding controls.
