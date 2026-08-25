import Config

# Load .env file if present (dev/prod — test config disables channels)
# M2: In production, use fixed trusted path to prevent CWD-based .env injection.
# In dev/test, CWD .env is still allowed for convenience.
dotenv_path =
  if config_env() == :prod do
    System.get_env("ARBOR_ENV_PATH") ||
      Path.expand("~/.arbor/.env")
  else
    Path.join(File.cwd!(), ".env")
  end

if File.exists?(dotenv_path) do
  if config_env() != :prod and dotenv_path == Path.join(File.cwd!(), ".env") do
    IO.puts("[arbor] Loading .env from CWD: #{dotenv_path} (dev/test only)")
  end

  dotenv_path
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = key |> String.trim() |> String.replace_leading("export ", "")
        value = value |> String.trim() |> String.trim("\"") |> String.trim("'")
        System.put_env(key, value)

      _ ->
        :skip
    end
  end)
end

# ============================================================================
# Production security authority state root
# ============================================================================
# Explicit absolute path only. Full durable Security boots fail closed at
# freeze if this is unset. :activation_only boots do not freeze and do not
# require it. Do not default to cwd, ~, or ARBOR_DATA_DIR — that would
# silently choose a second root. Migration to a new directory is a separate
# operator action with a receipt.
if config_env() == :prod do
  case System.get_env("ARBOR_SECURITY_STATE_DIR") do
    dir when is_binary(dir) and dir != "" ->
      config :arbor_security, authority_state_root: dir

    _unset ->
      :ok
  end
end

# ============================================================================
# Production persistence
# ============================================================================

if config_env() == :prod do
  database_backend = System.get_env("ARBOR_DB", "sqlite")

  runtime_adapter =
    case database_backend do
      "sqlite" -> Ecto.Adapters.SQLite3
      "postgres" -> Ecto.Adapters.Postgres
      other -> raise "unsupported production ARBOR_DB value: #{inspect(other)}"
    end

  compiled_adapter =
    Application.get_env(:arbor_persistence, :repo_adapter, Ecto.Adapters.SQLite3)

  if compiled_adapter != runtime_adapter do
    raise """
    ARBOR_DB=#{database_backend} does not match the compiled persistence adapter.
    Rebuild with ARBOR_DB=#{database_backend}.
    """
  end

  positive_integer = fn env_name, default ->
    value = System.get_env(env_name, Integer.to_string(default))

    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> raise "#{env_name} must be a positive integer"
    end
  end

  pool_size = positive_integer.("ARBOR_DB_POOL_SIZE", 5)

  repo_config =
    case runtime_adapter do
      Ecto.Adapters.SQLite3 ->
        data_dir =
          System.get_env("ARBOR_DATA_DIR") ||
            Path.join(System.user_home!(), ".arbor")

        database =
          System.get_env("ARBOR_SQLITE_PATH") ||
            Path.join(data_dir, "arbor_prod.sqlite3")

        database = Path.expand(database)
        File.mkdir_p!(Path.dirname(database))

        [
          database: database,
          pool_size: pool_size,
          busy_timeout: positive_integer.("ARBOR_SQLITE_BUSY_TIMEOUT_MS", 5_000),
          journal_mode: :wal,
          cache_size: -64_000,
          temp_store: :memory
        ]

      Ecto.Adapters.Postgres ->
        connection =
          case System.get_env("DATABASE_URL") do
            url when is_binary(url) and url != "" ->
              [url: url]

            _ ->
              [
                database: System.fetch_env!("ARBOR_DB_NAME"),
                username: System.fetch_env!("DB_USER"),
                password: System.fetch_env!("DB_PASS"),
                hostname: System.get_env("DB_HOST", "localhost"),
                port: positive_integer.("DB_PORT", 5432)
              ]
          end

        connection ++
          [
            pool_size: pool_size,
            types: Arbor.Persistence.PostgrexTypes,
            ssl: System.get_env("DB_SSL", "true") != "false"
          ]
    end

  config :arbor_persistence, Arbor.Persistence.Repo, repo_config
end

