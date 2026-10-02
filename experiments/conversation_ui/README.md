# Conversation UI comparison source snapshot

This archive preserves the authored sources accepted in the 2026-10-01
conversation UI comparison. It is an experiment, not a production dependency,
renderer migration, published library, or complete Arbor checkout.

The conclusion is to retain LiveView and Breeze for production. Assistant-ui web
and Ink worked through the tested external-store boundary, but this experiment
did not establish a required capability gap, lower maintenance cost, or general
agent productivity advantage.

## Contents and byte identity

`snapshot-manifest.json` records the SHA-256 and size of every preserved file.
It preserves 128 source/configuration/manifest origins from the accepted
workspace's frozen-input receipt. Of those, 113 files remain byte-identical;
15 Elixir files were normalized by the existing root formatter to satisfy the
commit hook. Their actual archive hashes differ from their original
`frozen_sha256` hashes and are marked `formatting_only`. The new README, ignore
file, portable reports, and reversible formatting patch are identified
separately in the manifest; the manifest does not hash itself.

`reports/original-source-formatting.patch` maps the exact qualified bytes to
the normalized archive files. To reconstruct those original bytes, use a
**disposable copy** of this archive, change into its root, and reverse the patch:

```sh
/usr/bin/patch --dry-run -R -p1 < reports/original-source-formatting.patch
/usr/bin/patch -R -p1 < reports/original-source-formatting.patch
```

The patch retains its nonblank context. Twelve blank context records are encoded
as empty lines instead of literal single-space lines to satisfy the commit
hook's whitespace check. Exact reversal with `/usr/bin/patch` was verified for
this representation; a naive zero-context diff misapplied an insertion on the
tested platform despite returning success and is not used here.

The restored source files must match the manifest's `frozen_sha256` and
`frozen_bytes` fields. The normal archive files match its `sha256` and `bytes`
fields. Reconstruction changes the 15 source files only; the manifest and
reports continue to describe the committed normalized archive. The formatter
configuration and original qualification sources were not changed. An
independent offline comparison confirmed identical metadata-free Elixir ASTs
for all 15 current normalized files. The pinned formatter required a second
pass for `application.ex`; its second and third outputs agree, and the archive
uses that stable layout. The actual public
`Mix.Tasks.Format.formatter_for_file/2` API verified all 218 selected Elixir
files, including the archive's 73, as formatter fixed points. A four-assertion
regression distinguishes matching an initial output from being a fixed point.
The previous manifest and reconstruction patch remain in the private evidence
packet. The archived qualification remains the original execution evidence;
no new host or renderer qualification is claimed from formatting alone.

| Path | Purpose |
| --- | --- |
| `typescript/shared/` | UI-independent host store, question envelope parser, protocol transport, Node WebSocket connector, and scripted transport fixture. |
| `typescript/web/`, `typescript/ink/` | Assistant-ui adapters, actual renderer controls, behavioral tests, joined-surface helper, and scale harness. |
| `typescript/tests/` | Dependency-free store/transport/resolver tests and the authenticated Gateway Node entrypoint. |
| `typescript/package.json`, `package-lock.json`, `published-resolution.json` | Exact published package selections, complete npm lock, integrity metadata, and peer/engine declarations. |
| `baseline/packages/{core,adapter,remote,demo}/` | ConversationKit prototype and LiveView/Breeze baseline, including the same structured-question extension and bounded history controls. |
| `baseline/source/clients/arbor_client/` | Standalone Elixir SDK source, tests, manifests, and lock used by the remote adapter. |
| `baseline/source/apps/`, `baseline/source/config/test.exs` | Host comparison test and its supporting fixture/configuration overlay. This is a source skeleton. |
| `baseline/bin/mix`, `.tool-versions`, `scripts/scale.exs` | Preserved toolchain wrapper, tool versions, and baseline scale harness. |
| `reports/` | Portable, sanitized qualification review and scale observations. |

No dependency sources, `node_modules`, build output, native archives, databases,
credentials, private conversation transcripts, raw operator logs, or complete
host copies are included. The copied Phoenix and LiveView JavaScript bundles
were excluded; reconstruct those assets from the baseline's locked dependencies
when preparing an interactive browser demo. The authored `app.js` and CSS remain.

The package READMEs and preparation helpers retain their historical wording and
local paths because their source bytes are preserved. This README and the
portable reports describe the final accepted comparison boundary.

## What the comparison qualified

All 25 execution phases passed. The selected tests were 23 shared-boundary,
14 published-resolution, 11 assistant-ui renderer, 17 baseline renderer, and
one real Gateway test: 66 distinct cases. Ten additional fresh processes each
passed the same 11 renderer cases; those repeats are not 110 new distinct tests.
Type checking, the web bundle, locked dependency preparation, and public export
inspection also passed.

The real Gateway journey used Arbor's actual Security, terminal DeviceFlow and
JWT verification, linked identities, Gateway v2 socket, Session, Engine, and
persistence. A test-owned loopback identity provider and scripted model replaced
external providers. The fixture retains its isolated policy profile, with wider
policy, reflex, and preprocessor integrations disabled; it does not qualify
every production policy profile. Actual mounted web choice/confirm controls and the Ink
Unicode composer submitted commands through the same authenticated store.
Both baseline surfaces observed the resulting host transcript. The final
transcript contained six entries and the delivery journal cursor was nine;
reconnect preserved host message IDs. Local access loss cleared both mounted
assistant-ui projections and their drafts.

