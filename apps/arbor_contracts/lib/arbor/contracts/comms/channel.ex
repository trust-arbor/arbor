defmodule Arbor.Contracts.Comms.Channel do
  @moduledoc """
  Behaviour for communication channel implementations.

  Each channel (Signal, Limitless, Email, etc.) implements this
  behaviour to provide a consistent interface for sending and
  receiving messages.
  """

  alias Arbor.Contracts.Comms.Message

  @type channel_info :: %{
          name: atom(),
          max_message_length: pos_integer() | :unlimited,
          supports_media: boolean(),
          supports_threads: boolean(),
          latency: :realtime | :polling
        }

  @doc "Returns channel capabilities and metadata."
  @callback channel_info() :: channel_info()

  @doc "Poll for new inbound messages. Returns {:ok, messages} or {:error, reason}."
  @callback poll() :: {:ok, [Message.t()]} | {:error, term()}

  @doc "Send a message to a recipient."
  @callback send_message(recipient :: String.t(), message :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc "Send a response to an inbound message."
  @callback send_response(original :: Message.t(), response :: String.t()) ::
              :ok | {:error, term()}

  @doc "Format a response string for this channel's constraints."
  @callback format_response(response :: String.t()) :: String.t()

  @optional_callbacks [poll: 0]
end
