defmodule Arbor.Contracts.API.Identity do
  @moduledoc """
  Public API contract for cryptographic agent identity management.

  Defines the facade interface for identity lifecycle: keypair generation,
  registration, public key lookup, and signed request verification.

  Identity is separate from Security (capabilities) and Trust (scoring/tiers).
  Security checks capabilities, Trust manages reputation — Identity provides
  the cryptographic foundation that binds agents to their keys.

  ## Quick Start

      # Generate and register an identity
      {:ok, identity} = Arbor.Security.generate_identity()
      :ok = Arbor.Security.register_identity(identity)

      # Look up a public key
      {:ok, public_key} = Arbor.Security.lookup_public_key(agent_id)

      # Verify a signed request
      {:ok, agent_id} = Arbor.Security.verify_request(signed_request)
  """

  alias Arbor.Types

  @type verification_error ::
          :unknown_agent
          | :invalid_signature
          | :expired_timestamp
          | :replayed_nonce
          | :malformed_request

  # ===========================================================================
  # Identity Lifecycle
  # ===========================================================================

  @doc """
  Generate a new cryptographic identity keypair.

  Creates an Ed25519 keypair and derives the agent ID from the public key hash.
  """
  @callback generate_cryptographic_identity_keypair(opts :: keyword()) ::
              {:ok, Arbor.Contracts.Security.Identity.t()} | {:error, term()}

  @doc """
  Register an agent identity with its public key.

  Stores the public key in the identity registry for later lookup and verification.
  The private key is stripped before storage.
  """
  @callback register_agent_identity_with_public_key(Arbor.Contracts.Security.Identity.t()) ::
              :ok | {:error, term()}

  @doc """
  Look up the public key for a registered agent.
  """
  @callback lookup_public_key_for_agent(Types.agent_id()) ::
              {:ok, Types.public_key()} | {:error, :not_found}

  @doc """
  Verify the authenticity of a signed request.

  Checks timestamp freshness, signature validity, and nonce uniqueness.
  Returns the verified agent ID on success.
  """
  @callback verify_signed_request_authenticity(Arbor.Contracts.Security.SignedRequest.t()) ::
              {:ok, Types.agent_id()} | {:error, verification_error()}
end
