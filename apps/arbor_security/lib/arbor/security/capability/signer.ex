defmodule Arbor.Security.Capability.Signer do
  @moduledoc """
  Pure functions for capability signing and verification.

  No state, no GenServer dependencies. Uses Ed25519 via `Arbor.Security.Crypto`
  for all cryptographic operations. The signing payload is computed deterministically
  from the capability's content fields (excluding signature fields).
  """

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.Crypto

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
    payload = delegation_signing_payload(new_cap)
    signature = Crypto.sign(payload, delegator_private_key)

    %{
      delegator_id: parent_cap.principal_id,
      delegator_signature: signature,
      constraints: new_cap.constraints,
      delegated_at: DateTime.utc_now()
    }
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
  def verify_delegation_chain(%Capability{delegation_chain: []}, _key_lookup_fn), do: :ok

  def verify_delegation_chain(%Capability{} = cap, key_lookup_fn)
      when is_function(key_lookup_fn, 1) do
    cap.delegation_chain
    |> Enum.all?(fn record ->
      verify_delegation_record(record, cap, key_lookup_fn)
    end)
    |> case do
      true -> :ok
      false -> {:error, :broken_delegation_chain}
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
    # Sign over the new capability's core content
    Capability.signing_payload(cap)
  end

  defp verify_delegation_record(
         %{delegator_id: delegator_id, delegator_signature: signature},
         cap,
         key_lookup_fn
       ) do
    case key_lookup_fn.(delegator_id) do
      {:ok, public_key} ->
        payload = delegation_signing_payload(cap)
        Crypto.verify(payload, signature, public_key)

      {:error, _} ->
        false
    end
  end

  defp verify_delegation_record(_, _cap, _key_lookup_fn), do: false
end
