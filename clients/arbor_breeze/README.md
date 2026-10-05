# arbor-tui (Breeze)

`arbor-tui` is Arbor's native terminal conversation client, version `0.1.0-dev`
(unpublished). The previous TermUI client remains available as `arbor-tui-legacy`
for explicit rollback, with its separate execution root and lockfile. This client
includes reviewed Breeze 0.5.3 and Termite 0.4.5 source copies with the qualified
input and ownership fixes, plus the maintained Arbor Client/ConversationKit
packages. See [VENDOR.md](VENDOR.md) for provenance and licenses. Default adoption
requires separately recorded current-source joined and physical acceptance.

From this directory, use the pinned toolchain wrapper:

```sh
../../bin/mix deps.get --check-locked
../../bin/mix deps.compile
../../bin/mix compile --warnings-as-errors
../../bin/mix test
../../bin/mix escript.build
./arbor-tui --agent agent_YOUR_AGENT --url http://127.0.0.1:4000
```

## Build and install from a checkout

Build from this directory in a complete repository checkout. ConversationKit,
its Arbor adapters and the Client SDK remain sibling path dependencies; this
Breeze source package alone is not independently buildable. Separate library
publication and standalone source distribution remain future packaging work.

Existing installed `arbor-tui` files keep their old code until you rebuild here
and manually copy the resulting escript into your chosen PATH directory. Retain
the previous executable as `arbor-tui-legacy` for rollback. The repository does
not automatically install, copy or update either executable. Old `arbor-breeze`
files are also unchanged; the new canonical build produces `arbor-tui`.

Human device sign-in is the default. Target-specific startup prints the public verification URL and user code;
no-agent startup shows the same instructions in the native scroll region. It retains the resulting target-bound credential in the private
controller and SDK connection; it never writes a signing key or credential.
To use an existing owner-private agent/human signing key, pass `--key PATH`.
Remote Gateways require TLS. Exit closes the exact remote connection and attempts
logout of an owned human session. A host restart, grant revocation or expired
reconnect grace requires signing in again. No client wall-clock session cap is
introduced.

## Compatible startup preferences

`-a`, `-u` and `-k` are aliases for `--agent`, `--url` and `--key`.
Duplicate switches, including mixed short and long spellings, are refused.
Arguments remain independent of environment and file preferences when parsed.
The startup entry point resolves and validates the selected Gateway before any
signing key is loaded or a browser sign-in is requested.

URL precedence is **CLI → `tui.conf` → `ARBOR_GATEWAY_URL` →
`http://127.0.0.1:4000`**. Only `url` and `agent` preferences are used from the
legacy `key = value` file. A configured `agent` applies to chat only, below an
explicit `--agent`, and still requires fresh human browser approval. Operator
commands retain their explicit positional targets.

When `ARBOR_HOME` is explicitly set, preferences are read only from
`$ARBOR_HOME/tui.conf`; otherwise they come from `~/.arbor/tui.conf`. An isolated
home never falls through to the real home directory. Config reads accept regular
files up to 4,096 bytes. Unknown settings are ignored; malformed lines, duplicate
recognized settings, unreadable selected files, and oversized files fail with a
static message. Missing files use the remaining sources. Complete explicit
settings skip unused config. An invalid selected URL never falls back to another
Gateway.

Signing always requires an explicit `--key PATH`. Config `key`, `ARBOR_KEY`,
default key files and legacy credentials never choose signing mode automatically.
An existing script can deliberately pass `--key "$ARBOR_KEY"`. The signing
file's `agent_` or `human_` subject is retained verbatim; browser identity linking
and permissions remain host decisions.

`ws`/`wss` URLs are canonicalized by the shared Client to `http`/`https` origins.
Remote Gateways require TLS. Human login accepts plaintext only at literal
loopback addresses, so a legacy `ws://localhost:4000` preference must be explicitly
changed to `http://127.0.0.1:4000` or a TLS origin for human use. Signing mode
retains its existing `localhost` policy; the client never substitutes a hostname.

Legacy `tui.state` has no Gateway binding and remains untouched. Select its prior
target explicitly once; a confirmed attachment can then save the existing
Gateway-bound `breeze.state` hint. No credentials or transcript are migrated.
The executable name selects the renderer only. Gateway preferences, human
sign-in and explicit signing behavior remain as described above; this terminal
change does not select a web default.

