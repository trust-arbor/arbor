# Probe-only fixture; not a production application.
import Config

# Production-like owner defaults. This file does not change owner source.
config :arbor_kernel,
  common: [
    start_children: true
  ],
  signals: [
    start_children: true,
    security_telemetry_bridge: true
  ],
  monitor: [
    start_children: true
  ]