# Optional operator surface for the Apple Container runtime. Test VMs must not
# inherit the live operator journal through an ambient parent-process env.
if config_env() != :test do
  if config_path = System.get_env("ARBOR_APPLE_CONTAINER_CONFIG_PATH") do
    case Arbor.Shell.RuntimeConfigLoader.load(config_path) do
      {:ok, values} ->
        config :arbor_shell,
          apple_container: values.apple_container,
          linux_dependency_baseline: values.linux_dependency_baseline,
          apple_container_image_policy: values.apple_container_image_policy,
          apple_container_unit_journal_path: values.apple_container_unit_journal_path

      {:error, _reason} ->
        raise "invalid ARBOR_APPLE_CONTAINER_CONFIG_PATH configuration"
    end
  end
end

# Development creates a project-scoped temporary root so generated worktrees
# stay outside the source checkout. Production has no workspace-scope default:
# absent or invalid settings are rejected by CodingTaskExecutor before it starts
# a coding pipeline.
if config_env() == :dev do
  dev_coding_worktree_root = Path.join(System.tmp_dir!(), "arbor-coding-worktrees")
  File.mkdir_p!(dev_coding_worktree_root)

  config :arbor_orchestrator, coding_worktree_roots: [dev_coding_worktree_root]
end

# A comma-separated value is intentionally kept as a list so Config can reject
# empty, relative, and filesystem-root entries consistently in every environment.
parse_coding_roots = fn env_name ->
  case System.get_env(env_name) do
    nil -> nil
    value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end
end

if roots = parse_coding_roots.("ARBOR_CODING_REPO_ROOTS") do
  config :arbor_orchestrator, coding_repo_roots: roots
end

if roots = parse_coding_roots.("ARBOR_CODING_WORKTREE_ROOTS") do
  config :arbor_orchestrator, coding_worktree_roots: roots
end

# ============================================================================
# Dashboard secret key base (production)
# ============================================================================

# ---------------------------------------------------------------------------
# Listen ports (any environment)
# ---------------------------------------------------------------------------
#
# Both were effectively fixed: the gateway defaulted to 4000 with no env
# override, and dev.exs hard-coded the dashboard to 4001. Two Arbor instances on
# one machine therefore could not coexist — the second failed to bind, and
# `arbor.start` hung holding its lifecycle lock rather than reporting the
# conflict, so every retry said "already in progress".
#
# `DASHBOARD_PORT` already existed but only inside the prod block, and only to
# build `check_origin` — it never set the listen port. It is honoured as a
# fallback so existing prod setups keep working.
parse_port = fn name, raw, default ->
  case Integer.parse(raw || default) do
    {port, ""} when port > 0 and port < 65_536 -> port
    _ -> raise "#{name} must be an integer between 1 and 65535, got: #{inspect(raw)}"
  end
end

arbor_gateway_port =
  parse_port.("ARBOR_GATEWAY_PORT", System.get_env("ARBOR_GATEWAY_PORT"), "4000")

arbor_dashboard_port =
  parse_port.(
    "ARBOR_DASHBOARD_PORT",
    System.get_env("ARBOR_DASHBOARD_PORT") || System.get_env("DASHBOARD_PORT"),
    "4001"
  )

config :arbor_gateway, port: arbor_gateway_port

# Keyword lists deep-merge in config, so this sets the port without discarding
# the endpoint's other options (secret_key_base, check_origin, server, ...).
config :arbor_dashboard, Arbor.Dashboard.Endpoint, http: [port: arbor_dashboard_port]

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :arbor_dashboard, Arbor.Dashboard.Endpoint, secret_key_base: secret_key_base

  # M2: production defaults to strict taint enforcement. Externally influenced
  # action parameters (LLM output, persisted records, external HTTP) carry
  # taint metadata; in :audit_only mode violations log but execute anyway,
  # which means the audit trail tells you what already happened rather than
  # blocking it. config.exs keeps :audit_only as the dev default for
  # observability during migration; runtime.exs flips prod to :strict so the
  # enforcement actually fires.
  config :arbor_actions, default_taint_policy: :strict

  # M14: Enforce check_origin in production (override dev's check_origin: false)
  dashboard_host = System.get_env("DASHBOARD_HOST") || "localhost"
  dashboard_port = to_string(arbor_dashboard_port)

  config :arbor_dashboard, Arbor.Dashboard.Endpoint,
    check_origin: [
      "https://#{dashboard_host}",
      "http://#{dashboard_host}:#{dashboard_port}"
    ]

  # H5: Require dashboard auth in production
  config :arbor_dashboard, require_auth: true
