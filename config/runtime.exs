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
