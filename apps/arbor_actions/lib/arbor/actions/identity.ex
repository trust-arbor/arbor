defmodule Arbor.Actions.Identity do
  @moduledoc """
  Cryptographic identity operations as Jido actions.

  Provides actions for requesting endorsements (from system authority or
  peer agents) and signing other agents' public keys to build a web of trust.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `RequestEndorsement` | Request endorsement from the system authority or a peer agent |
  | `SignPublicKey` | Sign another agent's public key, creating a web-of-trust link |

  ## Web of Trust

  Beyond the system authority's centralized endorsement, agents can build a
  decentralized web of trust by signing each other's public keys. A peer
  signature says "I, agent_X, vouch for agent_Y's public key." The more
  signatures an identity accumulates, the stronger its trust chain.

  ## Authorization

  - RequestEndorsement: `arbor://actions/execute/identity.request_endorsement`
  - SignPublicKey: `arbor://actions/execute/identity.sign_public_key`
  """

  defmodule RequestEndorsement do
    @moduledoc """
    Request endorsement of this agent's identity.

    When `target` is "system_authority" (default), requests the system authority
    to sign this agent's public key — producing an endorsement certificate that
    proves the agent is authorized to operate in this cluster.

    When `target` is another agent_id, sends an endorsement request to that
    peer agent. The peer may sign or refuse based on its own trust policies.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `agent_id` | string | yes | The requesting agent's ID |
    | `target` | string | no | Who to request from: "system_authority" or a peer agent_id (default: "system_authority") |

    ## Returns

    - `endorsement` - The endorsement map (for system authority)
    - `status` - "endorsed" or "requested" (for peer requests)
    """

    use Jido.Action,
      name: "identity_request_endorsement",
      description:
        "Request endorsement of this agent's identity from the system authority or a peer agent",
      category: "identity",
      tags: ["identity", "endorsement", "trust", "security"],
      schema: [
        agent_id: [
          type: :string,
          required: true,
          doc: "The requesting agent's ID (must have a registered identity)"
        ],
        target: [
          type: :string,
          default: "system_authority",
          doc: "Who to request endorsement from: \"system_authority\" or a peer agent_id"
        ]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(params, _context) do
      %{agent_id: agent_id} = params
      target = params[:target] || "system_authority"

      Actions.emit_started(__MODULE__, %{agent_id: agent_id, target: target})

      case target do
        "system_authority" ->
          request_system_endorsement(agent_id)

        peer_id ->
          request_peer_endorsement(agent_id, peer_id)
      end
    end

    defp request_system_endorsement(agent_id) do
      # Look up the agent's full identity from the registry
      with {:ok, public_key} <- Arbor.Security.lookup_public_key(agent_id),
           identity <- build_identity_for_endorsement(agent_id, public_key),
           {:ok, endorsement} <- Arbor.Security.endorse_agent(identity) do
        result = %{
          endorsement: endorsement,
          status: "endorsed",
          endorsed_by: "system_authority",
          agent_id: agent_id
        }

        Actions.emit_completed(__MODULE__, %{agent_id: agent_id, status: "endorsed"})
        {:ok, result}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, format_error(reason)}
      end
    end

    defp request_peer_endorsement(agent_id, peer_id) do
      # Verify both agents exist in the registry
      with {:ok, _requester_key} <- Arbor.Security.lookup_public_key(agent_id),
           {:ok, _peer_key} <- Arbor.Security.lookup_public_key(peer_id) do
        # Emit a signal that the peer can listen for and respond to
        Arbor.Signals.emit(:identity, :endorsement_requested, %{
          requester_id: agent_id,
          target_id: peer_id,
          requested_at: DateTime.utc_now()
        })

        result = %{
          status: "requested",
          requester_id: agent_id,
          target_id: peer_id,
          message: "Endorsement request sent to #{peer_id}. Awaiting response."
        }

        Actions.emit_completed(__MODULE__, %{agent_id: agent_id, status: "requested"})
        {:ok, result}
      else
        {:error, :not_found} ->
          Actions.emit_failed(__MODULE__, :identity_not_found)
          {:error, "One or both agent identities not found in the registry"}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, format_error(reason)}
      end
    end

    defp build_identity_for_endorsement(agent_id, public_key) do
      # Build a minimal Identity struct for the endorsement call
      %Arbor.Contracts.Security.Identity{
        agent_id: agent_id,
        public_key: public_key,
        created_at: DateTime.utc_now()
      }
    end

    defp format_error(:not_found), do: "Agent identity not found in registry"
    defp format_error(reason), do: "Endorsement request failed: #{inspect(reason)}"
  end

  defmodule SignPublicKey do
    @moduledoc """
    Sign another agent's public key to create a web-of-trust link.

    The signing agent uses its own Ed25519 private key (from its keychain)
    to sign the target agent's `public_key <> agent_id`, producing a peer
    signature. This creates a verifiable assertion: "I, agent_X, vouch for
    agent_Y's identity."

    The target agent accumulates these peer signatures as trust evidence.
    More signatures from trusted agents = stronger identity assurance.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `signer_id` | string | yes | The signing agent's ID (must have a keychain) |
    | `target_id` | string | yes | The agent whose public key is being signed |
    | `note` | string | no | Optional note explaining why this key is being signed |

    ## Returns

    - `signature` - The peer signature (hex-encoded)
    - `signer_id` - Who signed
    - `target_id` - Whose key was signed
    - `signed_at` - When the signature was created
    """

    use Jido.Action,
      name: "identity_sign_public_key",
      description: "Sign another agent's public key to create a web-of-trust link",
      category: "identity",
      tags: ["identity", "trust", "web-of-trust", "signature", "security"],
      schema: [
        signer_id: [
          type: :string,
          required: true,
          doc: "The signing agent's ID (must have a keychain with signing keys)"
        ],
        target_id: [
          type: :string,
          required: true,
          doc: "The target agent whose public key will be signed"
        ],
        note: [
          type: :string,
          default: "",
          doc: "Optional note explaining the reason for signing"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Security.Crypto

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(params, context) do
      %{signer_id: signer_id, target_id: target_id} = params
      note = params[:note] || ""

      Actions.emit_started(__MODULE__, %{signer_id: signer_id, target_id: target_id})

      # Get the signer's private key from context (injected by the execution environment)
      # The agent's keychain holds its signing keypair
      signer_private_key = Map.get(context, :signer_private_key)

      with :ok <- validate_not_self_signing(signer_id, target_id),
           {:ok, target_public_key} <- Arbor.Security.lookup_public_key(target_id),
           {:ok, private_key} <- resolve_signing_key(signer_id, signer_private_key) do
        # Sign: target_public_key <> target_agent_id (same format as system authority)
        payload = target_public_key <> target_id
        signature = Crypto.sign(payload, private_key)

        peer_signature = %{
          signer_id: signer_id,
          target_id: target_id,
          target_public_key: target_public_key,
          signature: signature,
          note: note,
          signed_at: DateTime.utc_now()
        }

        # Emit signal so the target agent and observers can record this
        Arbor.Signals.emit(:identity, :public_key_signed, %{
          signer_id: signer_id,
          target_id: target_id,
          note: note,
          signed_at: peer_signature.signed_at
        })

        result = %{
          signature: Base.encode16(signature, case: :lower),
          signer_id: signer_id,
          target_id: target_id,
          note: note,
          signed_at: peer_signature.signed_at
        }

        Actions.emit_completed(__MODULE__, %{signer_id: signer_id, target_id: target_id})
        {:ok, result}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, format_error(reason)}
      end
    end

    defp validate_not_self_signing(id, id), do: {:error, :cannot_sign_own_key}
    defp validate_not_self_signing(_signer, _target), do: :ok

    defp resolve_signing_key(_signer_id, key) when is_binary(key) and byte_size(key) > 0 do
      {:ok, key}
    end

    defp resolve_signing_key(signer_id, _nil_or_empty) do
      # Try to get the signing key from the signer's keychain
      case Arbor.Security.lookup_public_key(signer_id) do
        {:ok, _} ->
          # We can verify the signer exists, but we need the private key
          # from the execution context. The keychain holds it but we can't
          # extract it through the public API for safety.
          {:error, :signer_private_key_required}

        {:error, :not_found} ->
          {:error, :signer_not_found}
      end
    end

    defp format_error(:cannot_sign_own_key), do: "Cannot sign your own public key"
    defp format_error(:signer_not_found), do: "Signer identity not found in registry"
    defp format_error(:not_found), do: "Target identity not found in registry"

    defp format_error(:signer_private_key_required),
      do: "Signer's private key must be provided in execution context (:signer_private_key)"

    defp format_error(reason), do: "Public key signing failed: #{inspect(reason)}"
  end
end