The native textarea owns the draft, Unicode editing, cursor and multiline
layout. Enter sends; Shift+Enter inserts a newline. Tab switches focus between
the transcript and composer. F3 refreshes, F4 disconnects, F5 reconnects, F6
looks up and checks/retries the saved delivery ID, F9/F10 browse older/newer
bounded host windows, and F11 returns to the latest window. Escape exits.
The composer shows three lines and scrolls with its native caret; ArrowUp and
ArrowDown expose earlier and later draft lines. The latest transcript opens at
the bottom. With transcript focus, Home/End and PageUp/PageDown browse the
current window; returning to End resumes bottom pinning as host messages arrive.
Drafts survive manual disconnect. Access or ownership loss clears the active
private transcript and draft. Existing physical terminal scrollback cannot be
erased by an active-view clear.

`ConversationKit.Arbor.Connection` owns authorization, bounded host reads,
automatic updates and uncertain delivery reconciliation. The Breeze view
receives only closed snapshots; it never owns a second transcript store or
optimistic durable rows. A matching admission acknowledgement clears only the
unchanged submitted draft. Editing during a pending request preserves the new
draft. There is no full-transcript replay button or fixture question approval.
Voice capture/playback remains outside this text client.

The render cache defaults to an explicit 256 MiB limit. Set
`ARBOR_BREEZE_RENDER_CACHE_BYTES` to a positive integer before launching to
override it. The standalone client does not start OS disk/CPU monitors.
Breeze's public `logger: :replace` mode captures logs and temporarily silences
the default handler while the native UI is active, then restores it on exit.

The selected lock retains seven unchanged Hex records from the qualified
comparison. Breeze and Termite are repository-owned path dependencies; no
additional registry versions were selected. Tests use native `Breeze.Test`
components and an injected local authenticated host seam. They exercise the
actual decoded key/batch input and rendering path rather than a parallel mock
widget. Those frames do not establish raw terminal decoding or physical PTY,
keyboard, paste, resize or microphone acceptance. The included input fixes have
separate actual raw PTY paste and cleanup evidence. Complete current-source
browser/terminal acceptance remains a gate for default adoption. Normal Mix
and real Gateway qualification results are recorded separately in the production
UI packet.

Raw paste is configured for Arbor's 32,768-byte turn limit and
provides a bounded, safe rejection notice without submitting or replacing the
existing draft. The included parser preserves slow framing and discards expired
framing until its closing marker, without replaying its content as Enter.
Access/ownership loss unconditionally
resets the native editor, even when its visible draft is already empty, to
retire an in-flight paste generation.

Current work is separate from the history window and composer. F7 opens its
native list; arrow keys select a specific command or numbered choice, and
Enter requests that exact cancellation or answer. Escape returns to the
composer; a second Escape exits. F8 reads the next bounded activity page and
F12 returns to latest work. Tab reaches the selected item's scrollable details.
A changed prompt retires the old selection; select again before answering.
The host decides the result, so neither an answer request nor a cancellation
request removes a prompt or claims that execution stopped. Incomplete or
truncated discovery and unavailable controls are shown explicitly.

Protected approvals are read-only in this terminal. Their safe original-action
summary and public conversation review path guide the human to an authenticated
browser with approval permission. A target-bound terminal chat lease grants no
approval permission, and the terminal controller exposes no approval action.
Untrusted host text is displayed literally: C0/C1/DEL control codepoints are
escaped, tabs become spaces, and Unicode/newlines remain text. Host prompts
cannot emit ANSI/OSC terminal commands. These component tests do not establish
physical PTY input acceptance or a new dependency release.

## Local conversation commands

F1 or `/help` opens local help even while a read is busy or the connection is
disconnected. Escape dismisses it and returns focus to the draft. `/quit` uses
the ordinary surface shutdown and Controller cleanup path. `/retry` checks the
saved original request, while `/refresh`, `/disconnect`, `/reconnect`, `/older`,
`/newer` and `/latest` use the same intents as the existing function keys. `/work`
opens the exact current-work selector; `/more-work` and `/latest-work` navigate
its bounded discovery. These commands accept no arguments; `/attach TOKEN` is
the explicit target selection command.

Help/refusals are local display panels, never durable transcript entries. They
do not acknowledge a pending request or overwrite a newer draft. Runtime and
unknown slash commands are refused locally. Signed directory and attach are local navigation intents. Alias editing and
lifecycle commands provide guidance to the separately authorized Console or
CLI; a terminal chat lease grants no management authority. Input that is not
leading slash text retains its original Unicode, whitespace and newline bytes.
Decoded Breeze tests qualify native event routing; physical terminal paste and
key decoding require separate raw PTY acceptance.

Explicit signed operator commands run outside an active conversation:

