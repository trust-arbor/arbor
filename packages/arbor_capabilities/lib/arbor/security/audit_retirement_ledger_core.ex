defmodule Arbor.Security.AuditRetirementLedgerCore do
  @moduledoc """
  Pure CRC core for the cold authority-audit retirement ledger.

  The ledger is the cold, append-only segment of the Security audit journal:
  every delivered terminal a retiring publication removes from the hot
  snapshot is written, as its exact compact string, into one ledger frame
  before the journal candidate is renamed. The journal's v3 snapshot binds the
  ledger tip (`retirement.ledger`: `frames`, `tip_offset`, `tip_len`,
  `tip_digest`).

  Ledger frames reuse the journal frame format
  (`AuditJournalFileCore.encode_frame/2`): the predecessor of the first frame
  is the journal genesis digest, and every later frame chains from the bound
  tip digest. Payloads are closed `arbor.security.audit_retirement_batch.v1`
  objects (`AuditJournal.canonical_retirement_batch_bytes/1`).

  This module decides; it never reads or writes a file:

  - `frame/3` builds the next frame and the binding that names it;
  - `verify_bound_frame/2` proves the bytes at the bound tip are the frame
    the binding names;
  - `classify_tail/3` classifies the bytes beyond the bound as `:bound`
    (nothing), `:bound_orphan` (overwritable: a torn prefix of a frame at the
    bound, or exactly one complete frame chained from the tip whose retired
    entries are all still hot delivered terminals) or `:ahead` (anything else,
    never overwritten);
  - `retiring_allowed?/1` maps a posture to "a publication may retire".

  No IO, time, randomness, processes or logging.
  """

  alias Arbor.Security.AuditJournalFileCore, as: FileCore
  alias Arbor.Security.Contracts.AuditJournal

  @retiring_states [:absent, :bound, :bound_orphan]
  @paused_states [:mismatch, :ahead]

  @type binding :: %{String.t() => non_neg_integer() | String.t()}

  @typedoc """
  Ledger posture of a journal handle.

  `:absent | :bound | :bound_orphan` retire normally; `:mismatch | :ahead`
  pause retirement (publications run non-retiring, never refused).
  """
  @type posture :: :absent | :bound | :bound_orphan | :mismatch | :ahead

  @type framed :: %{
          payload: binary(),
          frame: binary(),
          digest: binary(),
          offset: non_neg_integer(),
          next_binding: binding()
        }

  @doc "Postures under which a publication may retire delivered terminals."
  @spec retiring_states() :: [posture()]
  def retiring_states, do: @retiring_states

  @doc "Postures that pause retirement."
  @spec paused_states() :: [posture()]
  def paused_states, do: @paused_states

  @spec retiring_allowed?(term()) :: boolean()
  def retiring_allowed?(state), do: state in @retiring_states

  @spec paused?(term()) :: boolean()
  def paused?(state), do: state in @paused_states

  @doc """
  Build the next ledger frame for `retired` (operation id => delivered
  terminal compact string, as `AuditJournalCore.retirement_batch/1` returns),
  bound to the journal `source` of the retiring publication, chained from the
  `bound` binding's tip.

  Returns `{:ok, %{payload, frame, digest, offset, next_binding}}` where
  `offset` is the bound size (where the frame is written) and `next_binding`
  is the string-keyed binding `AuditJournalCore.compact/3` requires:
  `frames + 1`, `tip_offset` = bound size, `tip_len` = payload size and
  `tip_digest` = lowercase hex of the frame digest.
  """
  @spec frame(term(), term(), term()) ::
          {:ok, framed()} | {:error, :malformed | :record_too_large}
  def frame(retired, source, bound) do
    with {:ok, bound} <- admit_binding(bound),
         {:ok, offset} <- map_malformed(AuditJournal.ledger_bound_size(bound)),
         {:ok, predecessor} <- tip_digest(bound),
         {:ok, payload} <- batch_bytes(retired, source),
         {:ok, frame, digest} <- FileCore.encode_frame(payload, predecessor) do
      next = %{
        "frames" => bound["frames"] + 1,
        "tip_offset" => offset,
        "tip_len" => byte_size(payload),
        "tip_digest" => Base.encode16(digest, case: :lower)
      }

      {:ok, %{payload: payload, frame: frame, digest: digest, offset: offset, next_binding: next}}
    end
  end

  @doc """
  Byte size of the ledger prefix `binding` covers (0 at genesis, else the end
  of the bound tip frame). Delegates to `AuditJournal.ledger_bound_size/1`
  after admitting the binding's closed shape.
  """
  @spec bound_size(term()) :: {:ok, non_neg_integer()} | {:error, :malformed}
  def bound_size(binding) do
    with {:ok, binding} <- admit_binding(binding) do
      map_malformed(AuditJournal.ledger_bound_size(binding))
    end
  end

  @doc """
  Byte range `{offset, length}` of the bound tip frame, or `:none` at genesis.
  """
  @spec tip_range(term()) ::
          {:ok, {non_neg_integer(), pos_integer()} | :none} | {:error, :malformed}
  def tip_range(binding) do
    with {:ok, binding} <- admit_binding(binding) do
      case binding["frames"] do
        0 -> {:ok, :none}
        _ -> {:ok, {binding["tip_offset"], FileCore.header_size() + binding["tip_len"]}}
      end
    end
  end

  @doc """
  Prove `bytes` (exactly the bound tip frame, `[tip_offset, bound_size)`) is
  the frame `binding` names: a well-formed header whose payload length is
  `tip_len`, a digest that recomputes to `tip_digest` over the header's own
  predecessor (the genesis digest for the first frame), and a canonical
  retirement-batch payload. At genesis only the empty binary proves.
  """
  @spec verify_bound_frame(term(), term()) :: :ok | {:error, atom()}
  def verify_bound_frame(binding, bytes) when is_binary(bytes) do
    with {:ok, binding} <- admit_binding(binding) do
      case binding["frames"] do
        0 when bytes == <<>> -> :ok
        0 -> {:error, :size_mismatch}
        _ -> verify_tip(binding, bytes)
      end
    end
  end

  def verify_bound_frame(_binding, _bytes), do: {:error, :malformed}

  @doc """
  Prove `frame` is a well-formed frame chained from `binding`'s tip (the frame
  the next retiring publication writes at the bound offset).
  """
  @spec verify_next_frame(term(), term()) :: :ok | {:error, atom()}
  def verify_next_frame(binding, frame) when is_binary(frame) do
    header_size = FileCore.header_size()

    with {:ok, binding} <- admit_binding(binding),
         {:ok, tip} <- tip_digest(binding),
         true <- byte_size(frame) > header_size || {:error, :malformed_header},
         <<header_bytes::binary-size(header_size), payload::binary>> = frame,
         {:ok, header} <- FileCore.decode_header(header_bytes),
         {:ok, _digest} <- FileCore.verify_frame(header, payload, tip),
         {:ok, _batch} <- admit_batch_payload(payload) do
      :ok
    end
  end

  def verify_next_frame(_binding, _frame), do: {:error, :malformed}

  @doc """
  Classify the ledger bytes beyond the bound.

  `tail` is at most `AuditJournalFileCore.max_frame_bytes() + 1` bytes read at
  the bound offset (a longer read proves more than one frame). `hot_delivered`
  is the map of hot delivered terminals (`AuditJournalCore.retirement_batch/1`)
  of the surviving journal.

  - `<<>>` -> `:bound`
  - a torn prefix of a frame chained from the tip -> `:bound_orphan`
  - exactly one complete frame chained from the tip whose admitted batch
    entries (id AND compact string) are all hot delivered terminals ->
    `:bound_orphan` (an unpublished attempt for operations the journal still
    holds: overwritable)
  - anything else -> `:ahead` (never overwritten)
  """
  @spec classify_tail(term(), term(), term()) ::
          :bound | :bound_orphan | :ahead | {:error, :malformed}
  def classify_tail(binding, tail, hot_delivered)
      when is_binary(tail) and is_map(hot_delivered) do
    with {:ok, binding} <- admit_binding(binding),
         {:ok, tip} <- tip_digest(binding) do
      cond do
        tail == <<>> -> :bound
        byte_size(tail) > FileCore.max_frame_bytes() -> :ahead
        true -> classify_nonempty_tail(tail, tip, hot_delivered)
      end
    end
  end

  def classify_tail(_binding, _tail, _hot_delivered), do: {:error, :malformed}

  @doc """
  Admit a ledger binding's closed shape (the same rules the v3 snapshot
  applies): exact keys, non-negative integers, lowercase hex64 digest, and a
  single genesis representation.
  """
  @spec admit_binding(term()) :: {:ok, binding()} | {:error, :malformed}
  def admit_binding(
        %{
          "frames" => frames,
          "tip_offset" => offset,
          "tip_len" => len,
          "tip_digest" => digest
        } = binding
      )
      when map_size(binding) == 4 and is_integer(frames) and frames >= 0 and
             is_integer(offset) and offset >= 0 and is_integer(len) and len >= 0 and
             is_binary(digest) do
    if hex64?(digest) and consistent_binding?(frames, offset, len, digest),
      do: {:ok, binding},
      else: {:error, :malformed}
  end

  def admit_binding(_binding), do: {:error, :malformed}

  # Genesis has exactly one representation; the first frame is written at
  # offset 0 and every later frame follows at least one earlier frame.
  defp consistent_binding?(0, offset, len, digest),
    do: offset == 0 and len == 0 and digest == genesis_hex()

  defp consistent_binding?(frames, offset, len, digest) do
    len > 0 and len <= FileCore.max_payload_bytes() and digest != genesis_hex() and
      ((frames == 1 and offset == 0) or (frames > 1 and offset > 0))
  end

  @doc "Admit one ledger frame payload as a canonical retirement batch."
  @spec admit_batch_payload(term()) :: {:ok, map()} | {:error, :malformed}
  def admit_batch_payload(payload) when is_binary(payload) do
    with {:ok, decoded} <- decode_json(payload),
         {:ok, batch} <- map_malformed(AuditJournal.admit_retirement_batch(decoded)),
         {:ok, canonical} <- map_malformed(AuditJournal.canonical_retirement_batch_bytes(batch)) do
      if canonical == payload, do: {:ok, batch}, else: {:error, :malformed}
    end
  end

  def admit_batch_payload(_payload), do: {:error, :malformed}

  # ---------------------------------------------------------------------------

  defp verify_tip(binding, bytes) do
    header_size = FileCore.header_size()

    with true <- byte_size(bytes) == header_size + binding["tip_len"] || {:error, :size_mismatch},
         <<header_bytes::binary-size(header_size), payload::binary>> = bytes,
         {:ok, header} <- FileCore.decode_header(header_bytes),
         true <- header.payload_len == binding["tip_len"] || {:error, :size_mismatch},
         :ok <- first_frame_predecessor(binding, header.predecessor),
         {:ok, digest} <- FileCore.verify_frame(header, payload, header.predecessor),
         true <-
           Base.encode16(digest, case: :lower) == binding["tip_digest"] ||
             {:error, :digest_mismatch},
         {:ok, _batch} <- admit_batch_payload(payload) do
      :ok
    end
  end

  # The first frame is written at offset 0 and chains from genesis; a later
  # tip's predecessor is interior-chain evidence verified offline only.
  defp first_frame_predecessor(%{"frames" => 1}, predecessor) do
    if predecessor == FileCore.genesis_digest(),
      do: :ok,
      else: {:error, :predecessor_mismatch}
  end

  defp first_frame_predecessor(_binding, _predecessor), do: :ok

  defp classify_nonempty_tail(tail, tip, hot_delivered) do
    case FileCore.classify_suffix(tail, tip) do
      :torn_tail ->
        :bound_orphan

      {:frame, header, payload} ->
        single? = byte_size(tail) == FileCore.header_size() + header.payload_len

        if single? and orphan_of_hot?(payload, hot_delivered),
          do: :bound_orphan,
          else: :ahead

      {:error, _reason} ->
        :ahead
    end
  end

  defp orphan_of_hot?(payload, hot_delivered) do
    case admit_batch_payload(payload) do
      {:ok, %{"retired" => retired}} ->
        Enum.all?(retired, fn {id, compact} -> Map.get(hot_delivered, id) == compact end)

      {:error, _reason} ->
        false
    end
  end

  defp batch_bytes(retired, source) when is_map(retired) do
    batch = %{
      "version" => 1,
      "kind" => AuditJournal.retirement_batch_kind(),
      "source" => source,
      "retired" => retired
    }

    case AuditJournal.canonical_retirement_batch_bytes(batch) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :record_too_large} -> {:error, :record_too_large}
      {:error, _reason} -> {:error, :malformed}
    end
  end

  defp batch_bytes(_retired, _source), do: {:error, :malformed}

  defp tip_digest(%{"tip_digest" => hex}) do
    case Base.decode16(hex, case: :lower) do
      {:ok, digest} when byte_size(digest) == 32 -> {:ok, digest}
      _other -> {:error, :malformed}
    end
  end

  defp genesis_hex, do: AuditJournal.ledger_genesis_binding()["tip_digest"]

  defp hex64?(value) do
    byte_size(value) == 64 and
      match?({:ok, _}, Base.decode16(value, case: :lower))
  end

  defp decode_json(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :malformed}
    end
  end

  defp map_malformed({:ok, value}), do: {:ok, value}
  defp map_malformed({:error, _reason}), do: {:error, :malformed}
end
