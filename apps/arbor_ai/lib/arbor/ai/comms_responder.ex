defmodule Arbor.AI.CommsResponder do
  @moduledoc """
  ResponseGenerator implementation that uses Arbor.AI for response generation.

  Builds a prompt from the system context file, conversation history,
  and the new inbound message, then calls `Arbor.AI.generate_text/2`
  using the CLI backend (free via subscriptions).
  """

  @behaviour Arbor.Contracts.Comms.ResponseGenerator

  alias Arbor.Contracts.Comms.ResponseEnvelope

  require Logger

  @impl true
  def generate_response(message, context) do
    prompt = build_prompt(message, context)
    system_prompt = context[:system_prompt]

    opts = [
      backend: :cli,
      system_prompt: system_prompt
    ]

    case Arbor.AI.generate_text(prompt, opts) do
      {:ok, %{text: text}} when is_binary(text) and text != "" ->
        {:ok, ResponseEnvelope.new(body: text)}

      {:ok, _} ->
        {:error, :empty_response}

      {:error, reason} ->
        Logger.warning("CommsResponder generation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_prompt(message, context) do
    history = context[:conversation_history] || []

    history_text =
      if history == [] do
        ""
      else
        formatted =
          Enum.map_join(history, "\n", fn
            {:user, content} -> "User: #{content}"
            {:assistant, content} -> "Assistant: #{content}"
          end)

        "Previous conversation:\n#{formatted}\n\n"
      end

    "#{history_text}User: #{message.content}"
  end
end