```sh
arbor-tui agents --key /private/operator.arbor.key
arbor-tui resolve cedar --key /private/operator.arbor.key
arbor-tui aliases --key /private/operator.arbor.key
arbor-tui alias cedar agent_FULL_ID --key /private/operator.arbor.key
arbor-tui unalias cedar --key /private/operator.arbor.key
arbor-tui new researcher --name Cedar --key /private/operator.arbor.key
arbor-tui start cedar --key /private/operator.arbor.key
arbor-tui stop agent_FULL_ID --key /private/operator.arbor.key
arbor-tui --agent cedar --key /private/operator.arbor.key
```

All commands accept `--url GATEWAY_URL`. `new` also accepts `--model MODEL`.
The host resolves names, unique prefixes, and per-principal aliases; ambiguity is
refused. Signed conversation startup resolves to an exact authorized target
before creating its private connection. Human device sign-in continues to
require an exact agent ID and remains chat only. Use the authenticated Console
or an independently authorized signing identity for management.

Create/start/stop use existing public Gateway endpoints and independent host
capability gates. They never auto-attach a conversation or silently switch an
existing target. A missing capability or pending approval refuses the command.
If an operator reply is unconfirmed, inspect authoritative state before issuing
another command; no automatic retry is sent. Listing output is bounded, labels
and aliases render literally, and truncation is explicit. Catalogs belong to the
exact signing principal, which may differ from the linked browser identity.

## Explicit target selection

Omitting `--agent` opens detached selection. F2 or `/agents` loads/refreshes a
bounded signed directory using the existing Gateway catalog gate; Tab reaches
the native list and scrollable instructions. Arrow keys select an exact row,
and Enter explicitly attaches. `/attach TOKEN` freshly resolves a signed alias,
name or prefix, then binds the resulting full ID. Directory labels are literal
text and truncation is visible. No lifecycle action is implied by selection.

Human mode accepts only a full agent ID obtained through the authenticated Home
at `/home`. Every different target starts a new target-specific browser sign-in;
the existing chat lease cannot list or resolve agents or grant management or
approval authority. Escape dismisses help first, returns from selection to an
existing conversation when idle, or closes detached selection and cancels its
owned pending login.

Switching is refused during a host operation or unresolved delivery. `/retry`
checks the original saved ID before another target may be selected. Once idle,
the Controller confirms the old Connection and transport are closed and its
owned human lease cleanup is confirmed before opening another binding. A private
cleanup guardian also attempts logout if the Controller is killed; a network
failure in that best-effort path does not establish remote revocation. An
unconfirmed cleanup blocks a replacement; there is no automatic resend or
transfer of unresolved commands. Late results from the old owner are ignored.

Ordinary exit waits for owned cleanup and returns an error if cancellation or
logout cannot be confirmed. Acquisition workers retain their private receipts
until explicit adoption or discard; exit never kills that sole receipt owner.
All acquired handoffs share one 45-second cleanup wait. The public close budget
is 100 seconds, covering that wait, a pending login cancellation, and both
possible Connection/transport/lease retirement sets. No cleanup timing option is
exposed as a command-line flag. Owner death still triggers best-effort cleanup
and does not establish remote revocation after an uncertain network result.

Only unsubmitted drafts are cached in memory, bounded to 16 exact
Gateway/principal/target scopes. Access invalidation clears the whole cache.
Credentials, transcripts and submitted requests are never migrated or persisted.
A private `breeze.state` file under `ARBOR_HOME` (or `~/.arbor`) stores only a
confirmed public target ID and its Gateway string. On the next no-agent startup
this preselects the input as a hint; it never attaches, starts an agent, changes
the Gateway, or grants access. Malformed or oversized state is ignored.

Alias editing inside the active UI and parking unresolved work remain separate
features. Selecting Breeze as `arbor-tui` does not restore server slash dispatch.
Decoded native journeys qualify component routing and ownership; current
physical PTY/Gateway acceptance is recorded separately.

### Read-only notices

`/notices` opens a separate notice panel. Shift+F7 and CSI-u F13 provide keyboard shortcuts; traditional xterm F13 (`ESC[25~`) is not decoded by the pinned renderer, so use `/notices` if the shortcut is unavailable. PageUp reads the next older page at the original cutoff; Home checks the latest head. `/older-notices` and `/latest-notices` perform the same reads. Escape returns to the draft. Notices never enter the transcript, create commands, or play audio. A notice-only timeout clears the notice panel while keeping a separately refreshed transcript; sign-in or scope loss clears the whole private conversation.
