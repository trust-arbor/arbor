defmodule Arbor.AI.CommsResponder do
  @moduledoc """
  ResponseGenerator implementation that uses Arbor.AI for response generation.

  Uses a persistent Claude session (via `session_context: "comms"`) so all
  channels (Signal, Limitless, Email) share the same conversation. Claude's
  own session history replaces the need for a conversation buffer — each
  message becomes a new turn in the same session regardless of channel.

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
  def generate_response(message, _context) do
    prompt = build_prompt(message)

    opts = [
      backend: :cli,
      session_context: "comms"
    ]

    case Arbor.AI.generate_text(prompt, opts) do
      {:ok, %{text: text}} when is_binary(text) and text != "" ->
        cleaned = strip_predicted_turns(text)
        {channel, body} = extract_channel_hint(cleaned)
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

  # Claude sometimes generates past its response, predicting what the user
  # will say next (especially when conversation history uses "User:" prefixes).
  # Strip any trailing "User:" or "Assistant:" turns from the response.
  @turn_suffix_regex ~r/\n\n(?:User|Assistant):.*\z/s

  defp strip_predicted_turns(text) do
    Regex.replace(@turn_suffix_regex, text, "")
  end

  defp build_prompt(message) do
    channel = message.channel || :unknown
    "[via #{channel}] #{message.content}"
  end
end
