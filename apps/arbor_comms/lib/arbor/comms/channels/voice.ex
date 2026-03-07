defmodule Arbor.Comms.Channels.Voice do
  @moduledoc """
  Voice channel for Android phone nodes in the Arbor cluster.

  Provides thin wrappers around `:rpc.call` to the phone's `:android` module
  for STT (speech-to-text), TTS (text-to-speech), and device interaction.

  The phone handles all audio processing locally — this module only
  transports text over Erlang distribution.

  ## Usage

      # Listen for speech (returns transcribed text)
      Voice.listen(phone_node, 5)

      # Speak text aloud
      Voice.speak(phone_node, "Hello from Arbor!")

      # Show a toast notification
      Voice.toast(phone_node, "Connected")

  ## Configuration

      config :arbor_comms, :voice,
        default_listen_seconds: 5,
        tts_timeout: 30_000,
        stt_timeout: 15_000,
        default_voice: nil
  """

  require Logger

  @default_tts_timeout 30_000
  @default_stt_timeout 15_000
  @default_listen_seconds 5

  # -- STT (Speech-to-Text) --

  @doc """
  Listen for speech on the phone and return the transcription.

  Uses the phone's online STT (Google). Blocks for `seconds` while recording.

  ## Options

    - `:timeout` — RPC timeout in ms (default: #{@default_stt_timeout})
  """
  @spec listen(node(), pos_integer(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def listen(phone_node, seconds \\ nil, opts \\ []) do
    seconds = seconds || config(:default_listen_seconds, @default_listen_seconds)
    timeout = Keyword.get(opts, :timeout, config(:stt_timeout, @default_stt_timeout))

    case rpc(phone_node, "listen", to_string(seconds), timeout) do
      {:ok, json} -> extract_text(json)
      error -> error
    end
  end

  @doc """
  Listen with streaming partial results.

  Returns the final transcription. Partial results are logged.
  """
  @spec stream_listen(node(), pos_integer(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def stream_listen(phone_node, seconds \\ nil, opts \\ []) do
    seconds = seconds || config(:default_listen_seconds, @default_listen_seconds)
    timeout = Keyword.get(opts, :timeout, config(:stt_timeout, @default_stt_timeout))

    case rpc(phone_node, "stream_listen", to_string(seconds), timeout) do
      {:ok, json} -> extract_text(json)
      error -> error
    end
  end

  @doc """
  Listen via earbuds with VAD (voice activity detection).

  Listens until silence is detected (up to `seconds` max).
  Best for natural conversation turn-taking.
  """
  @spec buddie_listen(node(), pos_integer(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def buddie_listen(phone_node, seconds \\ nil, opts \\ []) do
    seconds = seconds || config(:default_listen_seconds, @default_listen_seconds)
    timeout = Keyword.get(opts, :timeout, config(:stt_timeout, @default_stt_timeout))

    case rpc(phone_node, "buddie_listen", to_string(seconds), timeout) do
      {:ok, json} -> extract_text(json)
      error -> error
    end
  end

  # -- TTS (Text-to-Speech) --

  @doc """
  Speak text aloud on the phone via TTS.

  ## Options

    - `:voice` — TTS voice index (0-7, default: device default)
    - `:timeout` — RPC timeout in ms (default: #{@default_tts_timeout})
  """
  @spec speak(node(), String.t(), keyword()) :: :ok | {:error, term()}
  def speak(phone_node, text, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, config(:tts_timeout, @default_tts_timeout))
    voice = Keyword.get(opts, :voice, config(:default_voice, nil))

    {command, args} =
      if voice do
        {"tts", "#{voice} 1.0 #{text}"}
      else
        {"tts", text}
      end

    case rpc(phone_node, command, args, timeout) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # -- Device Interaction --

  @doc "Show a toast notification on the phone."
  @spec toast(node(), String.t()) :: :ok | {:error, term()}
  def toast(phone_node, message) do
    case rpc_direct(phone_node, :toast, [message], 5_000) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Get the phone's current location."
  @spec location(node(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def location(phone_node, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    rpc_direct(phone_node, :location, [], timeout)
  end

  @doc "Read a sensor value by name."
  @spec sensor(node(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def sensor(phone_node, sensor_name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    rpc_direct(phone_node, :sensor_read, [sensor_name], timeout)
  end

  @doc "Take a photo with the phone camera."
  @spec camera_photo(node(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def camera_photo(phone_node, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 15_000)
    rpc(phone_node, "camera_photo", "", timeout)
  end

  @doc "Get battery level."
  @spec battery(node(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def battery(phone_node, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    rpc_direct(phone_node, :battery, [], timeout)
  end

  @doc "Check if a phone node is reachable."
  @spec ping(node()) :: boolean()
  def ping(phone_node) do
    :net_adm.ping(phone_node) == :pong
  end

  @doc "List available commands on the phone."
  @spec help(node()) :: {:ok, String.t()} | {:error, term()}
  def help(phone_node) do
    rpc(phone_node, "help", 5_000)
  end

  # -- Internal --

  # call/3: commands with arguments (STT, TTS, etc.)
  # The :android GenServer returns {:ok, json_string} or {:error, reason}.
  # The RPC timeout must exceed the android GenServer timeout to avoid double-timeout.
  defp rpc(phone_node, command, args, timeout) do
    rpc_timeout = timeout + 5_000

    result =
      :rpc.call(phone_node, :android, :call, [command, args, timeout], rpc_timeout)

    handle_rpc_result(phone_node, result)
  end

  # call/1: no-arg commands routed through the GenServer command parser
  defp rpc(phone_node, command, timeout) do
    rpc_timeout = timeout + 5_000

    result =
      :rpc.call(phone_node, :android, :call, [command, timeout], rpc_timeout)

    handle_rpc_result(phone_node, result)
  end

  # Direct function calls for dedicated :android exports (toast/1, battery/0, etc.)
  defp rpc_direct(phone_node, function, args, timeout) do
    rpc_timeout = timeout + 5_000

    result =
      :rpc.call(phone_node, :android, function, args, rpc_timeout)

    handle_rpc_result(phone_node, result)
  end

  defp handle_rpc_result(phone_node, result) do
    case result do
      {:badrpc, reason} ->
        Logger.warning("[Voice] RPC to #{phone_node} failed: #{inspect(reason)}")
        {:error, {:rpc_failed, reason}}

      {:ok, data} ->
        {:ok, data}

      {:error, reason} ->
        {:error, reason}

      :ok ->
        :ok

      result when is_binary(result) ->
        {:ok, result}

      other ->
        {:ok, inspect(other)}
    end
  end

  # Extract the "text" field from STT JSON responses.
  # STT returns JSON like: {"text":"hello","duration":5.0,"elapsed_ms":383}
  defp extract_text(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"text" => text}} -> {:ok, text}
      {:ok, _} -> {:ok, json}
      {:error, _} -> {:ok, json}
    end
  end

  defp extract_text(other), do: {:ok, inspect(other)}

  defp config(key, default) do
    Application.get_env(:arbor_comms, :voice, [])
    |> Keyword.get(key, default)
  end
end
