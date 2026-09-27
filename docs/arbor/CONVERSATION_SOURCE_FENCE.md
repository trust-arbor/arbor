# HMAC conversation continuation fence

Implemented 2026-09-27 for the bounded Voice binding work.

`Arbor.Agent.send_message/4` and `send_message_response/4` accept
`expected_engagement_id: "eng_" <> 32_lowercase_hex_digits` only alongside
`:session_token`. The option is an equality assertion against the private
engagement that Session resolves through Security's canonical owner and Comms.
It does not select an engagement or rewrite `UserMessage`.

Security validates the closed option set before proof/nonce or allowance effects,
removes the fence from authorization options, and stores it in the opaque receipt
broker entry. Receipt exchange carries it into the caller-owned private-memory
admission. `Security.check_private_memory_engagement/2` compares the resolved
engagement before Session starts or queues the turn. Activation repeats the
comparison. Mismatch denies without queueing, model execution, or transcript
commit. The fence does not appear in public memory scope or turn authority.

Ordinary messages, native signed requests, non-chat receipts, malformed fences,
duplicate options, and unknown options reject this option before admission.
No-option delivery retains its existing behavior. This restriction applies to
the native message API: the separate conversation v2 signed request format
already binds its own compare-only engagement field.

`Security.recheck_conversation_session/4` validates the original HMAC proof's
exact subject and expiry, then rechecks current canonical ownership and chat
grant without consuming rate or use allowances. It neither creates a receipt
nor admits a new operation. Voice uses this for continued access; individual
operations still require fresh receipt admission.

## Qualification

Warnings-as-errors compilation passed in the isolated binding checkout. The
following tests passed with seed 0 and private runtime storage:

- Security conversation authorization: 16 tests.
- Agent message facade: 53 tests plus 2 isolated database cases.
- Session turn authority: 46 tests.
- Receipt broker, delivery receipts, and private memory: 31 tests.
- Conversation facade and signed binding: 22 tests.

These tests cover the new closed API contract, private receipt propagation,
pending and active admission checks, exact subject/expiry, owner change and
resolver outage, grant revocation, nonconsuming continuation, and existing
delivery paths. Predecessor production rejects the newly introduced option;
that rejection is not evidence of an old authorization bypass. Behavioral
predecessor witnesses for the repaired Voice authority gap belong to the Voice
binding qualification, separately from these new source-boundary tests.
