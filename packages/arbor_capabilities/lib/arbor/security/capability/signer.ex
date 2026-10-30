defmodule Arbor.Security.Capability.Signer do
  @moduledoc """
  Pure functions for capability signing and verification.

  No state, no GenServer dependencies. Uses Ed25519 via `Arbor.Security.Crypto`
  for all cryptographic operations. The signing payload is computed deterministically
  from the capability's content fields (excluding signature fields).
  """

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.Crypto

  @delegation_record_version "arbor-delegation-record-v2"

  @doc """
  Sign a capability with a private key, setting `issuer_id` and `issuer_signature`.

  The issuer_id must already be set on the capability before signing.
  """
  @spec sign(Capability.t(), binary()) :: Capability.t()
  def sign(%Capability{} = cap, private_key) when is_binary(private_key) do
    payload = canonical_payload(cap)
    signature = Crypto.sign(payload, private_key)
    %{cap | issuer_signature: signature}
  end

  @doc """
  Verify a capability's issuer signature against a public key.

  Returns `:ok` if valid, `{:error, :invalid_capability_signature}` otherwise.
  """
  @spec verify(Capability.t(), binary()) :: :ok | {:error, :invalid_capability_signature}
  def verify(%Capability{issuer_signature: nil}, _public_key) do
    {:error, :invalid_capability_signature}
  end

  def verify(%Capability{} = cap, public_key) when is_binary(public_key) do
    payload = canonical_payload(cap)

    if Crypto.verify(payload, cap.issuer_signature, public_key) do
      :ok
    else
      {:error, :invalid_capability_signature}
    end
  end

  @doc """
  Create a signed delegation record for a capability delegation.

  The delegation record captures who delegated (delegator_id), the constraints
  applied to the delegation, and a signature over the new capability's content
  using the delegator's private key.
  """
  @spec sign_delegation(Capability.t(), Capability.t(), binary()) :: map()
  def sign_delegation(%Capability{} = parent_cap, %Capability{} = new_cap, delegator_private_key)
      when is_binary(delegator_private_key) do
    record = %{
      delegator_id: parent_cap.principal_id,
      delegatee_id: new_cap.principal_id,
      parent_capability_id: parent_cap.id,
      capability_id: new_cap.id,
      payload_digest: delegation_payload_digest(new_cap),
      constraints: new_cap.constraints,
      delegated_at: DateTime.utc_now()
    }

    Map.put(
      record,
      :delegator_signature,
      Crypto.sign(delegation_record_payload(record), delegator_private_key)
    )
  end

  @doc """
  Verify the delegation chain of a capability.

  Each delegation record's signature is verified using the key_lookup_fn, which
  takes a delegator_id and returns `{:ok, public_key}` or `{:error, :not_found}`.

  Returns `:ok` if all delegation records are valid (or chain is empty),
  `{:error, :broken_delegation_chain}` if any record fails verification.
  """
  @spec verify_delegation_chain(Capability.t(), (String.t() -> {:ok, binary()} | {:error, term()})) ::
          :ok | {:error, :broken_delegation_chain}
  # An empty chain is valid only for a root capability. A delegated capability
  # must carry the signed link from its parent; otherwise clearing the chain
  # would turn a delegated token into an unverifiable root-shaped token.
  def verify_delegation_chain(
        %Capability{delegation_chain: [], parent_capability_id: nil},
        _key_lookup_fn
      ),
      do: :ok

  def verify_delegation_chain(%Capability{delegation_chain: []}, _key_lookup_fn),
    do: {:error, :broken_delegation_chain}

  def verify_delegation_chain(%Capability{} = cap, key_lookup_fn)
      when is_function(key_lookup_fn, 1) do
    records = cap.delegation_chain

    with true <- is_list(records) and records != [],
         true <- Enum.all?(records, &verify_delegation_record(&1, key_lookup_fn)),
         true <- valid_chain_links?(records),
         true <- final_record_matches_capability?(List.last(records), cap) do
      :ok
    else
      _ -> {:error, :broken_delegation_chain}
    end
  end

  @doc """
  Compute the canonical signing payload for a capability.

  This is the deterministic binary that gets signed/verified. It delegates
  to `Capability.signing_payload/1` for consistency.
  """
  @spec canonical_payload(Capability.t()) :: binary()
  def canonical_payload(%Capability{} = cap) do
    Capability.signing_payload(cap)
  end

  # Private

  defp delegation_signing_payload(%Capability{} = cap) do
    # Delegation signing happens before SystemAuthority sets issuer_id,
    # so we exclude it to ensure sign/verify see the same payload.
    %{cap | issuer_id: nil}
    |> Capability.signing_payload()
  end

  defp delegation_payload_digest(%Capability{} = cap) do
    cap
    |> delegation_signing_payload()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp delegation_record_payload(record) do
    with {:ok, delegator_id} <- record_field(record, :delegator_id),
         {:ok, delegatee_id} <- record_field(record, :delegatee_id),
         {:ok, parent_capability_id} <- record_field(record, :parent_capability_id),
         {:ok, capability_id} <- record_field(record, :capability_id),
         {:ok, payload_digest} <- record_field(record, :payload_digest),
         {:ok, delegated_at} <- record_field(record, :delegated_at) do
      [
        @delegation_record_version,
        delegator_id,
        delegatee_id,
        parent_capability_id,
        capability_id,
        payload_digest,
        encode_datetime(delegated_at)
      ]
      |> Enum.map_join(&length_prefix/1)
    else
      _ -> :invalid_delegation_record
    end
  end

  defp verify_delegation_record(
         record,
         key_lookup_fn
       ) do
    with {:ok, delegator_id} when is_binary(delegator_id) <-
           record_field(record, :delegator_id),
         {:ok, signature} when is_binary(signature) and byte_size(signature) == 64 <-
           record_field(record, :delegator_signature),
         {:ok, public_key} when is_binary(public_key) <- key_lookup_fn.(delegator_id),
         payload when is_binary(payload) <- delegation_record_payload(record) do
      Crypto.verify(payload, signature, public_key)
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp valid_chain_links?([_record]), do: true

  defp valid_chain_links?([record, next | rest]) do
    with {:ok, delegatee_id} <- record_field(record, :delegatee_id),
         {:ok, capability_id} <- record_field(record, :capability_id),
         {:ok, next_delegator_id} <- record_field(next, :delegator_id),
         {:ok, next_parent_capability_id} <- record_field(next, :parent_capability_id),
         true <- delegatee_id == next_delegator_id,
         true <- capability_id == next_parent_capability_id do
      valid_chain_links?([next | rest])
    else
      _ -> false
    end
  end

  defp valid_chain_links?(_), do: false

  defp final_record_matches_capability?(record, %Capability{} = cap) do
    with {:ok, delegatee_id} <- record_field(record, :delegatee_id),
         {:ok, parent_capability_id} <- record_field(record, :parent_capability_id),
         {:ok, capability_id} <- record_field(record, :capability_id),
         {:ok, payload_digest} <- record_field(record, :payload_digest) do
      delegatee_id == cap.principal_id and
        parent_capability_id == cap.parent_capability_id and
        capability_id == cap.id and
        payload_digest == delegation_payload_digest(cap)
    else
      _ -> false
    end
  end

  defp record_field(record, key) when is_map(record) do
    case Map.fetch(record, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(record, Atom.to_string(key))
    end
  end

  defp record_field(_record, _key), do: :error

  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_datetime(value) when is_binary(value), do: value
  defp encode_datetime(_value), do: :invalid_datetime

  defp length_prefix(value) when is_binary(value), do: <<byte_size(value)::32, value::binary>>
  defp length_prefix(_value), do: <<0::32>>
end
