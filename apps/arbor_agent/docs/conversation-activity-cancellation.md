# Conversation activity and cancellation

2026-10-03. This additive host API reads bounded source command activity and
persists cancellation intent independently of delivery. It uses fresh
authenticated conversation receipts; expected_engagement_id is compare-only.

## Record compatibility and rollback

Existing admitted, dispatch_started and settled v1 records and existing signed
payload bytes remain unchanged. Readers explicitly support cancel_requested.v2
and cancel_acknowledged.v2 before the cancellation operation writes them. New
v2 writes occur only through the explicitly invoked cancellation API; existing
submission and history operations do not enable them. There is no global writer
flag: requesting the new operation opts that stream into v2 compatibility.

Once a stream contains v2 records, an old reader rejects it safely. A code rollback
must retain the compatible reader, or restore a saved compatible journal snapshot
under a separate operator-approved data recovery procedure. Never downcast or
rewrite v2 cancellation to v1 completion/uncertainty. No live data migration is
part of this code change. The command index is a rebuildable read model and its
watermark must never be used as execution or cancellation authority.

## Closed result policy

Activity defaults to 20 active records, maximum 50. Exact original
owner/target/engagement and active-state SQL filtering happens before the limit.
Pages start with the newest immutable admission tuple
`{admitted_event_number, command_id}`, descending on both fields. `next_cursor`
selects strictly older tuples, with the command ID breaking equal ordinal ties.
F8/earlier work follows that cutoff; F12/latest work resets it. New admissions
and later updates cannot move an existing admission key across a saved cutoff.
Each page observes current active state and fresh source/index watermarks; this
is live discovery, not a frozen historical state. Completed or confirmed work
may leave later pages. An incomplete index remains explicit, and clients never
follow every page automatically. A preview is cumulative UTF-8 text capped at
32 KiB per command and encoded response
is capped at 128 KiB; truncation is explicit. Missing live Session state is
not_observed. Heartbeat, consultation and unbound messages supply no activity.

Cancellation first commits cancel_requested under stream-version CAS, then
contacts the configured Session port. Missing Session, timeout and lost reply
remain requested/unconfirmed. Confirmed active termination requires the exact
private binding and positive Engine DOWN proof after publication/egress fencing.
Queued cancellation closes only that admission and advances FIFO. Durable intent
refuses later claim, admission and queued activation. Completed and uncertain
delivery outcomes remain immutable even when cancellation is acknowledged.

A bound command must open its private Comms interaction source before the Engine
starts. Source admission failure refuses the turn and cleans preparation resources.
Source handles travel only through execution controls, never serialized context or
provider options.

## Projection recovery

Writes and authenticated discovery enqueue one supervised Comms projector.
After restart, the first read returns durable indexed rows immediately and
queues catch-up from the saved watermark; it does not replay in the client.
Source pages are contiguous and capped at 100 records. A page and its index
watermark commit atomically. Fair rotation prevents one long history from
starving another scope; failed scopes retry after five seconds. The process
backlog holds at most 1,024 scopes. A full backlog leaves explicit index lag and
a later read can retry enqueueing. The source journal retains every record.

The index conservatively includes uncertain delivery until a separate durable
termination acknowledgement exists. Uncertain delivery alone cannot prove that
execution ended. Activity exposes not_observed when its live generation is gone.
