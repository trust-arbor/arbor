# Voice conversation convergence

Candidate implementation checkpoint, 2026-09-27. Private Voice binding is
implemented in this change; qualification is recorded below. Device capture and
playback remain separate work.

The first useful journey is an authenticated web turn, a bounded Voice turn in
the same private engagement, and a web follow-up whose running Agent has seen
the durable Voice exchange. Keep the existing Voice Session, ResourceOwner,
backend and Speakable ownership. Do not add a receipt broker or a second chat
engine. Orchestrator transcript freshness is a separate source-owned slice.

## Current source and limits

* `Arbor.Voice.start_session/3` requires a session token for every backend.
  `text_turn/3` addresses a trusted local tuple and reauthenticates that stored
  proof at each turn. An external transport must authenticate its caller; tuple
  knowledge is never a remote credential.
* `Voice.ConversationAuthority` retains the authenticated subject separately
  from the canonical owner. It resolves and checks the complete private
  engagement scope, consumes one fresh receipt, and retains one immutable
  redacted binding. `EgressAuthority` adds provider disclosure and route gates;
  choosing a local backend no longer skips conversation authentication.
* `TranscriptRecorder.record/5` still writes one ordered pair through
  `Comms.record_engagement_turn/5`. Only its exact `{:ok, 2}` acknowledgement
  admits publication. Session checks authority before and after that write,
  during presentation, and immediately before the public reply.
* The default `PrivateConversation` catalog exposes only `consult_agent`.
  Explicit `FrontDesk` retains managed dispatch, outside this bounded private
  continuity qualification. Denial never changes catalogs or backends.
* The realtime front desk does not automatically receive historical context.
  Shared durable storage plus a source-fenced Agent consultation is the first
  qualified continuity path. Direct history injection remains deferred.
* `audio_mode: :pcm16` enables the bounded `Arbor.Voice.audio_turn/4` API.
  Completed STT supplies the durable user text; provider PCM is presentation
  only and is never persisted. Each completed audio turn closes its backend
  and Session before returning. Start a fresh authenticated Session for the
  next utterance until provider item correlation is qualified. This mode
  rejects text turns before admission or provider effects; text sessions reject
  audio turns.

## Admission and lifetime

Use the existing Security authority for every private Voice backend, including
local backends. Egress classification must not decide whether private chat
requires authentication. Keep egress capabilities and disclosure leases as
additional gates, with their existing cleanup ownership.

At startup and before each new turn, a Voice-owned boundary performs:

1. `Security.authorize_and_issue_conversation_receipt(subject,
   "arbor://chat/agent/" <> agent, :chat, session_token: token)`.
2. `Security.conversation_receipt_owner(receipt, subject, agent)` before receipt
   consumption. Document this existing facade function for Voice consumption.
3. `Comms.resolve_user_engagement(agent, owner)` and validate the returned
   agent, private user scope, owner and canonical engagement identifier.
4. `Security.consume_delivery_receipt(receipt, resource, :chat)` exactly once;
   match the authenticated subject. Always discard an unconsumed receipt with
   `Security.discard_delivery_receipt/1` on unwind.

Keep subject, canonical owner, target and engagement immutable in one redacted,
Session-owned binding. The tuple remains `{authenticated_subject, agent}`;
neither token subject nor grants are rewritten to the canonical owner. The
owner's grant never substitutes for the subject's own grant. Subsequent
admission compares the new binding to the pinned one; it cannot silently
rebind. Alias changes, expiry, revocation and resolver failures close the
private session and require explicit authenticated restart.

The existing session token is reusable proof, but every turn must authenticate
it again. Its lifetime is independent of the Voice budget. Do not keep one
startup receipt alive for the whole session or verify one SignedRequest twice.
The first slice remains session-token-only. Future signed transport calls need
fresh nonce-bearing, operation/payload-bound requests per admission; never
cache a start request as session authority or replay it for a tool/history call.

## Continuation fences

