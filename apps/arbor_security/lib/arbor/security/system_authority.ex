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
  alias Arbor.Security.SigningKeyStore

  # Runtime bridge — arbor_persistence is Level 1 peer, no compile-time dep
  @buffered_store Arbor.Persistence.BufferedStore
  @key_store_name :arbor_security_signing_keys

  # The authority's *private* keypair is held in SigningKeyStore under this
  # logical agent_id (AES-GCM encrypted at rest). The corresponding public
  # metadata (public keys, agent_id, name, created_at) is held under
  # @authority_metadata_key in the same BufferedStore — public material is
  # not encrypted because it's not a secret.
  @authority_signing_id "system_authority"
  @authority_metadata_key "system_authority_metadata_v2"

  # P0-5: pre-v2 layout stored the private key as plaintext base64 under this
  # key. We never read it again; on first boot after upgrade we delete it so
  # the secret stops sitting on disk.
  @legacy_plaintext_key "system_authority_keypair"

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
  Verify that a capability was signed by the current system authority.

  The issuer check and signature verification happen in one authority call so
  a concurrent authority rotation cannot admit a capability from the previous
  authority.
  """
  @spec verify_authority_capability_signature(Capability.t()) ::
          :ok | {:error, :invalid_capability_signature}
  def verify_authority_capability_signature(%Capability{} = cap) do
    GenServer.call(__MODULE__, {:verify_authority_capability_signature, cap})
  end

  @doc """
  Verify a batch of capability signatures in one authority call.

  Returns the ids whose signatures are valid. Issuer keys are resolved once
  per distinct issuer, preventing authorization candidate scans from making
  one cross-GenServer call per capability.
  """
  @spec verify_capability_signatures([Capability.t()]) ::
          {:ok, [String.t()]} | {:error, :invalid_capabilities}
  def verify_capability_signatures(caps) when is_list(caps) do
    if Enum.all?(caps, &match?(%Capability{}, &1)) do
      GenServer.call(__MODULE__, {:verify_capability_signatures, caps})
    else
      {:error, :invalid_capabilities}
    end
  end

  def verify_capability_signatures(_caps), do: {:error, :invalid_capabilities}

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
    # P0-5: any pre-v2 plaintext keypair record is orphan data — delete it
    # before doing anything else so the plaintext private key stops sitting
    # on disk. Idempotent: no-op if the legacy record never existed.
    cleanup_legacy_plaintext_record()

    case load_persisted_keypair() do
      {:ok, identity} ->
        Logger.info("[SystemAuthority] Loaded persistent keypair: #{identity.agent_id}")

        case Registry.register(Identity.public_only(identity)) do
          :ok -> :ok
          {:error, {:already_registered, _}} -> :ok
        end

        {:ok, %{identity: identity}}

      :not_found ->
        # First boot — generate and persist
        case Identity.generate() do
          {:ok, identity} ->
            :ok = persist_keypair(identity)

            Logger.info(
              "[SystemAuthority] Generated new persistent keypair: #{identity.agent_id}"
            )

            :ok = Registry.register(Identity.public_only(identity))
            {:ok, %{identity: identity}}

          {:error, reason} ->
            {:stop, {:failed_to_generate_identity, reason}}
        end

      {:error, reason} ->
        # P0-5: load failure is fatal. Silently rotating the trust root on a
        # transient persistence/decode error would invalidate every signed
        # capability, receipt, and endorsement in the cluster without any
        # operator awareness. Stop and require explicit recovery instead.
        Logger.error(
          "[SystemAuthority] Failed to load persisted keypair: #{inspect(reason)}. " <>
            "Refusing to silently rotate the trust root. Investigate the persistence " <>
            "backend or call SystemAuthority.rotate/0 explicitly to mint a new authority key."
        )

        {:stop, {:authority_load_failed, reason}}
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
    # Set issuer_id BEFORE computing the payload so it is covered by the
    # signature (issuer_id is part of signing_payload as of the 2026-06-09 fix).
    receipt = Map.put(receipt, :issuer_id, identity.agent_id)
    payload = InvocationReceipt.signing_payload(receipt)
    signature = Crypto.sign(payload, identity.private_key)

    {:reply, {:ok, Map.put(receipt, :signature, signature)}, state}
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
    {:reply, verify_capability_signature_safe(cap, identity), state}
  end

  @impl true
  def handle_call(
        {:verify_authority_capability_signature, cap},
        _from,
        %{identity: identity} = state
      ) do
    {:reply, verify_authority_capability_signature_safe(cap, identity), state}
  end

  @impl true
  def handle_call(
        {:verify_capability_signatures, caps},
        _from,
        %{identity: identity} = state
      ) do
    {:reply, {:ok, verify_capability_signatures_safe(caps, identity)}, state}
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

  defp verify_capability_signature_safe(cap, identity) do
    with true <- valid_capability_signature_shape?(cap),
         {:ok, public_key} <- issuer_public_key(cap.issuer_id, identity),
         :ok <- Signer.verify(cap, public_key) do
      :ok
    else
      _ -> {:error, :invalid_capability_signature}
    end
  rescue
    _ -> {:error, :invalid_capability_signature}
  catch
    _, _ -> {:error, :invalid_capability_signature}
  end

  defp verify_authority_capability_signature_safe(cap, identity) do
    with true <- valid_capability_signature_shape?(cap),
         true <- cap.issuer_id == identity.agent_id,
         :ok <- Signer.verify(cap, identity.public_key) do
      :ok
    else
      _ -> {:error, :invalid_capability_signature}
    end
  rescue
    _ -> {:error, :invalid_capability_signature}
  catch
    _, _ -> {:error, :invalid_capability_signature}
  end

  defp verify_capability_signatures_safe(caps, identity) do
    {valid_ids, _key_cache} =
      Enum.reduce(caps, {[], %{}}, fn cap, accumulator ->
        verify_capability_with_cache(cap, accumulator, identity)
      end)

    Enum.reverse(valid_ids)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp verify_capability_with_cache(cap, {valid_ids, key_cache}, identity) do
    if valid_capability_signature_shape?(cap) do
      {key_result, updated_cache} = cached_issuer_public_key(cap.issuer_id, identity, key_cache)
      maybe_collect_verified_id(key_result, cap, valid_ids, updated_cache)
    else
      {valid_ids, key_cache}
    end
  end

  defp maybe_collect_verified_id({:ok, public_key}, cap, valid_ids, cache) do
    if safe_signer_verify(cap, public_key) == :ok,
      do: {[cap.id | valid_ids], cache},
      else: {valid_ids, cache}
  end

  defp maybe_collect_verified_id({:error, _reason}, _cap, valid_ids, cache),
    do: {valid_ids, cache}

  defp valid_capability_signature_shape?(%Capability{
         issuer_id: issuer_id,
         issuer_signature: signature
       }) do
    is_binary(issuer_id) and is_binary(signature) and byte_size(signature) == 64
  end

  defp issuer_public_key(issuer_id, %{agent_id: issuer_id, public_key: public_key}),
    do: {:ok, public_key}

  defp issuer_public_key(issuer_id, _identity) when is_binary(issuer_id),
    do: Registry.lookup(issuer_id)

  defp issuer_public_key(_issuer_id, _identity), do: {:error, :not_found}

  defp cached_issuer_public_key(
         issuer_id,
         %{agent_id: issuer_id, public_key: public_key},
         cache
       ),
       do: {{:ok, public_key}, cache}

  defp cached_issuer_public_key(issuer_id, identity, cache) do
    case Map.fetch(cache, issuer_id) do
      {:ok, result} ->
        {result, cache}

      :error ->
        result = issuer_public_key(issuer_id, identity)
        {result, Map.put(cache, issuer_id, result)}
    end
  end

  defp safe_signer_verify(cap, public_key) do
    Signer.verify(cap, public_key)
  rescue
    _ -> {:error, :invalid_capability_signature}
  catch
    _, _ -> {:error, :invalid_capability_signature}
  end

  # Length-prefixed endorsement payload to prevent field-boundary ambiguity.
  defp endorsement_payload(public_key, agent_id) do
    <<byte_size(public_key)::32, public_key::binary, byte_size(agent_id)::32, agent_id::binary>>
  end

  # ===========================================================================
  # Persistent Keypair Storage
  # ===========================================================================
  #
  # P0-5: the v2 layout splits the authority record into two pieces:
  #
  #   1. Private keypair (Ed25519 signing + X25519 encryption) — held under
  #      @authority_signing_id in SigningKeyStore (AES-GCM at rest, master
  #      key in ~/.arbor/security/master.key).
  #   2. Public metadata (agent_id, public_keys, name, created_at) — held
  #      under @authority_metadata_key in BufferedStore. Public material is
  #      not encrypted because it isn't a secret.
  #
  # The pre-v2 layout serialized the private key as plaintext base64 directly
  # into BufferedStore — see cleanup_legacy_plaintext_record/0.

  # Public (@doc false) for the P0-5 regression test, which corrupts the
  # persisted metadata and asserts the load returns {:error, _} rather than
  # silently regenerating the trust root.
  @doc false
  def load_persisted_keypair do
    if Process.whereis(@key_store_name) do
      case load_public_metadata() do
        {:ok, metadata} ->
          load_private_and_reconstruct(metadata)

        :not_found ->
          :not_found

        {:error, reason} ->
          {:error, {:metadata_load_failed, reason}}
      end
    else
      :not_found
    end
  catch
    _, reason ->
      {:error, {:store_unavailable, reason}}
  end

  defp load_public_metadata do
    case apply(@buffered_store, :get, [@authority_metadata_key, [name: @key_store_name]]) do
      {:ok, %Record{data: data}} when is_map(data) -> {:ok, data}
      {:error, :not_found} -> :not_found
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_metadata_format}
    end
  end

  defp load_private_and_reconstruct(metadata) do
    with {:ok, public_key} <- decode_b64(metadata["public_key"]),
         {:ok, enc_public_key} <- decode_b64(metadata["encryption_public_key"]),
         {:ok, created_at} <- decode_created_at(metadata["created_at"]),
         {:ok, keypair} <- SigningKeyStore.get_keypair(@authority_signing_id),
         {:ok, private_key} <- fetch_signing(keypair),
         {:ok, enc_private_key} <- fetch_encryption(keypair) do
      Identity.new(
        public_key: public_key,
        private_key: private_key,
        encryption_public_key: enc_public_key,
        encryption_private_key: enc_private_key,
        name: metadata["name"],
        created_at: created_at
      )
    else
      {:error, :no_signing_key} ->
        # Metadata says we have an authority, but the encrypted private key
        # is gone. That's an inconsistent state, not "first boot" — refuse.
        {:error, :metadata_without_keypair}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_persisted_format}
    end
  end

  # Public (@doc false) for the P0-5 regression test, which calls it directly
  # with a generated identity to verify the persisted record layout. The test
  # environment uses :ephemeral mode, so the live SystemAuthority never
  # exercises this path.
  @doc false
  def persist_keypair(identity) do
    with :ok <-
           SigningKeyStore.put_keypair(
             @authority_signing_id,
             identity.private_key,
             identity.encryption_private_key
           ),
         :ok <- persist_public_metadata(identity) do
      :ok
    end
  end

  defp persist_public_metadata(identity) do
    data = %{
      "v" => 2,
      "agent_id" => identity.agent_id,
      "public_key" => Base.encode64(identity.public_key),
      "encryption_public_key" => Base.encode64(identity.encryption_public_key || <<>>),
      "name" => identity.name,
      "created_at" => DateTime.to_iso8601(identity.created_at)
    }

    record = Record.new(@authority_metadata_key, data)
    apply(@buffered_store, :put, [@authority_metadata_key, record, [name: @key_store_name]])
    :ok
  catch
    _, reason ->
      Logger.error("[SystemAuthority] Failed to persist public metadata: #{inspect(reason)}")
      {:error, {:metadata_persist_failed, reason}}
  end

  # Public (@doc false) for the P0-5 regression test.
  @doc false
  def cleanup_legacy_plaintext_record do
    if Process.whereis(@key_store_name) do
      case apply(@buffered_store, :get, [@legacy_plaintext_key, [name: @key_store_name]]) do
        {:ok, _} ->
          apply(@buffered_store, :delete, [@legacy_plaintext_key, [name: @key_store_name]])

          Logger.warning(
            "[SystemAuthority] Deleted pre-v2 plaintext authority keypair record. " <>
              "Existing capabilities signed by the old key will not verify under the new authority."
          )

          :ok

        _ ->
          :ok
      end
    else
      :ok
    end
  catch
    _, _ -> :ok
  end

  defp decode_b64(nil), do: {:error, :missing_public_key}
  defp decode_b64(""), do: {:error, :missing_public_key}

  defp decode_b64(s) when is_binary(s) do
    case Base.decode64(s) do
      {:ok, ""} -> {:error, :missing_public_key}
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :invalid_base64}
    end
  end

  defp decode_b64(_), do: {:error, :invalid_metadata}

  defp decode_created_at(nil), do: {:ok, DateTime.utc_now()}

  defp decode_created_at(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, :invalid_created_at}
    end
  end

  defp fetch_signing(%{signing: key}) when is_binary(key) and byte_size(key) > 0, do: {:ok, key}
  defp fetch_signing(_), do: {:error, :missing_signing_key}

  defp fetch_encryption(%{encryption: key}) when is_binary(key) and byte_size(key) > 0,
    do: {:ok, key}

  # X25519 key may legitimately be absent in older keypair records.
  defp fetch_encryption(_), do: {:ok, nil}
end
