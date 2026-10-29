defmodule Arbor.Contracts.Comms.Message do
  @moduledoc """
  Unified message struct for all communication channels.

  Represents both inbound and outbound messages across Signal,
  Limitless, Email, and other channels.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          channel: atom(),
          direction: :inbound | :outbound,
          from: String.t(),
          to: String.t() | nil,
          content: String.t(),
          content_type: atom(),
          received_at: DateTime.t(),
          metadata: map(),
          reply_to: String.t() | nil,
          conversation_id: String.t() | nil
        }

  @enforce_keys [:channel, :from, :content]
  defstruct [
    :id,
    :channel,
    :direction,
    :from,
    :to,
    :content,
    :reply_to,
    :conversation_id,
    content_type: :text,
    received_at: nil,
    metadata: %{}
  ]

  @doc """
  Creates a new Message with auto-generated ID and timestamp.
  """
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    attrs =
      attrs
      |> Keyword.put_new(:id, generate_id())
      |> Keyword.put_new(:direction, :inbound)
      |> Keyword.put_new(:received_at, DateTime.utc_now())

    struct!(__MODULE__, attrs)
  end

  @doc """
  Creates a new outbound message.
  """
  @spec outbound(atom(), String.t(), String.t(), keyword()) :: t()
  def outbound(channel, to, content, opts \\ []) do
    new(
      [
        channel: channel,
        direction: :outbound,
        from: "arbor",
        to: to,
        content: content
      ] ++ opts
    )
  end

  defp generate_id do
    "msg_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
