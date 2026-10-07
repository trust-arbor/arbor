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

  - RequestEndorsement: `arbor://agent/identity`
  - SignPublicKey: `arbor://agent/identity`
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

    def taint_roles do
      %{agent_id: :control, target: :control}
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(params, context) do
      %{agent_id: agent_id} = params
      target = params[:target] || "system_authority"

      Actions.emit_started(__MODULE__, %{agent_id: agent_id, target: target})

      case target do
        "system_authority" ->
          request_system_endorsement(agent_id, signing_authority(context))

        peer_id ->
          request_peer_endorsement(agent_id, peer_id)
      end
    end

    defp request_system_endorsement(agent_id, actor_authority) do
      # Look up the agent's full identity from the registry
      with {:ok, public_key} <- Arbor.Security.lookup_public_key(agent_id),
           identity <- build_identity_for_endorsement(agent_id, public_key),
           {:ok, endorsement} <- Arbor.Security.endorse_agent(identity, actor_authority) do
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

    defp signing_authority(context) when is_map(context) do
      Map.get(context, :signing_authority) || Map.get(context, "signing_authority")
    end

    defp signing_authority(_context), do: nil

    defp format_error(:not_found), do: "Agent identity not found in registry"
    defp format_error(reason), do: "Endorsement request failed: #{inspect(reason)}"
  end

  defmodule SignPublicKey do
    @moduledoc """
    Sign another agent's public key to create a web-of-trust link.

    The signing agent uses a caller-owned signing authority. Security binds
    the authority to the asserted signer and signs a canonical, domain-bound
    endorsement without exposing private key material to the action context.

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
          doc: "The signing agent's ID (must match the caller-owned signing authority)"
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
    alias Arbor.Security

    def taint_roles do
      %{signer_id: :control, target_id: :control, note: :data}
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(params, context) do
      %{signer_id: signer_id, target_id: target_id} = params
      note = params[:note] || ""

      Actions.emit_started(__MODULE__, %{signer_id: signer_id, target_id: target_id})

      with :ok <- validate_not_self_signing(signer_id, target_id),
           {:ok, signing_authority} <- require_signing_authority(context, signer_id),
           {:ok, target_public_key} <- Security.lookup_public_key(target_id),
           {:ok, signature} <-
             Security.sign_identity_endorsement(
               signing_authority,
               signer_id,
               target_id,
               target_public_key
             ) do
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

    defp require_signing_authority(context, signer_id) when is_map(context) do
      case Map.get(context, :signing_authority) || Map.get(context, "signing_authority") do
        nil ->
          {:error, :signing_authority_required}

        authority ->
          case Security.signing_authority_principal(authority) do
            {:ok, ^signer_id} -> {:ok, authority}
            {:ok, _other} -> {:error, :signing_authority_principal_mismatch}
            {:error, _reason} -> {:error, :signing_authority_unauthorized}
          end
      end
    end

    defp require_signing_authority(_context, _signer_id),
      do: {:error, :signing_authority_required}

    defp format_error(:cannot_sign_own_key),
      do: "Cannot sign your own public key. Provide a different agent's key to sign."

    defp format_error(:not_found),
      do:
        "Target agent identity not found in the registry. Ensure the target agent has a registered identity."

    defp format_error(:signing_authority_required),
      do: "A caller-owned signing authority is required for key signing operations."

    defp format_error(:signing_authority_principal_mismatch),
      do: "The signing authority principal does not match signer_id."

    defp format_error(:signing_authority_unauthorized),
      do: "The signing authority is invalid, closed, or not owned by this process."

    defp format_error(:identity_endorsement_unauthorized),
      do: "The signing authority is not authorized to endorse this identity."

    defp format_error(reason) when is_binary(reason), do: reason
    defp format_error(reason), do: "Public key signing failed: #{inspect(reason)}"
  end
end
