defmodule Arbor.Contracts.Comms.ResponseRouter do
  @moduledoc """
  Behaviour for routing responses to the appropriate channel.

  Given an inbound message and a response envelope, determines
  which channel to deliver on and adapts the content format.

  ## Channel Selection

  When the envelope's channel is `:auto`, the router applies
  heuristics based on content characteristics and available channels.
  Implementations can define their own routing rules.

  ## Routing Rules (Reference)

  Default heuristics an implementation might use:

  | Condition | Channel |
  |-----------|---------|
  | Body > 2000 chars, no attachments | Email |
  | Has attachments | Email |
  | Body ≤ 2000 chars, no attachments | Origin channel |
  | Format is :html | Email |
  | User requested specific channel | Honored |
  | Voice session active | Voice (for short responses) |

  ## Example Implementation

      defmodule MyRouter do
        @behaviour Arbor.Contracts.Comms.ResponseRouter

        @impl true
        def route(message, envelope) do
          channel = select_channel(message, envelope)
          adapted = adapt_format(envelope, channel)
          {:ok, channel, adapted}
        end

        @impl true
        def available_channels do
          [:signal, :email]
        end
      end
  """

  alias Arbor.Contracts.Comms.Message
  alias Arbor.Contracts.Comms.ResponseEnvelope

  @doc """
  Determine the delivery channel and adapt the response.

  Returns `{:ok, channel, adapted_envelope}` where `channel` is the
  resolved channel atom and `adapted_envelope` has format adjustments
  for that channel (e.g. truncation, HTML stripping).
  """
  @callback route(
              original :: Message.t(),
              envelope :: ResponseEnvelope.t()
            ) :: {:ok, atom(), ResponseEnvelope.t()} | {:error, term()}

  @doc """
  Returns the list of channels currently available for outbound delivery.

  Used by the router to check if a requested channel is available
  before attempting delivery.
  """
  @callback available_channels() :: [atom()]
end
