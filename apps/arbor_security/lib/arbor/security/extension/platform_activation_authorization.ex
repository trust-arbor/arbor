defmodule Arbor.Security.Extension.PlatformActivationAuthorization do
  @moduledoc false

  alias Arbor.Contracts.Extension.Envelope
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Security.Extension.PlatformActivationAuthorizationCore, as: Core
  alias Arbor.Security.ExtensionEnvelopes
  alias Arbor.Security.SigningAuthorityBroker

  @context_keys [
    :audience_host_id,
    :audience_install_id,
    :issued_at,
    :expires_at,
    :nonce
  ]
  @forbidden_keys MapSet.new([
                    :issuer_id,
                    :key_id,
                    :boot_epoch,
                    :boot_profile_sha256,
                    :boot_profile_id,
                    :platform_public_key,
                    :platform_key_id,
                    :profile_id,
                    :transaction_sha256,
                    :signature,
                    :public_key,
                    :private_key,
                    :signer,
                    :authority,
                    :principal_id,
                    :payload,
                    :schema,
                    :version
                  ])

  @spec issue(term(), term(), term()) :: {:ok, map()} | {:error, atom()}
  def issue(authority, transaction, context) do
    with {:ok, authority} <- canonicalize_authority(authority),
         {:ok, context} <- admit_context(context),
         {:ok, snapshot} <- fetch_boot_profile(),
         {:ok, transaction} <- validate_transaction(transaction),
         {:ok, digest} <- digest_transaction(transaction),
         {:ok, built} <-
           Core.build(%{
             snapshot: snapshot,
             transaction: transaction,
             digest: digest,
             context: context,
             authority_principal_id: authority.principal_id,
             authority_purpose: authority.purpose
           }),
         {:ok, signature} <-
           SigningAuthorityBroker.sign_detached(authority, built.signing_message),
         {:ok, signature_hex} <- encode_signature(signature),
         {:ok, envelope} <- Core.attach_signature(built, signature_hex),
         {:ok, verified} <-
           ExtensionEnvelopes.validate_signed(envelope, public_key: built.platform_public_key) do
      {:ok, verified}
    end
  end

  defp canonicalize_authority(authority) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, _reason} -> {:error, :invalid_authority}
    end
  end

  defp admit_context(context) when is_list(context) do
    if Keyword.keyword?(context) do
      admit_context_pairs(context)
    else
      {:error, :invalid_context}
    end
  end

  defp admit_context(context) when is_map(context) and not is_struct(context) do
    admit_context_pairs(Map.to_list(context))
  end

  defp admit_context(_context), do: {:error, :invalid_context}

  defp admit_context_pairs(pairs) do
    keys = Enum.map(pairs, &elem(&1, 0))

    cond do
      Enum.any?(keys, &(not is_atom(&1))) ->
        {:error, :mixed_option_keys}

      length(keys) != length(Enum.uniq(keys)) ->
        {:error, :duplicate_attribute}

      Enum.any?(keys, &MapSet.member?(@forbidden_keys, &1)) ->
        {:error, :forbidden_attribute}

      Enum.any?(keys, &(&1 not in @context_keys)) ->
        {:error, :unknown_attribute}

      Enum.sort(keys) != Enum.sort(@context_keys) ->
        {:error, :invalid_context}

      true ->
        {:ok, Map.new(pairs)}
    end
  end

  defp fetch_boot_profile do
    case Arbor.KernelRuntime.boot_profile() do
      {:ok, snapshot} when is_map(snapshot) -> {:ok, snapshot}
      {:error, :not_bound} -> {:error, :not_bound}
      {:error, _reason} -> {:error, :not_bound}
      _ -> {:error, :not_bound}
    end
  rescue
    _ -> {:error, :not_bound}
  catch
    _, _ -> {:error, :not_bound}
  end

  defp validate_transaction(transaction) do
    case Envelope.validate(:activation_transaction, transaction) do
      {:ok, validated} -> {:ok, validated}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_transaction}
    end
  end

  defp digest_transaction(transaction) do
    case Envelope.digest_of(transaction) do
      {:ok, digest} -> {:ok, digest}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_transaction}
    end
  end

  defp encode_signature(signature) when is_binary(signature) and byte_size(signature) == 64 do
    {:ok, Base.encode16(signature, case: :lower)}
  end

  defp encode_signature(_signature), do: {:error, :signing_failed}
end
