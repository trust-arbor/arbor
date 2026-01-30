defmodule Arbor.AI.CommsResponder do
  @moduledoc """
  ResponseGenerator implementation that uses Arbor.AI for response generation.

  Builds a prompt from the system context file, conversation history,
  and the new inbound message, then calls `Arbor.AI.generate_text/2`
  using the CLI backend (free via subscriptions).

  ## Channel Intent Detection

  The system prompt instructs the AI to prefix responses with
  `[CHANNEL:email]` or `[CHANNEL:signal]` when the user explicitly
  requests a delivery method (e.g. "email me the report"). The prefix
  is parsed, stripped from the body, and set on the response envelope.
  """

  @behaviour Arbor.Contracts.Comms.ResponseGenerator

  alias Arbor.Contracts.Comms.ResponseEnvelope

  require Logger

  @channel_prefix_regex ~r/^\[CHANNEL:(\w+)\]\s*/i

  @allowed_channels ~w(signal email)

  @impl true
  def generate_response(message, context) do
    prompt = build_prompt(message, context)
    system_prompt = build_system_prompt(context[:system_prompt])

    opts = [
      backend: :cli,
      system_prompt: system_prompt,
      new_session: true
    ]

    case Arbor.AI.generate_text(prompt, opts) do
      {:ok, %{text: text}} when is_binary(text) and text != "" ->
        {channel, body} = extract_channel_hint(text)
        {:ok, ResponseEnvelope.new(body: body, channel: channel)}

      {:ok, _} ->
        {:error, :empty_response}

      {:error, reason} ->
        Logger.warning("CommsResponder generation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Extract a `[CHANNEL:xxx]` prefix from AI output.

  Returns `{channel_atom, stripped_body}`. If no valid prefix is found,
  returns `{:auto, original_body}`.
  """
  @spec extract_channel_hint(String.t()) :: {atom(), String.t()}
  def extract_channel_hint(text) do
    case Regex.run(@channel_prefix_regex, text) do
      [full_match, channel_name] ->
        normalized = String.downcase(channel_name)

        if normalized in @allowed_channels do
          body = String.replace_prefix(text, full_match, "")
          {String.to_existing_atom(normalized), body}
        else
          {:auto, text}
        end

      _ ->
        {:auto, text}
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

  defp build_system_prompt(nil), do: routing_instruction()
  defp build_system_prompt(""), do: routing_instruction()

  defp build_system_prompt(base) do
    base <> "\n\n" <> routing_instruction()
  end

  defp routing_instruction do
    """
    If the user explicitly requests a specific delivery method \
    (e.g. "email me", "send me a text", "message me on Signal"), \
    prefix your response with [CHANNEL:email] or [CHANNEL:signal] accordingly. \
    Do not include the prefix unless the user explicitly asks for a specific channel.\
    """
  end
end
