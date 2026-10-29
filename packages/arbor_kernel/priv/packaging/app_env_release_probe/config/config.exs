# Probe-only fixture; not a production release.
import Config

config :arbor_kernel,
  common: [
    start_children: false,
    skill_embedding_module: nil,
    tool_catalog_enabled: true
  ],
  monitor: [
    start_children: false,
    channel_bridge_module: nil,
    signal_emission_enabled: false
  ]

config :arbor_signals,
  start_children: false,
  security_telemetry_bridge: false,
  durable_sink_module: nil,
  relay_enabled: false,
  supervision_root: {:application, :arbor_kernel_runtime},
  supervision_path: [Arbor.Signals.Application]
