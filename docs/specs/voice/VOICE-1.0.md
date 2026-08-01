# VOICE-1.0 — Voice-First Interface Specification

**Status:** Draft (2026-07-13)
**Scope:** the voice-first interface (`apps/arbor_voice`, plus small contract additions) —
engagement-native voice conversations, the realtime backend boundary, speakable rendering,
voice security posture, phone transport, and voice notifications/approvals.
**Plan:** `.arbor/roadmap/2-planned/voice-first-interface.md` (design rationale lives there).
**Conformance:** every statement below is proven by tests tagged `@tag spec: "<ID>"`.
Run `mix arbor.spec.coverage` for the current proof map. Statements marked `(planned)`
describe committed direction not yet implemented; they are excluded from `--strict`.
Work packets in `docs/specs/voice/packets/` implement these statements and say which
`(planned)` markers they remove.

The key words MUST, MUST NOT, SHOULD, and MAY are to be interpreted as described in
RFC 2119.

## Architecture summary (non-normative)

One new umbrella app, `arbor_voice` (L8; deps: contracts, common, signals, comms,
llm, ai, orchestrator, agent), is the engagement-substrate consumer for voice — the
headless sibling of `arbor_dashboard`. `Arbor.Voice.Session` owns a realtime backend
session (xAI Realtime first, behind `Arbor.Voice.RealtimeBackend`), resolves the same
`:user`-scoped engagement ChatLive uses, mirrors every voice turn into the durable
engagement transcript, renders all speech through `Arbor.Voice.Speakable`, and exposes
tools to the front-desk voice model (`consult_agent`, `delegate_to_agent`, later
dispatch/status). The phone path (Phase 2) reuses `Arbor.Comms.Channels.Voice`
STT/TTS primitives as a text transport — raw audio never leaves the phone.

## Transport & Engagement

- **VOICE-1** (MUST): Every user utterance entering Arbor from the voice interface MUST
  be represented as an `Arbor.Contracts.Session.UserMessage` with `transport: :voice`
  and the most accurate `sent_at` available (utterance end time, not processing time).

