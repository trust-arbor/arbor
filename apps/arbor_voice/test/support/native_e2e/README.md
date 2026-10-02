# Hermetic Desk / native adapter integration

Run only in a fresh VM in an isolated worktree, after compiling the candidate
production applications in that worktree. This harness is deliberately outside
ordinary ExUnit discovery. It first runs the Multimedia sealed loader, which
removes the real PortAudio code path and purges native and permission modules
before installing fakes. No fake BEAMs are written to the build directory.

```sh
MIX_ENV=test ARBOR_TEST_PORTAUDIO_SOURCE="$PWD/deps/membrane_portaudio_plugin" \
  ./bin/mix run --no-start --no-compile --no-deps-check \
  apps/arbor_voice/test/support/native_e2e/runner.exs
```

The source path must contain the pinned plugin implementation. The compiled
production Multimedia, Voice, Security and Comms modules must match the candidate
source. `--no-deps-check` only avoids dependency tooling during this sealed run;
it does not establish that those artifacts match. Compile and qualify dependency
pins separately before using this command as evidence.

The harness includes the 13 Multimedia native regression tests and six
cross-application cases:

- Real scoped Security exchange and admission, Desk capture, Native pipeline,
  Voice Session, presentation playback, and canonical Comms recording succeed.
- Speakable shaping preserves the raw canonical reply while blocking raw
  provider audio playback and any text/TTS submission.
- Cancellation during native capture remains pending until native close and
  element termination are observed; it never opens the provider or records.
- Cancellation during presentation startup joins playback cleanup while retaining
  the already recorded turn and preventing native playback start.
- Capability revocation between capture and fresh Session admission prevents
  provider startup and recording.
- Cancellation during an ordinary bounded provider receive discards its late
  audio, positively closes the provider, and permits an explicit fresh turn.

The checks use actual Membrane Core processes and plugin Elixir code, the actual
Multimedia adapter and owners, actual Voice Session/Presentation/recorder, actual
Security signatures and scoped tokens, and the actual Comms canonical turn and
durable taint encoding. Fakes are limited to native device calls and permissions,
the realtime provider, local identity-provider fixtures, budget/observability
collaborators, and an in-memory persistence/engagement-store boundary. This proves
the application seams and cleanup contract, not physical-device behavior,
provider compatibility, or database durability.