The store preserves host message and command IDs, separate transcript and
delivery cursors, history-first reconnect, and explicit unknown send outcomes.
It looks up a saved command before an explicit retry, clears active private
projections after disconnect/access loss, and does not create optimistic durable
transcript rows. A question must be parsed from an authoritative assistant entry.

The three-choice question is an experimental text envelope in an ordinary chat
message. Selection is local until confirmation sends an ordinary chat command.
It is not a security approval or a production host-enforced form protocol: the
host does not atomically enforce one answer across stale surfaces or validate
question revisions as a production interaction contract.

No physical browser, PTY, mobile device, microphone, live model, or voice playback
acceptance is claimed. Local clearing is not a real Gateway revocation test and
cannot erase physical terminal scrollback. Streaming, independent simultaneous
surface drafts, and renderer process-death recovery remain outside this result.

## Scale observations

Both stacks retained 100, 1,000, and 10,000 authoritative messages while rendering
a default window of 20; all windowed lanes passed. All six assistant-ui full
history lanes passed. LiveView's three full history lanes and Breeze's 100 and
1,000 message lanes passed. Breeze's 10,000 message full-history lane reached
the public test API's five-second timeout in the one observation taken.

These measurements use different boundaries: LiveView HTML rendering, JSDOM
mounts, Breeze redraws, and Ink test frames. Ink's recorded geometry also differs
from Breeze's 110-by-55 test terminal. The timings are not a direct performance
ranking. The complete content-free measurements and limitations are in
`reports/scale-summary.json`.

## Qualification review and local receipts

The original operator result remains `frozen_input_drift`. A separate review
accepted exactly two generated PortAudio C/C++ outputs whose only changes were
local loop-index identifier renames. The review reconstructed their original
bytes, checked 12,231 unchanged frozen inputs and 24 execution-log hashes, and
did not rewrite the original result. The portable report retains the original
result and review hashes, selected counts, claims, and the exact reviewed change.

The full local receipts remain outside this archive at:

- `tmp/preserved/conversation-ui-dependency-bootstrap-20261001/attempt-20261001T195800Z-1a41cd/`
- `tmp/preserved/conversation-ui-generated-drift-review-20261001/`
- Accepted source workspace: `tmp/worktrees/conversation-ui-dependency-bootstrap-20261001-rz4ezrx2/`

This snapshot is not the original closed qualification runner. In particular,
`typescript/verify-prepared.mjs` requires the deliberately omitted
`dependency-evidence/` operator receipts. Do not treat it as a portable archive
verification command. Registry inspection/resolution scripts are retained
source, not an instruction to reselect packages or perform network calls. Reuse
the exact package manifest and lock for this experiment.

## Using the preserved sources

The four dependency-free test files can run from `typescript/` without npm
installation:

```sh
node --test --test-reporter=tap tests/store.test.mjs tests/transport.test.mjs tests/node-channel.test.mjs tests/published-resolution.test.mjs
```

Renderer tests require the exact locked npm graph and a compatible Node version
(the executed qualification used Node 26). Dependency preparation used
`npm ci --ignore-scripts --no-audit --no-fund`, with engine and peer checks and
one shared assistant-ui core; it used neither force nor legacy peer resolution.
After deliberate dependency preparation, the complete 11-case renderer command
is:

```sh
node --import tsx --test --test-reporter=tap --test-concurrency=1 web/renderer.test.tsx ink/renderer.test.tsx web/renderer-journey.test.tsx
```

The unchanged package `test:renderers` script names only the two original files;
use the explicit command above to include the joined-surface lifecycle case.

For host integration, populate `baseline/source/` with a fresh isolated Arbor
checkout containing the conversation host fixes, then deliberately overlay the
included SDK and host test/support files. Preserve the sibling `baseline/packages`
and `typescript` layout: the adapter dependencies and the comparison test pin
those relative paths. Review the included voice `mix.exs` test-only dependencies
and private `config/test.exs` against that checkout before applying them. The
host was qualified from a frozen source snapshot, not a pristine commit; this
archive does not preserve the entire host tree.

Use an isolated home/environment with no copied `.env`, production credentials,
or application data. The preserved test configuration loads `.env` if present
and relies on the original runner's environment isolation. Its private storage
paths and fixture startup checks must remain intact. Do not overlay this source
skeleton onto the running development server. No automatic reproduction runner
or host adoption is provided here.

The actual comparison fixture is
`baseline/source/apps/arbor_voice/test/arbor/voice/conversation_ui_comparison_test.exs`.
It requires `CONVERSATION_COMPARISON_NODE_SCRIPT` to resolve to this archive's
`typescript/tests/real_gateway.mjs`, mints a test-owned session through the real
login path, writes its temporary configuration with mode `0600`, and removes it
after Node completes. No human signing key export or invented login path is
needed. Preparing and rerunning that fixture is a new qualification; the archived
result does not claim that an arbitrary checkout has been tested.
