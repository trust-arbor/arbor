defmodule Arbor.Voice.TranscriptRecorder do
  @moduledoc """
  Isolated engagement-transcript persistence boundary for voice (VP-04D2A).

  Builds one ordered user/assistant entry pair from an already engagement-tagged
  voice `UserMessage` and raw, unrendered assistant text, then calls the public
  `Arbor.Comms.record_engagement_turn/5` facade exactly once. Session lifecycle,
  backend polling, Speakable rendering, and output are deliberately out of scope
  so the durable-write contract can be reviewed on its own.

  Production defaults to `Arbor.Comms`. Hermetic tests inject a module exposing
  the same public `record_engagement_turn/5` shape via `opts[:comms]`. The only
  option forwarded to Comms is `:persistence`.
  """

  alias Arbor.Contracts.Session.UserMessage

  @id_max_bytes 256
  @opts_allowlist [:comms, :persistence, :backend, :mode]

  @doc """
  Record one completed voice turn through the public Comms engagement path.

  `user_message` must already be engagement-tagged
  (`%UserMessage{transport: :voice, engagement_id: ...}`). `raw_assistant_text`
  is persisted verbatim before any future Speakable/render call site.
  `completed_at` is the assistant completion timestamp.

  ## Options

  * `:comms` — module implementing `record_engagement_turn/5` (default
    `Arbor.Comms`; closed test seam only)
  * `:persistence` — forwarded unchanged to Comms
  * `:backend` / `:mode` — trusted backend metadata; existing atoms or valid
    UTF-8 binaries, normalized to strings via `Atom.to_string/1` (never
    `String.to_atom/1`)

  Rejects unknown or duplicate option keys, invalid envelopes/timestamps, and
  a missing/blank/oversized/invalid-UTF-8 engagement id without calling Comms.
  Content-size, chronological-order, and final metadata-size policy remain at
  the Comms boundary.
  """
  @spec record(String.t(), UserMessage.t(), String.t(), DateTime.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def record(agent_id, user_message, raw_assistant_text, completed_at, opts \\ []) do
    with :ok <- validate_opts(opts),
         :ok <- validate_user_message(user_message),
         :ok <- validate_completed_at(completed_at),
         :ok <- validate_engagement_id(user_message.engagement_id),
         {:ok, metadata} <- build_metadata(opts) do
      comms = Keyword.get(opts, :comms, Arbor.Comms)
      forwarded_opts = Keyword.take(opts, [:persistence])

      user_entry = %{
        content: user_message.content,
        sent_at: user_message.sent_at,
        metadata: metadata
      }

      assistant_entry = %{
        content: raw_assistant_text,
        completed_at: completed_at,
        metadata: metadata
      }

      # Exactly one call; return result unchanged. Do not catch raise/throw/exit.
      comms.record_engagement_turn(
        agent_id,
        user_message.engagement_id,
        user_entry,
        assistant_entry,
        forwarded_opts
      )
    end
  end

  # -- validation -------------------------------------------------------------

  defp validate_opts(opts) do
    cond do
      not is_list(opts) or not Keyword.keyword?(opts) ->
        {:error, {:invalid_opts, :not_a_keyword_list}}

      has_duplicate_keys?(opts) ->
        {:error, {:invalid_opts, :duplicate_keys}}

      true ->
        case Enum.reject(Keyword.keys(opts), &(&1 in @opts_allowlist)) do
          [] -> :ok
          unknown -> {:error, {:invalid_opts, {:unknown_keys, unknown}}}
        end
    end
  end

  defp has_duplicate_keys?(opts) do
    keys = Keyword.keys(opts)
    length(keys) != length(Enum.uniq(keys))
  end

  defp validate_user_message(%UserMessage{transport: :voice, sent_at: %DateTime{}}), do: :ok

  defp validate_user_message(%UserMessage{transport: :voice}),
    do: {:error, {:invalid_timestamp, :sent_at}}

  defp validate_user_message(%UserMessage{}),
    do: {:error, {:invalid_user_message, :not_voice}}

  defp validate_user_message(_),
    do: {:error, {:invalid_user_message, :not_a_user_message}}

  defp validate_completed_at(%DateTime{}), do: :ok
  defp validate_completed_at(_), do: {:error, {:invalid_timestamp, :completed_at}}

  # Same preflight shape as Arbor.Comms engagement-id validation: byte bound
  # first, then UTF-8, then blank — reject without calling Comms.
  defp validate_engagement_id(v) when is_binary(v) do
    cond do
      byte_size(v) > @id_max_bytes -> {:error, {:invalid_id, :engagement_id, :too_large}}
      not String.valid?(v) -> {:error, {:invalid_id, :engagement_id, :not_utf8}}
      String.trim(v) == "" -> {:error, {:invalid_id, :engagement_id, :blank}}
      true -> :ok
    end
  end

  defp validate_engagement_id(_v), do: {:error, {:invalid_id, :engagement_id, :not_a_string}}

  # -- metadata ---------------------------------------------------------------

  defp build_metadata(opts) do
    base = %{"transport" => "voice"}

    with {:ok, meta} <- put_optional_meta(base, opts, :backend),
         {:ok, meta} <- put_optional_meta(meta, opts, :mode) do
      {:ok, meta}
    end
  end

  defp put_optional_meta(meta, opts, key) do
    if Keyword.has_key?(opts, key) do
      case normalize_meta_value(Keyword.get(opts, key)) do
        {:ok, value} ->
          {:ok, Map.put(meta, Atom.to_string(key), value)}

        {:error, _reason} = error ->
          error
      end
    else
      {:ok, meta}
    end
  end

  # Trusted values only: existing atoms (Atom.to_string/1 — never create atoms)
  # or valid UTF-8 binaries. Final size/scalar policy remains at Comms.
  defp normalize_meta_value(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp normalize_meta_value(value) when is_binary(value) do
    if String.valid?(value) do
      {:ok, value}
    else
      {:error, {:invalid_opts, :invalid_metadata_value}}
    end
  end

  defp normalize_meta_value(_value), do: {:error, {:invalid_opts, :invalid_metadata_value}}
end
