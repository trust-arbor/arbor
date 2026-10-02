import Config

config :conversation_demo, ConversationDemo.Endpoint,
  url: [host: "127.0.0.1"],
  http: [ip: {127, 0, 0, 1}, port: 4791],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  server: config_env() == :dev,
  secret_key_base: String.duplicate("experiment-only-local-loopback-key-", 3),
  live_view: [signing_salt: "conversation-spike"],
  pubsub_server: ConversationDemo.PubSub,
  render_errors: [formats: [html: ConversationDemo.ErrorHTML], layout: false],
  check_origin: ["http://127.0.0.1:4791", "http://localhost:4791"]

config :phoenix, :json_library, Jason
config :logger, level: :warning
config :back_breeze, render_cache_max_memory_bytes: 64 * 1_024 * 1_024
