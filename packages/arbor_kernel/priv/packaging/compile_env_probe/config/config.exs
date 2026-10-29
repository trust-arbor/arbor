# Probe-only fixture; not a production release.
import Config

config :arbor_kernel, common: [k2e_compile_probe: :first]
