defmodule Arbor.Contracts.Comms.ResponseEnvelope do
  @moduledoc """
  A response with routing and formatting metadata.

  Wraps a response body with information about how and where to
  deliver it. Used by ResponseGenerator implementations to express
  channel preferences, and by the response router to make delivery
  decisions.

  ## Channel Selection

  The `:channel` field controls routing:

  - `:auto` — let the router decide based on content characteristics
  - `:signal` — force delivery via Signal
  - `:email` — force delivery via Email
  - `:voice` — deliver via active voice session (if any)
  ## Examples

      # Simple text response (router decides channel)
      ResponseEnvelope.new(body: "Got it, thanks!")

      # Force email for a long report
      ResponseEnvelope.new(
        body: long_report,
        channel: :email,
        subject: "Weekly Status Report",
        format: :markdown
      )

      # Response with attachments
      ResponseEnvelope.new(
        body: "Here's the export.",
        channel: :email,
        subject: "Data Export",
        attachments: [{"data.csv", csv_content}]
      )

      # Answer to a pending agent question
      ResponseEnvelope.new(
        body: "Use approach B with the retry logic.",
        in_reply_to: "q_abc123"
      )
  """

  use TypedStruct

  typedstruct do
    @typedoc "A response with routing metadata"

    field(:body, String.t(), enforce: true)
    field(:channel, channel_hint(), default: :auto)
    field(:format, :text | :markdown | :html, default: :text)
    field(:subject, String.t())
    field(:attachments, [attachment()], default: [])
    field(:in_reply_to, String.t())
    field(:metadata, map(), default: %{})
  end

  @typedoc """
  Channel routing hint.

  - `:auto` — router picks based on content size, attachments, etc.
  - Specific atom (`:signal`, `:email`, etc.) — force a particular channel
  """
  @type channel_hint :: :auto | atom()

  @typedoc """
  An attachment: either a file path or a `{filename, binary}` tuple.
  """
  @type attachment :: String.t() | {String.t(), binary()}

  @doc """
  Create a new response envelope.
  """
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc """
  Returns true if this envelope has attachments.
  """
  @spec has_attachments?(t()) :: boolean()
  def has_attachments?(%__MODULE__{attachments: [_ | _]}), do: true
  def has_attachments?(%__MODULE__{}), do: false

  @doc """
  Returns the approximate content size (body + attachment data).
  """
  @spec content_size(t()) :: non_neg_integer()
  def content_size(%__MODULE__{body: body, attachments: attachments}) do
    body_size = byte_size(body)

    attachment_size =
      Enum.reduce(attachments, 0, fn
        {_name, data}, acc when is_binary(data) -> acc + byte_size(data)
        path, acc when is_binary(path) -> acc + (file_size(path) || 0)
      end)

    body_size + attachment_size
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end
end
