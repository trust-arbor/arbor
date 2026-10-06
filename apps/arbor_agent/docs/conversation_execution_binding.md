# Conversation execution binding

This slice connects the durable conversation ingress journal to the existing
Session execution owner. It does not add another execution engine or a public
stream subscription API.

After authentication, ConversationFacade resolves the canonical private owner
and engagement, admits the exact command, and starts its supervised delivery
worker. Only the winning durable claim creates a private binding. MessageFacade
passes that binding through dedicated Manager and SessionManager arguments to
the configured Session port. Existing authenticated sends, consultation calls,
and signed request payloads retain their signatures.

Session independently consumes the one-use Security receipt, resolves the
canonical owner and private engagement, then asks the lower Comms public facade
to verify the exact command text, scope and still-live winning claim. Execution
requires a nonempty valid UTF-8 binary of at most 32,768 bytes; the token-only
helper used to construct a binding cannot bypass this execution
check. Session retains the binding separately from UserMessage and TurnAuthority.
Immediately before a queued turn activates, it rechecks both private ownership
and the durable claim.
A command already settled as uncertain cannot activate later. A refused queued
command releases its admission and continues to the next FIFO entry only while
Session is idle; an active asynchronous preflight retains the mind. The task ID
is a deterministic digest of the source scope and command ID; Session puts it into
authoritative Engine options so immutable RunAuthorization owns the value.
The private claim bearer never enters graph JSON, checkpoints, provider options,
status projections, renderer state or wire replies.

The reserved metadata names `command_binding`, `conversation_command_binding`
and `claim_token` are rejected by both authenticated ingress boundaries, including
nested maps/lists. Ordinary transport `task_id` metadata remains compatible, but
cannot create a journal binding or a RunAuthorization task ID.

## Reversible policy decision — 2026-10-03

Journal commands wait as separate FIFO turns. They are not implicitly folded
into another turn as steering messages: doing that would merge command outcomes
and make scoped progress/cancellation ambiguous. Existing ordinary authenticated
steering remains available. A future explicit steering command can have its own
qualified outcome contract.

## Producer generation boundary

Turn stream and Engine event callbacks capture the Session's process-local turn
generation. Session admits them only while that exact generation is executing,
outside embedding/index phases, with current private-owner authorization.
Retired callbacks and unqualified legacy `stream_chunk` messages are dropped
before accumulation or live-turn signal publication. Internal consultation
chunks retain private interrupted-turn evidence under the same generation gate,
but never publish human turn output or progress. Heartbeat callbacks retain their
separate heartbeat signal source and do not enter the human turn accumulator.
Progress is a closed bounded pair of lifecycle type and optional node ID: arbitrary
Engine context, notes, errors, paths and tool payloads are discarded. This state
remains excluded from general public Session status. The authenticated scoped
reader is available through `Arbor.Agent.conversation_activity/3`; Session checks
the command binding and current private-owner authority before returning progress.

## Qualification and original-source witness

Normal Mix checks run in the detached worktree
`tmp/worktrees/conversation-execution-binding-20261003`, with private dependency,
build, temporary and Arbor homes. The retained runner and source-bound receipts
are under `tmp/preserved/conversation-execution-binding-20261003`. The Security
observational EventLog uses its established recording adapter; these checks do
not claim durable Security audit persistence or microphone/provider acceptance.

The original-stream witness uses the unchanged current regression test with only
Session and Builders replaced by their `313b6a34` source bytes. It selects the
delayed producer test, compiles normally, and must fail in its test body because
the old producer's chunk enters the next turn's accumulator. Candidate source is
then restored and the same test must pass. The test uses the real public Builder
callback and an actual initialized Session, with a separate producer process and
an ordered public Session barrier; it does not fabricate a producer message.
