# Concrete bounded multimedia driver follow-up

Initial source review, 2026-09-27. Arbor design base:
`91e01de3802a1297205cc3c9d457ddea704c3db2`.
Reviewed PortAudio fork: `3ecfad95d64b0edde79219c37934ac660083d9a6`.
Reviewed sensitive Core: `bc01d4f7d08522a5e5028078a082a311161b7b9c`.
These published prerequisites retain their exact scope. The default Arbor driver
stays `Unavailable` until the follow-up and renewed admission are qualified.

## First implementation slice — 2026-09-27

The local PortAudio follow-up implements immutable executor leases and separate
bounded Source open/start. A leased effect addresses its pinned executor
PID/generation, checks deadline/revocation after queueing, and cannot fall back
to the unrestricted legacy path after executor replacement. Unbounded
inline-start constructors are excluded from leased admission. Caller/custodian
death retains checked cleanup; resource destruction remains available after
revocation. Source/Sink carry the pinned identity into their native operations
and cleanup callbacks.

This is isolated fork candidate
`a24bb59d5fa906e0b8f073d2c15ea697fa05dd8d`, not an Arbor dependency update. Its
immediate test-bearing predecessor is `54610f666bbeb87995a0b59da50182e4904d6c20`
in `tmp/worktrees/portaudio-lease-source-20260927`. Qualification records live in
`tmp/preserved/voice-native-lease-source-20260927/`. The published Core and
PortAudio pins and the active Linux baseline retain their earlier scope.

The fixed candidate passes 396 native fake assertions under ASan/UBSan and
49 sealed Elixir tests (27 element/ownership, 22 executor lease). Independent
exact-parent runs fail two premature native start/payload assertions, four
element tests and 20 lease tests behaviorally; no missing-function failure is
used as a witness. The public lease APIs and actual Source/Sink callbacks are
exercised with real Native modules removed from the test VM code path. There is
no automatic deadline timer stopping an already-running stream: the host still
owns revocation/close and the device fence.

The actual Unifex/C/Objective-C dependency and Arbor multimedia app also compile
with warnings as errors in both development and test environments in an isolated
Arbor checkout. This is host compiler evidence, not renewed Linux admission or
device execution. A complete Git bundle preserves the candidate and regression
history in the evidence directory.

The next plugin slice is the no-effect startup registration/custody ACK and
native payload/completion correlation described below. Permission status queries
still precede the executor gate in the current elements. Bounded enumeration,
dormant NativeSession activation and actual capture/playback integration also
remain open. None of the fake-native results establish physical audio behavior.

## Minimal host structure

Keep the public `Arbor.Multimedia` facade and its qualified DeviceOwner,
DriverWorker, OperationCore, permit and atomic fence. Add one internal native
adapter and a temporary supervised NativeSession. NativeSession owns one
sensitive pipeline, records its supervisor/PID, every effect-capable element PID,
the pinned executor PID/generation, and at most one active cleanup request.
It monitors DriverWorker and continues cleanup if that worker dies. All ordinary
status, current-message and crash formatting remains redacted.

A native adapter `open/2` creates a **dormant** NativeSession with no native work
and no PCM in startup arguments, returning its opaque custody handle. Extend the
internal Driver contract with an activation callback: DriverWorker installs the
handle in its state first, then sends the authenticated, redacted activation
request containing spec/permit. A queued self-activation inside `open/2` alone
does not prove this handoff ordering. Existing fake drivers implement activation
without hardware. The handle can expose a private atomic dormant/closing/closed
state so no-effect cancellation and already-proven close survive controller exit.
Unknown active-controller loss stays cleanup-pending.

NativeSession init and pipeline init create no device elements. The pipeline
uses `use Membrane.Pipeline, sensitive: true` and initially returns
`setup: :incomplete`. PCM arrives later through a private, correlated message.
Its custom collector/binary-source modules also opt into sensitive diagnostics;
Core inheritance protects the dependency Source/Sink and their owned utilities.
No PCM or credentials go into names, Logger metadata or printed errors.

## Required prerequisite follow-up: element lease and startup custody

