# Arbor Multimedia

A trusted local device boundary with no in-umbrella dependencies. The facade
provides `devices/0`, `capture_pcm/1`, `play_pcm/2`, `device_status/0`, and explicit
microphone permission status/request functions. **The default driver remains
unavailable.** The opt-in `Arbor.Multimedia.Driver.Native` implementation uses
the reviewed bounded Membrane/PortAudio interfaces. Sealed tests qualify its
Elixir integration; real microphone/speaker qualification remains separate.
It performs no device enumeration, permission query/request, or playback at boot.

Capture accepts a duplicate-free keyword list with required `duration_ms`
(100..30_000) and `sample_rate` (8_000..192_000), plus optional
`device_id: :default | 0..65_535`. Duration must describe an integral number of
frames, with at most 2 MiB of mono s16le PCM. Playback accepts the exact map
`%{pcm: binary, sample_rate: integer, channels: 1, sample_format: :s16le}` with
at most 8 MiB, and only optional `device_id`. No public modules, functions,
process identifiers, arbitrary native options, file paths or resampling.

The coordinating owner serializes operations. A separately supervised temporary
worker retains the internal driver handle and performs checked cleanup, including
after caller or coordinator death. Media completion and positive resource close
are independent conditions. Capture joins the final count and received bytes
regardless of arrival order, timestamps the first accepted completion, and
materializes reversed PCM chunks once. Identical completion is idempotent.

One absolute monotonic deadline covers admission, startup, media and cleanup.
The default budget is the media duration plus 2 seconds. If cleanup remains
uncertain at expiry, the caller receives `{:error, :cleanup_pending}` while the
worker keeps custody and retries close. No new device operation is admitted.
Private reference credentials correlate both driver notification hops; numeric fence
identities carry no completion authority. A VM-retained atomic fence survives coordinator/worker/application restarts;
only exact-token positive close can clear it. If handle custody itself is lost,
the VM remains fenced. There is no public force-clear API. An internal revocable
permit checks the deadline and caller/coordinator liveness before effects; a
native driver passes the exact revocation cell into the pinned executor lease;
there is no asynchronous cancellation mirror.

Raw PCM stays in process memory, with state, message and reason redaction on
the owners, native session, pipeline, feeder and collector. Startup arguments
contain no PCM. Playback payload enters the sensitive feeder only after its
actual process and the device process are recorded and admitted. Intentional trusted-VM
`:sys.get_state`, tracing/debug history, arbitrary injected drivers and direct
callback logging are outside the ordinary diagnostics policy. Driver failures
are normalized to closed atoms. Device names reject control characters and have
bounded UTF-8 lengths; device data has a closed shape and unique IDs.

The internal Driver seam is application configuration, never a facade option.
Its `open(spec, permit)` returns a dormant custody handle without native effects.
DriverWorker commits that handle before calling `activate(handle, spec, permit)`
in a later callback. NativeSession waits for the coordinator to commit its
private custody identity before creating a pipeline. It records the empty
pipeline and real child PIDs before binding leases or acknowledging setup. An exception after
unknown effects is cleanup uncertainty, never proof of closure. `close(handle)`
returns `:ok`, a media error plus positive `:closed`, or `:cleanup_pending`.
Stream/pipeline DOWN or a media close notification is not checked close evidence.

The concrete native driver requires the reviewed and pinned bounded
Source/Sink, enumeration, executor generation/element cleanup barrier, permission
query, and actual Core sensitive diagnostics changes. Dependency/build/NIF admission
is tracked separately from this application. Original VP-07B0 evidence covers the
original pinned dependencies only. NativeSession retains one supervised cleanup
helper for the pinned native barrier, then joins termination of the entire recorded
process tree. A changed native generation retains `:cleanup_pending`; process
death alone does not prove closure. Worker death can recover through the exact
recorded NativeSession credential only after both barriers succeed.

`device_status/0` returns `:idle` only when the registered coordinator has no
operation and the persistent fence is empty. It otherwise returns `:busy`,
`:cleanup_pending`, or `:device_unavailable`; it never releases custody. Permission
functions return only `:authorized`, `:denied`, `:restricted`, `:not_determined`, or
`:unavailable`. The Darwin request is asynchronous and is followed by one status
query; an unanswered prompt stays `:not_determined`. There are no implicit retries
or device opens. Other platforms return `:unavailable` for this Darwin boundary.

Fake-only isolated qualification:

```sh
cd apps/arbor_multimedia
../../bin/mix test --no-start
../../bin/mix compile --warnings-as-errors
```

`test_helper.exs` selects a fail-closed fake before starting either owner. There
are no passthrough mocks or hardware tests in this suite.

The actual-Core/plugin harness is deliberately excluded from ordinary test
discovery. Compile the application first, then run this in a fresh isolated VM
from the repository root, with `ARBOR_TEST_PORTAUDIO_SOURCE` set to the reviewed
PortAudio source checkout:

```sh
./bin/mix run --no-start --no-compile --no-deps-check \
  apps/arbor_multimedia/test/native/sealed_runner.exs
```

The harness removes the plugin code path and purges every native/permission
module before defining marked fakes. It recompiles only the actual plugin Elixir
source in memory; no fake BEAM is written into dependency build artifacts. It
exercises the public Multimedia facade against the real Core pipeline machinery,
including blocked native create, queue expiry, worker death, unknown generation,
positive close, exact tails, custody spoof rejection, and ordinary PCM diagnostic
redaction. Live device and provider journeys remain separate qualification gates.
