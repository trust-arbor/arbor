# Private goal context

M3 adds an explicit private goal update and a bounded private Session prompt
section. It retains M1b1's denial of tool-derived memory writes. Ordinary chat
does not infer goals or promote model output into this lane.

`Arbor.Orchestrator.Session.update_private_goal(session, request, receipt,
goal_id, attrs)` accepts the same exact `UserMessage` and one-use Security
delivery receipt as authenticated chat. The sender is a claim compared with
the broker's actual principal. Session resolves that human's canonical private
Comms engagement, activates the admission in its own PID, performs the update,
and closes it. The request is not appended to the transcript. Busy and legacy
Sessions refuse the update; presented receipts are spent on rejection.

The goal identifier is 1–64 ASCII letters, digits, underscores or hyphens.
Attributes have exactly four string keys: `description` (1–4096 UTF-8 bytes),
`priority` (integer 0–100), `progress` (number 0–1), and `status` (`active`,
`achieved` or `abandoned`). One identifier replaces one goal within the proven
pair. There are at most 50 goals and at most 262,144 canonical JSON bytes per
snapshot. The unsigned payload is bounded before signing and the complete
sealed payload is checked before storage.

`Arbor.Memory.put_private_goal/3`, `get_private_active_goals/1`, and
`private_goal_context/2` require a live exact-caller admission. Security checks
the current human and agent identities, current human chat authorization, and
the agent's ordinary self-scoped memory read/write capability on each use.
No new grants or caller-selected scope options are introduced. Engagement,
session and turn remain sealed source provenance, not independent Security
membership claims.

The existing MemoryStore holds one acknowledged snapshot in `private_goals`.
Its key is SHA-256 of canonical JSON `[agent_id, human_id]`; its Record ID is
`memory:private_goals:<key>`. A separate system-root signing purpose binds that
physical identity, all five provenance fields, the complete unsigned body,
and its logical `snapshot_revision`. A trusted persisted root is required;
an agent signature or copied metadata label cannot replace it. The current
root alone verifies historical seals, so root rotation requires an explicit
migration/recovery decision before old snapshots become readable again.

Writes require a selected backend advertising `:node_restart` authority and
use MemoryStore's acknowledged CAS with the exact observed physical Record.
Success verifies the returned identity, complete body and valid physical
fences. Cache-only acceptance is insufficient. `:outcome_unknown` remains an
ambiguous outcome; it does not assert rollback. The synchronous call inherits
the backend's execution behavior and does not establish caller-death rollback
or a new latency bound. The existing MutationAdmission lease encloses the
write; no private goal data enters the legacy goal ETS projection or embedding
index.

Decision recorded 2026-09-09: backend generation/revision are concurrency
fences, not part of the origin seal. A missing row may hide a generation
tombstone, so predicting its next generation before CAS could persist a
knowingly invalid seal. The seal instead binds a logical snapshot revision.
Live CAS still uses the actual backend fences. Cold verification proves
root-origin authenticity; it does **not** prove freshness against offline
rollback or reinsertion of an authentic older snapshot. No new store callback,
transaction mechanism, signer service or ownership schema is added.

Cold reads re-read the authoritative store and verify the whole snapshot,
physical identity, restricted fallback taint and root seal before selecting
active goals. They recheck the live admission before releasing data. Another
human using the same agent selects another pair. Unscoped legacy goal APIs do
not enumerate private snapshots. Existing GoalStore destruction and absence
checks include a bounded authoritative private inventory: every candidate row
is verified before filtering by agent, and deletion uses the exact verified
Record in compare-and-delete. Malformed or ambiguous inventory refuses cleanup.
The existing caller-owned mutation drain remains a destruction precondition.

The ordering boundary is one live local BufferedStore owner. A CAS is either
not submitted when its caller dies (and no later task submits it), or is already
in that owner's mailbox/execution. Cleanup's synchronous authoritative inventory
queues behind submitted CAS work, even when the inventory ultimately returns
empty, and its exact compare-and-delete follows that inventory. There is no
cache-only absence shortcut or deferred private projection. MutationAdmission
does expose `handoff/3`; the existing proposal-transfer protocol would become
necessary if future work is deferred to another owner after admission. This
slice does not make that transfer or assert cancellation of remote outstanding
backend writes after owner/backend failure.

Session inserts only the verified goal section after preprocessing, with
restricted untrusted taint. Rendering uses the existing model-relative goal
budget (5% of context, bounded to 200–4000 estimated tokens). Both provider
messages and the flat user prompt derive from the enriched last user message;
the configured identity/system content remains byte-identical. The existing LLM
handler prepends a fresh security nonce on every call, so the complete outbound
system message is intentionally not byte-identical between calls. This slice
preserves that defense and checks the unchanged content behind its exact preamble.
Storage or authorization
failure omits this section rather than releasing cached data.

Private turns omit the named agent-global goal, working-memory, self-knowledge,
intent, knowledge-graph, proposal and recent-activity sections because those
stores do not prove ownership by the current human. Conversation recall keeps
its separate M2 admission path. Direct APIAgent and Claude host calls still
lack private Session admission and cannot use this private goal lane or gain
automatic private writes from caller labels. Their supported boundary remains
the source-only Session path.
