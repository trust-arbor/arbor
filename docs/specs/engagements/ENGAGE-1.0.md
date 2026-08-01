# ENGAGE-1.0 — Engagement Substrate Completion Specification

**Status:** Draft (2026-07-13)
**Scope:** wiring the remaining conversational paths through the Engagement
substrate — external comms adapters (Signal/Limitless/Email), the ACP chat runtime,
task↔engagement linkage, `Message.conversation_id`, the disclosure-gating baseline,
and interaction recording.
**Plan:** `.arbor/roadmap/2-planned/engagement-substrate-completion.md` (audit +
rationale). Substrate design: `.arbor/roadmap/2-planned/channels-as-engagements.md`.
**Conformance:** every statement below is proven by tests tagged `@tag spec: "<ID>"`.
Run `mix arbor.spec.coverage` for the current proof map. Statements marked `(planned)`
describe committed direction not yet implemented; they are excluded from `--strict`.
Work packets in `docs/specs/engagements/packets/` say which markers they remove.

The key words MUST, MUST NOT, SHOULD, and MAY are to be interpreted as described in
RFC 2119.

## Inbound external messages (Signal / Limitless / Email)

- **ENGAGE-1** (MUST, planned): Every authorized inbound external message that will
  receive an agent response MUST have an Engagement resolved before response
  generation: a known sender resolves `scope: :user` with the sender's canonical
  user id; an unknown-but-authorized sender resolves `scope: :channel`,
  `visibility: :private`, keyed on the channel-local sender address.

- **ENGAGE-2** (MUST, planned): For known senders, the resolution key MUST be the
  same user identifier the dashboard uses for that human (ChatLive's
  `approval_actor_id/1` value), so Signal/Email turns land in the same `:user`
  engagement as dashboard and voice.

- **ENGAGE-3** (MUST, planned): `Message.conversation_id` MUST be populated with the
  engagement id at the inbound entry point, and every outbound reply produced for
  that message MUST carry the same `conversation_id`.

- **ENGAGE-4** (MUST, planned): Engagement resolution MUST idempotently attach a
  channel descriptor for the transport endpoint (`"signal:<e164>"`,
  `"limitless:<source>"`, `"email:<address>"`) via `EngagementStore.attach_channel`.

- **ENGAGE-5** (MUST, planned): Response generation for an engagement-resolved
  message MUST go through the agent's Session (`send_message` with an
  engagement-tagged `UserMessage`), not a direct LLM/CLI call. The existing
  `ResponseGenerator` config seam is the injection point; the generator is the only
  permitted place that bridges to the Session.

- **ENGAGE-6** (MUST, planned): Adapter-built `UserMessage`s MUST use the transport
  union value matching their platform (`:signal`, `:email`, `:limitless`) and MUST
  stamp `sent_at` from the platform timestamp when the platform provides one.

- **ENGAGE-7** (MUST, planned): The shared cross-channel CLI session
  (`~/.arbor/comms-session-id`) MUST be retired. Two different senders MUST NOT
  share conversational context by construction. Rollback to the legacy responder is
  operator-only via env (`ARBOR_COMMS_RESPONDER=legacy`) for one release window,
  selected before startup, never by message content.

- **ENGAGE-8** (MUST): Sender authorization (the fail-closed `authorized_senders`
  check) MUST run before engagement resolution; unauthorized senders create no
  engagement and no store writes.

## ACP as a Session runtime; tasks link to engagements

- **ENGAGE-9** (MUST, planned): Conversational ACP turns initiated from an
  engagement-aware surface MUST flow through the agent's Session with
  `set_runtime(:acp)` (engagement-tagged envelope, persisted transcript). The
  dashboard's direct `Claude.query` chat path is removed behind the same
  one-release-window rollback convention.

- **ENGAGE-10** (MUST, planned): Structured task dispatch initiated from an
  engagement context MUST record the initiating `engagement_id` with the task, and
  the task's terminal outcome MUST append a summary entry to that engagement's
  transcript (provenance: `task_id`, normalized outcome) and emit a signal
  (`engagement.task.completed`).

- **ENGAGE-11** (MUST, planned): Raw task ACP output (tool streams, worker
  transcripts) MUST NOT be mirrored into engagement transcripts; engagements receive
  the summary entry only. The task artifact surface remains the source of detail.

## Disclosure baseline (visibility enforcement)

- **ENGAGE-12** (MUST, planned): Memory entries created from engagement-tagged turns
  MUST carry the source `engagement_id` as provenance.

- **ENGAGE-13** (MUST, planned): Memory recall into an engagement MUST apply
  audience containment on provenance: an entry whose source engagement's visibility
  is narrower than the target engagement's visibility MUST NOT be surfaced
  (`:private ⊂ :group ⊂ :public`; `:internal` surfaces only into `:internal`).
  Entries with no provenance (legacy) are exempt — documented debt, revisit after
  Phase C.

- **ENGAGE-14** (MUST, planned): Widening an engagement's visibility MUST be an
  explicit operation that emits an audit signal; nothing widens visibility as a side
  effect.

## Interactions in the conversation record

- **ENGAGE-15** (MUST, planned): Every interaction request and its resolution for an
  agent with an active engagement for that user MUST be appended to that
  engagement's transcript (entry metadata: `request_id`, kind, outcome).

- **ENGAGE-16** (SHOULD, planned): Interaction delivery SHOULD prefer adapters of
  the target user's active engagement channels before the presence-based fallback,
  behind a config flag, pending the full convergence decision
  (`.arbor/roadmap/1-brainstorming/interaction-routing-into-engagements.md`).

## Uniformity & observability

- **ENGAGE-17** (MUST): All surfaces list and resolve conversations through the
  EngagementStore APIs; no parallel conversation registry may be introduced.

- **ENGAGE-18** (MUST, planned): A canary test MUST enumerate the known
  conversational entry points (dashboard, gateway socket, comms adapters, voice) and
  assert each resolves an engagement before reaching an LLM — new islands fail CI.
