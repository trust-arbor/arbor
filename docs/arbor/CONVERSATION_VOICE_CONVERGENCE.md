# Voice conversation convergence

Design checkpoint, 2026-09-27. This document proposes the next bounded slices;
it does not claim that private Voice binding or device playback is implemented.

The first useful journey is an authenticated web turn, a bounded Voice turn in
the same private engagement, and a web follow-up whose running Agent has seen
the durable Voice exchange. Keep the existing Voice Session, ResourceOwner,
backend and Speakable ownership. Do not add a receipt broker or a second chat
engine. Orchestrator transcript freshness is a separate source-owned slice.

## Current source and gaps

* `Arbor.Voice.start_session/3` accepts a redacted session token;
  `text_turn/3` subsequently addresses a trusted local tuple, without new proof.
  No external transport may treat knowledge of that tuple as authentication.
* `Voice.EgressAuthority.authenticate_human/2` authenticates external backend
  startup through `Security.authorize_and_issue_delivery_receipt/4`, then
  consumes and discards its binding. Local backends skip this check.
* `Voice.Session.resolve_engagement/1` passes the raw subject to
  `Comms.resolve_user_engagement/3`. This can differ from authenticated web
  history's canonical owner. The tool closure also retains the original token
  without checking it on ordinary later Voice turns.
* `TranscriptRecorder.record/5` writes through
  `Comms.record_engagement_turn/5`; Session correctly persists before Speakable
  or output. The write and later publication lack a live conversation fence.
* `configure_and_read_meta/2` configures tools only. The front desk has its own
  provider context; a common transcript store alone does not make it consume
  the Agent's prior conversation.

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
spending rate/use counters. It does not verify token expiry. Add a narrow
Security facade continuation check for the session-token profile which verifies
the HMAC token's exact subject and expiry inside Security, then calls that
existing owner check. This is a proposed facade addition, not an existing API;
Voice must not import `Security.SessionToken` or decode token claims itself.
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

The existing `Agent.send_message/4` tool path does not accept
`:expected_engagement_id`. An external precheck alone leaves a scope-change
race before the source admits the tool. Extend its authenticated source path
with the same compare-only fence as the public conversation APIs, or use a
reviewed source-owned continuation. Do not import MessageFacade/Manager from
Voice. Likewise, `dispatch_task/4` needs a source-admission binding fence before
it qualifies as part of this private profile. Until qualified, the selected
profile excludes that tool explicitly; unrelated existing profiles retain
their behavior. A model cannot select the binding, collaborator or target.

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
