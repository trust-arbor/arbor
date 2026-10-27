# FINDING-011: outbound sensitivity enforcement

Implementation record, 2026-10-27. Validation and integration results are recorded
in the accompanying security report. This implements the conservative policy
recommended in [the original proposal](sensitivity-dispatch-proposal-2026-10-15.md).

## Policy decisions

- Sensitivity is the maximum of valid caller labels, recorded taint, source
  labels and a local scan. A caller's `public` label never suppresses scanning.
  Present malformed labels, unavailable classifiers/policies and unknown
  destinations deny with a content-free `{:sensitivity_blocked, reason}`.
- Credentials, private keys, SSNs and payment cards are restricted. The existing
  Common classifier remains unchanged for its other consumers; the outbound
  policy raises its credential category to restricted.
- Every outbound generation and embedding operation is covered, including
  system/eval callers, OAuth, owned HTTP adapters and ACP. There is no
  request-level bypass. Verified local replay/hash operations remain local.
- Provider/model clearance and the actual destination both matter. Nonpublic
  local-provider calls require an on-host endpoint and a non-cloud-proxy model.
  Restricted data requires local inference; private-network endpoints and a
  loopback CLI process do not establish that clearance. Cloud model overrides
  cannot grant restricted clearance.
- Custom adapters handling nonpublic content must be registered by the host as
  owners of sensitivity checks at their real effects. Registration is a host
  trust decision, not request data. An orchestrator wrapper checks its inner
  adapter as well.
- Source APIs that render private memory, profile, project or loaded skill
  content without authoritative labels conservatively retain a restricted
  floor. This can refuse cloud calls that previously succeeded. Restoring
  granular cloud use requires source-owned classification, not a caller opt-out.

## Enforcement and propagation

`Arbor.LLM.Plugs.Sensitivity` is the common admission plug. `Dispatch` invokes it
mandatorily even if a host replaces the ordinary pipeline. The runtime policy
behaviour belongs to `arbor_llm`; `Arbor.LLM.Config` injects the AI facade as its
implementation without a reverse Mix dependency or new kernel contract.

Client binds the selected adapter before middleware, joins the original and
final request floors and rechecks model selection. ReqLLM carries the private
source floor separately from provider JSON and replay fixtures. Final HTTP
request steps scan the bounded decoded wire payload and bind scheme, host and
port to the admitted endpoint on every transport retry. Streaming repeats
admission inside the owned producer immediately before Finch. OAuth and owned
LM Studio transports use the same checks; ACP checks before checkout and again
before its prompt worker sends content.

The scan includes system/history/tool content, tool schemas and descriptions,
provider payload fields, batch embedding inputs and transmitted map keys. JSON
escapes are decoded before scanning. A later request/model/body rewrite cannot
reuse stale admission. Private policy metadata is not emitted in provider JSON.
Stock transport identity binds the added implementation and host policy state.

Memory embeddings, summarization, extraction, reflection, compression, search
and action patterns carry source labels and the actual principal. Stored
context windows and agent summaries ratchet their floor before discarding raw
records and preserve it across serialization and compaction. Legacy summaries
without labels restore conservatively. Prompt packets return text and its
source floor from the same reads, covering memory fetched after agent startup.
Actions, consensus, comms, tool loops and direct agents carry that floor before
formatting. Both successful and error tool results retain their labels before
the next model attempt.

Existing local egress gates and authorization controls remain additional
requirements. Sensitivity refusal is terminal; the effect layer does not reroute
unchanged data to another provider. Routing may independently choose a new
candidate and admit it afresh.

## Regression evidence

Tests were committed before fixes. Real ReqLLM/HTTP and ACP-session fixtures
prove restricted ordinary prose is refused before an effect, while permitted
public cloud and restricted local controls still execute. Additional regressions
cover higher recorded labels, malformed aliases/taint, request rewrites, JSON
escape rewrites, actual-origin changes, transport retries, delayed adapter
streams, wrapper/inner-adapter identity, fresh memory reads, compaction,
embedding options and labeled tool success/error continuations.

Unrelated fixture transport controls use an explicit test-owned registry rather
than putting PIDs/functions in provider payloads. Only uniquely named in-memory
test providers receive a scoped fixture policy; real providers still use the
production policy. Security regressions that prove actual transport refusal do
not use that fixture policy.

Applied Learning: validate the producer's exact wire envelope before accepting
test evidence [AL:test-producer-to-consumer-contracts-with-the-exact-current-wire-envelope!].
The prompt HTTP fixture initially omitted the provider's actual Responses fields;
its corrected public transport controls were required before recording red proof.
Also scan decoded final content and retain source floors before formatting;
encoded text alone cannot establish the model's received sensitivity. A Client
owned stream can prefetch, so delayed-consumption tests use the adapter's actual
lazy Enumerable boundary.
