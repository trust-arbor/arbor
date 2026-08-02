# VOICE-1.0 — Voice-First Interface Specification

**Status:** Draft, canonical conformance source (created 2026-07-13; refreshed 2026-08-01)
**Scope:** the voice-first interface (`apps/arbor_voice`, plus small contract additions) —
engagement-native voice conversations, the realtime backend boundary, speakable rendering,
voice security posture, phone transport, and voice notifications/approvals.
**Plan:** `.arbor/roadmap/3-in-progress/voice-first-interface.md` (design rationale lives there).
**Conformance:** every statement below is proven by tests tagged `@tag spec: "<ID>"`.
Run `./bin/mix arbor.spec.coverage` for the current proof map. Statements marked `(planned)`
describe committed direction not yet implemented; they are excluded from `--strict`.
Local work packets in `docs/specs/voice/packets/` implement these statements. That
directory is an ignored operator handoff, not conformance authority. A packet removes
a `(planned)` marker from this tracked file only in the same commit that adds the
proving test.

The key words MUST, MUST NOT, SHOULD, and MAY are to be interpreted as described in
RFC 2119.

## Architecture summary (non-normative)

One new umbrella app, `arbor_voice` (L8; deps: contracts, common, signals,
persistence, comms, llm, ai, orchestrator, agent), is the engagement-substrate
consumer for voice — the headless sibling of `arbor_dashboard`. `Arbor.Voice.Session`
owns a realtime backend session (xAI Realtime first, behind
`Arbor.Voice.RealtimeBackend`), resolves the same `:user`-scoped engagement ChatLive
uses, mirrors every voice turn into the durable engagement transcript, renders all
speech through `Arbor.Voice.Speakable`, and exposes tools to the front-desk voice model
(`consult_agent`, managed task dispatch, and status). The phone path (Phase 2) reuses
phone voice operations exposed through the public `Arbor.Comms` facade as a text
transport — raw audio never leaves the phone.

## Transport & Engagement

- **VOICE-1** (MUST, planned): Every user utterance entering Arbor from the voice interface MUST
  be represented as an `Arbor.Contracts.Session.UserMessage` with `transport: :voice`
  and the most accurate `sent_at` available (utterance end time, not processing time).

- **VOICE-2** (MUST, planned): The voice interface MUST resolve its engagement through
  the public `Arbor.Comms` facade with `scope: :user`, `visibility: :private`, and
  `owner_tenant: user_id`, then tag every `UserMessage` via
  `UserMessage.with_engagement/2`. The `user_id` MUST be the same identifier the
  dashboard uses for this human, so voice and dashboard resolve to the same engagement.

- **VOICE-3** (MUST, planned): Both sides of every completed voice turn (user transcript and
  spoken/assistant text, including delegation summaries) MUST be durably recorded as
  session entries carrying `metadata["engagement_id"]`, in the same public
  session-entry shape the existing orchestrator path writes, through owner-library
  facades, so ChatLive's restore-on-switch renders the voice conversation without
  voice-specific code.

- **VOICE-4** (SHOULD, planned): Each completed voice turn SHOULD emit an Arbor signal
  (`voice.turn.completed`) carrying engagement_id, turn duration, and backend, so open
  dashboards and telemetry observe voice activity live.

## Realtime backend boundary

- **VOICE-5** (MUST, planned): All realtime voice backends MUST implement the
  `Arbor.Voice.RealtimeBackend` behaviour. `Arbor.Voice.Session` MUST NOT reference a
  concrete backend module except through configuration.

- **VOICE-6** (MUST, planned): Backend credentials MUST be resolved on the core node
  (`Arbor.LLM.OAuth.access_token(:xai)` for xAI) and MUST NOT be transmitted to edge
  devices or logged.

- **VOICE-7** (MUST, planned): Closing a voice session MUST close the backend connection and
  stop any delegate/ephemeral agents minted for that session, on both normal exit and
  crash. Cleanup MUST be owned by supervision or a dedicated resource owner and MUST
  NOT rely only on the session process's `terminate/2` callback.

- **VOICE-8** (MUST, planned): Every backend `function_call` event MUST receive exactly one
  matching `function_call_output` (success or structured error). Tool calls MUST NOT
  be silently dropped, and unknown tool names MUST return a structured error output
  rather than crash the session.

## Turn loop & tools

- **VOICE-9** (MUST, planned): The `consult_agent` tool MUST post the engagement-tagged
  `UserMessage` through a public agent/orchestrator facade to the target agent's live
  Session path and return the agent's reply text to the backend as the tool output.

- **VOICE-10** (MUST, planned): Delegation MUST use Arbor's managed, owner-scoped
  orchestration facades. Long-running coding work MUST use a version-2 structured
  `coding_change` task rather than a raw provider session. Any bounded synchronous ACP
  consultation MUST use the public `Arbor.AI.acp_*` facade with deterministic cleanup.
  The delegation (provider, task, task id or session id, and outcome summary) MUST be
  included in the turn's engagement record.

- **VOICE-11** (MUST, planned): A tool execution exceeding a configured progress threshold
  (default 2000 ms) MUST trigger a progress cue to the user (spoken filler or earcon)
  without blocking the tool.

- **VOICE-12** (MUST, planned): Dispatching a long-running task by voice MUST verbally
  confirm-and-release (one-sentence confirmation; the voice channel is not held open);
  completion arrives via the notification queue (VOICE-29).

