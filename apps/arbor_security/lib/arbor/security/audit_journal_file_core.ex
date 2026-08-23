defmodule Arbor.Security.AuditJournalFileCore do
  @moduledoc """
  Pure CRC core for the v1 Security authority-mutation audit file log.

  Closed binary framing, SHA-256 predecessor+header+payload digests,
  torn-tail vs corruption classification, record-only and snapshot-first
  replay into AuditJournalCore, and publication decision helpers.

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
  @known_unsupported_dir_sync [:eisdir, :enotsup, :einval, :enotty, :eopnotsupp]
  @pre_rename_phases [
    :admit,
    :cleanup,
    :create,
    :write,
    :sync,
    :candidate_proof,
    :candidate_reproof,
    :source_tip_proof
  ]
  @post_rename_phases [:dir_finalize, :reopen, :published_replay]

  @type torn_tail :: nil | %{offset: non_neg_integer(), byte_size: pos_integer()}

  @type pending_needed :: [{String.t(), String.t(), String.t()}]

  @type replay_state :: %{
          core: AuditJournalCore.state(),
          digest: binary(),
          offset: non_neg_integer(),
          frames: non_neg_integer(),
          torn_tail: torn_tail(),
          snapshot: map() | nil,
          pending_needed: pending_needed(),
          pending_have: [map()]
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
       torn_tail: nil,
       snapshot: nil,
       pending_needed: [],
       pending_have: []
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

  @spec source_binding(term(), term(), term()) :: {:ok, map()} | {:error, :malformed}
  def source_binding(digest, frames, offset)
      when is_binary(digest) and byte_size(digest) == @digest_size and is_integer(frames) and
             frames >= 0 and is_integer(offset) and offset >= 0 do
    {:ok,
     %{
       "committed_digest" => Base.encode16(digest, case: :lower),
       "committed_frames" => frames,
       "committed_offset" => offset
     }}
  end

  def source_binding(_digest, _frames, _offset), do: {:error, :malformed}

  @spec encode_compacted(term(), term()) ::
          {:ok, binary(), replay_state()} | {:error, atom()}
  def encode_compacted(snapshot, pending) when is_list(pending) do
    with {:ok, snap_bytes} <- map_bytes(AuditJournal.canonical_snapshot_bytes(snapshot)),
         {:ok, frame, digest} <- encode_frame(snap_bytes, @genesis_digest),
         {:ok, bytes, _digest} <- encode_pending_frames(pending, digest, frame),
         {:ok, empty} <- new(),
         {:ok, replay} <- consume(empty, bytes) do
      {:ok, bytes, replay}
    end
  end

  def encode_compacted(_snapshot, _pending), do: {:error, :malformed}

  @spec core_match?(term(), term()) :: boolean()
  def core_match?(left, right)
      when is_map(left) and is_map(right) and not is_struct(left) and not is_struct(right) do
    left === right
  end

  def core_match?(_left, _right), do: false

  @spec source_tip_match?(term(), term()) :: boolean()
  def source_tip_match?(
        %{digest: digest, frames: frames, offset: offset},
        %{
          "committed_digest" => hex,
          "committed_frames" => frames,
          "committed_offset" => offset
        }
      )
      when is_binary(digest) and byte_size(digest) == @digest_size and is_binary(hex) do
    Base.encode16(digest, case: :lower) == hex
  end

  def source_tip_match?(_replay, _source), do: false

  @spec candidate_basename(term()) :: {:ok, String.t()} | {:error, :malformed}
  def candidate_basename(name) when is_binary(name) do
    cond do
      name in ["", ".", ".."] -> {:error, :malformed}
      String.contains?(name, <<0>>) -> {:error, :malformed}
      String.contains?(name, "/") -> {:error, :malformed}
      true -> {:ok, "." <> name <> ".compact"}
    end
  end

  def candidate_basename(_name), do: {:error, :malformed}

  @spec leftover_action(term()) :: :unlink | {:error, atom()}
  def leftover_action(%{type: :symlink}), do: {:error, :symlink_rejected}

  def leftover_action(%{type: type}) when type != :regular, do: {:error, :not_regular}

  def leftover_action(%{type: :regular, links: links}) when is_integer(links) and links != 1,
    do: {:error, :hardlink_rejected}

  def leftover_action(%{type: :regular, mode: mode, links: 1}) when is_integer(mode) do
    if Bitwise.band(mode, 0o777) == 0o600 do
      :unlink
    else
      {:error, :insecure_mode}
    end
  end

  def leftover_action(_facts), do: {:error, :malformed}

  @spec classify_dir_sync(term()) :: :ok | {:error, term()}
  def classify_dir_sync(:ok), do: :ok

  def classify_dir_sync({:error, reason}) when reason in @known_unsupported_dir_sync, do: :ok

  def classify_dir_sync({:error, reason}), do: {:error, reason}

  def classify_dir_sync(_result), do: {:error, :malformed}

  @spec classify_rename_outcome(term()) ::
          :continue | {:not_published, atom()} | {:publish_uncertain, :rename_ambiguous}
  def classify_rename_outcome(%{rename: :ok}), do: :continue

  def classify_rename_outcome(%{
        rename: {:error, _reason},
        candidate_present?: true,
        target_identity_match?: true
      }) do
    {:not_published, :write_failed}
  end

  def classify_rename_outcome(_outcome), do: {:publish_uncertain, :rename_ambiguous}

  @spec classify_publish_phase(term(), term()) ::
          {:not_published, atom()} | {:publish_uncertain, atom()} | {:error, :malformed}
  def classify_publish_phase(phase, reason)
      when phase in @pre_rename_phases and is_atom(reason) do
    {:not_published, reason}
  end

  def classify_publish_phase(phase, reason)
      when phase in @post_rename_phases and is_atom(reason) do
    {:publish_uncertain, reason}
  end

  def classify_publish_phase(_phase, _reason), do: {:error, :malformed}

  @spec admit_snapshot_payload(term()) :: {:ok, map()} | {:error, atom()}
  def admit_snapshot_payload(payload) when is_binary(payload) do
    with {:ok, decoded} <- decode_json(payload),
         {:ok, snapshot} <- map_snapshot_admit(AuditJournal.admit_snapshot(decoded)),
         {:ok, canonical} <- map_bytes(AuditJournal.canonical_snapshot_bytes(snapshot)) do
      if canonical == payload do
        {:ok, snapshot}
      else
        {:error, :non_canonical}
      end
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  def admit_snapshot_payload(_payload), do: {:error, :malformed}

  defp consume_loop(state, binary) do
    size = byte_size(binary)
    offset = state.offset

    cond do
      offset > size ->
        {:error, :malformed}

      offset == size and state.pending_needed != [] ->
        {:error, :pending_mismatch}

      offset == size ->
        {:ok, %{state | torn_tail: nil}}

      true ->
        suffix = binary_part(binary, offset, size - offset)
        consume_suffix(state, binary, suffix)
    end
  end

  defp consume_suffix(state, binary, suffix) do
    case classify_suffix(suffix, state.digest) do
      :torn_tail ->
        finish_torn_tail(state, suffix)

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
    with {:ok, folded} <- admit_and_fold(state, payload) do
      next = %{
        folded
        | digest: header.frame_digest,
          offset: state.offset + @header_size + header.payload_len,
          frames: state.frames + 1,
          torn_tail: nil
      }

      consume_loop(next, binary)
    end
  end

  defp finish_torn_tail(state, suffix) do
    if is_map(state.snapshot) and state.pending_needed != [] do
      {:error, :pending_mismatch}
    else
      torn = %{offset: state.offset, byte_size: byte_size(suffix)}
      {:ok, %{state | torn_tail: torn}}
    end
  end

  defp admit_and_fold(state, payload) do
    case payload_kind(payload) do
      :snapshot when state.frames == 0 ->
        admit_snapshot_frame(state, payload)

      :snapshot ->
        {:error, :snapshot_not_first}

      :record when state.pending_needed != [] ->
        admit_pending_frame(state, payload)

      :record ->
        admit_record_frame(state, payload)
    end
  end

  defp payload_kind(payload) when is_binary(payload) do
    case decode_json(payload) do
      {:ok, %{"kind" => kind}} ->
        if kind == AuditJournal.snapshot_kind() do
          :snapshot
        else
          :record
        end

      _other ->
        :record
    end
  end

  defp admit_snapshot_frame(state, payload) do
    with {:ok, snapshot} <- admit_snapshot_payload(payload) do
      needed = pending_needed_from(snapshot)
      finish_snapshot_frame(state, snapshot, needed)
    end
  end

  defp finish_snapshot_frame(state, snapshot, []) do
    case AuditJournalCore.restore(snapshot, []) do
      {:ok, core} ->
        {:ok, %{state | core: core, snapshot: snapshot, pending_needed: [], pending_have: []}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_snapshot_frame(state, snapshot, needed) do
    {:ok, %{state | snapshot: snapshot, pending_needed: needed, pending_have: []}}
  end

  defp pending_needed_from(snapshot) do
    snapshot
    |> AuditJournal.snapshot_pending_entries()
    |> Enum.map(&{&1["operation_id"], &1["record_type"], &1["sha256"]})
  end

  defp admit_pending_frame(state, payload) do
    with {:ok, record} <- admit_payload(payload),
         {:ok, bytes} <- map_bytes(AuditJournal.canonical_record_bytes(record)),
         {:ok, fingerprint} <- map_fingerprint(AuditJournal.record_fingerprint(bytes)),
         :ok <- match_pending_head(state.pending_needed, record, fingerprint) do
      have = state.pending_have ++ [record]
      needed = tl(state.pending_needed)
      finish_pending_prefix(state, have, needed)
    end
  end

  defp finish_pending_prefix(state, have, []) do
    case AuditJournalCore.restore(state.snapshot, have) do
      {:ok, core} ->
        {:ok, %{state | core: core, pending_needed: [], pending_have: have}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_pending_prefix(state, have, needed) do
    {:ok, %{state | pending_have: have, pending_needed: needed}}
  end

  defp match_pending_head([{oid, type, sha} | _rest], record, fingerprint) do
    cond do
      record["operation_id"] == oid and record["record_type"] == type and fingerprint == sha ->
        :ok

      record["operation_id"] != oid ->
        {:error, :cross_operation}

      true ->
        {:error, :pending_mismatch}
    end
  end

  defp match_pending_head(_needed, _record, _fingerprint), do: {:error, :pending_mismatch}

  defp admit_record_frame(state, payload) do
    with {:ok, record} <- admit_payload(payload),
         {:ok, core} <- fold_record(state.core, record) do
      {:ok, %{state | core: core}}
    end
  end

  defp encode_pending_frames([], digest, acc), do: {:ok, acc, digest}

  defp encode_pending_frames([record | rest], pred, acc) do
    with {:ok, rec_bytes} <- map_bytes(AuditJournal.canonical_record_bytes(record)),
         {:ok, frame, digest} <- encode_frame(rec_bytes, pred) do
      encode_pending_frames(rest, digest, acc <> frame)
    end
  end

  defp encode_pending_frames(_records, _pred, _acc), do: {:error, :malformed}

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
    <<magic::binary-size(4), len_prefix::binary>> = suffix

    with :ok <- require_magic(magic),
         :ok <- require_possible_payload_len(len_prefix) do
      :torn_tail
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

  defp require_possible_payload_len(<<>>), do: :ok

  defp require_possible_payload_len(len_prefix)
       when is_binary(len_prefix) and byte_size(len_prefix) in 1..3 do
    pad = 4 - byte_size(len_prefix)
    min_len = :binary.decode_unsigned(len_prefix <> :binary.copy(<<0>>, pad), :big)
    max_len = :binary.decode_unsigned(len_prefix <> :binary.copy(<<0xFF>>, pad), :big)
    max_payload = max_payload_bytes()

    cond do
      min_len > max_payload -> {:error, :oversized_frame}
      max_len < 1 -> {:error, :malformed_header}
      true -> :ok
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

  defp map_snapshot_admit({:ok, snapshot}), do: {:ok, snapshot}
  defp map_snapshot_admit({:error, :record_too_large}), do: {:error, :record_too_large}
  defp map_snapshot_admit({:error, _reason}), do: {:error, :malformed}

  defp map_fingerprint({:ok, sha256}), do: {:ok, sha256}
  defp map_fingerprint({:error, :record_too_large}), do: {:error, :record_too_large}
  defp map_fingerprint({:error, _reason}), do: {:error, :malformed}

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
         torn_tail: torn_tail,
         snapshot: snapshot,
         pending_needed: pending_needed,
         pending_have: pending_have
       })
       when is_binary(digest) and byte_size(digest) == @digest_size and is_integer(offset) and
              offset >= 0 and is_integer(frames) and frames >= 0 do
    with :ok <- valid_torn_tail(torn_tail),
         :ok <- valid_snapshot(snapshot),
         :ok <- valid_pending_needed(pending_needed),
         :ok <- valid_pending_have(pending_have) do
      valid_core(core)
    end
  end

  defp valid_state(_state), do: {:error, :malformed}

  defp valid_snapshot(nil), do: :ok
  defp valid_snapshot(snapshot) when is_map(snapshot) and not is_struct(snapshot), do: :ok
  defp valid_snapshot(_snapshot), do: {:error, :malformed}

  defp valid_pending_needed(list) when is_list(list) do
    if Enum.all?(list, &valid_pending_tuple?/1) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp valid_pending_needed(_list), do: {:error, :malformed}

  defp valid_pending_tuple?({oid, type, sha})
       when is_binary(oid) and is_binary(type) and is_binary(sha),
       do: true

  defp valid_pending_tuple?(_tuple), do: false

  defp valid_pending_have(list) when is_list(list) do
    if Enum.all?(list, &(is_map(&1) and not is_struct(&1))) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp valid_pending_have(_list), do: {:error, :malformed}

  defp valid_torn_tail(nil), do: :ok

  defp valid_torn_tail(%{offset: offset, byte_size: byte_size})
       when is_integer(offset) and offset >= 0 and is_integer(byte_size) and byte_size > 0 do
    :ok
  end

  defp valid_torn_tail(_torn), do: {:error, :malformed}

  defp valid_core(core) when is_map(core) and not is_struct(core), do: :ok
  defp valid_core(_core), do: {:error, :malformed}
end
