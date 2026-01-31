defmodule Arbor.AI.CommsResponder do
  @moduledoc """
  ResponseGenerator implementation that uses Arbor.AI for response generation.

  Maintains a persistent Claude session across app restarts by saving the
  session_id to disk (`.arbor/comms-session-id`). All channels (Signal,
  Limitless, Email) share the same conversation — each message becomes a
  new turn in the same session regardless of channel.

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

  @session_file "comms-session-id"

  @impl true
  def generate_response(message, _context) do
    prompt = build_prompt(message)

    opts =
      case load_session_id() do
        nil ->
          Logger.info("CommsResponder: starting new session")
          [backend: :cli, session_context: "comms"]

        session_id ->
          Logger.info("CommsResponder: resuming session #{String.slice(session_id, 0, 12)}...")
          [backend: :cli, session_id: session_id, session_context: "comms"]
      end

    case Arbor.AI.generate_text(prompt, opts) do
      {:ok, %{text: text} = response} when is_binary(text) and text != "" ->
        save_session_id(Map.get(response, :session_id))
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

  @doc """
  Reset the persisted session, forcing a new one on next message.
  """
  @spec reset_session() :: :ok
  def reset_session do
    path = session_file_path()

    case File.rm(path) do
      :ok ->
        Logger.info("CommsResponder: session reset")

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("CommsResponder: failed to reset session: #{inspect(reason)}")
    end

    :ok
  end

  # ============================================================================
  # Session Persistence
  # ============================================================================

  defp session_file_path do
    Path.join(Path.expand("~/.arbor"), @session_file)
  end

  defp load_session_id do
    case File.read(session_file_path()) do
      {:ok, content} ->
        id = String.trim(content)
        if id != "", do: id, else: nil

      {:error, _} ->
        nil
    end
  end

  defp save_session_id(nil), do: :ok

  defp save_session_id(session_id) when is_binary(session_id) do
    path = session_file_path()
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    case File.write(path, session_id) do
      :ok ->
        Logger.debug("CommsResponder: saved session #{String.slice(session_id, 0, 12)}...")

      {:error, reason} ->
        Logger.warning("CommsResponder: failed to save session: #{inspect(reason)}")
    end
  end

  defp build_prompt(message) do
    channel = message.channel || :unknown
    "[via #{channel}] #{message.content}"
  end
end
