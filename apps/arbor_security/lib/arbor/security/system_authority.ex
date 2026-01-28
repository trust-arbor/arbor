defmodule Arbor.Security.SystemAuthority do
  @moduledoc """
  The system authority is the root of trust for locally-issued capabilities.

  It holds an Ed25519 keypair generated on first boot and signs capabilities
  on request. Its public key is registered in the Identity Registry so that
  any node can verify capability signatures using a standard key lookup.

  ## Design

  - One SystemAuthority per cluster (started by the Application supervisor)
  - Keypair is generated fresh on startup (ephemeral per cluster lifecycle)
  - Private key lives only in GenServer state — never serialized or stored
  - Public key is registered in the Identity Registry under a deterministic agent_id
  """

  use GenServer

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.Capability.Signer
  alias Arbor.Security.Identity.Registry

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

  # Server callbacks

  @impl true
  def init(_opts) do
    case Identity.generate() do
      {:ok, identity} ->
        # Register the public identity so other modules can look up the key
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
end
