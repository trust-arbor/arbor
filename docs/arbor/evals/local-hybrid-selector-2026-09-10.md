# Local hybrid relevance selector measurement — 2026-09-10

Gemma 4 12B with constrained JSON output passed the original and supplemental
controls. On the independent holdout it retrieved 11 of 12 relevant passages,
returned no incorrect records, and correctly abstained on 11 of 12 negatives;
the remaining negative timed out. This supports an opt-in experimental route,
with a known partial-information recall miss and an availability limitation.
It is not a claim of perfect retrieval, general prompt-injection resistance,
or a completed live Arbor deployment.

## Fixed procedure

The embedding route was local Ollama `embeddinggemma:latest`, native 768 dimensions
(weight digest `85462619ee721b466c5927d109d4cb765861907d5417b9109caebc4e614679f1`).
The selector used LM Studio's OpenAI-compatible endpoint at literal
`127.0.0.1:1234/v1`. Its downloaded model metadata identified
`gemma-4-12b-it-qat`, Unsloth Gemma 4 12B Instruct QAT UD, GGUF Q4_K_XL,
6,925,877,568 bytes, reported context limit 262,144. The local inventory exposed
no cryptographic weight digest for this selector; the model ID is not immutable
model attestation. No cloud request, download or private transcript was used.

Each query embedded `[query | all documents sorted by opaque ID]` as one batch.
The scoring mirror used the committed whole-token keyword rule, float32 vectors,
70% cosine plus 30% keyword overlap, both floors explicitly zero, and a shortlist
of eight. The source defaults were unchanged. Known fixture labels were not
shown to the model: IDs were opaque SHA-256-derived strings. Shortlisting and
final selection were measured separately, with every positive in the denominator.

The fixed `knowledge-relevance-v1` prompt hash was
`1eac3962d07455b32ea44c163c58cee5eb9e35d86338084b67dc0610d746cd3e`.
After development exposed fenced JSON, transport policy v2 added the provider's
`response_format` with a strict closed JSON schema: required `selected_ids`,
array of exact shortlist-ID enum values, zero to shortlist-size entries, and no
additional properties. The raw decision validator continued rejecting fences,
extra/duplicate keys, unknown/duplicate IDs, unfinished output and oversize text.
This was constrained generation, not output repair. The prompt did not change.
The full schema for every v2 request is retained in the measurement data.

All runs used temperature zero and omitted `max_tokens`, leaving the supported
model budget intact. Limits were 32 KiB for encoded input plus system text and,
in v2, response format; 64 KiB for the response; 4 KiB for raw decision text;
20 seconds for selector HTTP within a 30-second query budget. HTTP was literal
loopback with no proxy, redirect, retry or fallback. The initial cold 12B request
failed its 20-second budget. Later measurements followed prior model use and
must not be advertised as cold-start latency guarantees.

## Observed results

“Negative abstentions” counts only successful empty decisions. Errors remain in
the query denominator and never become abstentions. Each labeled case expects
one relevant record; no accepted result contained an extra record except the
recorded E4B Ann/Anna failure.

| Model / policy | Dataset | Positive shortlist hits | Positive final hits | Negative abstentions | False-acceptance queries | Errors |
| --- | --- | --- | --- | --- | --- | --- |
| Gemma E4B, unconstrained v1 | Original | 3/3 | 3/3 | 1/2 | 1 | 0 |
| Gemma E4B, unconstrained v1 | Supplemental | 21/21 | 16/21 | 6/7 | 1 | 5 |
| Gemma 12B, unconstrained v1 | Original | 3/3 | 0/3 | 1/2 | 0 | 4 |
| Gemma 12B, constrained v2 | Original, full development run | 3/3 | 3/3 | 2/2 | 0 | 0 |
| Gemma 12B, constrained v2 | Supplemental | 21/21 | 21/21 | 7/7 | 0 | 0 |
| Gemma 12B, constrained v2 | Independent holdout | 12/12 | 11/12 | 11/12 | 0 | 1 |

The supplemental v2 run had median total latency 14.19 seconds and maximum
20.12 seconds, including embedding. The holdout had median 9.16 seconds and
maximum 20.16 seconds, including the timed-out request. Actual token usage and
all individual timings are retained in the data. No monetary-cost claim is made.

E4B's five supplemental errors were fenced JSON; it also selected Anna for “Ann.”
The unconstrained 12B original run had one cold timeout and three fenced decisions.
Those failures were retained rather than rewritten as successful classifications.

## Independent holdout and limits

A separate author froze 12 practical synthetic documents and 24 queries before
seeing any selector output, SHA-256
`413920c4afe0dbc54d42efcfbef08837b4408f12cf147145c1c9a0a9ab352f88`.
The author consulted only the original corpus to avoid repeating its software
domains. Neither labels nor the prompt were changed after holdout results.

The missed positive was `p_rolls_missing_temperature`: the rolls passage was
relevant to the recipe but did not give the requested baking temperature. It
reached the shortlist, but the selector returned empty. This is a relevance
miss, not a relabeled successful abstention. Negated-fact positives were
retrieved correctly. The instruction-bearing exhibit card selected only its
legitimate record, but one example does not prove injection immunity.

The `n_mina_patient` negative timed out. It was not retried. The runner stopped,
then observed the exact model's existing `lms ps --json` status as idle with zero
queued work before issuing the eleven remaining, previously unattempted queries.
Both result segments are retained; together they contain each of the 24 frozen
queries exactly once. The timeout is neither a false acceptance nor a successful
abstention. The other five absent near-name entities and all six unrelated
queries returned empty. No observed holdout result substituted another entity.

No numerical holdout pass threshold was predeclared. The frozen protocol required
separate reporting of the original, supplemental and independent sets, their full
denominators, false acceptances, misses and errors. Practical acceptance therefore
requires an explicit review of these measured tradeoffs; a perfect-score criterion
must not be invented or relaxed after results. This small synthetic sample does
not estimate real-world error rates or establish privacy/authority enforcement.

## Evidence boundary

The [compact measurements](data/local-hybrid-selector-2026-09-10.json) retain the
synthetic corpus, exact query labels, opaque IDs, schema, raw decisions, errors,
usage and source-artifact hashes. The committed
[`selector_holdout.json`](../../../apps/arbor_memory/priv/eval_datasets/knowledge_hybrid/selector_holdout.json)
retains the independently frozen examples.

These model measurements used direct local HTTP and a Python scoring mirror.
Separate offline public Memory/LLM tests exercise prepared HTTP, actual graph
provenance, capability revocation, changed snapshots, strict decisions and
transport restrictions. A configured, deployed public-facade canary remains a
separate acceptance step. Hybrid is disabled by default, and no live setting was
changed for this measurement. Model quality does not supply authorization or
turn agent-global knowledge into human-owned private memory.