end

# Dashboard auth credentials (any environment)
dashboard_user = System.get_env("DASHBOARD_USER")
dashboard_pass = System.get_env("DASHBOARD_PASS")

if dashboard_user && dashboard_pass do
  config :arbor_dashboard, auth_user: dashboard_user, auth_pass: dashboard_pass
end

# ============================================================================
# OIDC — Human identity authentication
# ============================================================================
# Activate by setting both OIDC_ISSUER and OIDC_CLIENT_ID.
# Works with any OIDC provider (Zitadel, Google, GitHub, Keycloak, etc.)
# For self-hosted Zitadel see docker/zitadel/README.md

oidc_issuer = System.get_env("OIDC_ISSUER")
oidc_client_id = System.get_env("OIDC_CLIENT_ID")

if oidc_issuer && oidc_client_id do
  oidc_client_secret = System.get_env("OIDC_CLIENT_SECRET")

  oidc_scopes =
    case System.get_env("OIDC_SCOPES") do
      nil -> ["openid", "email", "profile"]
      scopes -> String.split(scopes, ",", trim: true) |> Enum.map(&String.trim/1)
    end

  # Provider entry for auth code + PKCE flow (dashboard)
  provider = %{
    issuer: oidc_issuer,
    client_id: oidc_client_id,
    scopes: oidc_scopes
  }

  provider =
    if oidc_client_secret,
      do: Map.put(provider, :client_secret, oidc_client_secret),
      else: provider

  # Device flow enabled by default (for CLI auth). Disable with OIDC_DEVICE_FLOW=false
  device_flow_enabled =
    case System.get_env("OIDC_DEVICE_FLOW") do
      val when val in ["false", "0", "no"] -> false
      _ -> true
    end

  oidc_config = [providers: [provider]]

  # Device flow can use a separate client ID (e.g. Zitadel Native app)
  device_client_id = System.get_env("OIDC_DEVICE_CLIENT_ID") || oidc_client_id

  oidc_config =
    if device_flow_enabled do
      Keyword.put(oidc_config, :device_flow, %{
        issuer: oidc_issuer,
        client_id: device_client_id,
        scopes: oidc_scopes
      })
    else
      oidc_config
    end

  config :arbor_security, :oidc, oidc_config
end

# ============================================================================
# Signal channel
# ============================================================================

signal_account = System.get_env("SIGNAL_FROM") || System.get_env("SIGNAL_ACCOUNT")
signal_cli_path = System.get_env("SIGNAL_CLI_PATH")
signal_to = System.get_env("SIGNAL_TO")
arbor_user_id = System.get_env("ARBOR_USER_ID") || "operator"

if signal_account do
  signal_config =
    Application.get_env(:arbor_comms, :signal, [])
    |> Keyword.put(:account, signal_account)
    |> then(fn cfg ->
      if signal_cli_path, do: Keyword.put(cfg, :signal_cli_path, signal_cli_path), else: cfg
    end)
    # HITL router Phase 2 (2026-06-06): if SIGNAL_TO is set, also use
    # it as the interaction-routing recipient so approval requests
    # delivered to this user route to their phone. The user_id maps
    # to ARBOR_USER_ID (default "operator") — must match the agent's
    # operator binding so the router's PresenceTracker lookup hits.
    |> then(fn cfg ->
      if signal_to, do: Keyword.put(cfg, :interaction_recipient, signal_to), else: cfg
    end)
    |> Keyword.put_new(:interaction_user_id, arbor_user_id)

  config :arbor_comms, :signal, signal_config
end

