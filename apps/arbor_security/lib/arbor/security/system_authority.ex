defmodule Arbor.Security.SystemAuthority do
  @moduledoc """
  The system authority is the root of trust for locally-issued capabilities.

  It holds an Ed25519 keypair and signs capabilities on request. Its public
  key is registered in the Identity Registry so that any node can verify
  capability signatures using a standard key lookup.

  ## Design

  - One SystemAuthority per cluster (started by the Application supervisor)
  - **Persistent mode** (default): Keypair is persisted to BufferedStore and
    loaded on startup. All cluster nodes share the same keypair, enabling
    cross-node capability verification without RPC.
  - **Ephemeral mode**: Fresh keypair generated on every startup (legacy
    single-node behavior, useful for testing).
  - Private key lives in GenServer state and (in persistent mode) encrypted
    in the signing keys BufferedStore.
  - Public key is registered in the Identity Registry under a deterministic agent_id.

  ## Configuration

      config :arbor_security,
        system_authority_mode: :persistent   # or :ephemeral
  """

  use GenServer

  require Logger

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.InvocationReceipt
  alias Arbor.Security.Capability.Signer
  alias Arbor.Security.Config
  alias Arbor.Security.Crypto
  alias Arbor.Security.Identity.Registry

  # Runtime bridge — arbor_persistence is Level 1 peer, no compile-time dep
  @buffered_store Arbor.Persistence.BufferedStore
  @key_store_name :arbor_security_signing_keys
  @authority_key "system_authority_keypair"

  # Client API

  @doc """
  Start the system authority.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Sign a capability with the system authority's private key.

  Sets `issuer_id` to the system authority's agent_id and `issuer_signature`
  to the Ed25519 signature over the canonical capability payload.
  """
  @spec sign_capability(Capability.t()) :: {:ok, Capability.t()}
  def sign_capability(%Capability{} = cap) do
    GenServer.call(__MODULE__, {:sign_capability, cap})
  end

  @doc """
  Sign an invocation receipt with the system authority's private key.

  Sets `issuer_id` and `signature` on the receipt.
  """
  @spec sign_receipt(InvocationReceipt.t()) :: {:ok, InvocationReceipt.t()}
  def sign_receipt(%InvocationReceipt{} = receipt) do
    GenServer.call(__MODULE__, {:sign_receipt, receipt})
  end

  @doc """
  Return the system authority's public key.
  """
  @spec public_key() :: binary()
  def public_key do
    GenServer.call(__MODULE__, :public_key)
  end

  @doc """
  Return the system authority's agent_id.
  """
  @spec agent_id() :: String.t()
  def agent_id do
    GenServer.call(__MODULE__, :agent_id)
  end

  @doc """
  Verify a capability's issuer signature.

  For capabilities signed by the system authority, uses the local public key.
  For delegated capabilities, looks up the issuer's public key from the Registry.
  """
  @spec verify_capability_signature(Capability.t()) ::
          :ok | {:error, :invalid_capability_signature}
  def verify_capability_signature(%Capability{} = cap) do
    GenServer.call(__MODULE__, {:verify_capability_signature, cap})
  end

  @doc """
  Endorse an agent's identity by signing their public key.

  Returns an endorsement map that proves the system authority authorized
  this agent to operate in this cluster.
  """
  @spec endorse_agent(Identity.t()) :: {:ok, map()}
  def endorse_agent(%Identity{} = identity) do
    GenServer.call(__MODULE__, {:endorse_agent, identity})
  end

  @doc """
  Verify an agent endorsement signed by the system authority.

  Checks that the endorsement signature is valid for the agent's public key
  and agent_id, signed by the current system authority.
  """
  @spec verify_agent_endorsement(map()) :: :ok | {:error, :invalid_endorsement}
  def verify_agent_endorsement(endorsement) do
    GenServer.call(__MODULE__, {:verify_agent_endorsement, endorsement})
  end

  @doc """
  Rotate the system authority's keypair.

  Generates a new identity, registers it in the Identity Registry, and
  updates the GenServer state. The old keypair is discarded.

  Note: Existing capabilities signed with the old key will fail verification
  after rotation. Plan rotation during maintenance windows.
  """
  @spec rotate() :: {:ok, %{old_agent_id: String.t(), new_agent_id: String.t()}}
  def rotate do
    GenServer.call(__MODULE__, :rotate)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    case Config.system_authority_mode() do
      :persistent ->
        init_persistent()

      :ephemeral ->
        init_ephemeral()
    end
  end

  defp init_persistent do
    case load_persisted_keypair() do
      {:ok, identity} ->
        Logger.info("[SystemAuthority] Loaded persistent keypair: #{identity.agent_id}")
        :ok = Registry.register(Identity.public_only(identity))
        {:ok, %{identity: identity}}

      :not_found ->
        # First boot — generate and persist
        case Identity.generate() do
          {:ok, identity} ->
            persist_keypair(identity)
            Logger.info("[SystemAuthority] Generated new persistent keypair: #{identity.agent_id}")
            :ok = Registry.register(Identity.public_only(identity))
            {:ok, %{identity: identity}}

          {:error, reason} ->
            {:stop, {:failed_to_generate_identity, reason}}
        end

      {:error, reason} ->
        Logger.warning(
          "[SystemAuthority] Failed to load persisted keypair: #{inspect(reason)}, generating new"
        )

        case Identity.generate() do
          {:ok, identity} ->
            persist_keypair(identity)
            :ok = Registry.register(Identity.public_only(identity))
            {:ok, %{identity: identity}}

          {:error, gen_reason} ->
            {:stop, {:failed_to_generate_identity, gen_reason}}
        end
    end
  end

  defp init_ephemeral do
    case Identity.generate() do
      {:ok, identity} ->
        :ok = Registry.register(Identity.public_only(identity))
        {:ok, %{identity: identity}}

      {:error, reason} ->
        {:stop, {:failed_to_generate_identity, reason}}
    end
  end

  @impl true
  def handle_call({:sign_capability, cap}, _from, %{identity: identity} = state) do
    signed_cap =
      cap
      |> Map.put(:issuer_id, identity.agent_id)
      |> Signer.sign(identity.private_key)

    {:reply, {:ok, signed_cap}, state}
  end

  @impl true
  def handle_call({:sign_receipt, receipt}, _from, %{identity: identity} = state) do
    payload = InvocationReceipt.signing_payload(receipt)
    signature = Crypto.sign(payload, identity.private_key)

    signed_receipt =
      receipt
      |> Map.put(:issuer_id, identity.agent_id)
      |> Map.put(:signature, signature)

    {:reply, {:ok, signed_receipt}, state}
  end

  @impl true
  def handle_call(:public_key, _from, %{identity: identity} = state) do
    {:reply, identity.public_key, state}
  end

  @impl true
  def handle_call(:agent_id, _from, %{identity: identity} = state) do
    {:reply, identity.agent_id, state}
  end

  @impl true
  def handle_call({:verify_capability_signature, cap}, _from, %{identity: identity} = state) do
    result =
      if cap.issuer_id == identity.agent_id do
        # Signed by this system authority — use local key
        Signer.verify(cap, identity.public_key)
      else
        # Signed by another entity — look up their key
        case Registry.lookup(cap.issuer_id) do
          {:ok, public_key} -> Signer.verify(cap, public_key)
          {:error, :not_found} -> {:error, :invalid_capability_signature}
        end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:endorse_agent, agent_identity}, _from, %{identity: authority} = state) do
    payload = endorsement_payload(agent_identity.public_key, agent_identity.agent_id)
    signature = Crypto.sign(payload, authority.private_key)

    endorsement = %{
      agent_id: agent_identity.agent_id,
      agent_public_key: agent_identity.public_key,
      authority_id: authority.agent_id,
      authority_signature: signature,
      endorsed_at: DateTime.utc_now()
    }

    {:reply, {:ok, endorsement}, state}
  end

  @impl true
  def handle_call({:verify_agent_endorsement, endorsement}, _from, %{identity: authority} = state) do
    payload = endorsement_payload(endorsement.agent_public_key, endorsement.agent_id)
    valid? = Crypto.verify(payload, endorsement.authority_signature, authority.public_key)

    result = if valid?, do: :ok, else: {:error, :invalid_endorsement}
    {:reply, result, state}
  end

  @impl true
  def handle_call(:rotate, _from, %{identity: old_identity} = state) do
    case Identity.generate() do
      {:ok, new_identity} ->
        :ok = Registry.register(Identity.public_only(new_identity))

        # Persist the new keypair if in persistent mode
        if Config.system_authority_mode() == :persistent do
          persist_keypair(new_identity)
        end

        result = %{
          old_agent_id: old_identity.agent_id,
          new_agent_id: new_identity.agent_id
        }

        {:reply, {:ok, result}, %{state | identity: new_identity}}

      {:error, reason} ->
        {:reply, {:error, {:rotation_failed, reason}}, state}
    end
  end

  # Length-prefixed endorsement payload to prevent field-boundary ambiguity.
  defp endorsement_payload(public_key, agent_id) do
    <<byte_size(public_key)::32, public_key::binary,
      byte_size(agent_id)::32, agent_id::binary>>
  end

  # ===========================================================================
  # Persistent Keypair Storage
  # ===========================================================================

  defp load_persisted_keypair do
    if Process.whereis(@key_store_name) do
      case apply(@buffered_store, :get, [@authority_key, [name: @key_store_name]]) do
        {:ok, %Record{data: data}} ->
          deserialize_keypair(data)

        {:error, :not_found} ->
          :not_found

        {:error, reason} ->
          {:error, reason}
      end
    else
      :not_found
    end
  catch
    _, reason ->
      {:error, {:store_unavailable, reason}}
  end

  defp persist_keypair(identity) do
    if Process.whereis(@key_store_name) do
      data = serialize_keypair(identity)
      record = Record.new(@authority_key, data)
      apply(@buffered_store, :put, [@authority_key, record, [name: @key_store_name]])
    end

    :ok
  catch
    _, reason ->
      Logger.warning("[SystemAuthority] Failed to persist keypair: #{inspect(reason)}")
      :ok
  end

  defp serialize_keypair(identity) do
    %{
      "agent_id" => identity.agent_id,
      "public_key" => Base.encode64(identity.public_key),
      "private_key" => Base.encode64(identity.private_key),
      "name" => identity.name,
      "created_at" => DateTime.to_iso8601(identity.created_at)
    }
  end

  defp deserialize_keypair(data) when is_map(data) do
    with {:ok, public_key} <- Base.decode64(data["public_key"]),
         {:ok, private_key} <- Base.decode64(data["private_key"]),
         {:ok, created_at, _} <- DateTime.from_iso8601(data["created_at"] || "2026-01-01T00:00:00Z") do
      Identity.new(
        public_key: public_key,
        private_key: private_key,
        name: data["name"],
        created_at: created_at
      )
    else
      _ -> {:error, :invalid_persisted_format}
    end
  end

  defp deserialize_keypair(_), do: {:error, :invalid_persisted_format}
end
