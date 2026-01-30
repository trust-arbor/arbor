import Config

# Load .env file if present (dev/prod — test config disables channels)
dotenv_path = Path.join(File.cwd!(), ".env")

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
