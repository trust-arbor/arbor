import Config

# Reviewed Phase E routing profile. Both routes passed the heartbeat eval suite
# on the immutable clean revision recorded by the scoreboard evidence below.
provider_route_profile_enabled = true

config :arbor_ai, :provider_route_profile, %{
  enabled: provider_route_profile_enabled,
  task_registry: %{
    "default" => %{requirements: %{}}
  },
  default_task_class: "default",
  catalog_model_ids: ["gpt-5.6-sol", "grok-4.5"],
  scoreboard: [
    %{
      model: "gpt-5.6-sol",
      provider: "openai_oauth",
      runtime: "arbor",
      score: 1.0,
      dangerous_misses: 0,
      format_failure_rate: 0.0,
      variance: 0.0,
      # Subscription OAuth had no marginal API charge in this eval. This is
      # separate from subscription capacity and total economic cost.
      marginal_cost: 0.0,
      latency_ms: 6_256.1,
      eval_run_ref: "gpt-5-6-sol-heartbeat-2026-08-01-2a1cc2",
      last_verified: "2026-08-01T19:41:34.301064Z"
    },
    %{
      model: "grok-4.5",
      provider: "xai_oauth",
      runtime: "arbor",
      score: 1.0,
      dangerous_misses: 0,
      format_failure_rate: 0.0,
      variance: 0.0,
      marginal_cost: 0.0,
      latency_ms: 4_217.1,
      eval_run_ref: "grok-4-5-heartbeat-2026-08-01-4fcb18",
      last_verified: "2026-08-01T19:42:36.096985Z"
    }
  ],
  providers: ["openai_oauth", "xai_oauth"],
  fallback_limit: 1,
  params: %{}
}

# These are deployment policy inputs, not provider-observed capacity. Runtime
# auth, catalog, quota, route-failure, and usage evidence remains authoritative
# and can block either configured route.
config :arbor_ai, :provider_route_concurrency_limits, %{
  "openai_oauth" => %{"arbor" => 2},
  "xai_oauth" => %{"arbor" => 2}
}

config :arbor_ai, :provider_spend_ceilings_usd, %{
  "openai_oauth" => 1.0,
  "xai_oauth" => 1.0
}

config :arbor_ai, :subscription_capacity_states, %{
  "openai_oauth" => "available",
  "xai_oauth" => "available"
}
