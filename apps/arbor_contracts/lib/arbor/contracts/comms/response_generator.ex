defmodule Arbor.Contracts.Comms.ResponseGenerator do
  @moduledoc """
  Behaviour for generating responses to inbound messages.

  Implementations receive a message and conversation context,
  and return a `ResponseEnvelope` with the response body and
  routing metadata. This allows arbor_comms to dispatch to
  different response backends (AI, rule-based, etc.) without a
  direct dependency on arbor_ai.

  ## Example Implementation

      defmodule MyApp.SimpleResponder do
        @behaviour Arbor.Contracts.Comms.ResponseGenerator
        alias Arbor.Contracts.Comms.ResponseEnvelope

        @impl true
        def generate_response(_message, _context) do
          {:ok, ResponseEnvelope.new(body: "Thanks for your message!")}
        end
      end

      defmodule MyApp.SmartResponder do
        @behaviour Arbor.Contracts.Comms.ResponseGenerator
        alias Arbor.Contracts.Comms.ResponseEnvelope

        @impl true
        def generate_response(_message, _context) do
          {:ok, ResponseEnvelope.new(
            body: long_report,
            channel: :email,
            subject: "Status Report",
            format: :markdown
          )}
        end
      end
  """

  alias Arbor.Contracts.Comms.Message
  alias Arbor.Contracts.Comms.ResponseEnvelope

  @type context :: %{
          conversation_history: [{:user | :assistant, String.t()}],
          system_prompt: String.t() | nil
        }

  @doc """
  Generate a response to an inbound message.

  Receives the message and a context map containing conversation
  history and system prompt. Returns a ResponseEnvelope or an error.
  """
  @callback generate_response(message :: Message.t(), context :: context()) ::
              {:ok, ResponseEnvelope.t()} | {:error, term()}
end
