defmodule Arbor.Voice.RealtimeBackend do
  @moduledoc """
  Behaviour every realtime voice backend implements.

  Arbor.Voice.Session (VP-04) drives a conversation turn loop against
  whichever backend Arbor.Voice.Config.backend_module/0 names, without
  referencing a concrete backend module directly (VOICE-5). A backend owns
  a bidirectional realtime connection — audio/text in, audio/text/tool-call
  events out — to either a cloud provider (xAI Realtime, VP-03) or a local
  engine.

  `session/0` is backend-opaque: callers pass it back into every callback
  and treat it as an unstructured handle. Implementations typically wrap a
  connection struct (socket/port reference, buffered state) in it.
  """

  @typedoc "Backend-opaque session handle, passed back into every callback."
  @type session :: term()

  @typedoc """
  Backend-native tool declaration shaped for that backend's wire format
  (name, description, JSON-schema-ish parameters). Arbor.Voice.Session
  translates Arbor's tool catalog into this shape before calling
  configure/2.
  """
  @type tool_decl :: map()

  @typedoc """
  Events a backend emits from recv/2. A turn typically yields zero or more
  :input_transcript chunks, interleaved :output_text_delta / :output_audio
  chunks, zero or more :tool_call events, and exactly one terminal
  :turn_done (or :error).
  """
  @type event ::
          {:input_transcript, String.t()}
          | {:output_text_delta, String.t()}
          | {:output_audio, binary()}
          | {:tool_call, %{id: String.t(), name: String.t(), arguments: map()}}
          | {:turn_done, %{text: String.t()}}
          | {:error, term()}

  @doc """
  Opens a new realtime connection and returns its opaque session handle.

  `opts` is backend-specific (API key/token, model id, sample rates, ...);
  each backend documents its own accepted keys. Credentials are expected to
  already be resolved by the caller (VOICE-6) — open/1 does not fetch
  secrets itself.

  Returns `{:error, :missing_credentials}` when a required credential opt
  is absent, `{:error, :invalid_opts}` when opts fails backend-specific
  validation, or `{:error, term()}` for transport-level failures
  (connection refused, TLS handshake failure, DNS) — that space is
  genuinely open-ended and backend-specific.
  """
  @callback open(opts :: keyword()) :: {:ok, session()} | {:error, term()}

  @doc """
  Applies or updates session-level configuration: system instructions, the
  tool catalog, and audio format/voice settings. Callable more than once on
  the same session (e.g. to update instructions mid-conversation); a
  backend that cannot reconfigure a live session returns
  `{:error, :reconfigure_not_supported}` instead of closing it implicitly.

  Returns `{:error, :invalid_config}` when a supplied field fails
  backend-specific validation, `{:error, :unsupported_capability}` when a
  requested tool/audio option isn't supported by this backend,
  `{:error, :reconfigure_not_supported}`, or `{:error, term()}` for
  transport failures.
  """
  @callback configure(
              session(),
              %{
                optional(:instructions) => String.t(),
                optional(:tools) => [tool_decl()],
                optional(:audio) => map()
              }
            ) :: {:ok, session()} | {:error, term()}

  @doc """
  Sends a text turn input. Used for text-mode fallback and for injecting
  tool-result-triggered follow-ups that aren't voice audio.

  Returns `{:error, :session_closed}` if the session was already closed, or
  `{:error, term()}` for transport failures.
  """
  @callback send_text(session(), String.t()) :: {:ok, session()} | {:error, term()}

  @doc """
  Sends a chunk of PCM16 audio input (rate per meta/1's input_rate).
  Callers stream this incrementally as microphone audio arrives; a backend
  buffers/frames it per its own protocol.

  Returns `{:error, :session_closed}`, `{:error, :invalid_audio}` when the
  chunk fails backend-specific format validation, or `{:error, term()}` for
  transport failures.
  """
  @callback send_audio(session(), binary()) :: {:ok, session()} | {:error, term()}

  @doc """
  Sends the result of a tool call the backend previously requested via a
  :tool_call event, keyed by that event's id. `output` is the tool's result
  rendered as a string — callers are responsible for serializing per
  VOICE-8's "every tool call gets exactly one output" rule, including
  structured-error outputs for unknown tool names.

  Returns `{:error, :session_closed}`, `{:error, :unknown_call_id}` when
  call_id doesn't match a pending tool call, or `{:error, term()}` for
  transport failures.
  """
  @callback send_tool_result(session(), call_id :: String.t(), output :: String.t()) ::
              {:ok, session()} | {:error, term()}

  @doc """
  Blocks up to `timeout` milliseconds for the next backend event. Callers
  are expected to call this in a receive loop for the session's lifetime.

  Returns `{:error, :timeout}` when no event arrives within timeout,
  `{:error, :session_closed}` if the session was already closed, or
  `{:error, term()}` for transport failures (connection dropped, decode
  error).
  """
  @callback recv(session(), timeout()) :: {:ok, session(), event()} | {:error, term()}

  @doc """
  Closes the backend connection and releases resources held for `session`.
  Idempotent — closing an already-closed session is not an error. Always
  returns :ok, even when the underlying close is imperfect, so callers
  (VOICE-7's cleanup owner) can unconditionally release the session;
  backends surface close problems via telemetry/logging instead.
  """
  @callback close(session()) :: :ok

  @doc """
  Returns metadata about this session's backend: which backend
  module/family it is, whether it runs :cloud or :local (feeds VOICE-23's
  user-visible cue), and the PCM sample rates the caller must
  produce/consume for send_audio/2 and :output_audio events. Rates are nil
  for a text-only backend/session.
  """
  @callback meta(session()) :: %{
              backend: atom(),
              mode: :cloud | :local,
              input_rate: pos_integer() | nil,
              output_rate: pos_integer() | nil
            }
end