`Security.recheck_conversation_owner(subject, agent, pinned_owner)` already
checks active identities, alias binding and current chat authority without
spending rate/use counters. `Security.recheck_conversation_session/4` adds
the original token: it verifies the HMAC token's exact subject and expiry inside
Security, then calls the existing owner check. Voice does not import
`Security.SessionToken` or decode token claims itself.
The continuation check is not fresh admission and cannot create authority.

Run the continuation check at each provider effect, tool dispatch, durable
transcript commit, guarded output admission and final response publication.
Compare the pinned engagement when resolving any new projection. Denial fences
the generation, cancels outstanding work, closes ambiguous backend state,
suppresses output and releases resources. It must not fall back to a local
backend, raw text, a partial successful reply or a new owner.

Check again after a successful append and before publication. This suppresses
disclosure if authority changes during persistence; it does not roll back an
already committed pair. Tests must state that boundary honestly. Playback is
an effect: the later presentation owner rechecks when dequeuing, and revocation
or cancellation stops active playback. Already emitted audio is irreversible.

The authenticated `Agent.send_message/4` tool path admits the compare-only
`:expected_engagement_id` fence with HMAC session proof. Ordinary and signed
message modes reject this new option; their existing no-fence behavior remains.
Malformed, duplicate, or unsupported fence options fail before authorization
allowances or receipt issue. Security stores the fence in its opaque receipt,
then transfers it into the source Session's private-memory admission. The
source compares its resolved engagement before queue/start and again at
activation. The message itself remains route-free, and a caller cannot choose
an owner, turn authority, collaborator, or destination with this fence.

`dispatch_task/4` still needs a corresponding source-admission fence before it
qualifies for this private profile. `PrivateConversation` excludes it. Operators
who explicitly select `FrontDesk` retain its existing managed-dispatch behavior
with the new conversation proof requirement.

The ResourceOwner checks continuation before every backend callback (except
cleanup), including local backends with no physical effect callback. It also
rechecks callback results before returning them. Cloud physical frames retain
their own effect checks. The immutable conversation binding remains alive after
the turn-egress lease is finalized, so transcript and publication gates do not
lose their proof prematurely.

## History and continuity qualification

The display path is already
`Agent.conversation_history(subject, agent, session_token: token,
expected_engagement_id: engagement, ...)`. Its engagement root and ordinal
cursor qualify only the display projection. Never feed raw signal payloads,
other engagements, arbitrary tool receipts or unverified display text into an
Agent's trusted context.

For the first continuity proof, the front desk must consult the authoritative
Agent, whose authenticated pre-turn boundary refreshes acknowledged durable
entries for the pinned engagement. Preserve provenance/taint and synchronize
the active messages, compactor and session-state projection. This is owned by
the separate Orchestrator freshness slice, including previously cached scopes.

Direct history injection into the realtime provider is a later explicit
channel qualification: use an authenticated, bounded history projection;
retain roles and source labels as untrusted data; pass it through the existing
disclosure/egress path; pin a snapshot cursor and prevent duplicated provider
items. Loading history is not authorization to disclose it to a cloud backend.
Test the exact provider request. Until then, claim shared durable transcript
and Agent consultation continuity, not identical front-desk context.

## Implementation slices and acceptance

1. **Private text binding:** implement the admission/continuation boundary and
   immutable binding; wire startup, each text turn, provider effects and final
   publication. Exercise real Security plus scripted backend through public
   Voice APIs. Missing/expired/foreign proof, suspended subject, alias change,
   resolver outage and grant revocation must prevent subsequent effects.
2. **Commit and tool fences:** gate TranscriptRecorder invocation and output;
   qualify consult/dispatch at their source admission boundaries. Block the
   backend or append, revoke/unlink, release it, and assert no forbidden commit
   or success disclosure. Test independent subjects sharing one canonical
   owner and prove grants are not transferred. Preserve exact cleanup behavior.
