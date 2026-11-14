defmodule Arbor.Security.LocalHumanRegistration do
  @moduledoc false
  # Registration of a local human whose private key the caller holds.
  #
  # `mix arbor.user.init` generates the operator's Ed25519 keypair in its own
  # process and keeps the private key in its key file. Only the public key and
  # a `SignedRequest` over `request_payload/2` reach the server; the server
  # never holds the private key (security review F-002).
  #
  # The proof binds, in the signed payload: a version tag, the fixed
  # registration resource (the purpose), the principal and the public key
  # being registered. The `SignedRequest` envelope adds the principal again,
  # a timestamp and a single-use nonce. So a proof cannot register another
  # key, serve another purpose, or be replayed.

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.Identity.Verifier

  @request_version "arbor-local-human-registration-request-v1"
  @request_resource "arbor://security/identity/local_human/register"
  @unauthorized {:error, :local_human_registration_unauthorized}

  @doc false
  # Exact bytes the operator signs. Pure; usable offline in a CLI process.
  @spec request_payload(String.t(), binary()) ::
          {:ok, binary()} | {:error, :local_human_registration_unauthorized}
  def request_payload("human_" <> rest = principal_id, public_key)
      when rest != "" and is_binary(public_key) and byte_size(public_key) == 32 do
    {:ok,
     Enum.map_join(
       [@request_version, @request_resource, principal_id, public_key],
       &length_prefix/1
     )}
  end

  def request_payload(_principal_id, _public_key), do: @unauthorized

  @doc false
  # Ed25519 public key of key-file signing material: a 32-byte seed, or a
  # 64-byte seed followed by its public key (which must agree).
  @spec public_key(binary()) :: {:ok, binary()} | {:error, :invalid_key_file_signing_material}
  def public_key(<<seed::binary-size(32)>>), do: derive_public_key(seed)

  def public_key(<<seed::binary-size(32), embedded::binary-size(32)>>) do
    case derive_public_key(seed) do
      {:ok, ^embedded} -> {:ok, embedded}
      _ -> {:error, :invalid_key_file_signing_material}
    end
  end

  def public_key(_private_key), do: {:error, :invalid_key_file_signing_material}

  @doc false
  # Server side. Every refusal is the same error, like local genesis, so the
  # response is not an oracle for which check failed. The proof's nonce is
  # consumed only after its signature verifies.
  @spec verify(String.t(), binary(), term()) ::
          :ok | {:error, :local_human_registration_unauthorized}
  def verify(principal_id, public_key, proof) do
    with {:ok, canonical} <- SignedRequest.canonicalize(proof),
         true <- canonical.agent_id == principal_id,
         {:ok, expected} <- request_payload(principal_id, public_key),
         true <- canonical.payload == expected,
         {:ok, ^principal_id} <- Verifier.verify_with_public_key(canonical, public_key) do
      :ok
    else
      _ -> @unauthorized
    end
  end

  @doc false
  # Register the verified public identity. Re-registering the same key is
  # idempotent (`:existing`); a different key for a registered principal is
  # refused, never replaced.
  @spec register(Identity.t()) ::
          {:ok, Identity.t(), :created | :existing} | {:error, term()}
  def register(%Identity{private_key: nil, encryption_private_key: nil} = identity) do
    case Registry.register_local_human(identity) do
      :ok -> {:ok, identity, :created}
      {:error, {:already_registered, _id}} -> match_registered(identity)
      {:error, _reason} = error -> error
    end
  catch
    :exit, _ -> {:error, :registry_unavailable}
  end

  def register(_identity), do: {:error, :invalid_identity}

  @doc false
  # The registered signing key for `principal_id`, or nil when unregistered.
  @spec registered_public_key(String.t()) :: {:ok, binary() | nil} | {:error, term()}
  def registered_public_key(principal_id) do
    case Registry.lookup(principal_id) do
      {:ok, public_key} -> {:ok, public_key}
      {:error, :not_found} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  catch
    :exit, _ -> {:error, :registry_unavailable}
  end

  defp match_registered(%Identity{agent_id: principal_id, public_key: public_key} = identity) do
    case registered_public_key(principal_id) do
      {:ok, ^public_key} -> {:ok, identity, :existing}
      {:ok, _other} -> {:error, :local_human_key_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp derive_public_key(seed) do
    {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519, seed)
    {:ok, public_key}
  rescue
    _ -> {:error, :invalid_key_file_signing_material}
  end

  defp length_prefix(value), do: <<byte_size(value)::unsigned-big-32, value::binary>>
end
