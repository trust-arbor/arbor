# Local Ollama embedding comparison — 2026-09-10

## Decision

Use **Ollama with `embeddinggemma:latest` as the preferred local candidate**.
Provider, endpoint and model remain user configuration choices, not global
hardcoded defaults. No additional model download is justified by this small
comparison. Selection is provisional: calibrate retrieval acceptance before
enabling the new private/hybrid routes. No running Arbor configuration changed.

EmbeddingGemma has the strongest compatible ranking on this probe and returns
all relevant documents within the first three. Nomic is faster and remains a
reasonable alternative. mxbai has similar first-result accuracy but its native
1,024-dimensional output is incompatible with the current 768-dimensional
Memory contract; this experiment did not truncate any vectors.

## Measured results

Direct requests used `http://127.0.0.1:11434/v1/embeddings` on the existing
Ollama `0.33.3` daemon. The 37.606-second run made sequential requests to the
three already downloaded local models. No cloud model, download, personal record,
Arbor application startup, live memory write or runtime reload was involved.

The corpus contains the existing seven M6 documents and five queries plus
fourteen newly labeled synthetic documents and twenty-three queries:
**21 documents, 21 positive queries and 7 negative controls**. Labels were frozen
before model calls. Three proposed supplemental negatives were corrected before
execution because an unanswered question can still have a relevant document.

The table reports cosine-only ranking of raw inputs, as current private/hybrid
code sends them. Ranking is measured before filtering; these are not counts of
memories actually returned
by the configured Arbor consumer. Warm query latency is one direct embedding
HTTP request, without Arbor authorization/storage/prompt overhead.

| Model | Dimensions | Correct first result | Relevant within first 3 | MRR | Warm query median / p95 | Query + all 21 documents, median |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `nomic-embed-text:latest` | 768 | 19/21 | 20/21 | 0.935 | 9.6 / 23.0 ms | 107.9 ms |
| `embeddinggemma:latest` | 768 | 20/21 | 21/21 | 0.976 | 24.8 / 37.7 ms | 168.9 ms |
| `mxbai-embed-large:latest` | 1024 | 20/21 | 20/21 | 0.964 | 14.0 / 24.9 ms | 257.2 ms |

The first observed requests took 13.67 s for Nomic, 1.13 s for EmbeddingGemma,
and 13.64 s for mxbai. No models were resident at the initial inventory. These
are single observations, not a controlled cold-start benchmark. They do show
why warm latency alone cannot determine a first-call timeout.

For the original M6 subset alone, every model ranked 2/3 positives first and
3/3 within the first three. The deliberately ambiguous “all-or-nothing updates”
query retrieved the meeting distractor first. The extended corpus also made
Nomic place a backup passage above the intended crashed-child supervisor passage.
Existing whole-query substring recall finds none of the positive queries and
incorrectly matches `Ann` against text containing that substring.

### Acceptance is a separate unresolved issue

The hybrid figures below use the substring keyword formula at the recorded
source revision. The subsequent whole-token keyword repair changes that formula;
it does not change these measured cosine-only rankings or establish an acceptance
policy. See the [current scoring contract](../EXPERIMENTAL_KNOWLEDGE_HYBRID_SEARCH.md).

Applying that 70% semantic / 30% keyword ranking leaves first-result
counts unchanged. Before cutoff filtering, relevant-within-three counts become
19/21 for Nomic, 21/21 for EmbeddingGemma, and 20/21 for mxbai.

The example configuration in `EXPERIMENTAL_KNOWLEDGE_HYBRID_SEARCH.md` uses
`semantic_weight: 0.7`, `min_cosine: 0.7`, and `min_score: 0.6`. These were explicit
unmeasured example values, not calibrated production defaults. Mirroring that
formula and both cutoffs on the real vectors gives:

| Model, raw inputs | Positive queries with a relevant accepted result | Negative queries returning anything |
| --- | ---: | ---: |
| `nomic-embed-text:latest` | 14/21 | 0/7 |
| `embeddinggemma:latest` | 1/21 | 0/7 |
| `mxbai-embed-large:latest` | 15/21 | 0/7 |

All three return **0/3 relevant results on the original M6 positive queries**
at those example cutoffs. Their zero negative-acceptance counts therefore do
not establish a useful operating point. EmbeddingGemma’s better ranking cannot
be used with a cutoff copied from another model.