The published executor serializes native operations and rejects dead/fenced
owners. It does not know Arbor's deadline or revocation flag. Checking before
starting a pipeline cannot prevent a queued create or Sink ready-to-start call
from running after expiry. The native agent independently confirmed this gap.

Add a generic, data-only bounded lease, with no Arbor dependency or callbacks:

- Pinned executor PID/generation.
- Absolute monotonic deadline and a revocable atomics cell.
- Live host custody/caller processes and the actual creating element PID.
- Private operation/notification correlation.

Bind it once to each creating element before effects. The executor checks the
same immutable lease immediately before create, write and start, including after
queueing. Deadline values may be negative monotonic timestamps. Cleanup remains
available after revocation. A conflicting rebind cannot renew an expired/fenced
owner. Executor replacement invalidates the lease rather than silently accepting
an old operation in the new generation.

Add an opt-in gated initialization mode to bounded Source/Sink:

1. Validate options and enter incomplete setup with no permission query or native
   work. Notify the parent of the actual `self()` PID using a private startup
   correlation supplied through the internal options.
2. NativeSession records/monitors that PID and binds its executor lease before
   acknowledging admission. Every potentially effectful child is known before
   it can open. Pipeline failure before acknowledgement therefore has no hidden
   native constructor to discover.
3. The acknowledged Source performs a gated authorization-status query on Darwin.
   Only authorized status proceeds. No implicit permission request is added.
4. Complete setup and issue native effects through the lease-aware executor.
   Recheck at the effect boundary, including after permission/setup waits.

This supplies an explicit public plugin lifecycle notification instead of reading
`context.children[name].pid`: `Membrane.ChildEntry` expressly excludes `pid` from
its public API. Public parent callbacks expose child names, not a documented PID
lookup. `handle_child_setup_completed` is too late to make the existing Source
initialization permission query safe.

Split **bounded Source open and start**. Its current Native.create calls both
`init_pa` and `start_pa`; if opening blocks until after expiry, one pre-create
lease check does not prevent the later start. Sink already has a separate start.
Initialize callback storage before either phase, then recheck the lease before
Source.Native.start. An already-entered Pa_OpenStream/Pa_StartStream NIF still
cannot be forcibly cancelled; report pending cleanup and retain custody.

The callback/parent evidence must carry private per-operation correlation all
the way from the producing stream. The current raw
`{:portaudio_capture_finished, disposition, frames}`,
`{:portaudio_playback_finished, disposition, frames}`, and capture payload
messages do not themselves authenticate their producer. Rewrapping a message in
Arbor's private `Driver.notify/2` does not repair an earlier uncorrelated hop.
Add a bounded private stream token to native payload/completion messages and
validate it in the element; preserve correlation in parent notifications. Treat
unmatched/stale notifications as non-authoritative. Alternatively, a separately
qualified native completion query may corroborate wakeups, but it must also solve
capture-payload provenance; a count query alone does not do that.

## Concrete pipelines

Capture:

```
PortAudio.Source(max_frames: exact_frames, channels: 1,
  sample_format: :s16le, sample_rate: requested_rate,
  device_id: requested_device, portaudio_buffer_size: 256,
  gated lease/correlation)
  -> Arbor bounded PCM collector
```

The collector validates the exact stream format, even nonempty byte counts and
aggregate ceiling, then emits authenticated PCM chunks. NativeSession accepts
only this operation's registered source/collector and routes through
`Driver.notify`. A native `:complete` disposition must report the exact requested
frame count. Failed/cancelled dispositions are media failures. OperationCore
joins count and bytes in either arrival order and stamps accepted completion.
There is no public early-finish API in this slice. Stream EOS is not success.

Playback:

```
Arbor bounded binary PCM source
  -> PortAudio.Sink(expected_frames: exact_frames,
       device_id: requested_device, portaudio_buffer_size: 256,
       gated lease/correlation)
```

The binary source receives the payload after custody/admission, publishes the
exact RawAudio format and emits bounded aligned buffers in response to demand.
No PCM is an element or pipeline startup option. Sink's checked write path
collects the exact payload and starts through the final lease check. Only the
correlated native finished callback with `:complete` and exact consumed frame
count becomes `{:complete, frames}`. Buffer acceptance, demand, EOS and a close
ACK never substitute for playback completion. This proves driver completion,
not that a listener heard the audio.

