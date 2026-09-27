# Arbor Multimedia

VP-07B0 dependency-admission scaffold. This application has no in-umbrella
dependencies and no capture or playback API. It does not request microphone
permission or open a sound device.

Membrane Core, the PortAudio plugin and RawAudio are direct dependencies.
The umbrella lockfile records their exact Hex source identities. Bundlex must
resolve PortAudio through `pkg-config`; precompiled OS dependency downloads are
disabled specifically for `membrane_portaudio_plugin` in `config/config.exs`.
The lockfile does not attest native libraries downloaded by a build script.

Before VP-07B, record the admitted native image, PortAudio/pkg-config/ALSA
identities, exact dependency tree and NIF identity, and prove a no-network Linux
compile/load in the configured validation backend. A macOS compile is host
feasibility only. Do not activate a new live baseline from this scaffold.
