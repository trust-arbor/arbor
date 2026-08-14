# Probe-only fixture; not a production release.
import Config

config :arbor_kernel,
  common: [
    start_children: false,
    skill_embedding_module: nil,
    tool_catalog_enabled: true
  ],
  signals: [
    start_children: false,
    security_telemetry_bridge: false,
    durable_sink_module: nil,
    relay_enabled: false
  ],
  monitor: [
    start_children: false,
    channel_bridge_module: nil,
    signal_emission_enabled: false
  ]
