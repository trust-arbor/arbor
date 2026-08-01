import Config

# Reviewed Phase E routing candidate. Development enables this profile for live
# restart dogfood. Production remains disabled until these evals are rerun on an
# immutable clean revision; changing that gate is a separate reviewed rollout.
provider_route_profile_enabled = config_env() == :dev

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
      latency_ms: 5_690.875,
      eval_run_ref: "gpt-5-6-sol-heartbeat-2026-08-01-1bcb2f",
      last_verified: "2026-08-01T16:05:45.559268Z"
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
      latency_ms: 4_616.75,
      eval_run_ref: "grok-4-5-heartbeat-2026-08-01-207268",
      last_verified: "2026-08-01T16:22:36.985474Z"
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