Blindly lowering the two global cutoffs is insufficient for these controls.
For raw EmbeddingGemma, the intended transaction passage scores about 0.395
cosine / 0.277 combined, while the false-name `Ann`→`Anna` match scores about
0.500 / 0.650. Any pair of lower-bound cutoffs that accepts the former also
admits the latter. Review query-specific acceptance and entity-name handling,
then validate on a separate corpus; do not claim that tuning on these labels
is independent validation. Similarity ranking is not identity resolution.

### Retrieval-prefix comparison

A separate profile applied each author’s documented retrieval formatting:
- Nomic: separate query/document prefixes from the [Nomic model card](https://huggingface.co/nomic-ai/nomic-embed-text-v1.5).
- EmbeddingGemma: query task and document title/text formatting from the [Google model card](https://huggingface.co/google/embeddinggemma-300m).
- mxbai: its query instruction, with unprefixed documents, from the [Mixedbread model card](https://huggingface.co/mixedbread-ai/mxbai-embed-large-v1).

The installed model templates are plain prompt passthrough. The prefixed profile
is an experiment with a prospective input contract; current private/hybrid
configuration has no prefix option. No extra title or label was supplied.

The following table also uses cosine-only ranking, before cutoff filtering.

| Model | Prefixed correct first result | Prefixed relevant within first 3 |
| --- | ---: | ---: |
| `nomic-embed-text:latest` | 18/21 | 19/21 |
| `embeddinggemma:latest` | 19/21 | 21/21 |
| `mxbai-embed-large:latest` | 20/21 | 20/21 |

The prescribed formatting did not improve this small corpus’s first-result
accuracy. That does not overturn the authors’ broader training guidance.

## Configuration and remaining qualification

The current settings are `:private_conversation_memory` in `:arbor_orchestrator`
and `:hybrid_knowledge_search` in `:arbor_memory`.
They already carry provider, exact model and endpoint. The local choice is
Ollama at the literal-loopback `/v1` endpoint above; it must also agree with the
existing provider endpoint admission. A unified user-facing settings surface
is not yet provided by these application settings.

Changing a hybrid model recomputes its transient vectors. Changing a private
conversation model does not automatically re-embed retained rows: existing
rows retain their original model attestation and recall selects the current
model. Preserve that separation and provide an explicit re-indexing design
before presenting model switching as seamless. This run changed no model setting.

Follow-up work: choose and validate an acceptance policy for useful retrieval
and false-name controls, expose the supported settings clearly to users, then
qualify the actual enabled Arbor consumer against the selected local model.
The benchmark does not replace facade authorization, egress, transcript commit,
storage/recovery or outbound prompt evidence.

## Evidence and limits

Source revision: `ce9e787be372e626edf5da5d9e78eee3ccf469eb`.
Combined frozen corpus SHA-256: `389ccb33de47765f3c82e1bb32cdacc59b6870cc7b55eb58d4dcee1b42b7d935`.

| Model tag | Installed manifest digest |
| --- | --- |
| `nomic-embed-text:latest` | `0a109f422b47e3a30ba2b10eca18548e944e8a23073ee3f3e947efcf3c45e59f` |
| `embeddinggemma:latest` | `85462619ee721b466c5927d109d4cb765861907d5417b9109caebc4e614679f1` |
| `mxbai-embed-large:latest` | `468836162de7f81e041c43663fedbbba921dcea9b9fefea135685a39b2d83dd8` |

Local preserved artifacts:
- [Runner](../../../tmp/preserved/ollama-embedding-eval-20260910/evaluate.py)
- [Frozen corpus](../../../tmp/preserved/ollama-embedding-eval-20260910/frozen-corpus.json)
- [Summary](../../../tmp/preserved/ollama-embedding-eval-20260910/summary.json)
- [Full request/vector/score evidence](../../../tmp/preserved/ollama-embedding-eval-20260910/results.json)
- [Installed model inventory](../../../tmp/preserved/ollama-embedding-eval-20260910/inventory.json)

The reviewer independently checked scoring, index associations and consistent
returned model/dimension fields. Float32 normalization, as used by Arbor, changes
none of the rankings or cutoff results. The script sorts response indices; it
does not test Arbor’s stricter ordered-association admission.

This is a small development probe with correlated paraphrases, many easy named
queries, short English texts and synthetic facts. It has no representative
production query distribution, long-context, multilingual or noisy-data proof.
Model order was fixed and timings share one active host. The observed runtime
is not a proof of a hard cancellation deadline. The metric fields named
`example_threshold_*` always describe the hybrid formula, including when nested
under a semantic ranking result. No thresholds were tuned or activated here.