## Close and abnormal failure

Revocation prevents new effects. Request checked close from every known native
owner, and use `close_owner(pinned_identity, creating_element_pid)` for the
serialized exhaustion barrier. A successful barrier fences later queued work;
a live pipeline cannot reopen after it. `:stop_failed_closed` releases custody
while preserving the media failure.

NativeSession handles close requests asynchronously and immediately reports its
current closed/pending status. It runs at most one owned cleanup operation at a
time; repeated DriverWorker retries must not pile up queued native calls. Native
work that outlives the caller deadline remains supervised. After positive native
closure, terminate the pipeline and confirm its owned process tree/cleanup work
has settled. Only then publish closed state and allow DriverWorker to release
its exact fence. Pipeline/ResourceGuard DOWN alone proves no native exhaustion.

On startup failure, close all **recorded** potential constructors, including
children that never reported successful open. Not-opened is accepted only from
the gated no-effect phase or a classified native result. An unknown constructor
result, changed/dead executor generation, or lost active custody remains pending.
There is no replacement-generation shortcut and no forced public fence clear.

## Required prerequisite follow-up: bounded device enumeration

Do not route `devices/0` through the published `list_devices/0` yet. Its
`pa_devices.c` ignores Initialize/Terminate results, accepts an unbounded device
count, does not check allocation/device-info pointers, and does not free its
allocated device array. The executor treats it as a generic call with no retained
initialization lease. Elixir normalization cannot repair those native defects.

Add a bounded enumeration resource to the same serialized ownership system:

- Checked initialization, maximum 128 entries, checked allocation and device
  info pointers, bounded name reads/copies, and a freed temporary array.
- Fixed, nonformatted errors and the existing UTF-8/control-character/name,
  channel, rate and unique-ID checks before public release.
- Retained ownership after successful initialization until checked termination;
  failed termination retains a retryable resource. Unknown constructor outcome
  remains pending. No stream is opened and no permission request is made.
- The same generation/deadline/revocation admission and cleanup barrier.

Normalize only the facade's five allowed fields; do not pass native structs or
arbitrary device metadata through. Deliver the list only after positive close.
Until this API is qualified, native enumeration remains unavailable.

## Implementation and acceptance sequence

1. Make a separate reviewed plugin follow-up for gated startup/leases, public
   correlated element registration, bounded Source open/start, and native event
   correlation. Preserve the already-published commits; do not rewrite them.
2. Add bounded enumeration ownership independently with fake native allocation,
   initialization, pointer/error, oversized-count/name, and failed-termination
   cases. Keep the old listing API out of Arbor's device path.
3. Add the dormant NativeSession/activation contract, two tiny sensitive elements
   and pipeline adapter in an isolated Arbor worktree. The facade/default remain
   unchanged until qualification. No new umbrella dependency is required.
4. Run sealed fake-native tests using actual Core processes and actual plugin
   element/executor code. Remove real Native modules from the fresh VM code path
   before installing fakes; never depend on Mockery passthrough behavior.
5. Adopt new immutable revisions only after review, renew native build/NIF/image
   admission and contained no-device evidence, then separately qualify explicit
   device permission/capture/playback behavior. Existing B0 evidence covers only
   its original exact inputs.

Required behavioral witnesses: delayed create/start after expiry; revocation
between final write and start; open returning after expiry; no native effect
before PID registration/custody ACK; pipeline death at every bootstrap stage;
caller/coordinator/controller death; closed or replaced executor generations;
source completion before/after last payload; forged/stale native and parent
notifications; exact mono format/byte count/tail; failed stop with confirmed
close; close/terminate uncertainty and eventual retry without queue growth;
pending fence across owner restart; enumeration allocation/termination failures;
and raw Logger/status/crash-term PCM sentinel checks at every real Core/owner
boundary. Run each applicable security regression against its exact predecessor.
Hardware, OS permission behavior and audibility are separate acceptance evidence.
