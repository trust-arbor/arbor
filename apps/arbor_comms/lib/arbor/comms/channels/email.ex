defmodule Arbor.Comms.Channels.Email do
  @moduledoc """
  Email communication channel — outbound only.

  Sends emails via SMTP using Swoosh. Supports plain text, HTML,
  and attachments.

  ## Configuration

      config :arbor_comms, :email,
        enabled: true,
        from: System.get_env("SMTP_USER"),
        to: System.get_env("EMAIL_TO"),
        smtp_host: System.get_env("SMTP_HOST"),
        smtp_port: System.get_env("SMTP_PORT"),
        smtp_user: System.get_env("SMTP_USER"),
        smtp_pass: System.get_env("SMTP_PASS")
  """

  @behaviour Arbor.Contracts.Comms.ChannelSender

  require Logger

  import Swoosh.Email

  alias Swoosh.Adapters.SMTP

  @max_message_length 50_000

  @content_types %{
    ".pdf" => "application/pdf",
    ".json" => "application/json",
    ".csv" => "text/csv",
    ".txt" => "text/plain",
    ".md" => "text/markdown",
    ".html" => "text/html",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".zip" => "application/zip",
    ".ex" => "text/x-elixir",
    ".exs" => "text/x-elixir"
  }

  @doc "Returns channel capabilities and metadata."
  def channel_info do
    %{
      name: :email,
      max_message_length: @max_message_length,
      supports_media: true,
      supports_threads: true,
      supports_outbound: true,
      latency: :polling
    }
  end

  @impl Arbor.Contracts.Comms.ChannelSender
  def send_message(recipient, message, opts \\ []) do
    subject = Keyword.get(opts, :subject, "Arbor Notification")
    from = Keyword.get(opts, :from, config(:from))
    attachments = Keyword.get(opts, :attachments, [])
    formatted = do_format(message)

    email =
      new()
      |> to(recipient)
      |> from(from)
      |> subject(subject)
      |> text_body(formatted)

    email =
      case Keyword.get(opts, :reply_to) do
        nil -> email
        reply -> reply_to(email, reply)
      end

    email = Enum.reduce(attachments, email, &add_attachment/2)

    Logger.info("Sending email",
      to: recipient,
      subject: subject,
      body_length: String.length(formatted),
      attachment_count: length(attachments)
    )

    case deliver(email) do
      {:ok, _metadata} ->
        Logger.info("Email sent successfully", to: recipient)
        :ok

      {:error, reason} ->
        Logger.error("Email send failed", to: recipient, reason: inspect(reason))
        {:error, reason}
    end
  end

  @impl Arbor.Contracts.Comms.ChannelSender
  def format_for_channel(message), do: do_format(message)

  defp do_format(response) do
    response = String.trim(response)

    if String.length(response) > @max_message_length do
      String.slice(response, 0, @max_message_length - 100) <>
        "\n\n[Message truncated]"
    else
      response
    end
  end

  # ============================================================================
  # Convenience Functions
  # ============================================================================

  @doc """
  Send an email with the given subject and body.

  ## Options
  - `:to` - Recipient (default: from config)
  - `:from` - Sender (default: from config)
  - `:reply_to` - Reply-to address
  """
  @spec send_email(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def send_email(subject, body, opts \\ []) do
    to = Keyword.get(opts, :to, config(:to))
    send_message(to, body, Keyword.put(opts, :subject, subject))
  end

  @doc """
  Send an email with file attachments.

  Attachments can be file paths (read from disk) or `{filename, binary}` tuples.

  ## Options
  - `:to` - Recipient (default: from config)
  - `:attachments` - List of file paths or `{filename, content}` tuples
  """
  @spec send_with_attachments(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def send_with_attachments(subject, body, opts \\ []) do
    to = Keyword.get(opts, :to, config(:to))
    send_message(to, body, Keyword.put(opts, :subject, subject))
  end

  @doc """
  Send an email with both HTML and plain text bodies.
  """
  @spec send_html(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def send_html(subject, text_body, html_body, opts \\ []) do
    to = Keyword.get(opts, :to, config(:to))
    from = Keyword.get(opts, :from, config(:from))

    email =
      new()
      |> to(to)
      |> from(from)
      |> subject(subject)
      |> text_body(text_body)
      |> html_body(html_body)

    case deliver(email) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp add_attachment(path, email) when is_binary(path) do
    if File.exists?(path) do
      filename = Path.basename(path)
      content = File.read!(path)
      content_type = guess_content_type(filename)

      attachment(email, %Swoosh.Attachment{
        filename: filename,
        content_type: content_type,
        data: content
      })
    else
      Logger.warning("Attachment file not found", path: path)
      email
    end
  end

  defp add_attachment({filename, content}, email)
       when is_binary(filename) and is_binary(content) do
    content_type = guess_content_type(filename)

    attachment(email, %Swoosh.Attachment{
      filename: filename,
      content_type: content_type,
      data: content
    })
  end

  @doc false
  def guess_content_type(filename) do
    ext = filename |> Path.extname() |> String.downcase()
    Map.get(@content_types, ext, "application/octet-stream")
  end

  defp deliver(email) do
    smtp_config = [
      relay: config(:smtp_host) || "localhost",
      port: smtp_port(),
      username: config(:smtp_user),
      password: config(:smtp_pass),
      ssl: false,
      tls: :if_available,
      tls_options: [verify: :verify_none],
      auth: :if_available,
      retries: 2,
      no_mx_lookups: true
    ]

    SMTP.deliver(email, smtp_config)
  end

  defp smtp_port do
    case config(:smtp_port) do
      port when is_integer(port) -> port
      port when is_binary(port) -> String.to_integer(port)
      nil -> 587
    end
  end

  defp config(key) do
    Application.get_env(:arbor_comms, :email, [])
    |> Keyword.get(key)
  end
end
