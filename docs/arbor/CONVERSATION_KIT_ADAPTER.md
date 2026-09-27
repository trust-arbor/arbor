# Standalone ConversationKit Arbor adapter

The consumer integration lives in the independently versioned
[`conversation-adapter-requalified-20260927` artifact](../../tmp/preserved/conversation-adapter-requalified-20260927/README.md).
Its three packages separate generic conversation display, Arbor authentication
and replay, and native LiveView/Breeze interfaces. The isolated Arbor fixture
imports those external packages through test-only path dependencies.

| Package | Responsibility |
| --- | --- |
| `conversation_kit` | Dependency-free event reduction and semantic snapshot projection |
| `conversation_kit_arbor` | Authenticated public facade calls, strict response validation, independent read positions |
| `conversation_demo` | Per-surface client owner, local drafts, native LiveView and Breeze input/rendering |

The adapter calls the four [conversation host APIs](CONVERSATION_HOST_BOUNDARY.md).
It obtains a fresh proof for every request, including each replay page and
retry. Trusted server configuration supplies the principal, target, facade and
proof provider. Those values remain outside renderable snapshots. A production
web entry point must supply that binding from its authenticated user session;
the experiment uses one ephemeral configured principal on loopback.

```elixir
alias ConversationKit.Arbor

{:ok, client} = Arbor.new(caller_id, agent_id, proof_provider)
{:ok, client} = Arbor.sync(client)
view = Arbor.projection(client)
positions = Arbor.position(client) # %{history: ordinal, commands: cursor}

# Generate and retain this ID before submission. Retry the same ID and text.
{:ok, client, delivery} = Arbor.submit(client, stable_command_id, text)
```

Keep the client in a trusted owner process. The proof provider is a function of
the request context returning `{:ok, [session_token: token]}` or
`{:ok, [signed_request: fresh_request]}`. A signed request must have a fresh nonce.
Only projection, position and sync-status values belong in renderer state.

## Two records, shared presentation

The transcript supplies chat messages. Command records supply separate delivery
status blocks and acknowledged delivery results. The adapter never invents a
command-to-transcript correlation, substitutes a result for a missing transcript
message, or merges the two cursors. Equal content remains distinct when its
source identities differ.

Each sync reads bounded pages through independently pinned heads. If a read
fails, it returns no replacement client. If the page budget is exhausted,
successful prefixes are retained and the next refresh continues the pinned
sequence. Oversized pages reduce their page limit; oversized individual content
remains an explicit error. The adapter does not truncate text.

Each interface owns its draft and read positions. Refresh/reconnect catches up
from the shared host. A lost admission acknowledgement retains the original
command ID and text for lookup or equal retry. Admission confirmation clears
the matching submitted draft even if the following read fails; newer edits are
preserved. Authorization denial clears cached private projection, positions and
drafts, including the browser
input through its client hook.

## Qualified boundary and limits

The isolated composition uses real Arbor Security, Comms, Session, Engine and
SQLite. Session executes a deterministic transform-only DOT and commits its
ordinary transcript; there is no substitute Session or manually inserted
conversation history. Tests exercise both renderer runtimes, lost replies,
renderer process death, private-user isolation and revocation. Model calls,
external tools and audio are outside the fixture. Test configuration also
disables some broader policy/reflex and durable-audit integrations; this is not
a qualification of every deployment policy combination.

The demo uses explicit refresh. Push delivery, remote terminal transport and
production login wiring remain integration work. Drafts and the unresolved
submission buffer are process-local; only host-admitted commands survive losing
that owner. Replay produces no speech playback or unclassified speech content.
The package retains growing history in memory and the host journal currently
reconstructs its prefix: large-history indexing, retention and windowed rendering
need a later performance slice.

Standalone source revision `898c3bfc2a8fb5d04fc4667bc6a481bc8e93a5ec` passed
requalification against Arbor `51b2d08e8`, including canonical-owner convergence,
transcript freshness and the source engagement fence: 17 core, 32 adapter,
22 renderer and 8 real-host tests (79 total). All four warnings-as-errors builds
passed. The host patch changes only test fixtures and their dependencies.

Repeated failed initial reconnects now remain visibly unavailable until source
synchronization succeeds. The new regression fails behaviorally on the previous
package. Previously attached clients retain verified cache on a transient read
failure. Actual browser and Breeze PTY checks exchanged Unicode messages in both
directions and preserved a browser draft through disconnect/reconnect. The
temporary qualification listener exited cleanly.

The [current-host report](../../tmp/preserved/conversation-adapter-requalified-20260927/integration/CURRENT_HOST_QUALIFICATION.md)
contains reproducible commands and explicit limitations. Its separate
`host-current.patch`, source hashes, fixture bundle, test logs and PTY evidence
are preserved with the artifact. The older `host.patch` and preparation script
target the historical host and must not be applied to the current baseline.
No library has been published and no existing Arbor UI route has been migrated
by this experiment. Audio and the final assistant-ui comparison remain separate
qualification work.
