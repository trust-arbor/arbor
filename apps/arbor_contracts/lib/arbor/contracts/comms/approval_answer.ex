defmodule Arbor.Contracts.Comms.ApprovalAnswer do
  @moduledoc """
  Shared normalization for operator approval answers across backends.

  Both `Arbor.Comms.InteractionRouter` and consensus authorization-request
  answers must map approve / deny / rework + bounded note / request metadata
  identically. Opaque request IDs are validated (never truncated). Notes are
  bound with linear UTF-8 prefix processing (never full-string grapheme walks).
  """

  @max_note_bytes 1_024
  @max_request_id_bytes 256

  @type decision :: :approve | :deny | :rework
  @type normalize_result ::
          {:ok, :approve}
          | {:ok, :rework, String.t()}
          | {:ok, :deny, String.t()}
          | {:error, term()}

  @doc "Maximum accepted note size in bytes."
  @spec max_note_bytes() :: pos_integer()
  def max_note_bytes, do: @max_note_bytes

  @doc "Maximum accepted opaque request/proposal id size in bytes."
  @spec max_request_id_bytes() :: pos_integer()
  def max_request_id_bytes, do: @max_request_id_bytes

  @doc """
  Validate an opaque approval id. Rejects empty, non-UTF-8, oversized, or
  control-character-bearing ids rather than truncating them.
  """
  @spec validate_request_id(term()) :: {:ok, String.t()} | {:error, term()}
  def validate_request_id(id) when is_binary(id) do
    cond do
      id == "" ->
        {:error, :empty_request_id}

      not String.valid?(id) ->
        {:error, :invalid_request_id_utf8}

      byte_size(id) > @max_request_id_bytes ->
        {:error, :request_id_too_large}

      String.contains?(id, <<0>>) ->
        {:error, :invalid_request_id}

      true ->
        {:ok, id}
    end
  end

  def validate_request_id(_), do: {:error, :invalid_request_id}

  @doc """
  Validate and bound an operator note. Oversized valid UTF-8 notes are
  truncated on a codepoint boundary with linear scanning. Invalid UTF-8 is
  rejected at MCP answer time; consumers that must keep going may pass
  `drop_invalid: true` to coerce to `\"\"`.
  """
  @spec validate_note(term(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def validate_note(note, opts \\ [])

  def validate_note(nil, _opts), do: {:ok, ""}

  def validate_note(note, opts) when is_binary(note) do
    drop_invalid? = Keyword.get(opts, :drop_invalid, false)

    cond do
      not String.valid?(note) and drop_invalid? ->
        {:ok, ""}

      not String.valid?(note) ->
        {:error, :invalid_note_utf8}

      true ->
        {:ok, bound_utf8_prefix(note, @max_note_bytes)}
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
        case validate_note(metadata_get(metadata, :note), drop_invalid: true) do
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