## Speakable rendering

- **VOICE-13** (MUST, planned): Every string sent to any TTS output MUST first pass through
  `Arbor.Voice.Speakable.render/2`. There MUST be no TTS call site that bypasses it.

- **VOICE-14** (MUST, planned): `Speakable.render/2` MUST enforce a word budget (default: 60
  words) and MUST NOT emit URLs, fenced code blocks, markdown tables, or base64 blobs
  into speech output.

- **VOICE-15** (MUST, planned): When rendering truncates or elides content, the spoken form
  MUST say so ("the rest is on your screen" or equivalent), and the full-fidelity
  content MUST already be in the engagement transcript (VOICE-3) before the truncated
  form is spoken.

- **VOICE-16** (MUST, planned): Content classified as sensitive (restricted/confidential per
  the sensitivity classifier) MUST NOT be synthesized to speech; the spoken form MUST
  be a non-specific escalation ("that's on your screen") while the content remains
  screen-only in the transcript.

## Security posture

- **VOICE-17** (MUST, planned): Voice transcripts are tainted, untrusted user input — the same
  taint class as dashboard chat input. STT output MUST NOT enter any path with
  elevated trust, and MUST NOT be used to construct raw action attributes, principal
  IDs, or capability grants.

- **VOICE-18** (MUST, planned): The voice interaction adapter (approvals) MUST require an
  explicit confirmation phrase that includes a request-specific token (e.g.
  "confirm <word>" where <word> is spoken to the user with the request). A bare
  affirmative ("yes", "sure", "do it") MUST NOT resolve an approval.

- **VOICE-19** (MUST, planned): Approval requests whose authoritative effect class,
  egress tier, data class, blast radius, reversibility, or resource scope exceeds the
  configured voice ceiling MUST NOT be resolvable via voice. Classification MUST be
  supplied by the action/security owner and MUST NOT be inferred from a resource URI
  or free-form metadata. The ceiling MUST be enforced below the channel adapter; the
  adapter additionally routes rejected requests to the screen and says only that an
  approval is waiting. The default ceiling is read and reversible local writes within
  the configured workspace, with no secrets, egress, spend, identity/trust mutation,
  or destructive Git/filesystem effects.

- **VOICE-20** (MUST, planned): When multiple approvals are pending and a voice response does
  not name a request id, the adapter MUST disambiguate (list by id), never guess —
  the `{:interaction_response_partial, ...}` contract of
  `Arbor.Contracts.Comms.ChannelAdapter` with zero tolerance for multi-match.

- **VOICE-21** (MUST, planned): Privileged actions initiated by voice MUST pass a
  speaker-verification gate before dispatch (diarization/enrollment based); failure
  degrades to screen confirmation, never to silent acceptance.

- **VOICE-22** (MUST, planned): Voice session lifecycle (start, stop, backend connect,
  backend switch) MUST be audited via Arbor signals including backend identity and
  cloud/local mode.

- **VOICE-23** (MUST, planned): While a cloud backend is live, the fact and whether it
  receives raw audio or transcript text MUST be user-visible through a session-start
  cue and dashboard-visible indicator (signal-driven). Switching between cloud and
  local backends MUST produce a distinct cue.

- **VOICE-24** (MUST, planned): Per-session and per-day voice minute budgets MUST be enforced
  with a hard stop (default: 60 min/day; config-overridable). Per-day accounting MUST
  be shared or durable across voice-session restarts; process-local elapsed time alone
  is insufficient. Exceeding the budget MUST close the backend session with a spoken
  notice and an audit signal.

## Phone transport (Phase 2)

- **VOICE-25** (MUST, planned): The phone voice loop MUST use phone-local STT/TTS
  operations exposed through the public `Arbor.Comms` facade over the existing cluster
  transport. Raw microphone audio MUST NOT leave the phone in this path; only
  transcripts egress to the backend.

- **VOICE-26** (MUST, planned): Spoken responses are control-plane traffic: if the
  phone is unreachable when a response is produced, the response MUST be dropped
  (with a transcript record and a notification marker), not queued for replay after a
  staleness window (default 30 s).

- **VOICE-27** (SHOULD, planned): Push-to-talk MUST be the default activation mode in
  the phone loop; continuous/VAD modes are opt-in per session.

- **VOICE-28** (MUST, planned): Phone-loop failures (RPC timeout, node down, STT/TTS
  error) MUST degrade loudly — a phone notification/toast and a transcript marker —
  never a silent stall.

## Notifications & status (Phase 4)

- **VOICE-29** (MUST, planned): Voice notifications MUST flow through an ordered,
  priority-classed queue that never interrupts in-flight TTS playback and batches
  below-threshold notifications during active conversation.

- **VOICE-30** (MUST, planned): Unsolicited spoken notifications MUST carry only the
  fact and source of the notification for sensitive content; the content itself goes
  to the screen (VOICE-16 applies).

- **VOICE-31** (MUST, planned): "What's running?"-class status answers MUST be
  grounded in the task status facade (the same data `arbor_task_status` exposes), not
  generated from model memory.

## Latency (measured, not enforced in tests)

- **VOICE-32** (SHOULD, planned): Telemetry MUST-carry: end-of-utterance→ack-cue and
  end-of-utterance→first-audio durations per turn. Targets: ack ≤ 300 ms p95, first
  audio ≤ 2 s p95. These are dogfood metrics; tests prove the measurements exist, not
  the targets.
