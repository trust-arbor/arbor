defmodule Arbor.Contracts.Comms.ApprovalAnswer do
  @moduledoc """
  Shared normalization for operator approval answers across backends.

  Both `Arbor.Comms.InteractionRouter` and consensus authorization-request
  answers must map approve / deny / rework + bounded note / request metadata
  identically.

  Opaque request IDs use a closed ASCII grammar and are **rejected** (never
  mutated/trimmed) when oversized, non-ASCII, or control-bearing. Notes are
  size-checked with `byte_size/1` before any UTF-8 walk; MCP answer paths reject
  oversized notes, while internal projection may truncate via
  `validate_note/2` with `truncate: true`.
  """

  # Opaque ids: irq_<hex>, proposal ids, etc. Closed printable ASCII subset.
  @request_id_max_bytes 256
  @note_max_bytes 1_024

  @type decision :: :approve | :deny | :rework
  @type normalize_result ::
          {:ok, :approve}
          | {:ok, :rework, String.t()}
          | {:ok, :deny, String.t()}
          | {:error, term()}

  @doc "Maximum accepted note size in bytes."
  @spec max_note_bytes() :: pos_integer()
  def max_note_bytes, do: @note_max_bytes

  @doc "Maximum accepted opaque request/proposal id size in bytes."
  @spec max_request_id_bytes() :: pos_integer()
  def max_request_id_bytes, do: @request_id_max_bytes

  @doc """
  Validate an opaque approval id.

  Rejects empty, non-binary, oversized, non-ASCII-grammar, or control-bearing
  ids. Does **not** trim or mutate the input.
  """
  @spec validate_request_id(term()) :: {:ok, String.t()} | {:error, term()}
  def validate_request_id(id) when is_binary(id) do
    # byte_size before any content walk
    size = byte_size(id)

    cond do
      size == 0 ->
        {:error, :empty_request_id}

      size > @request_id_max_bytes ->
        {:error, :request_id_too_large}

      not ascii_opaque_id?(id) ->
        {:error, :invalid_request_id}

      true ->
        {:ok, id}
    end
  end

  def validate_request_id(_), do: {:error, :invalid_request_id}

  @doc """
  Validate an operator note.

  Options:
    * `:truncate` (default `false`) — when true, oversized valid UTF-8 notes
      are truncated on a codepoint boundary (internal projection only).
      MCP answer paths must leave this false so oversized notes are rejected.
    * `:drop_invalid` (default `false`) — coerce invalid UTF-8 / non-binary
      to `\"\"` instead of erroring (bounded projection of control payloads).
  """
  @spec validate_note(term(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def validate_note(note, opts \\ [])

  def validate_note(nil, _opts), do: {:ok, ""}

  def validate_note(note, opts) when is_binary(note) do
    drop_invalid? = Keyword.get(opts, :drop_invalid, false)
    truncate? = Keyword.get(opts, :truncate, false)
    size = byte_size(note)

    cond do
      size == 0 ->
        {:ok, ""}

      # byte_size gate before UTF-8 validity scan / walk
      size > @note_max_bytes and not truncate? ->
        {:error, :note_too_large}

      not String.valid?(note) and drop_invalid? ->
        {:ok, ""}

      not String.valid?(note) ->
        {:error, :invalid_note_utf8}

      has_disallowed_control?(note) and not drop_invalid? ->
        {:error, :invalid_note_control}

      has_disallowed_control?(note) and drop_invalid? ->
        {:ok, ""}

      size > @note_max_bytes and truncate? ->
        {:ok, bound_utf8_prefix(note, @note_max_bytes)}

      true ->
        {:ok, note}
    end
  end

  def validate_note(_note, opts) do
    if Keyword.get(opts, :drop_invalid, false), do: {:ok, ""}, else: {:error, :invalid_note}
  end

  @doc """
  Normalize a backend response + metadata pair into a canonical decision.

  InteractionRouter uses `:approved`/`:rejected` plus metadata.decision/rework.
  Consensus stores `decision: :approved|:rejected` and may include
  `requested_decision: :approve|:deny|:rework` plus `note`.
  """
  @spec normalize(term(), term()) :: normalize_result()
  def normalize(response, metadata) do
    metadata = if is_map(metadata), do: metadata, else: %{}

    with {:ok, response_kind} <- classify_response(response),
         {:ok, decision} <- classify_metadata(metadata),
         :ok <- consistent?(response_kind, decision) do
      note =
        case validate_note(metadata_get(metadata, :note), drop_invalid: true, truncate: true) do
          {:ok, n} -> n
          _ -> ""
        end

      case {response_kind, decision} do
        {:approved, d} when d in [:absent, :approve] ->
          {:ok, :approve}

        {:rejected, :rework} ->
          {:ok, :rework, note}

        {:rejected, d} when d in [:absent, :deny] ->
          {:ok, :deny, note}
      end
    end
  end

  @doc """
  Normalize a consensus decision map (from `Consensus.await/2`).
  """
  @spec normalize_consensus_decision(map()) :: normalize_result()
  def normalize_consensus_decision(decision) when is_map(decision) do
    status = metadata_get(decision, :decision) || metadata_get(decision, :status)
    requested = metadata_get(decision, :requested_decision)
    note = metadata_get(decision, :note)

    metadata =
      %{}
      |> maybe_put_meta(:decision, requested)
      |> maybe_put_meta(:note, note)
      |> maybe_put_meta(:rework, requested in [:rework, "rework"])

    normalize(status, metadata)
  end

  def normalize_consensus_decision(_), do: {:error, :malformed_decision}

  @doc "Linear UTF-8 prefix bound (codepoint-safe). Invalid UTF-8 becomes \"\"."
  @spec bound_utf8_prefix(binary(), non_neg_integer()) :: binary()
  def bound_utf8_prefix(value, max_bytes)
      when is_binary(value) and is_integer(max_bytes) and max_bytes >= 0 do
    cond do
      byte_size(value) == 0 ->
        ""

      not String.valid?(value) ->
        ""

      byte_size(value) <= max_bytes ->
        value

      true ->
        take_utf8_prefix(value, max_bytes, 0, 0)
    end
  end

  def bound_utf8_prefix(_value, _max_bytes), do: ""

  # -- private ---------------------------------------------------------------

  # Closed ASCII opaque-id grammar: letters, digits, underscore, hyphen, colon,
  # period only. Rejects every ASCII control byte (0x00-0x1F and DEL 0x7F) and
  # all non-ASCII bytes via a linear single-byte walk — no String.length/UTF-8
  # scan, no NUL-only special case.
  defp ascii_opaque_id?(id) when is_binary(id), do: opaque_id_bytes?(id)

  defp opaque_id_bytes?(<<>>), do: false

  defp opaque_id_bytes?(bin) when is_binary(bin) do
    opaque_id_bytes_loop(bin, false)
  end

  defp opaque_id_bytes_loop(<<>>, true), do: true
  defp opaque_id_bytes_loop(<<>>, false), do: false

  defp opaque_id_bytes_loop(<<b, rest::binary>>, _seen)
       when (b >= ?0 and b <= ?9) or (b >= ?A and b <= ?Z) or (b >= ?a and b <= ?z) or
              b in [?_, ?., ?:, ?-] do
    opaque_id_bytes_loop(rest, true)
  end

  defp opaque_id_bytes_loop(_bin, _seen), do: false

  defp has_disallowed_control?(note) when is_binary(note) do
    # Reject every ASCII control byte including NUL, TAB, LF, CR, and DEL.
    has_ascii_control_byte?(note)
  end

  defp has_ascii_control_byte?(<<>>), do: false
  defp has_ascii_control_byte?(<<b, _rest::binary>>) when b <= 0x1F or b == 0x7F, do: true
  defp has_ascii_control_byte?(<<_b, rest::binary>>), do: has_ascii_control_byte?(rest)

  defp classify_response(r) when r in [:approved, :approve, "approved", "approve"],
    do: {:ok, :approved}

  defp classify_response(r)
       when r in [:rejected, :reject, :denied, "rejected", "reject", "deny", "denied"],
       do: {:ok, :rejected}

  defp classify_response(other), do: {:error, "unexpected_response:#{inspect(other)}"}

  defp classify_metadata(metadata) when not is_map(metadata), do: {:error, :malformed_metadata}

  defp classify_metadata(metadata) do
    decision = metadata_get(metadata, :decision)
    rework_flag? = truthy?(metadata_get(metadata, :rework))
    decision_rework? = decision in [:rework, "rework"]

    cond do
      (rework_flag? or decision_rework?) and decision in [nil, :rework, "rework"] ->
        {:ok, :rework}

      rework_flag? or decision_rework? ->
        {:error, :inconsistent_rework_marker}

      decision in [:approve, "approve"] ->
        {:ok, :approve}

      decision in [:deny, "deny", :denied, "denied"] ->
        {:ok, :deny}

      is_nil(decision) ->
        {:ok, :absent}

      true ->
        {:error, :malformed_decision}
    end
  end

  defp consistent?(:approved, decision) when decision in [:absent, :approve], do: :ok
  defp consistent?(:rejected, decision) when decision in [:absent, :deny, :rework], do: :ok

  defp consistent?(response_kind, decision),
    do: {:error, "inconsistent:#{response_kind}/#{decision}"}

  defp truthy?(flag) when flag in [true, "true", 1, "1"], do: true
  defp truthy?(_), do: false

  defp metadata_get(metadata, key) when is_atom(key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp maybe_put_meta(map, _key, nil), do: map
  defp maybe_put_meta(map, key, value), do: Map.put(map, key, value)

  # Walk codepoints without materializing the full grapheme list.
  defp take_utf8_prefix(binary, max_bytes, byte_offset, acc_size)
       when byte_offset < byte_size(binary) do
    <<_prefix::binary-size(byte_offset), rest::binary>> = binary

    case rest do
      <<cp::utf8, _tail::binary>> ->
        cp_size = byte_size(<<cp::utf8>>)
        next = acc_size + cp_size

        if next <= max_bytes do
          take_utf8_prefix(binary, max_bytes, byte_offset + cp_size, next)
        else
          binary_part(binary, 0, acc_size)
        end

      _ ->
        binary_part(binary, 0, acc_size)
    end
  end

  defp take_utf8_prefix(binary, _max_bytes, _byte_offset, acc_size) do
    binary_part(binary, 0, acc_size)
  end
end
