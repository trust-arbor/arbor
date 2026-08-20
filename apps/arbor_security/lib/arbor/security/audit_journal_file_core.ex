defmodule Arbor.Security.AuditJournalFileCore do
  @moduledoc """
  Pure CRC core for the v1 Security authority-mutation audit file log.

  Closed binary framing, SHA-256 predecessor+header+payload digests,
  torn-tail vs corruption classification, and replay into AuditJournalCore.

  Returns data and errors only. No IO, time, randomness, processes, ETS,
  logging, signals, or store/facade calls.
  """

  alias Arbor.Security.AuditJournalCore
  alias Arbor.Security.Contracts.AuditJournal

  @magic <<"AJL1">>
  @header_size 72
  @digest_size 32
  @frame_domain <<"arbor.security.audit_journal.frame.v1", 0>>
  @genesis_domain <<"arbor.security.audit_journal.genesis.v1", 0>>
  @genesis_digest :crypto.hash(:sha256, @genesis_domain)

  @type torn_tail :: nil | %{offset: non_neg_integer(), byte_size: pos_integer()}

  @type replay_state :: %{
          core: AuditJournalCore.state(),
          digest: binary(),
          offset: non_neg_integer(),
          frames: non_neg_integer(),
          torn_tail: torn_tail()
        }

  @type header :: %{
          payload_len: pos_integer(),
          predecessor: binary(),
          frame_digest: binary()
        }

  @type classify_result ::
          :torn_tail
          | {:frame, header(), binary()}
          | {:error, atom()}

  @spec header_size() :: 72
  def header_size, do: @header_size

  @spec max_payload_bytes() :: pos_integer()
  def max_payload_bytes, do: AuditJournal.limits().max_record_bytes

  @spec max_frame_bytes() :: pos_integer()
  def max_frame_bytes, do: @header_size + max_payload_bytes()

  @spec max_committed_frames() :: pos_integer()
  def max_committed_frames, do: AuditJournal.limits().hard_entry_cap

  @spec max_file_bytes() :: pos_integer()
  def max_file_bytes, do: max_committed_frames() * max_frame_bytes() + max_frame_bytes() - 1

  @spec genesis_digest() :: binary()
  def genesis_digest, do: @genesis_digest

  @spec new() :: {:ok, replay_state()}
  def new do
    {:ok, core} = AuditJournalCore.new()

    {:ok,
     %{
       core: core,
       digest: @genesis_digest,
       offset: 0,
       frames: 0,
       torn_tail: nil
     }}
  end

  @spec encode_frame(term(), term()) ::
          {:ok, binary(), binary()} | {:error, :record_too_large | :malformed}
  def encode_frame(payload, predecessor)
      when is_binary(payload) and is_binary(predecessor) do
    len = byte_size(payload)

    cond do
      byte_size(predecessor) != @digest_size ->
        {:error, :malformed}

      len < 1 ->
        {:error, :malformed}

      len > max_payload_bytes() ->
        {:error, :record_too_large}

      true ->
        digest = compute_digest(len, predecessor, payload)
        frame = @magic <> <<len::32-big>> <> predecessor <> digest <> payload
        {:ok, frame, digest}
    end
  end

  def encode_frame(_payload, _predecessor), do: {:error, :malformed}

  @spec decode_header(term()) :: {:ok, header()} | {:error, :malformed_header | :oversized_frame}
  def decode_header(
        <<magic::binary-size(4), len::32-big, predecessor::binary-size(32),
          frame_digest::binary-size(32)>>
      ) do
    cond do
      magic != @magic -> {:error, :malformed_header}
      len == 0 -> {:error, :malformed_header}
      len > max_payload_bytes() -> {:error, :oversized_frame}
      true -> {:ok, %{payload_len: len, predecessor: predecessor, frame_digest: frame_digest}}
    end
  end

  def decode_header(_other), do: {:error, :malformed_header}

  @spec classify_suffix(term(), term()) :: classify_result()
  def classify_suffix(suffix, expected)
      when is_binary(suffix) and is_binary(expected) and byte_size(expected) == @digest_size do
    r = byte_size(suffix)

    cond do
      r == 0 -> {:error, :malformed_header}
      r < 4 -> classify_magic_prefix(suffix)
      r < 8 -> classify_incomplete_length(suffix)
      r < 40 -> classify_incomplete_predecessor(suffix, expected)
      r < 72 -> classify_incomplete_digest(suffix, expected)
      true -> classify_complete_header(suffix, expected)
    end
  end

  def classify_suffix(_suffix, _expected), do: {:error, :malformed_header}

  @spec verify_frame(term(), term(), term()) ::
          {:ok, binary()} | {:error, :digest_mismatch | :predecessor_mismatch | :malformed_header}
  def verify_frame(
        %{payload_len: len, predecessor: predecessor, frame_digest: stored} = _header,
        payload,
        expected
      )
      when is_integer(len) and is_binary(predecessor) and is_binary(stored) and is_binary(payload) and
             is_binary(expected) do
    cond do
      predecessor != expected ->
        {:error, :predecessor_mismatch}

      byte_size(payload) != len ->
        {:error, :malformed_header}

      true ->
        computed = compute_digest(len, predecessor, payload)

        if computed == stored do
          {:ok, computed}
        else
          {:error, :digest_mismatch}
        end
    end
  end

  def verify_frame(_header, _payload, _expected), do: {:error, :malformed_header}

  @spec admit_payload(term()) :: {:ok, map()} | {:error, atom()}
  def admit_payload(payload) when is_binary(payload) do
    with {:ok, decoded} <- decode_json(payload),
         {:ok, record} <- map_admit(AuditJournal.admit_record(decoded)),
         {:ok, canonical} <- map_bytes(AuditJournal.canonical_record_bytes(record)) do
      if canonical == payload do
        {:ok, record}
      else
        {:error, :non_canonical}
      end
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  def admit_payload(_payload), do: {:error, :malformed}

  @spec consume(term(), term()) :: {:ok, replay_state()} | {:error, atom()}
  def consume(state, binary) when is_binary(binary) do
    with :ok <- valid_state(state),
         :ok <- bound_file_size(binary) do
      consume_loop(state, binary)
    end
  end

  def consume(_state, _binary), do: {:error, :malformed}

  @spec show(replay_state()) :: map()
  def show(%{core: core, digest: digest, offset: offset, frames: frames, torn_tail: torn_tail}) do
    %{
      projection: AuditJournalCore.show(core),
      evidence: %{
        committed_offset: offset,
        committed_digest: digest,
        committed_frames: frames,
        torn_tail: torn_tail
      }
    }
  end

  defp consume_loop(state, binary) do
    remaining = byte_size(binary) - state.offset

    if remaining == 0 do
      {:ok, state}
    else
      suffix = binary_part(binary, state.offset, remaining)
      consume_suffix(state, binary, suffix)
    end
  end

  defp consume_suffix(state, binary, suffix) do
    case classify_suffix(suffix, state.digest) do
      :torn_tail ->
        torn = %{offset: state.offset, byte_size: byte_size(suffix)}
        {:ok, %{state | torn_tail: torn}}

      {:error, reason} ->
        {:error, reason}

      {:frame, header, payload} ->
        admit_complete_frame(state, binary, header, payload)
    end
  end

  defp admit_complete_frame(state, binary, header, payload) do
    if state.frames >= max_committed_frames() do
      {:error, :capacity_exhausted}
    else
      fold_complete_frame(state, binary, header, payload)
    end
  end

  defp fold_complete_frame(state, binary, header, payload) do
    with {:ok, record} <- admit_payload(payload),
         {:ok, core} <- fold_record(state.core, record) do
      next = %{
        state
        | core: core,
          digest: header.frame_digest,
          offset: state.offset + @header_size + header.payload_len,
          frames: state.frames + 1
      }

      consume_loop(next, binary)
    end
  end

  defp fold_record(core, record) do
    case AuditJournalCore.append(core, record) do
      {:ok, next} -> {:ok, next}
      {:ok, next, :idempotent} -> {:ok, next}
      {:error, reason} -> {:error, reason}
    end
  end

  defp classify_magic_prefix(suffix) do
    expected = binary_part(@magic, 0, byte_size(suffix))

    if suffix == expected do
      :torn_tail
    else
      {:error, :malformed_header}
    end
  end

  defp classify_incomplete_length(suffix) do
    <<magic::binary-size(4), _rest::binary>> = suffix

    if magic == @magic do
      :torn_tail
    else
      {:error, :malformed_header}
    end
  end

  defp classify_incomplete_predecessor(suffix, expected) do
    <<magic::binary-size(4), len::32-big, pred_prefix::binary>> = suffix

    with :ok <- require_magic(magic),
         :ok <- require_payload_len(len),
         :ok <- require_pred_prefix(pred_prefix, expected) do
      :torn_tail
    end
  end

  defp classify_incomplete_digest(suffix, expected) do
    <<magic::binary-size(4), len::32-big, pred::binary-size(32), _digest_prefix::binary>> = suffix

    with :ok <- require_magic(magic),
         :ok <- require_payload_len(len),
         :ok <- require_predecessor(pred, expected) do
      :torn_tail
    end
  end

  defp classify_complete_header(suffix, expected) do
    header_bytes = binary_part(suffix, 0, @header_size)

    case decode_header(header_bytes) do
      {:error, reason} ->
        {:error, reason}

      {:ok, header} ->
        finish_complete_header(suffix, expected, header)
    end
  end

  defp finish_complete_header(suffix, expected, header) do
    remaining_payload = byte_size(suffix) - @header_size

    cond do
      header.predecessor != expected ->
        {:error, :predecessor_mismatch}

      remaining_payload < header.payload_len ->
        :torn_tail

      true ->
        payload = binary_part(suffix, @header_size, header.payload_len)

        case verify_frame(header, payload, expected) do
          {:ok, _digest} -> {:frame, header, payload}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp require_magic(@magic), do: :ok
  defp require_magic(_magic), do: {:error, :malformed_header}

  defp require_payload_len(0), do: {:error, :malformed_header}

  defp require_payload_len(len) when is_integer(len) and len > 0 do
    if len > max_payload_bytes() do
      {:error, :oversized_frame}
    else
      :ok
    end
  end

  defp require_pred_prefix(prefix, expected) when is_binary(prefix) and is_binary(expected) do
    want = binary_part(expected, 0, byte_size(prefix))

    if prefix == want do
      :ok
    else
      {:error, :predecessor_mismatch}
    end
  end

  defp require_predecessor(pred, expected) when pred == expected, do: :ok
  defp require_predecessor(_pred, _expected), do: {:error, :predecessor_mismatch}

  defp compute_digest(len, predecessor, payload) do
    authenticated = @magic <> <<len::32-big>> <> predecessor <> payload
    :crypto.hash(:sha256, @frame_domain <> authenticated)
  end

  defp decode_json(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :malformed}
    end
  end

  defp map_admit({:ok, record}), do: {:ok, record}
  defp map_admit({:error, :cross_operation}), do: {:error, :cross_operation}
  defp map_admit({:error, :record_too_large}), do: {:error, :record_too_large}
  defp map_admit({:error, _reason}), do: {:error, :malformed}

  defp map_bytes({:ok, bytes}), do: {:ok, bytes}
  defp map_bytes({:error, :record_too_large}), do: {:error, :record_too_large}
  defp map_bytes({:error, _reason}), do: {:error, :malformed}

  defp bound_file_size(binary) do
    if byte_size(binary) > max_file_bytes() do
      {:error, :log_too_large}
    else
      :ok
    end
  end

  defp valid_state(%{
         core: core,
         digest: digest,
         offset: offset,
         frames: frames,
         torn_tail: torn_tail
       })
       when is_binary(digest) and byte_size(digest) == @digest_size and is_integer(offset) and
              offset >= 0 and is_integer(frames) and frames >= 0 do
    case valid_torn_tail(torn_tail) do
      :ok -> valid_core(core)
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_state(_state), do: {:error, :malformed}

  defp valid_torn_tail(nil), do: :ok

  defp valid_torn_tail(%{offset: offset, byte_size: byte_size})
       when is_integer(offset) and offset >= 0 and is_integer(byte_size) and byte_size > 0 do
    :ok
  end

  defp valid_torn_tail(_torn), do: {:error, :malformed}

  defp valid_core(core) when is_map(core) and not is_struct(core), do: :ok
  defp valid_core(_core), do: {:error, :malformed}
end