- **VOICE-2** (MUST): The voice interface MUST resolve its engagement with
  `Arbor.Comms.EngagementStore.resolve_or_create(agent_id, user_id, scope: :user,
  visibility: :private, owner_tenant: user_id)` and tag every `UserMessage` via
  `UserMessage.with_engagement/2`. The `user_id` MUST be the same identifier the
  dashboard uses for this human (ChatLive's `approval_actor_id/1`), so voice and
  dashboard resolve to the same engagement.

- **VOICE-3** (MUST): Both sides of every completed voice turn (user transcript and
  spoken/assistant text, including delegation summaries) MUST be durably recorded as
  session entries carrying `metadata["engagement_id"]`, in the same entry shape
  `Arbor.Orchestrator.Session.Persistence` writes, so ChatLive's restore-on-switch
  renders the voice conversation without voice-specific code.

- **VOICE-4** (SHOULD): Each completed voice turn SHOULD emit an Arbor signal
  (`voice.turn.completed`) carrying engagement_id, turn duration, and backend, so open
  dashboards and telemetry observe voice activity live.

## Realtime backend boundary

- **VOICE-5** (MUST): All realtime voice backends MUST implement the
  `Arbor.Voice.RealtimeBackend` behaviour. `Arbor.Voice.Session` MUST NOT reference a
  concrete backend module except through configuration.

- **VOICE-6** (MUST): Backend credentials MUST be resolved on the core node
  (`Arbor.LLM.OAuth.access_token(:xai)` for xAI) and MUST NOT be transmitted to edge
  devices or logged.

- **VOICE-7** (MUST): Closing a voice session MUST close the backend connection and
  stop any delegate/ephemeral agents minted for that session, on both normal exit and
  crash (supervised cleanup, not only happy-path code).

- **VOICE-8** (MUST): Every backend `function_call` event MUST receive exactly one
  matching `function_call_output` (success or structured error). Tool calls MUST NOT
  be silently dropped, and unknown tool names MUST return a structured error output
  rather than crash the session.

## Turn loop & tools

- **VOICE-9** (MUST): The `consult_agent` tool MUST post the engagement-tagged
  `UserMessage` to the target agent's live Session process (the same
  `Session.send_message/2` path ChatLive's `:arbor` runtime uses) and return the
  agent's reply text to the backend as the tool output.

- **VOICE-10** (MUST): The `delegate_to_agent` tool MUST create, prompt, and close ACP
  sessions exclusively through the `Arbor.AI.acp_*` facade, and MUST include the
  delegation (provider, task, outcome summary) in the turn's engagement record.

- **VOICE-11** (MUST): A tool execution exceeding a configured progress threshold
  (default 2000 ms) MUST trigger a progress cue to the user (spoken filler or earcon)
  without blocking the tool.

- **VOICE-12** (MUST, planned): Dispatching a long-running task by voice MUST verbally
  confirm-and-release (one-sentence confirmation; the voice channel is not held open);
  completion arrives via the notification queue (VOICE-29).

## Speakable rendering

- **VOICE-13** (MUST): Every string sent to any TTS output MUST first pass through
  `Arbor.Voice.Speakable.render/2`. There MUST be no TTS call site that bypasses it.

- **VOICE-14** (MUST): `Speakable.render/2` MUST enforce a word budget (default: 60
  words) and MUST NOT emit URLs, fenced code blocks, markdown tables, or base64 blobs
  into speech output.

- **VOICE-15** (MUST): When rendering truncates or elides content, the spoken form
  MUST say so ("the rest is on your screen" or equivalent), and the full-fidelity
  content MUST already be in the engagement transcript (VOICE-3) before the truncated
  form is spoken.

- **VOICE-16** (MUST): Content classified as sensitive (restricted/confidential per
  the sensitivity classifier) MUST NOT be synthesized to speech; the spoken form MUST
  be a non-specific escalation ("that's on your screen") while the content remains
  screen-only in the transcript.

## Security posture

- **VOICE-17** (MUST): Voice transcripts are tainted, untrusted user input — the same
  taint class as dashboard chat input. STT output MUST NOT enter any path with
  elevated trust, and MUST NOT be used to construct raw action attributes, principal
  IDs, or capability grants.

- **VOICE-18** (MUST): The voice interaction adapter (approvals) MUST require an
  explicit confirmation phrase that includes a request-specific token (e.g.
  "confirm <word>" where <word> is spoken to the user with the request). A bare
  affirmative ("yes", "sure", "do it") MUST NOT resolve an approval.

- **VOICE-19** (MUST): Approval requests whose effect class exceeds the configured
  voice ceiling (default ceiling: read/local_write within the workspace; anything
  touching secrets, egress, spend, or destructive git/filesystem operations is above
  it) MUST NOT be resolvable via voice. The adapter MUST route them to the screen and
  say only that an approval is waiting.

- **VOICE-20** (MUST): When multiple approvals are pending and a voice response does
  not name a request id, the adapter MUST disambiguate (list by id), never guess —
  the `{:interaction_response_partial, ...}` contract of
  `Arbor.Contracts.Comms.ChannelAdapter` with zero tolerance for multi-match.

- **VOICE-21** (MUST, planned): Privileged actions initiated by voice MUST pass a
  speaker-verification gate before dispatch (diarization/enrollment based); failure
  degrades to screen confirmation, never to silent acceptance.

- **VOICE-22** (MUST): Voice session lifecycle (start, stop, backend connect,
  backend switch) MUST be audited via Arbor signals including backend identity and
  cloud/local mode.

- **VOICE-23** (MUST): While a cloud backend is live, the fact MUST be user-visible:
  a session-start cue and a dashboard-visible indicator (signal-driven). Switching
  between cloud and local backends MUST produce a distinct cue.

- **VOICE-24** (MUST): Per-session and per-day voice minute budgets MUST be enforced
  with a hard stop (default: 60 min/day; config-overridable). Exceeding the budget
  MUST close the backend session with a spoken notice and an audit signal.

## Phone transport (Phase 2)

- **VOICE-25** (MUST, planned): The phone voice loop MUST use phone-local STT/TTS
  (`Arbor.Comms.Channels.Voice` primitives over the existing cluster transport). Raw
  microphone audio MUST NOT leave the phone in this path; only transcripts egress to
  the backend.

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

- **VOICE-32** (SHOULD): Telemetry MUST-carry: end-of-utterance→ack-cue and
  end-of-utterance→first-audio durations per turn. Targets: ack ≤ 300 ms p95, first
  audio ≤ 2 s p95. These are dogfood metrics; tests prove the measurements exist, not
  the targets.
