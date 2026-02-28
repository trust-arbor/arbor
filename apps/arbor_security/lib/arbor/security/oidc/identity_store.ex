defmodule Arbor.Security.OIDC.IdentityStore do
  @moduledoc """
  Manages persistent human keypairs bound to OIDC claims.

  When a human authenticates via OIDC, this module either loads their existing
  Ed25519+X25519 keypair or creates a new one. The keypair is stored encrypted
  via `SigningKeyStore` and bound to the OIDC `iss:sub` pair through a
  deterministic agent ID derivation.

  ## Agent ID Format

      "human_" <> hex(sha256(iss <> ":" <> sub))  (first 40 hex chars)

  This ensures the same OIDC identity always maps to the same agent ID and
  keypair, regardless of which device or session is used.
  """

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.Crypto
  alias Arbor.Security.SigningKeyStore

  require Logger

  @doc """
  Derive a deterministic agent ID from OIDC claims.

  ## Examples

      iex> IdentityStore.derive_agent_id(%{iss: "https://accounts.google.com", sub: "12345"})
      "human_" <> _hex
  """
  @spec derive_agent_id(map()) :: String.t()
  def derive_agent_id(%{iss: iss, sub: sub}) do
    hash = :crypto.hash(:sha256, "#{iss}:#{sub}")
    "human_" <> String.slice(Base.encode16(hash, case: :lower), 0, 40)
  end

  def derive_agent_id(%{"iss" => iss, "sub" => sub}) do
    derive_agent_id(%{iss: iss, sub: sub})
  end

  @doc """
  Load an existing identity or create a new one for the given OIDC claims.

  Claims must include `iss` and `sub`. Optional: `email`, `name`.

  Returns:
  - `{:ok, identity, :existing}` — loaded existing keypair
  - `{:ok, identity, :created}` — generated new keypair
  - `{:error, reason}` — failure
  """
  @spec load_or_create(map()) :: {:ok, Identity.t(), :existing | :created} | {:error, term()}
  def load_or_create(claims) do
    agent_id = derive_agent_id(claims)

    case SigningKeyStore.get_keypair(agent_id) do
      {:ok, keypair} ->
        load_existing(agent_id, keypair, claims)

      {:error, :no_signing_key} ->
        create_new(agent_id, claims)

      {:error, :store_unavailable} ->
        create_new(agent_id, claims)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private ---

  defp load_existing(agent_id, keypair, claims) do
    # Derive public key from the private signing key
    {public_key, _} = :crypto.generate_key(:eddsa, :ed25519, keypair.signing)

    identity_opts = [
      public_key: public_key,
      private_key: keypair.signing,
      name: extract_name(claims),
      metadata: build_metadata(claims)
    ]

    identity_opts =
      case Map.get(keypair, :encryption) do
        nil ->
          identity_opts

        enc_private ->
          {enc_public, _} = :crypto.generate_key(:ecdh, :x25519, enc_private)

          Keyword.merge(identity_opts,
            encryption_public_key: enc_public,
            encryption_private_key: enc_private
          )
      end

    # The Identity struct derives agent_id from public_key as "agent_<hash>",
    # but we need "human_<hash>". Build the struct manually.
    case Identity.new(identity_opts) do
      {:ok, identity} ->
        # Override the auto-derived agent_id with our human_ prefixed one
        {:ok, %{identity | agent_id: agent_id}, :existing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_new(agent_id, claims) do
    {pub, priv} = Crypto.generate_keypair()
    {enc_pub, enc_priv} = Crypto.generate_encryption_keypair()

    # Store encrypted keypair
    case SigningKeyStore.put_keypair(agent_id, priv, enc_priv) do
      :ok ->
        case Identity.new(
               public_key: pub,
               private_key: priv,
               encryption_public_key: enc_pub,
               encryption_private_key: enc_priv,
               name: extract_name(claims),
               metadata: build_metadata(claims)
             ) do
          {:ok, identity} ->
            {:ok, %{identity | agent_id: agent_id}, :created}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_name(claims) do
    Map.get(claims, :name) || Map.get(claims, "name") ||
      Map.get(claims, :email) || Map.get(claims, "email")
  end

  defp build_metadata(claims) do
    %{
      "oidc_issuer" => Map.get(claims, :iss) || Map.get(claims, "iss"),
      "oidc_sub" => Map.get(claims, :sub) || Map.get(claims, "sub"),
      "oidc_email" => Map.get(claims, :email) || Map.get(claims, "email"),
      "identity_type" => "human"
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