3. **Cross-channel proof:** web A -> Voice consult -> committed Voice pair ->
   web follow-up without restarting Session. Assert foreign history absent,
   taint retained, no duplicate injection, and no claim that transcript arrival
   proves a durable command completed. Add candidate-pass/base-fail regressions.
4. **Real audio:** retain VP-07A0 protocol/async ownership before A1 audio turns;
   B0 native dependency admission before B device I/O; C serialized, leased
   server capture and playback. Start with one same-host bounded mic capture,
   one guarded response and explicit stop. No raw PCM persistence, distribution
   round trip, provider-text/audio mismatch or overlapping progress speech.

The existing VP-07 packets are currently local ignored planning files under
`docs/specs/voice/packets/` in the operator checkout. Native packages, image
admission and hardware proof remain prerequisites; this design installs none.

## Qualification

The committed `conversation_binding_security_regression_test.exs` uses actual
OIDC identities, alias links, HMAC session proofs, capabilities, receipt broker,
Agent and Orchestrator Session, Comms, and a private migrated SQLite database.
The budget ledger and provider I/O are explicit test collaborators; no live LLM,
OAuth, microphone, speaker, terminal PTY, or remote deployment is exercised.
The cloud text-revocation lane drives the production xAI backend through a
scripted transport. The completed PCM journey uses a scripted local backend;
it proves the public turn, authority, persistence and presentation boundaries,
not provider recognition quality or device playback.

Run it in an isolated checkout with a private test database:

```sh
MIX_ENV=test ./bin/mix test apps/arbor_voice/test/arbor/voice/conversation_binding_security_regression_test.exs --include isolated_repo --include database --seed 0
```

The positive journey sends a web-origin Agent message, consults the same Agent
from a linked Voice subject, durably appends the Voice exchange, then inspects
the next real Agent provider request without restarting its Session. The
consultation creates its own genuine user/assistant pair; the outer Voice turn
creates another pair. Including the initial web pair, this is six entries,
not a deduplication or correlation protocol. A separate bounded audio journey
persists the actual completed STT and final text, returns guarded PCM only after
positive backend close, and verifies both in the next Agent provider context.
Negative journeys cover missing/foreign proof, foreign engagement scope, alias changes,
revocation in local/cloud receive, real token expiry, revocation after consult,
authorization changes after append and during presentation, incomplete pair
acknowledgements, and real grant revocation during audio receive.

On 2026-09-27, the full Voice suite passed **513 tests** and the isolated real
Security/SQLite journey passed **15 tests**. The existing consultation, egress
and managed-dispatch suite also passed **18 tests in four consecutive runs**.
The source engagement-fence commit separately passed 170 focused source tests;
see `CONVERSATION_SOURCE_FENCE.md` for its boundary and evidence.

The identical journey test was copied into an independently compiled checkout
of the immediate implementation parent `6c03e94797a8d43be23a652beed266a14e4dcdca`.
The eleven selected security witnesses failed there at the actual old public
behavior: local startup admitted missing proof or foreign scope; changed
authority still returned successful text; and recorder counts 0, 1, and 3 still
published a reply. All eleven pass as part of the candidate's fifteen tests.
The new audio API tests are excluded from the predecessor comparison.

To reproduce the selected predecessor witnesses after copying only the test
file into that revision:

```sh
MIX_ENV=test ./bin/mix compile --warnings-as-errors
MIX_ENV=test ./bin/mix test apps/arbor_voice/test/arbor/voice/conversation_binding_security_regression_test.exs:416:481:495:519:584:613:639:660 --include isolated_repo --include database --seed 0
```

The fixture exclusively creates a process-specific random temporary root, so
candidate and predecessor SQLite databases cannot share a VM-local counter path.

Existing lifecycle and presentation tests now supply explicit fixture proof and
a reviewed test-only Security collaborator. Their earlier unauthenticated-local
behavior is deliberately removed from the public API. No production option
bypasses the new authority requirement.
