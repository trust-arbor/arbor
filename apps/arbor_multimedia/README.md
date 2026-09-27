# Arbor Multimedia

A trusted local device boundary with no in-umbrella dependencies. The facade
provides `devices/0`, `capture_pcm/1`, and `play_pcm/2`. **The default driver is
unavailable:** this candidate qualifies the bounded owner and fake driver seam,
not a usable native microphone/speaker implementation or completed VP-07B.
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
future native driver must recheck it after every permission/setup wait.

Raw PCM stays in process memory, with state, message and reason redaction on
both actual OTP owners. Startup arguments contain no PCM. Intentional trusted-VM
`:sys.get_state`, tracing/debug history, arbitrary injected drivers and direct
callback logging are outside the ordinary diagnostics policy. Driver failures
are normalized to closed atoms. Device names reject control characters and have
bounded UTF-8 lengths; device data has a closed shape and unique IDs.

The internal Driver seam is application configuration, never a facade option.
Its `open(spec, permit)` must return a custody handle before asynchronous native
work, or positively attest that no resource was opened. An exception after
unknown effects is cleanup uncertainty, never proof of closure. `close(handle)`
returns `:ok`, a media error plus positive `:closed`, or `:cleanup_pending`.
Stream/pipeline DOWN or a media close notification is not checked close evidence.

Before adopting a concrete Membrane/PortAudio driver, review and pin the bounded
native Source/Sink, executor generation/element cleanup barrier, permission query,
and actual Core sensitive diagnostics changes. Renew immutable dependency/build/
NIF admission and no-device contained proof for those changed native sources.
Original VP-07B0 evidence covers the original pinned dependencies only.

Fake-only isolated qualification:

```sh
cd apps/arbor_multimedia
../../bin/mix test --no-start
../../bin/mix compile --warnings-as-errors
```

`test_helper.exs` selects a fail-closed fake before starting either owner. There
are no passthrough mocks or hardware tests in this candidate. Live device and
provider journeys remain later qualification gates.