# Owner phone number — used for authorized_senders, response routing, and contact aliases
if signal_to do
  handler_config =
    Application.get_env(:arbor_comms, :handler, [])
    |> Keyword.put(:authorized_senders, [signal_to])
    |> Keyword.put(:contact_aliases, %{signal_to => ["pendant"]})

  config :arbor_comms, :handler, handler_config

  limitless_config =
    Application.get_env(:arbor_comms, :limitless, [])
    |> Keyword.put(:response_recipient, signal_to)

  config :arbor_comms, :limitless, limitless_config
end

# ============================================================================
# Limitless channel
# ============================================================================

limitless_api_key = System.get_env("LIMITLESS_API_KEY")

if limitless_api_key do
  limitless_config =
    Application.get_env(:arbor_comms, :limitless, [])
    |> Keyword.put(:api_key, limitless_api_key)

  config :arbor_comms, :limitless, limitless_config
end

# ============================================================================
# Email channel
# ============================================================================

smtp_user = System.get_env("SMTP_USER")
smtp_pass = System.get_env("SMTP_PASS")
smtp_host = System.get_env("SMTP_HOST")
smtp_port = System.get_env("SMTP_PORT")
email_to = System.get_env("EMAIL_TO")

if smtp_user do
  email_config =
    Application.get_env(:arbor_comms, :email, [])
    |> Keyword.put(:from, smtp_user)
    |> Keyword.put(:smtp_user, smtp_user)
    |> then(fn cfg -> if smtp_pass, do: Keyword.put(cfg, :smtp_pass, smtp_pass), else: cfg end)
    |> then(fn cfg -> if smtp_host, do: Keyword.put(cfg, :smtp_host, smtp_host), else: cfg end)
    |> then(fn cfg -> if smtp_port, do: Keyword.put(cfg, :smtp_port, smtp_port), else: cfg end)
    |> then(fn cfg -> if email_to, do: Keyword.put(cfg, :to, email_to), else: cfg end)

  config :arbor_comms, :email, email_config
end

# ============================================================================
# Contacts - bidirectional contact resolution for friendly name → identifier
# ============================================================================
#
# Build contacts map from environment. Each contact can have:
#   - email: their email address
#   - signal: their phone number (Signal)
#   - aliases: list of alternative names that resolve to this contact
#
# Environment format: CONTACT_<NAME>_<CHANNEL>=value, CONTACT_<NAME>_ALIASES=alias1,alias2
# Example:
#   CONTACT_OWNER_EMAIL=hysun@example.com
#   CONTACT_OWNER_SIGNAL=+15551234567
#   CONTACT_OWNER_ALIASES=me,pendant,hysun
#
contacts =
  System.get_env()
  |> Enum.filter(fn {k, _v} -> String.starts_with?(k, "CONTACT_") end)
  |> Enum.reduce(%{}, fn {key, value}, acc ->
    case String.split(key, "_", parts: 3) do
      ["CONTACT", name, channel] ->
        name = String.downcase(name)
        channel_key = String.downcase(channel)

        contact = Map.get(acc, name, %{})

        updated =
          case channel_key do
            "email" -> Map.put(contact, :email, value)
            "signal" -> Map.put(contact, :signal, value)
            "aliases" -> Map.put(contact, :aliases, String.split(value, ",", trim: true))
            _ -> contact
          end

        Map.put(acc, name, updated)

      _ ->
        acc
    end
  end)

# Fallback: if no contacts defined via CONTACT_* vars, create owner from existing vars
contacts =
  if map_size(contacts) == 0 and (signal_to || email_to) do
    owner =
      %{}
      |> then(fn c -> if signal_to, do: Map.put(c, :signal, signal_to), else: c end)
      |> then(fn c -> if email_to, do: Map.put(c, :email, email_to), else: c end)
      |> Map.put(:aliases, ["me", "pendant"])

    %{"owner" => owner}
  else
    contacts
  end

if map_size(contacts) > 0 do
  config :arbor_comms, :contacts, contacts
end

