# Named evaluation fixtures

`Arbor.LLM.Eval.Subject.run/2` can explicitly record or replay a completion
through the real ReqLLM plug pipeline. This is disabled unless the caller
selects a configured name with `fixture_set:`. Configuring a set alone does
not capture ordinary Subject, agent, or adapter traffic.

```elixir
config :arbor_llm, :eval_fixture_sets, %{
  "review_corpus" => %{
    mode: :replay,
    path: "/absolute/operator-owned/eval-fixtures/review-corpus"
  }
}

Arbor.LLM.Eval.Subject.run("Public synthetic evaluation prompt",
  provider: "lm_studio",
  model: "evaluation-model",
  fixture_set: "review_corpus"
)
```

Names contain 1–64 ASCII letters, digits, underscores, or hyphens and begin
with a letter or digit. Each configuration entry contains exactly `:mode`
(`:record` or `:replay`) and `:path` (an absolute directory). Unknown names,
invalid entries, caller-supplied destination maps, and relative paths return
errors before transport. The operator controls the destination and capture
mode; the selector is not a security capability or permission to record
private content. Only approved synthetic or otherwise authorized evaluation
inputs should be selected for recording.

Recording invokes the provider, then publishes the existing version 2 fixture
format through `FileReceipt`. Publication errors fail the run; provider work
may already have occurred. Replay performs a bounded fixture read and restores
the typed ReqLLM response before ordinary adapter conversion and response
validation. A missing, malformed, mismatched, or over-budget fixture fails
without an HTTP attempt. Replay leaves the fixture bytes and timestamp intact.
Replay does not require a running local provider, a warm provider catalog,
or a keyless readiness probe. Named default transport selection uses the
known provider registry without catalog availability probes; OAuth and ACP
routes are explicitly unsupported. Ordinary Subject resolution is unchanged.

The supported named composition is the default pipeline, in this order:

```elixir
[
  Arbor.LLM.Plugs.ResponseLimit,
  Arbor.LLM.Plugs.EvalReplay,
  Arbor.LLM.Plugs.Dispatch,
  Arbor.LLM.Plugs.RateLimitBackoff,
  Arbor.LLM.Plugs.EvalRecord,
  Arbor.LLM.Plugs.Usage
]
```

The two eval plugs are inert without a selected named set. An explicitly
configured identical sequence is supported. Other custom pipelines return
`:eval_fixture_unsupported_pipeline` for named runs; ordinary custom calls
retain their configured sequence. Named runs support only non-streaming
`Arbor.LLM.Adapter.ReqLLM` completions and clients without completion
middleware. Unsupported adapters, streaming, and short-circuiting client
middleware fail explicitly. There is no new OAuth, embedding, or streaming
fixture workflow in this slice. Existing manually composed global Record and
Replay pipelines retain their legacy behavior.

The Subject passes only the name through a private transport option. The
adapter revalidates operator configuration and removes the selector before
provider option assembly. Destination, mode, and original Arbor provider live
in per-call metadata, independent of concurrent callers. No call changes
Application configuration. Configuration changes affect subsequent calls;
an admitted call retains its selected metadata and validated pipeline.

Named completion keys use a separate hash namespace. They bind the original
Arbor provider, resolved model identity, messages, and generation options.
Only known runtime controls are omitted: credentials, endpoint/HTTP hooks,
receive timeout, response byte limits, signing metadata, and anonymous-auth
markers. A tighter replay budget selects the same record and then applies the
current budget; it cannot silently become a provider-backed cache miss.
Global fixture keys remain unchanged.

Named successful Subject results include `:usage` from the validated Arbor
response, plus the existing text, model, provider, token count, and timings.
Output and usage are reproducible; wall-clock duration is measured anew.
Replays do not emit a new provider-usage charge. Fixture serialization retains
only the codec's closed response fields; it excludes transport headers,
credentials, provider internals, the selected name, and the destination.
Canonical token/cache/reasoning aliases and flags are retained, along with
closed ReqLLM tool, generated-image, and billing usage shapes. Nested usage
map keys retain their atom/string identity through explicit tags; decoding
uses only known schema keys and enum atoms. Unknown fields, malformed counts,
unreviewed tools/units, or values above the codec bounds fail recording or
replay instead of silently discarding usage. Billing lists are limited to 128
items and labels to 256 bytes; the existing fixture byte/depth limits remain.

The public behavioral selector is
`apps/arbor_llm/test/arbor/llm/eval/subject_fixtures_test.exs`. It uses real
provider request preparation and decoding with `Req.Test` replacing only HTTP,
private temporary destinations, and test-owned provider availability. It
covers recording/replay, concurrent uncaptured ordinary calls, failure paths,
and generation-sensitive identity. It does not qualify live provider access,
private capture, or host-crash durability.
