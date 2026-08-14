# Startup-footprint probe (read-only template)

Probe-only fixture; not a production application or release.

Do not run `mix compile` from this directory. The Mix task copies the
tracked template into a temp project, rewrites path deps to absolute
tracked app paths, and writes BEAMs into a fresh `MIX_BUILD_PATH`.
The active canonical Mix dependency cache (`MIX_DEPS_PATH`, or umbrella
`deps/`) and umbrella `mix.lock` are read-only inputs.

Each measured scenario runs in a fresh OS/BEAM process. The pre-start
snapshot is taken first. Baseline then starts only passive
`:arbor_contracts`. Proposed scenarios start the merged app's non-owner
runtime dependency union, including `:os_mon`, inside the timed action,
then start the probe root. Gated mode starts no Common, Signals, or
Monitor callbacks. Eager mode nests those current application callbacks
under the probe root without moving production source.