# ============================================================================
# Skill hybrid-search seams (injected into arbor_kernel :common; nil by default)
# ============================================================================
# arbor_common never hardcodes these modules. Wire the public persistence facade
# and embedding provider at runtime when the apps are available.
# Keep both seams nil in :test so hermetic suites inject fakes explicitly.
if config_env() != :test do
  if Code.ensure_loaded?(Arbor.Persistence) do
    config :arbor_kernel,
      common: [
        skill_persistence_module: Arbor.Persistence,
        telemetry_persistence_module: Arbor.Persistence
      ]
  end

  if Code.ensure_loaded?(Arbor.AI) do
    config :arbor_kernel, common: [skill_embedding_module: Arbor.AI]
  end

  if Code.ensure_loaded?(Arbor.Actions) do
    config :arbor_kernel, common: [action_capability_uri_module: Arbor.Actions]
  end

  if Code.ensure_loaded?(Arbor.Security) do
    config :arbor_kernel, common: [skill_import_security_module: Arbor.Security]
  end
end

# ============================================================================
# Monitor operational bridges (injected into arbor_kernel :monitor; nil by default in lib)
# ============================================================================
if config_env() != :test do
  if Code.ensure_loaded?(Arbor.Comms) do
    config :arbor_kernel, monitor: [channel_bridge_module: Arbor.Comms]
  end

  if Code.ensure_loaded?(Arbor.Agent) do
    config :arbor_kernel, monitor: [agent_directory_module: Arbor.Agent]
  end
end

# ============================================================================
# Signals durable sink (injected into arbor_kernel :signals; nil by default in lib)
# ============================================================================
if config_env() != :test do
  config :arbor_kernel,
    signals: [
      durable_sink_module: Arbor.Historian,
      security_module: Arbor.Security,
      crypto_module: Arbor.Security,
      identity_registry_module: Arbor.Security
    ]
end

# ============================================================================
# Security event log adapter (injected into arbor_security; nil by default in lib)
# ============================================================================
if config_env() != :test do
  config :arbor_security, event_log_adapter: Arbor.Historian.Adapters.SecurityEventLog
end

# ============================================================================
# Ollama base URL (local-LM provider)
# ============================================================================
# Single env var controlling where BOTH the embedding path and the
# text-generation path reach Ollama. Defaults to localhost so dev/test
# without the var behaves exactly as before; CI sets it to the homelab
# Ollama (e.g. ARBOR_OLLAMA_BASE_URL=http://10.42.42.100:11434).
#
# Two configs are set because the two paths read different keys with a
# different /v1 convention:
#   - Embedding path (Arbor.AI.Backends.OllamaEmbedding) hits the native
#     /api/embed endpoint → wants the bare base URL (NO /v1).
#   - Text-gen path (Arbor.AI.generate_text → arbor_llm → ProviderRegistry)
#     routes through req_llm's OpenAI-compatible adapter → wants the
#     /v1-suffixed base URL.
ollama_base_url = System.get_env("ARBOR_OLLAMA_BASE_URL") || "http://localhost:11434"

# Embedding path: arbor_ai reads `config :arbor_ai, :ollama, base_url`
# and calls "#{base_url}/api/embed" — bare URL, no /v1.
config :arbor_ai, :ollama, base_url: ollama_base_url

# Text-gen path: ProviderRegistry reads `config :arbor_orchestrator, :ollama,
# base_url` for the OpenAI-compatible endpoint — needs the /v1 suffix.
ollama_v1_base_url =
  if String.ends_with?(ollama_base_url, "/v1"),
    do: ollama_base_url,
    else: ollama_base_url <> "/v1"

config :arbor_orchestrator, :ollama, base_url: ollama_v1_base_url

# ============================================================================
# LLM Model & Provider Configuration
# ============================================================================
# These override the defaults in config.exs. All are optional.

# Safe provider string → atom mapping. Only known providers are accepted.
# This avoids String.to_atom/1 on user input (DoS via atom table exhaustion).
known_providers = %{
  "openrouter" => :openrouter,
  "anthropic" => :anthropic,
  "openai" => :openai,
  "gemini" => :gemini,
  "xai" => :xai,
  "zai" => :zai,
  "zai_coding_plan" => :zai_coding_plan,
  "ollama" => :ollama,
  "lmstudio" => :lmstudio,
  "opencode" => :opencode,
  "opencode_zen" => :opencode_zen,
  "qwen" => :qwen
}

