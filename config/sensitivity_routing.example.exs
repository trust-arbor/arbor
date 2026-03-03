# Sensitivity Routing Configuration
# ==================================
#
# Copy the relevant sections into config/config.exs or config/runtime.exs
# and customize for your setup.
#
# The sensitivity router automatically selects {provider, model} pairs based on
# data sensitivity classification. Sensitive data stays on local providers;
# public data can go anywhere.
#
# Sensitivity levels (lowest to highest):
#   :public       — no restrictions, any provider can see this
#   :internal     — internal docs, code, logs — trusted cloud providers ok
#   :confidential — PII (SSN, credit cards), contracts — major providers only
#   :restricted   — API keys, secrets, private keys — local only

# ── Provider/Model Trust ──────────────────────────────────────────────
#
# Declares what sensitivity levels each {provider, model} pair can handle.
#
# Format:
#   provider: %{default: [...], models: %{"glob" => [...]}}
#
# Glob patterns:
#   "anthropic/*"     — matches any model starting with "anthropic/"
#   "*:cloud"         — matches any model ending with ":cloud"
#   "llama3*"         — matches models starting with "llama3"
#
# Legacy flat format also works: provider: [:public, :internal]
#
config :arbor_ai, :backend_capabilities, %{
  # ── Local Providers (full trust) ──
  #
  # Data never leaves your machine. Full access to all sensitivity levels.
  ollama: %{
    default: [:public, :internal, :confidential, :restricted],
    models: %{
      # Ollama can now proxy cloud models — restrict those
      "*:cloud" => [:public, :internal]
    }
  },
  lmstudio: %{
    default: [:public, :internal, :confidential, :restricted],
    models: %{}
  },

  # ── Major Cloud Providers (high trust) ──
  #
  # Strong privacy policies, SOC2/HIPAA, data not used for training.
  # Allow up to :confidential by default.
  anthropic: %{
    default: [:public, :internal, :confidential],
    models:
      %{
        # If you have a BAA with Anthropic for HIPAA:
        # "claude-*" => [:public, :internal, :confidential, :restricted]
      }
  },
  openai: %{
    default: [:public, :internal],
    models:
      %{
        # Azure-hosted OpenAI with your own deployment:
        # "azure/*" => [:public, :internal, :confidential, :restricted]
      }
  },
  gemini: %{
    default: [:public, :internal],
    models: %{}
  },

  # ── Meta-Providers (trust depends on underlying model) ──
  #
  # OpenRouter, etc. route to different backends. Trust per model pattern.
  openrouter: %{
    default: [:public],
    models: %{
      # Anthropic models via OpenRouter — trust Anthropic's backend
      "anthropic/*" => [:public, :internal, :confidential],
      # Google models via OpenRouter
      "google/*" => [:public, :internal],
      # Meta models (open-source, but OpenRouter hosts them)
      "meta-llama/*" => [:public, :internal],
      # Free models — public only (unknown hosting)
      "*:free" => [:public]
    }
  },

  # ── Other Providers ──
  opencode: %{
    default: [:public, :internal, :confidential],
    models: %{}
  },
  qwen: %{
    default: [:public],
    models: %{}
  }
}

# ── Routing Candidates ────────────────────────────────────────────────
#
# Ordered list of {provider, model} pairs the router considers.
# Lower priority = preferred (tried first).
#
# When the current provider can't handle a sensitivity level, the router
# picks the lowest-priority candidate that can.
#
# Tip: Put your fastest/cheapest local model at priority 1.
#      It'll be the fallback for all restricted data.
#
config :arbor_ai, :routing_candidates, [
  # Priority 1: Local Ollama — fast, free, handles everything
  # %{provider: :ollama, model: "llama3.2", priority: 2},
  # Priority 2: Local LM Studio — alternative local
  %{provider: :lmstudio, model: "qwen3.5-122b-a10b", priority: 1},
  # Priority 3: Anthropic API — high quality, handles up to :confidential
  %{provider: :anthropic, model: "claude-sonnet-4-6", priority: 2},
  # Priority 4: OpenRouter Anthropic — same quality, different billing
  %{provider: :openrouter, model: "anthropic/claude-sonnet-4-6", priority: 3}
]

# ── Content Classification ────────────────────────────────────────────
#
# TaintCheck middleware automatically classifies content using
# Arbor.Common.SensitiveData pattern matching:
#
#   Secrets (API keys, tokens, private keys)  → :restricted
#   Financial PII (SSN, credit cards)         → :confidential
#   Contact PII (emails, phones, IPs, paths)  → :internal
#   No findings                               → :public
#
# Additionally, file path heuristics classify:
#   .env, credentials, secret, private_key    → :restricted
#   /tmp/, /var/, /proc/                      → :internal
#
# DOT pipeline authors can also set sensitivity floors on nodes:
#
#   <node id="process_secrets" taint_sensitivity="restricted" />
#
# This forces output sensitivity to at least :restricted regardless
# of content classification.

# ── Routing Modes (UX Control) ───────────────────────────────────────
#
# When the router detects that the current provider can't handle the
# data sensitivity, the *mode* determines what UX behavior occurs:
#
#   :auto  — Reroute silently (no notification). For trusted agents.
#   :warn  — Reroute + emit signal. Dashboard/UI shows notification.
#   :gated — Reroute + emit signal + write decision to context.
#            For new agents — gives the UI a chance to show the user.
#   :block — Fail the request entirely. Refuse to send sensitive data.
#
# Modes are resolved per-agent from their trust tier:
#
#   restricted (untrusted/probationary) → :gated
#   standard (trusted)                  → :warn
#   elevated (veteran)                  → :auto
#   autonomous (full_partner)           → :auto
#
# Override defaults:
#
config :arbor_ai, :sensitivity_routing_modes, %{
  restricted: :gated,
  standard: :warn,
  elevated: :auto,
  autonomous: :auto
}

# Per-agent overrides take precedence over trust-tier defaults.
# Use this for agents that always need maximum safety regardless of tier.
#
config :arbor_ai,
       :sensitivity_routing_overrides,
       %{
         # "agent_secrets_handler" => :block
       }

# ── How It All Connects ──────────────────────────────────────────────
#
# 1. TaintCheck.before_node scans input content → sets sensitivity
# 2. Sensitivity propagates through pipeline (worst wins)
# 3. CodergenHandler reads __data_sensitivity__ from context
# 4. SensitivityRouter.decide/4 checks clearance + resolves routing mode
# 5. If not ok → selects alternative, emits signal based on mode
# 6. TaintCheck.after_node validates the provider could see the data (safety net)
# 7. Result: secrets stay local, public data goes anywhere, users are informed
