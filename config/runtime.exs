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
        key = String.trim(key)
        value = value |> String.trim() |> String.trim("\"") |> String.trim("'")
        System.put_env(key, value)

      _ ->
        :skip
    end
  end)
end

# ============================================================================
# Dashboard secret key base (production)
# ============================================================================

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :arbor_dashboard, Arbor.Dashboard.Endpoint, secret_key_base: secret_key_base

  # M14: Enforce check_origin in production (override dev's check_origin: false)
  dashboard_host = System.get_env("DASHBOARD_HOST") || "localhost"
  dashboard_port = System.get_env("DASHBOARD_PORT") || "4001"

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
# Signal channel
# ============================================================================

signal_account = System.get_env("SIGNAL_FROM") || System.get_env("SIGNAL_ACCOUNT")
signal_cli_path = System.get_env("SIGNAL_CLI_PATH")
signal_to = System.get_env("SIGNAL_TO")

if signal_account do
  signal_config =
    Application.get_env(:arbor_comms, :signal, [])
    |> Keyword.put(:account, signal_account)
    |> then(fn cfg ->
      if signal_cli_path, do: Keyword.put(cfg, :signal_cli_path, signal_cli_path), else: cfg
    end)

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

# --- Advisory council model (all 13 perspectives) ---
if council_model = System.get_env("ARBOR_COUNCIL_MODEL") do
  # Apply the same model to all perspectives as a base default.
  # Individual perspectives can still be overridden at runtime via
  # AdvisoryLLM.configure_perspective/2.
  perspectives =
    ~w(security brainstorming vision emergence resource_usage user_experience
       consistency generalization capability performance privacy design_review
       risk_assessment feasibility)a
    |> Enum.map(fn p -> {p, council_model} end)
    |> Map.new()

  config :arbor_consensus, perspective_models: perspectives
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