parse_provider = fn str ->
  Map.get(known_providers, String.trim(str))
end

# --- Default model for general API calls ---
if default_model = System.get_env("ARBOR_DEFAULT_MODEL") do
  config :arbor_ai, default_model: default_model
end

if provider = System.get_env("ARBOR_DEFAULT_PROVIDER") |> then(&(&1 && parse_provider.(&1))) do
  config :arbor_ai, default_provider: provider
end

# --- Heartbeat model (agent periodic thinking cycle) ---
if heartbeat_model = System.get_env("ARBOR_HEARTBEAT_MODEL") do
  config :arbor_agent, heartbeat_model: heartbeat_model

  # Use the same model for idle heartbeats unless explicitly overridden
  unless System.get_env("ARBOR_IDLE_HEARTBEAT_MODEL") do
    config :arbor_agent, idle_heartbeat_model: heartbeat_model
  end
end

if idle_heartbeat_model = System.get_env("ARBOR_IDLE_HEARTBEAT_MODEL") do
  config :arbor_agent, idle_heartbeat_model: idle_heartbeat_model
end

if provider =
     System.get_env("ARBOR_HEARTBEAT_PROVIDER") |> then(&(&1 && parse_provider.(&1))) do
  config :arbor_agent, heartbeat_provider: provider
end

# --- Summarizer model (context window compression) ---
if summarizer_model = System.get_env("ARBOR_SUMMARIZER_MODEL") do
  config :arbor_agent, summarizer_model: summarizer_model
end

if provider =
     System.get_env("ARBOR_SUMMARIZER_PROVIDER") |> then(&(&1 && parse_provider.(&1))) do
  config :arbor_agent, summarizer_provider: provider
end

# --- Advisory council models (13 perspectives) ---
# Keep these values inert in runtime config. AdvisoryLLM owns the closed
# perspective table and validates the JSON when the consensus app uses it;
# lower-level app-specific Mix tasks must not need arbor_consensus on their path.
if council_model = System.get_env("ARBOR_COUNCIL_MODEL") do
  config :arbor_consensus, council_model: council_model
end

if perspective_models_json = System.get_env("ARBOR_COUNCIL_PERSPECTIVE_MODELS") do
  config :arbor_consensus, perspective_models_json: perspective_models_json
end

# --- Memory / reflection model ---
if memory_model = System.get_env("ARBOR_MEMORY_MODEL") do
  config :arbor_memory, default_model: memory_model
end

# --- CLI coding agents fallback chain ---
# Comma-separated list of providers to try in order.
# Example: ARBOR_CLI_CHAIN=anthropic,openai,gemini,lmstudio
if cli_chain = System.get_env("ARBOR_CLI_CHAIN") do
  chain =
    cli_chain
    |> String.split(",", trim: true)
    |> Enum.map(parse_provider)
    |> Enum.reject(&is_nil/1)

  if chain != [], do: config(:arbor_ai, cli_fallback_chain: chain)
end

# --- Daily API budget (USD) ---
if daily_budget = System.get_env("ARBOR_DAILY_BUDGET") do
  case Float.parse(daily_budget) do
    {amount, _} -> config :arbor_ai, daily_api_budget_usd: amount
    :error -> :skip
  end
end

# Durable provider usage ledger target for ordinary runtime (dev/prod).
# Tests leave this unset and inject an explicit ETS target per call/process.
if config_env() != :test do
  config :arbor_ai,
    provider_usage_ledger_target: [
      name: :arbor_ai_provider_usage,
      backend: Arbor.Persistence.EventLog.Ecto,
      opts: []
    ]
end

# ============================================================================
# Brave Search API (jido_browser)
# ============================================================================

# Map BRAVE_API_KEY to the key jido_browser expects
brave_key = System.get_env("BRAVE_SEARCH_API_KEY") || System.get_env("BRAVE_API_KEY")

if brave_key do
  config :jido_browser, brave_api_key: brave_key
end
