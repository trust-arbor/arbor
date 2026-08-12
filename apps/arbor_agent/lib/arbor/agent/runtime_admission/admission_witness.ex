defmodule Arbor.Agent.RuntimeAdmission.AdmissionWitness do
  @moduledoc """
  Pure closed validators for runtime-admission BranchSupervisor witnesses.

  Shared by `Lifecycle` (effect boundary) and `BranchSupervisor` (Registry
  normalize) so guarded schemas cannot drift. No IO, no GenServer.

  Lifecycle accepts **only** the canonical atom-key guarded witness. Registry
  normalize additionally admits an exact pure-string key form (JSON boundary)
  by converting then re-validating through the same atom path.
  """

  @guarded_atom_keys MapSet.new([
                       :v,
                       :kind,
                       :intent_id,
                       :fingerprint,
                       :operation_id,
                       :token
                     ])

  @guarded_string_keys MapSet.new([
                         "v",
                         "kind",
                         "intent_id",
                         "fingerprint",
                         "operation_id",
                         "token"
                       ])

  @max_intent_id_bytes 32
  @max_fingerprint_bytes 67
  @max_operation_id_bytes 128
  @max_token_bytes 32

  @intent_id_re ~r/\Arai_[A-Za-z0-9_-]{22}\z/
  @fingerprint_re ~r/\Afp_[0-9a-f]{64}\z/
  @operation_id_re ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @token_re ~r/\Arrt_[A-Za-z0-9_-]{22}\z/

  @type guarded_witness :: %{
          v: 1,
          kind: :guarded_restore,
          intent_id: String.t(),
          fingerprint: String.t(),
          operation_id: String.t(),
          token: String.t()
        }

  @doc """
  Admit a **canonical atom-key** guarded restore witness for Lifecycle.

  Requires exact six-key set `[:v, :kind, :intent_id, :fingerprint, :operation_id, :token]`,
  `v == 1` (integer only), `kind == :guarded_restore`, and claim/BranchSupervisor
  scalar grammars. Rejects mixed atom+string keys, string `"1"`, extras, missing
  keys, wrong types, invalid UTF-8, oversized or malformed scalars.
  """
  @spec admit_guarded(term()) ::
          {:ok, guarded_witness()} | {:error, :invalid_guarded_restore_witness}
  def admit_guarded(witness) when is_map(witness) and not is_struct(witness) do
    keys = witness |> Map.keys() |> MapSet.new()

    cond do
      not MapSet.equal?(keys, @guarded_atom_keys) ->
        {:error, :invalid_guarded_restore_witness}

      true ->
        admit_guarded_atom_map(witness)
    end
  end

  def admit_guarded(_), do: {:error, :invalid_guarded_restore_witness}

  @doc """
  Normalize a guarded Registry witness value to the canonical atom map, or nil.

  Accepts:
  - exact atom-key form (same as `admit_guarded/1`)
  - exact pure-string-key form (`"v"/"kind"/...` only, kind string `"guarded_restore"`,
    integer `v` only after conversion path uses string `"1"` rejected at admit)

  Mixed key representations and invalid scalars yield `nil` (bare).
  """
  @spec normalize_guarded(term()) :: guarded_witness() | nil
  def normalize_guarded(witness) when is_map(witness) and not is_struct(witness) do
    case admit_guarded(witness) do
      {:ok, canon} ->
        canon

      {:error, _} ->
        normalize_guarded_string_keys(witness)
    end
  end

  def normalize_guarded(_), do: nil

  @doc "True when scalars match the closed guarded witness grammar."
  @spec valid_guarded_scalars?(term(), term(), term(), term()) :: boolean()
  def valid_guarded_scalars?(id, fp, op, token)
      when is_binary(id) and is_binary(fp) and is_binary(op) and is_binary(token) do
    byte_size(id) <= @max_intent_id_bytes and String.valid?(id) and
      Regex.match?(@intent_id_re, id) and
      byte_size(fp) <= @max_fingerprint_bytes and String.valid?(fp) and
      Regex.match?(@fingerprint_re, fp) and
      byte_size(op) > 0 and byte_size(op) <= @max_operation_id_bytes and
      String.valid?(op) and Regex.match?(@operation_id_re, op) and
      byte_size(token) <= @max_token_bytes and String.valid?(token) and
      Regex.match?(@token_re, token)
  end

  def valid_guarded_scalars?(_, _, _, _), do: false

  defp admit_guarded_atom_map(%{
         v: 1,
         kind: :guarded_restore,
         intent_id: id,
         fingerprint: fp,
         operation_id: op,
         token: token
       }) do
    if valid_guarded_scalars?(id, fp, op, token) do
      {:ok,
       %{
         v: 1,
         kind: :guarded_restore,
         intent_id: id,
         fingerprint: fp,
         operation_id: op,
         token: token
       }}
    else
      {:error, :invalid_guarded_restore_witness}
    end
  end

  defp admit_guarded_atom_map(_), do: {:error, :invalid_guarded_restore_witness}

  defp normalize_guarded_string_keys(w) when is_map(w) do
    keys = w |> Map.keys() |> MapSet.new()

    # Pure string keyset only — any atom key means mixed/alias form → bare.
    if MapSet.equal?(keys, @guarded_string_keys) do
      # Integer 1 only after convert; string "1" must fail admit_guarded.
      v = Map.get(w, "v")
      kind = Map.get(w, "kind")

      atomized = %{
        v: v,
        kind: if(kind == "guarded_restore", do: :guarded_restore, else: kind),
        intent_id: Map.get(w, "intent_id"),
        fingerprint: Map.get(w, "fingerprint"),
        operation_id: Map.get(w, "operation_id"),
        token: Map.get(w, "token")
      }

      case admit_guarded(atomized) do
        {:ok, canon} -> canon
        {:error, _} -> nil
      end
    else
      nil
    end
  end
end
