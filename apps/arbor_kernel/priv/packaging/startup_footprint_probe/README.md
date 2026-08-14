# Startup-footprint probe (read-only template)

Probe-only fixture; not a production application or release.

Do not run `mix compile` from this directory. The Mix task copies the
tracked template into an exclusive owner-private temp project, rewrites
path deps to absolute tracked app paths, copies the selected dependency
cache with symlinks dereferenced, and writes BEAMs into a fresh
`MIX_BUILD_PATH`. The selected Mix dependency cache (`MIX_DEPS_PATH`, or
umbrella `deps/`) and umbrella `mix.lock` are read-only inputs.

Each measured scenario runs in a fresh OS/BEAM process. The pre-start
snapshot is taken first. Scenario-specific application loading and start
happen inside the timed interval. Baseline then starts only passive
`:arbor_contracts`. Proposed scenarios start the merged app's non-owner
runtime extras, including `:os_mon`, and never treat `:arbor_kernel` as
an external runtime dependency. Telemetry counts the Signals security
bridge on the concrete `[:arbor, :security, :authorization_granted]`
event. Gated mode starts no Common, Signals, or
Monitor callbacks. Eager mode nests those current application callbacks
under the probe root without moving production source.
