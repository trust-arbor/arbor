# Assembled-release probe (read-only template)

Probe-only fixture; not a production release.

Do not run `mix compile` or `mix release` from this directory. The Mix
task copies or generates a temp project, rewrites path deps to absolute
tracked app paths, and writes BEAMs/releases into a fresh MIX_BUILD_PATH.
The active canonical Mix dependency cache (`MIX_DEPS_PATH`, or umbrella
`deps/`) and umbrella `mix.lock` are read-only inputs. Artifact evaluation
starts the probe release application graph before reading owner facades.
