defmodule Arbor.Security.SystemAuthority do
  @moduledoc """
  The system authority is the root of trust for locally-issued capabilities.

  It holds an Ed25519 keypair and signs capabilities on request. Its public
  key is registered in the Identity Registry so that any node can verify
  capability signatures using a standard key lookup.

  ## Design

  - One SystemAuthority per cluster (started by the Application supervisor)
  - **Persistent mode** (default): Keypair is persisted to AuthorityStore and
    loaded on startup. All cluster nodes share the same keypair, enabling
    cross-node capability verification without RPC.
  - **Ephemeral mode**: Fresh keypair generated on every startup (legacy
    single-node behavior, useful for testing).
  - Private key lives in GenServer state and (in persistent mode) encrypted
    in the signing-key AuthorityStore.
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
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Security.Capability.Signer
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.Config
  alias Arbor.Security.Contracts.PrivateGoalSnapshot
  alias Arbor.Security.Contracts.PrivateMemoryAdmission
  alias Arbor.Security.Contracts.PrivateMemoryRecord
  alias Arbor.Security.Contracts.PrivateRelationshipSnapshot
  alias Arbor.Security.Contracts.PrivateMemorySource
  alias Arbor.Security.DeliveryReceiptBroker
  alias Arbor.Security.PrivateMemory
  alias Arbor.Security.PrivateState
  alias Arbor.Security.Crypto
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.Identity.Verifier
  alias Arbor.Security.IssuerRegistry
  alias Arbor.Security.SigningKeyStore
  alias Arbor.Security.SigningAuthorityBroker
  alias Arbor.Security.SupervisedOwner

  @key_store_name :arbor_security_signing_keys
  @max_memory_attestations 64
  @max_issuer_mutation_attestations 256
  @issuer_mutation_attestation_ttl_seconds 30
  @issuer_mutation_attestation_version "arbor-issuer-mutation-attestation-v1"
  @max_identity_registration_attestations 256
  @identity_registration_attestation_ttl_seconds 30
  @identity_registration_attestation_version "arbor-identity-registration-attestation-v1"
  @max_identity_status_attestations 512
  @identity_status_attestation_ttl_seconds 30
  @identity_status_attestation_version "arbor-identity-status-attestation-v1"
  @max_capability_mutation_attestations 1_024
  @capability_mutation_attestation_ttl_seconds 30
  @capability_mutation_attestation_version "arbor-capability-mutation-attestation-v1"
  @capability_mutation_request_version "arbor-capability-mutation-request-v1"
  @issuer_mutation_request_version "arbor-issuer-mutation-request-v1"
  @max_capability_revocation_attestations 1_024
  @capability_revocation_attestation_ttl_seconds 30
  @capability_revocation_attestation_version "arbor-capability-revocation-attestation-v1"

  # V3 stores the encrypted private keypair and non-secret public metadata in
  # one acknowledged AuthorityStore record under this logical id.
  @authority_signing_id "system_authority"
  @owner_table :arbor_security_system_authority_directory
  @private_state_anchor {__MODULE__, :private_state}
  @private_state_schema :system_authority_v1

  # V2 split public metadata. Read only for validated migration, then removed
  # after the v3 bundle is durably acknowledged.
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

  @doc false
  @spec complete_startup(pid(), reference()) :: :ok | {:error, term()}
  def complete_startup(supervisor, registration_token) do
    with {:ok, timeout} <- Config.startup_timeout_ms() do
      complete_startup(supervisor, registration_token, timeout)
    end
  end

  @spec complete_startup(pid(), reference(), timeout()) :: :ok | {:error, term()}

  def complete_startup(supervisor, registration_token, timeout)
      when is_pid(supervisor) and is_reference(registration_token) and is_integer(timeout) and
             timeout > 0 do
    case SupervisedOwner.child_pid(supervisor, __MODULE__) do
      authority when is_pid(authority) ->
        GenServer.call(
          authority,
          {:complete_startup, supervisor, registration_token},
          timeout
        )

      nil ->
        {:error, :system_authority_unavailable}
    end
  rescue
    _ -> {:error, :system_authority_unavailable}
  catch
    :exit, {:timeout, _} -> {:error, :system_authority_startup_timeout}
    :exit, _ -> {:error, :system_authority_unavailable}
  end

  def complete_startup(_supervisor, _registration_token, _timeout),
    do: {:error, :invalid_system_authority_startup}

  @doc """
  Sign a capability with the system authority's private key.

  Sets `issuer_id` to the system authority's agent_id and `issuer_signature`
  to the Ed25519 signature over the canonical capability payload.
  """
  @spec sign_capability(Capability.t()) :: {:error, :capability_signing_unauthorized}
  def sign_capability(%Capability{}), do: {:error, :capability_signing_unauthorized}

  @doc false
  @spec sign_capability_from_store(Capability.t()) :: {:ok, Capability.t()} | {:error, term()}
  def sign_capability_from_store(%Capability{} = cap) do
    Arbor.Common.authenticated_call(owner_pid(), {:sign_capability_from_store, cap})
  rescue
    _ -> {:error, :capability_signing_unavailable}
  catch
    :exit, _ -> {:error, :capability_signing_unavailable}
  end

  if Mix.env() == :test do
    @doc false
    @spec sign_capability_for_test(Capability.t()) :: {:ok, Capability.t()} | {:error, term()}
    def sign_capability_for_test(%Capability{} = cap) do
      Arbor.Common.authenticated_call(owner_pid(), {:sign_capability_for_test, cap})
    rescue
      _ -> {:error, :system_authority_unavailable}
    catch
      :exit, _ -> {:error, :system_authority_unavailable}
    end
  end

  @doc """
  Sign an invocation receipt with the system authority's private key.

  Sets `issuer_id` and `signature` on the receipt.
  """
  @spec sign_receipt(InvocationReceipt.t()) :: {:error, :receipt_signing_unauthorized}
  def sign_receipt(%InvocationReceipt{}), do: {:error, :receipt_signing_unauthorized}

  @doc false
  @spec sign_receipt_from_broker(InvocationReceipt.t()) ::
          {:ok, InvocationReceipt.t()} | {:error, :receipt_signing_unauthorized}
  def sign_receipt_from_broker(%InvocationReceipt{} = receipt) do
    Arbor.Common.authenticated_call(owner_pid(), {:sign_receipt_from_broker, receipt})
  rescue
    _ -> {:error, :receipt_signing_unauthorized}
  catch
    :exit, _ -> {:error, :receipt_signing_unauthorized}
  end

  if Mix.env() == :test do
    @doc false
    def sign_receipt_for_test(%InvocationReceipt{} = receipt) do
      Arbor.Common.authenticated_call(owner_pid(), {:sign_receipt_for_test, receipt})
    end

    @doc false
    def memory_attestations_for_test do
      Arbor.Common.authenticated_call(owner_pid(), :memory_attestations_for_test)
    end

    @doc false
    def persist_keypair_for_test(%Identity{} = identity) do
      Arbor.Common.authenticated_call(owner_pid(), {:persist_keypair_for_test, identity})
    end

    @doc false
    def load_persisted_keypair_for_test do
      Arbor.Common.authenticated_call(owner_pid(), :load_persisted_keypair_for_test)
    end

    def identity_for_test do
      Arbor.Common.authenticated_call(owner_pid(), :identity_for_test)
    end

    @doc false
    def cleanup_legacy_plaintext_record_for_test do
      Arbor.Common.authenticated_call(owner_pid(), :cleanup_legacy_plaintext_record_for_test)
    end
  end

  @doc """
  Return the system authority's public key.
  """
  @spec public_key() :: binary()
  def public_key do
    Arbor.Common.authenticated_call(owner_pid(), :public_key)
  end

  @doc false
  def attest_private_memory_record(admission, descriptor),
    do: private_memory_call({:attest_private_memory_record, admission, descriptor})

  @doc false
  def verify_private_memory_record(descriptor, stamp),
    do: private_memory_call({:verify_private_memory_record, descriptor, stamp})

  @doc false
  def attest_private_memory_source(admission, descriptor),
    do: private_memory_call({:attest_private_memory_source, admission, descriptor})

  @doc false
  def verify_private_memory_source(descriptor, stamp),
    do: private_memory_call({:verify_private_memory_source, descriptor, stamp})

  @doc false
  def attest_private_memory_record_from_source(admission, descriptor, source, stamp),
    do:
      private_memory_call(
        {:attest_private_memory_record_from_source, admission, descriptor, source, stamp}
      )

  @doc false
  def attest_private_goal_snapshot(admission, descriptor),
    do: private_memory_call({:attest_private_goal_snapshot, admission, descriptor})

  @doc false
  def verify_private_goal_snapshot(descriptor, stamp),
    do: private_memory_call({:verify_private_goal_snapshot, descriptor, stamp})

  @doc false
  def attest_private_relationship_snapshot(admission, descriptor),
    do: private_memory_call({:attest_private_relationship_snapshot, admission, descriptor})

  @doc false
  def verify_private_relationship_snapshot(descriptor, stamp),
    do: private_memory_call({:verify_private_relationship_snapshot, descriptor, stamp})

  defp private_memory_call(request) do
    Arbor.Common.authenticated_call(
      owner_pid(),
      request,
      Config.private_memory_attestation_timeout_ms() + 1_000
    )
  catch
    :exit, _ -> {:error, :memory_attestation_unavailable}
  end

  @doc """
  Return the system authority's agent_id.
  """
  @spec agent_id() :: String.t()
  def agent_id do
    Arbor.Common.authenticated_call(owner_pid(), :agent_id)
  end

  @doc """
  Verify a capability's issuer signature.

  For capabilities signed by the system authority, uses the local public key.
  For delegated capabilities, looks up the issuer's public key from the Registry.
  """
  @spec verify_capability_signature(Capability.t()) ::
          :ok | {:error, :invalid_capability_signature}
  def verify_capability_signature(%Capability{} = cap) do
    Arbor.Common.authenticated_call(owner_pid(), {:verify_capability_signature, cap})
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
    Arbor.Common.authenticated_call(owner_pid(), {:verify_authority_capability_signature, cap})
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
      Arbor.Common.authenticated_call(owner_pid(), {:verify_capability_signatures, caps})
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
  @spec endorse_agent(Identity.t()) :: {:error, :identity_endorsement_unauthorized}
  def endorse_agent(%Identity{}), do: {:error, :identity_endorsement_unauthorized}

  @spec endorse_agent(Identity.t(), term()) :: {:ok, map()} | {:error, term()}
  def endorse_agent(%Identity{} = identity, actor_authority) do
    Arbor.Common.authenticated_call(owner_pid(), {:endorse_agent, identity, actor_authority})
  catch
    :exit, _ -> {:error, :identity_endorsement_unauthorized}
  end

  @doc """
  Verify an agent endorsement signed by the system authority.

  Checks that the endorsement signature is valid for the agent's public key
  and agent_id, signed by the current system authority.
  """
  @spec verify_agent_endorsement(map()) :: :ok | {:error, :invalid_endorsement}
  def verify_agent_endorsement(endorsement) do
    Arbor.Common.authenticated_call(owner_pid(), {:verify_agent_endorsement, endorsement})
  end

  @doc """
  Rotate the system authority's keypair.

  Generates a new identity, registers it in the Identity Registry, and
  updates the GenServer state. The old keypair is discarded.

  Note: Existing capabilities signed with the old key will fail verification
  after rotation. Plan rotation during maintenance windows.
  """
  @spec rotate() :: {:error, :authority_rotation_unauthorized}
  def rotate, do: {:error, :authority_rotation_unauthorized}

  @spec rotate(term()) ::
          {:ok, %{old_agent_id: String.t(), new_agent_id: String.t()}} | {:error, term()}
  def rotate(actor_authority) do
    Arbor.Common.authenticated_call(owner_pid(), {:rotate, actor_authority})
  catch
    :exit, _ -> {:error, :authority_rotation_unavailable}
  end

  if Mix.env() == :test do
    @doc false
    def rotate_for_test, do: Arbor.Common.authenticated_call(owner_pid(), :rotate_for_test)
  end

  @doc false
  @spec issue_issuer_mutation_attestation(term(), atom(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def issue_issuer_mutation_attestation(authority, operation, payload_digest) do
    Arbor.Common.authenticated_call(
      owner_pid(),
      {:issue_issuer_mutation_attestation, authority, operation, payload_digest}
    )
  catch
    :exit, _ -> {:error, :issuer_mutation_authority_unavailable}
  end

  @doc false
  @spec issuer_mutation_request_payload(atom(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def issuer_mutation_request_payload(operation, payload_digest)
      when operation in [:register, :update, :revoke] do
    with :ok <- validate_sha256_digest(payload_digest) do
      {:ok,
       [@issuer_mutation_request_version, Atom.to_string(operation), payload_digest]
       |> Enum.map_join(&issuer_attestation_length_prefix/1)}
    end
  end

  def issuer_mutation_request_payload(_operation, _payload_digest),
    do: {:error, :issuer_mutation_unauthorized}

  @doc false
  @spec issue_issuer_mutation_attestation_proof(SignedRequest.t(), atom(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def issue_issuer_mutation_attestation_proof(
        %SignedRequest{} = actor_proof,
        operation,
        payload_digest
      ) do
    Arbor.Common.authenticated_call(
      owner_pid(),
      {:issue_issuer_mutation_attestation_proof, actor_proof, operation, payload_digest}
    )
  catch
    :exit, _ -> {:error, :issuer_mutation_authority_unavailable}
  end

  def issue_issuer_mutation_attestation_proof(_actor_proof, _operation, _payload_digest),
    do: {:error, :issuer_mutation_unauthorized}

  @doc false
  @spec consume_issuer_mutation_attestation(map(), atom(), String.t()) ::
          :ok | {:error, term()}
  def consume_issuer_mutation_attestation(proof, operation, payload_digest) do
    Arbor.Common.authenticated_call(
      owner_pid(),
      {:consume_issuer_mutation_attestation, proof, operation, payload_digest}
    )
  catch
    :exit, _ -> {:error, :issuer_mutation_unauthorized}
  end

  @doc false
  @spec issue_identity_registration_attestation(term(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def issue_identity_registration_attestation(authority, target_digest) do
    Arbor.Common.authenticated_call(
      owner_pid(),
      {:issue_identity_registration_attestation, authority, target_digest}
    )
  catch
    :exit, _ -> {:error, :identity_registration_unauthorized}
  end

  @doc false
  @spec consume_identity_registration_attestation(map(), String.t()) ::
          :ok | {:error, term()}
  def consume_identity_registration_attestation(proof, target_digest) do
    Arbor.Common.authenticated_call(
      owner_pid(),
      {:consume_identity_registration_attestation, proof, target_digest}
    )
  catch
    :exit, _ -> {:error, :identity_registration_unauthorized}
  end

  @doc false
  @spec issue_identity_status_mutation_attestation(
          term(),
          :deregister | :revoke | :suspend | :resume,
          String.t(),
          String.t()
        ) :: {:ok, map()} | {:error, term()}
  def issue_identity_status_mutation_attestation(
        authority,
        operation,
        agent_id,
        payload_digest
      ) do
    Arbor.Common.authenticated_call(
      owner_pid(),
      {:issue_identity_status_mutation_attestation, authority, operation, agent_id,
       payload_digest}
    )
  catch
    :exit, _ -> {:error, :identity_status_mutation_unauthorized}
  end

  @doc false
  @spec consume_identity_status_mutation_attestation(map(), atom(), String.t()) ::
          :ok | {:error, term()}
  def consume_identity_status_mutation_attestation(proof, operation, payload_digest) do
    Arbor.Common.authenticated_call(
      owner_pid(),
      {:consume_identity_status_mutation_attestation, proof, operation, payload_digest}
    )
  catch
    :exit, _ -> {:error, :identity_status_mutation_unauthorized}
  end

  @doc false
  @spec authorize_capability_mutation(term(), atom(), Capability.t()) ::
          {:ok, Capability.t(), map()} | {:error, term()}
  def authorize_capability_mutation(authority, operation, %Capability{} = cap) do
    Arbor.Common.authenticated_call(
      owner_pid(),
      {:authorize_capability_mutation, authority, operation, cap}
    )
  catch
    :exit, _ -> {:error, :capability_mutation_unauthorized}
  end

  @doc false
  @spec capability_mutation_request_payload(atom(), Capability.t()) ::
          {:ok, binary()} | {:error, term()}
  def capability_mutation_request_payload(operation, %Capability{} = cap)
      when operation in [:grant, :acknowledged_grant] do
    {:ok,
     [
       @capability_mutation_request_version,
       Atom.to_string(operation),
       capability_mutation_digest(cap)
     ]
     |> Enum.map_join(&issuer_attestation_length_prefix/1)}
  end

  def capability_mutation_request_payload(_operation, _cap),
    do: {:error, :capability_mutation_unauthorized}

  @doc false
  @spec authorize_capability_mutation_proof(SignedRequest.t(), atom(), Capability.t()) ::
          {:ok, Capability.t(), map()} | {:error, term()}
  def authorize_capability_mutation_proof(
        %SignedRequest{} = actor_proof,
        operation,
        %Capability{} = cap
      ) do
    Arbor.Common.authenticated_call(
      owner_pid(),
      {:authorize_capability_mutation_proof, actor_proof, operation, cap}
    )
  catch
    :exit, _ -> {:error, :capability_mutation_unauthorized}
  end

  def authorize_capability_mutation_proof(_actor_proof, _operation, _cap),
    do: {:error, :capability_mutation_unauthorized}

  @doc false
  @spec consume_capability_mutation_attestation(map(), atom(), Capability.t()) ::
          :ok | {:error, term()}
  def consume_capability_mutation_attestation(proof, operation, %Capability{} = cap) do
    Arbor.Common.authenticated_call(
      owner_pid(),
      {:consume_capability_mutation_attestation, proof, operation, cap}
    )
  catch
    :exit, _ -> {:error, :capability_mutation_unauthorized}
  end

  @doc false
  @spec issue_capability_revocation_attestation(term(), atom(), term()) ::
          {:ok, map()} | {:error, term()}
  def issue_capability_revocation_attestation(authority, operation, target) do
    Arbor.Common.authenticated_call(
      owner_pid(),
      {:issue_capability_revocation_attestation, authority, operation, target}
    )
  catch
    :exit, _ -> {:error, :capability_revocation_unauthorized}
  end

  @doc false
  @spec consume_capability_revocation_attestation(map(), atom(), term()) ::
          :ok | {:error, term()}
  def consume_capability_revocation_attestation(proof, operation, target) do
    Arbor.Common.authenticated_call(
      owner_pid(),
      {:consume_capability_revocation_attestation, proof, operation, target}
    )
  catch
    :exit, _ -> {:error, :capability_revocation_unauthorized}
  end

  # Server callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Process.flag(:sensitive, true)

    with {:ok, supervisor_pid} <- startup_supervisor_pid(),
         {:ok, registration_token_source} <- system_authority_registration_token(opts),
         :ok <- validate_registration_token_source(registration_token_source),
         {:ok, defer_initialization?} <- defer_initialization(opts),
         :ok <- claim_owner_directory() do
      # Every persistent-mode store call and the identity registration below
      # proves its target through Security.Supervisor. Running those calls in
      # init/1 deadlocks a dynamic Supervisor.start_child/2 because the parent
      # cannot answer which_children/1 until this child acknowledges startup.
      # A static Application start explicitly completes this pending child only
      # after its foundation supervisor has returned. Later restarts run the
      # continuation because the application is already started; the exact
      # supervisor-child proof then waits for rest_for_one reconstruction.
      pending_state = %{
        authenticated_calls: Arbor.Common.new_authenticated_call_custody(),
        initialization: :pending,
        registration_token_source: registration_token_source,
        security_supervisor_pid: supervisor_pid
      }

      private_state =
        PrivateState.new(@private_state_anchor, @private_state_schema, pending_state)

      if defer_initialization? and not SupervisedOwner.application_started?(:arbor_security),
        do: {:ok, private_state},
        else: {:ok, private_state, {:continue, :initialize}}
    else
      :error -> {:stop, :system_authority_registration_token_missing}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:initialize, private_state) do
    with {:ok, pending_state} <- private_state(private_state) do
      case initialize_private_state(pending_state) do
        {:noreply, state} ->
          case put_private_state(private_state, state) do
            :ok -> {:noreply, private_state}
            {:error, _reason} -> {:stop, :invalid_private_state, private_state}
          end

        {:stop, reason, state} ->
          _ = put_private_state(private_state, state)
          {:stop, reason, private_state}
      end
    else
      {:error, _reason} -> {:stop, :invalid_private_state, private_state}
    end
  end

  defp initialize_private_state(pending_state) do
    registration_token_source = Map.fetch!(pending_state, :registration_token_source)
    supervisor_pid = Map.fetch!(pending_state, :security_supervisor_pid)

    result =
      with {:ok, registration_token} <-
             resolve_system_authority_registration_token(registration_token_source) do
        case Config.system_authority_mode() do
          :persistent ->
            init_persistent(registration_token, supervisor_pid)

          :ephemeral ->
            init_ephemeral(registration_token, supervisor_pid)
        end
        |> attach_supervisor_identity(
          supervisor_pid,
          registration_token,
          pending_state.authenticated_calls
        )
      end

    finish_initialization(result, pending_state)
  end

  defp startup_supervisor_pid do
    case Process.get(:"$ancestors") do
      [pid | _] when is_pid(pid) ->
        linked_supervisor(pid)

      [name | _] when is_atom(name) ->
        name
        |> Process.whereis()
        |> linked_supervisor()

      _ ->
        {:error, :security_supervisor_unavailable}
    end
  end

  defp linked_supervisor(pid) when is_pid(pid) do
    case Process.info(self(), :links) do
      {:links, links} when is_list(links) ->
        if pid in links,
          do: {:ok, pid},
          else: {:error, :security_supervisor_unavailable}

      _other ->
        {:error, :security_supervisor_unavailable}
    end
  end

  defp linked_supervisor(_pid), do: {:error, :security_supervisor_unavailable}

  defp defer_initialization(opts) when is_list(opts) do
    case Keyword.get(opts, :defer_initialization, false) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, :invalid_system_authority_startup}
    end
  rescue
    _ -> {:error, :invalid_system_authority_startup}
  end

  defp defer_initialization(_opts), do: {:error, :invalid_system_authority_startup}

  if Mix.env() == :test do
    defp system_authority_registration_token(opts) when is_list(opts) do
      case Keyword.fetch(opts, :system_authority_registration_token) do
        {:ok, _token} = result -> result
        :error -> {:ok, :test_registry_lookup}
      end
    end
  else
    defp system_authority_registration_token(opts) do
      Keyword.fetch(opts, :system_authority_registration_token)
    end
  end

  defp validate_registration_token_source(token) when is_reference(token), do: :ok

  if Mix.env() == :test do
    defp validate_registration_token_source(:test_registry_lookup), do: :ok
  end

  defp validate_registration_token_source(_token),
    do: {:error, :invalid_system_authority_registration_token}

  defp resolve_system_authority_registration_token(token) when is_reference(token),
    do: {:ok, token}

  if Mix.env() == :test do
    defp resolve_system_authority_registration_token(:test_registry_lookup) do
      case Registry.test_system_authority_registration_token() do
        token when is_reference(token) -> {:ok, token}
        _other -> {:error, :invalid_system_authority_registration_token}
      end
    rescue
      _ -> {:error, :system_authority_registration_token_missing}
    catch
      _, _ -> {:error, :system_authority_registration_token_missing}
    end
  end

  defp resolve_system_authority_registration_token(_token),
    do: {:error, :invalid_system_authority_registration_token}

  defp finish_initialization({:ok, state}, _pending_state), do: {:noreply, state}

  defp finish_initialization({:stop, reason}, pending_state),
    do: {:stop, reason, pending_state}

  defp finish_initialization({:error, reason}, pending_state),
    do: {:stop, reason, pending_state}

  defp attach_supervisor_identity(
         {:ok, state},
         supervisor_pid,
         registration_token,
         authenticated_calls
       )
       when is_pid(supervisor_pid) and is_reference(registration_token) and
              is_reference(authenticated_calls) do
    {:ok,
     state
     |> Map.put(:security_supervisor_pid, supervisor_pid)
     |> Map.put(:system_authority_registration_token, registration_token)
     |> Map.put(:authenticated_calls, authenticated_calls)}
  end

  defp attach_supervisor_identity(
         {:ok, _state},
         _supervisor_pid,
         _registration_token,
         _authenticated_calls
       ),
       do: {:stop, :security_supervisor_unavailable}

  defp attach_supervisor_identity(
         other,
         _supervisor_pid,
         _registration_token,
         _authenticated_calls
       ),
       do: other

  defp init_persistent(registration_token, supervisor_pid) do
    # P0-5: any pre-v2 plaintext keypair record is orphan data — delete it
    # before doing anything else so the plaintext private key stops sitting
    # on disk. Idempotent: no-op if the legacy record never existed.
    cleanup_legacy_plaintext_record(supervisor_pid)

    case load_persisted_keypair(supervisor_pid) do
      {:ok, identity} ->
        Logger.info("[SystemAuthority] Loaded persistent keypair: #{identity.agent_id}")

        case register_public_identity(identity, registration_token, supervisor_pid) do
          :ok ->
            {:ok,
             %{
               identity: identity,
               private_memory_root_ready: durable_root_store?(supervisor_pid)
             }}

          {:error, reason} ->
            {:stop, {:authority_registration_failed, reason}}
        end

      :not_found ->
        # First boot only. metadata_load_failed and metadata_without_keypair
        # stay on the {:error, _} path below so we never silently rotate.
        case Identity.generate() do
          {:ok, identity} ->
            adopt_first_boot_identity(identity, registration_token, supervisor_pid)

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

  defp init_ephemeral(registration_token, supervisor_pid) do
    case Identity.generate() do
      {:ok, identity} ->
        case register_public_identity(identity, registration_token, supervisor_pid) do
          :ok -> {:ok, %{identity: identity, private_memory_root_ready: false}}
          {:error, reason} -> {:stop, {:authority_registration_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:failed_to_generate_identity, reason}}
    end
  end

  # First boot without :arbor_security_signing_keys (activation_only) cannot
  # persist. Keep the generated identity in memory instead of crashing.
  defp adopt_first_boot_identity(identity, registration_token, supervisor_pid) do
    case persist_keypair(identity, supervisor_pid) do
      :ok ->
        Logger.info("[SystemAuthority] Generated new persistent keypair: #{identity.agent_id}")

        register_generated_identity(identity, true, registration_token, supervisor_pid)

      {:error, :store_unavailable} ->
        Logger.info("[SystemAuthority] Generated in-memory keypair: #{identity.agent_id}")

        register_generated_identity(identity, false, registration_token, supervisor_pid)

      {:error, reason} ->
        {:stop, {:failed_to_persist_identity, reason}}
    end
  end

  defp register_generated_identity(identity, persisted?, registration_token, supervisor_pid) do
    case register_public_identity(identity, registration_token, supervisor_pid) do
      :ok ->
        {:ok,
         %{
           identity: identity,
           private_memory_root_ready: persisted? and durable_root_store?(supervisor_pid)
         }}

      {:error, reason} ->
        {:stop, {:authority_registration_failed, reason}}
    end
  end

  defp durable_root_store?(supervisor_pid) do
    AuthorityStore.durability_class_from_supervisor(supervisor_pid, name: @key_store_name) ==
      :node_restart
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp durable_root_store? do
    AuthorityStore.durability_class(name: @key_store_name) == :node_restart
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @impl true
  def handle_call(
        {:complete_startup, supervisor, registration_token},
        _from,
        private_state
      ) do
    with {:ok,
          %{
            initialization: :pending,
            registration_token_source: ^registration_token,
            security_supervisor_pid: ^supervisor
          } = pending_state} <- private_state(private_state) do
      case initialize_private_state(pending_state) do
        {:noreply, state} ->
          case put_private_state(private_state, state) do
            :ok -> {:reply, :ok, private_state}
            {:error, _reason} -> {:reply, {:error, :invalid_private_state}, private_state}
          end

        {:stop, reason, _state} ->
          {:reply, {:error, reason}, private_state}
      end
    else
      {:ok, _already_initialized} -> {:reply, {:error, :already_initialized}, private_state}
      {:error, _reason} -> {:reply, {:error, :invalid_private_state}, private_state}
    end
  end

  def handle_call(_request, _from, private_state),
    do: {:reply, {:error, :system_authority_unauthorized}, private_state}

  if Mix.env() == :test do
    defp handle_authenticated_request(:memory_attestations_for_test, _from, state) do
      {:reply, Map.get(state, :memory_attestations, %{}), state}
    end

    defp handle_authenticated_request(
           {:sign_capability_for_test, cap},
           _from,
           %{identity: identity} = state
         ) do
      {:reply, {:ok, sign_capability_with_identity(cap, identity)}, state}
    end

    defp handle_authenticated_request({:persist_keypair_for_test, identity}, _from, state) do
      {:reply, persist_keypair(identity), state}
    end

    defp handle_authenticated_request(:load_persisted_keypair_for_test, _from, state) do
      {:reply, load_persisted_keypair(), state}
    end

    defp handle_authenticated_request(:identity_for_test, _from, %{identity: identity} = state) do
      {:reply, {:ok, identity}, state}
    end

    defp handle_authenticated_request(:cleanup_legacy_plaintext_record_for_test, _from, state) do
      {:reply, cleanup_legacy_plaintext_record(), state}
    end
  end

  defp handle_authenticated_request({:sign_capability, _cap}, _from, state) do
    {:reply, {:error, :capability_signing_unauthorized}, state}
  end

  defp handle_authenticated_request({:sign_receipt, _receipt}, _from, state),
    do: {:reply, {:error, :receipt_signing_unauthorized}, state}

  if Mix.env() == :test do
    defp handle_authenticated_request(
           {:sign_receipt_for_test, receipt},
           _from,
           %{identity: identity} = state
         ) do
      receipt = Map.put(receipt, :issuer_id, identity.agent_id)
      payload = InvocationReceipt.signing_payload(receipt)
      signature = Crypto.sign(payload, identity.private_key)
      {:reply, {:ok, Map.put(receipt, :signature, signature)}, state}
    end
  end

  defp handle_authenticated_request(
         {:attest_private_memory_record, admission, descriptor},
         {owner, _} = from,
         state
       ) do
    with true <- Map.get(state, :private_memory_root_ready, false),
         true <- map_size(Map.get(state, :memory_attestations, %{})) < @max_memory_attestations,
         {:ok, token} <- PrivateMemoryAdmission.token(admission),
         {:ok, scope} <- DeliveryReceiptBroker.memory_attestation_scope(token, owner),
         :ok <- PrivateMemoryRecord.admit(descriptor),
         true <- PrivateMemoryRecord.scope_matches?(descriptor, scope) do
      start_memory_attestation(state, from, token, scope, descriptor)
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :memory_attestation_unavailable}, state}
    end
  end

  defp handle_authenticated_request(
         {:verify_private_memory_record, descriptor, stamp},
         _from,
         state
       ) do
    reply =
      if Map.get(state, :private_memory_root_ready, false) do
        PrivateMemoryRecord.verify(descriptor, stamp, state.identity)
      else
        {:error, :memory_attestation_unavailable}
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_request(
         {:attest_private_memory_source, admission, descriptor},
         {owner, _} = from,
         state
       ) do
    with true <- Map.get(state, :private_memory_root_ready, false),
         true <- map_size(Map.get(state, :memory_attestations, %{})) < @max_memory_attestations,
         {:ok, token} <- PrivateMemoryAdmission.token(admission),
         {:ok, scope} <- DeliveryReceiptBroker.memory_attestation_scope(token, owner),
         :ok <- PrivateMemorySource.admit(descriptor),
         true <- PrivateMemorySource.scope_matches?(descriptor, scope) do
      start_memory_attestation(state, from, token, scope, descriptor, :source)
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :memory_attestation_unavailable}, state}
    end
  end

  defp handle_authenticated_request(
         {:attest_private_relationship_snapshot, admission, descriptor},
         {owner, _} = from,
         state
       ) do
    with true <- Map.get(state, :private_memory_root_ready, false),
         true <- map_size(Map.get(state, :memory_attestations, %{})) < @max_memory_attestations,
         {:ok, token} <- PrivateMemoryAdmission.token(admission),
         {:ok, scope} <- DeliveryReceiptBroker.memory_attestation_scope(token, owner),
         :ok <- PrivateRelationshipSnapshot.admit(descriptor),
         true <- PrivateRelationshipSnapshot.scope_matches?(descriptor, scope) do
      start_memory_attestation(state, from, token, scope, descriptor, :relationship_snapshot)
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :memory_attestation_unavailable}, state}
    end
  end

  defp handle_authenticated_request(
         {:verify_private_relationship_snapshot, descriptor, stamp},
         _from,
         state
       ) do
    reply =
      if Map.get(state, :private_memory_root_ready, false),
        do: PrivateRelationshipSnapshot.verify(descriptor, stamp, state.identity),
        else: {:error, :memory_attestation_unavailable}

    {:reply, reply, state}
  end

  defp handle_authenticated_request(
         {:verify_private_memory_source, descriptor, stamp},
         _from,
         state
       ) do
    reply =
      if Map.get(state, :private_memory_root_ready, false),
        do: PrivateMemorySource.verify(descriptor, stamp, state.identity),
        else: {:error, :memory_attestation_unavailable}

    {:reply, reply, state}
  end

  defp handle_authenticated_request(
         {:attest_private_memory_record_from_source, admission, descriptor, source, stamp},
         {owner, _} = from,
         state
       ) do
    with true <- Map.get(state, :private_memory_root_ready, false),
         true <- map_size(Map.get(state, :memory_attestations, %{})) < @max_memory_attestations,
         {:ok, token} <- PrivateMemoryAdmission.token(admission),
         {:ok, scope} <- DeliveryReceiptBroker.memory_attestation_scope(token, owner),
         true <- PrivateMemorySource.binds_record?(source, descriptor),
         true <- PrivateMemorySource.pair_matches?(source, scope) do
      start_memory_attestation(
        state,
        from,
        token,
        scope,
        descriptor,
        {:from_source, source, stamp}
      )
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :memory_attestation_unavailable}, state}
    end
  end

  defp handle_authenticated_request(
         {:attest_private_goal_snapshot, admission, descriptor},
         {owner, _} = from,
         state
       ) do
    with true <- Map.get(state, :private_memory_root_ready, false),
         true <- map_size(Map.get(state, :memory_attestations, %{})) < @max_memory_attestations,
         {:ok, token} <- PrivateMemoryAdmission.token(admission),
         {:ok, scope} <- DeliveryReceiptBroker.memory_attestation_scope(token, owner),
         :ok <- PrivateGoalSnapshot.admit(descriptor),
         true <- PrivateGoalSnapshot.scope_matches?(descriptor, scope) do
      start_memory_attestation(state, from, token, scope, descriptor, :goal_snapshot)
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :memory_attestation_unavailable}, state}
    end
  end

  defp handle_authenticated_request(
         {:verify_private_goal_snapshot, descriptor, stamp},
         _from,
         state
       ) do
    reply =
      if Map.get(state, :private_memory_root_ready, false) do
        PrivateGoalSnapshot.verify(descriptor, stamp, state.identity)
      else
        {:error, :memory_attestation_unavailable}
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_request(:public_key, _from, %{identity: identity} = state) do
    {:reply, identity.public_key, state}
  end

  defp handle_authenticated_request(:agent_id, _from, %{identity: identity} = state) do
    {:reply, identity.agent_id, state}
  end

  defp handle_authenticated_request({:verify_capability_signature, cap}, _from, state) do
    {:reply, verify_capability_signature_safe(cap, state), state}
  end

  defp handle_authenticated_request(
         {:verify_authority_capability_signature, cap},
         _from,
         %{identity: identity} = state
       ) do
    {:reply, verify_authority_capability_signature_safe(cap, identity), state}
  end

  defp handle_authenticated_request(
         {:verify_capability_signatures, caps},
         _from,
         state
       ) do
    {:reply, {:ok, verify_capability_signatures_safe(caps, state)}, state}
  end

  defp handle_authenticated_request(
         {:endorse_agent, agent_identity, actor_authority},
         {owner, _tag},
         %{identity: authority} = state
       ) do
    result =
      with :ok <- validate_endorsement_target(agent_identity),
           {:ok, registered_key} <- registry_lookup(state, agent_identity.agent_id),
           true <- registered_key == agent_identity.public_key,
           {:ok, %{principal_id: actor_id}} <-
             recorded_signing_identity(state, actor_authority, owner),
           :ok <- authorize_endorsement_actor(actor_id, agent_identity.agent_id, state) do
        payload = endorsement_payload(agent_identity.public_key, agent_identity.agent_id)
        signature = Crypto.sign(payload, authority.private_key)

        {:ok,
         %{
           agent_id: agent_identity.agent_id,
           agent_public_key: agent_identity.public_key,
           authority_id: authority.agent_id,
           authority_signature: signature,
           endorsed_at: DateTime.utc_now()
         }}
      else
        _ -> {:error, :identity_endorsement_unauthorized}
      end

    {:reply, result, state}
  end

  defp handle_authenticated_request({:endorse_agent, _agent_identity}, _from, state),
    do: {:reply, {:error, :identity_endorsement_unauthorized}, state}

  defp handle_authenticated_request(
         {:verify_agent_endorsement, endorsement},
         _from,
         %{identity: authority} = state
       ) do
    payload = endorsement_payload(endorsement.agent_public_key, endorsement.agent_id)
    valid? = Crypto.verify(payload, endorsement.authority_signature, authority.public_key)

    result = if valid?, do: :ok, else: {:error, :invalid_endorsement}
    {:reply, result, state}
  end

  defp handle_authenticated_request(
         {:rotate, actor_authority},
         {owner, _tag},
         %{identity: old_identity} = state
       ) do
    with {:ok, %{principal_id: actor_id}} <-
           recorded_signing_identity(state, actor_authority, owner),
         :ok <-
           authorize_security_mutation_actor(
             actor_id,
             "arbor://security/authority/rotate",
             state
           ) do
      rotate_to_fresh_identity(old_identity, state)
    else
      _ -> {:reply, {:error, :authority_rotation_unauthorized}, state}
    end
  end

  defp handle_authenticated_request(:rotate, _from, state),
    do: {:reply, {:error, :authority_rotation_unauthorized}, state}

  if Mix.env() == :test do
    defp handle_authenticated_request(:rotate_for_test, _from, %{identity: old_identity} = state) do
      rotate_to_fresh_identity(old_identity, state)
    end
  end

  defp handle_authenticated_request(
         {:issue_issuer_mutation_attestation, authority, operation, payload_digest},
         {owner, _tag},
         state
       ) do
    state = prune_issuer_mutation_attestations(state)

    result =
      with :ok <- validate_issuer_mutation_request(operation, payload_digest),
           true <-
             map_size(Map.get(state, :issuer_mutation_attestations, %{})) <
               @max_issuer_mutation_attestations,
           consumer when is_pid(consumer) <-
             supervised_registered_child_pid(state, IssuerRegistry, IssuerRegistry),
           {:ok, %{principal_id: actor_id}} <-
             recorded_signing_identity(state, authority, owner),
           :ok <-
             authorize_security_mutation_actor(
               actor_id,
               "arbor://security/issuer/#{operation}",
               state
             ) do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        expires_at = DateTime.add(now, @issuer_mutation_attestation_ttl_seconds, :second)
        token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        proof = %{
          v: 1,
          token: token,
          actor_id: actor_id,
          operation: operation,
          payload_digest: payload_digest,
          authority_fingerprint: authority_fingerprint(state.identity),
          issued_at: DateTime.to_iso8601(now),
          expires_at: DateTime.to_iso8601(expires_at)
        }

        signature =
          Crypto.sign(issuer_mutation_attestation_payload(proof), state.identity.private_key)

        signed_proof = Map.put(proof, :signature, signature)

        entry = %{
          proof: signed_proof,
          consumer: consumer,
          expires_mono:
            System.monotonic_time(:millisecond) +
              @issuer_mutation_attestation_ttl_seconds * 1_000
        }

        {:ok, signed_proof, put_issuer_mutation_attestation(state, token, entry)}
      else
        false -> {:error, :issuer_mutation_attestation_capacity_exceeded}
        nil -> {:error, :issuer_mutation_authority_unavailable}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :issuer_mutation_unauthorized}
      end

    case result do
      {:ok, proof, next_state} -> {:reply, {:ok, proof}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_authenticated_request(
         {:consume_issuer_mutation_attestation, proof, operation, payload_digest},
         {consumer, _tag},
         state
       ) do
    state = prune_issuer_mutation_attestations(state)
    token = if is_map(proof), do: Map.get(proof, :token), else: nil
    {entry, attestations} = Map.pop(Map.get(state, :issuer_mutation_attestations, %{}), token)
    consumed_state = Map.put(state, :issuer_mutation_attestations, attestations)

    reply =
      with :ok <- validate_issuer_mutation_request(operation, payload_digest),
           %{proof: expected, consumer: expected_consumer} <- entry,
           true <- consumer == expected_consumer,
           true <- supervised_registered_child?(state, IssuerRegistry, IssuerRegistry, consumer),
           true <- proof == expected,
           true <- Map.get(proof, :operation) == operation,
           true <- Map.get(proof, :payload_digest) == payload_digest,
           true <-
             Map.get(proof, :authority_fingerprint) == authority_fingerprint(state.identity),
           signature when is_binary(signature) <- Map.get(proof, :signature),
           payload when is_binary(payload) <-
             issuer_mutation_attestation_payload(Map.delete(proof, :signature)),
           true <-
             Crypto.verify(
               payload,
               signature,
               state.identity.public_key
             ) do
        :ok
      else
        _ -> {:error, :issuer_mutation_unauthorized}
      end

    {:reply, reply, consumed_state}
  end

  defp handle_authenticated_request(
         {:issue_issuer_mutation_attestation_proof, actor_proof, operation, payload_digest},
         _from,
         state
       ) do
    state = prune_issuer_mutation_attestations(state)

    result =
      with :ok <- validate_issuer_mutation_request(operation, payload_digest),
           {:ok, canonical_proof} <- SignedRequest.canonicalize(actor_proof),
           {:ok, expected_payload} <- issuer_mutation_request_payload(operation, payload_digest),
           true <- canonical_proof.payload == expected_payload,
           {:ok, actor_id} <- Verifier.verify(canonical_proof),
           true <-
             map_size(Map.get(state, :issuer_mutation_attestations, %{})) <
               @max_issuer_mutation_attestations,
           consumer when is_pid(consumer) <-
             supervised_registered_child_pid(state, IssuerRegistry, IssuerRegistry),
           :ok <-
             authorize_security_mutation_actor(
               actor_id,
               "arbor://security/issuer/#{operation}",
               state
             ) do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        expires_at = DateTime.add(now, @issuer_mutation_attestation_ttl_seconds, :second)
        token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        proof = %{
          v: 1,
          token: token,
          actor_id: actor_id,
          operation: operation,
          payload_digest: payload_digest,
          authority_fingerprint: authority_fingerprint(state.identity),
          issued_at: DateTime.to_iso8601(now),
          expires_at: DateTime.to_iso8601(expires_at)
        }

        signature =
          Crypto.sign(issuer_mutation_attestation_payload(proof), state.identity.private_key)

        signed_proof = Map.put(proof, :signature, signature)

        entry = %{
          proof: signed_proof,
          consumer: consumer,
          expires_mono:
            System.monotonic_time(:millisecond) +
              @issuer_mutation_attestation_ttl_seconds * 1_000
        }

        {:ok, signed_proof, put_issuer_mutation_attestation(state, token, entry)}
      else
        false -> {:error, :issuer_mutation_unauthorized}
        nil -> {:error, :issuer_mutation_authority_unavailable}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :issuer_mutation_unauthorized}
      end

    case result do
      {:ok, proof, next_state} -> {:reply, {:ok, proof}, next_state}
      {:error, _reason} -> {:reply, {:error, :issuer_mutation_unauthorized}, state}
    end
  end

  defp handle_authenticated_request(
         {:issue_identity_registration_attestation, authority, target_digest},
         {owner, _tag},
         state
       ) do
    state = prune_identity_registration_attestations(state)

    result =
      with :ok <- validate_sha256_digest(target_digest),
           true <-
             map_size(Map.get(state, :identity_registration_attestations, %{})) <
               @max_identity_registration_attestations,
           consumer when is_pid(consumer) <-
             supervised_registered_child_pid(state, Registry, Registry),
           {:ok, %{principal_id: actor_id}} <-
             recorded_signing_identity(state, authority, owner),
           :ok <-
             authorize_security_mutation_actor(
               actor_id,
               "arbor://security/identity/register",
               state
             ) do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        expires_at = DateTime.add(now, @identity_registration_attestation_ttl_seconds, :second)
        token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        proof = %{
          v: 1,
          token: token,
          actor_id: actor_id,
          target_digest: target_digest,
          authority_fingerprint: authority_fingerprint(state.identity),
          issued_at: DateTime.to_iso8601(now),
          expires_at: DateTime.to_iso8601(expires_at)
        }

        signature =
          Crypto.sign(
            identity_registration_attestation_payload(proof),
            state.identity.private_key
          )

        signed_proof = Map.put(proof, :signature, signature)

        entry = %{
          proof: signed_proof,
          consumer: consumer,
          expires_mono:
            System.monotonic_time(:millisecond) +
              @identity_registration_attestation_ttl_seconds * 1_000
        }

        {:ok, signed_proof, put_identity_registration_attestation(state, token, entry)}
      else
        false -> {:error, :identity_registration_attestation_capacity_exceeded}
        nil -> {:error, :identity_registration_unavailable}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :identity_registration_unauthorized}
      end

    case result do
      {:ok, proof, next_state} -> {:reply, {:ok, proof}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_authenticated_request(
         {:consume_identity_registration_attestation, proof, target_digest},
         {consumer, _tag},
         state
       ) do
    state = prune_identity_registration_attestations(state)
    token = if is_map(proof), do: Map.get(proof, :token), else: nil

    {entry, attestations} =
      Map.pop(Map.get(state, :identity_registration_attestations, %{}), token)

    consumed_state = Map.put(state, :identity_registration_attestations, attestations)

    reply =
      with :ok <- validate_sha256_digest(target_digest),
           %{proof: expected, consumer: expected_consumer} <- entry,
           true <- consumer == expected_consumer,
           true <- supervised_registered_child?(state, Registry, Registry, consumer),
           true <- proof == expected,
           true <- Map.get(proof, :target_digest) == target_digest,
           true <-
             Map.get(proof, :authority_fingerprint) == authority_fingerprint(state.identity),
           signature when is_binary(signature) <- Map.get(proof, :signature),
           payload when is_binary(payload) <-
             identity_registration_attestation_payload(Map.delete(proof, :signature)),
           true <- Crypto.verify(payload, signature, state.identity.public_key) do
        :ok
      else
        _ -> {:error, :identity_registration_unauthorized}
      end

    {:reply, reply, consumed_state}
  end

  defp handle_authenticated_request(
         {:issue_identity_status_mutation_attestation, authority, operation, agent_id,
          payload_digest},
         {owner, _tag},
         state
       ) do
    state = prune_identity_status_attestations(state)

    result =
      with :ok <- validate_identity_status_mutation_request(operation, agent_id, payload_digest),
           true <-
             map_size(Map.get(state, :identity_status_attestations, %{})) <
               @max_identity_status_attestations,
           consumer when is_pid(consumer) <-
             supervised_registered_child_pid(state, Registry, Registry),
           {:ok, %{principal_id: actor_id}} <-
             recorded_signing_identity(state, authority, owner),
           :ok <-
             authorize_security_mutation_actor(
               actor_id,
               "arbor://security/identity/#{operation}/#{agent_id}",
               state
             ) do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        expires_at = DateTime.add(now, @identity_status_attestation_ttl_seconds, :second)
        token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        proof = %{
          v: 1,
          token: token,
          actor_id: actor_id,
          operation: operation,
          agent_id: agent_id,
          payload_digest: payload_digest,
          authority_fingerprint: authority_fingerprint(state.identity),
          issued_at: DateTime.to_iso8601(now),
          expires_at: DateTime.to_iso8601(expires_at)
        }

        signature =
          Crypto.sign(identity_status_attestation_payload(proof), state.identity.private_key)

        signed_proof = Map.put(proof, :signature, signature)

        entry = %{
          proof: signed_proof,
          consumer: consumer,
          expires_mono:
            System.monotonic_time(:millisecond) +
              @identity_status_attestation_ttl_seconds * 1_000
        }

        {:ok, signed_proof, put_identity_status_attestation(state, token, entry)}
      else
        false -> {:error, :identity_status_attestation_capacity_exceeded}
        nil -> {:error, :identity_status_mutation_unavailable}
        {:error, _reason} -> {:error, :identity_status_mutation_unauthorized}
        _ -> {:error, :identity_status_mutation_unauthorized}
      end

    case result do
      {:ok, proof, next_state} -> {:reply, {:ok, proof}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_authenticated_request(
         {:consume_identity_status_mutation_attestation, proof, operation, payload_digest},
         {consumer, _tag},
         state
       ) do
    state = prune_identity_status_attestations(state)
    token = if is_map(proof), do: Map.get(proof, :token), else: nil
    {entry, attestations} = Map.pop(Map.get(state, :identity_status_attestations, %{}), token)
    consumed_state = Map.put(state, :identity_status_attestations, attestations)

    reply =
      with agent_id when is_binary(agent_id) <-
             if(is_map(proof), do: Map.get(proof, :agent_id)),
           :ok <-
             validate_identity_status_mutation_request(operation, agent_id, payload_digest),
           %{proof: expected, consumer: expected_consumer} <- entry,
           true <- consumer == expected_consumer,
           true <- supervised_registered_child?(state, Registry, Registry, consumer),
           true <- proof == expected,
           true <- Map.get(proof, :operation) == operation,
           true <- Map.get(proof, :payload_digest) == payload_digest,
           true <-
             Map.get(proof, :authority_fingerprint) == authority_fingerprint(state.identity),
           signature when is_binary(signature) <- Map.get(proof, :signature),
           payload when is_binary(payload) <-
             identity_status_attestation_payload(Map.delete(proof, :signature)),
           true <- Crypto.verify(payload, signature, state.identity.public_key) do
        :ok
      else
        _ -> {:error, :identity_status_mutation_unauthorized}
      end

    {:reply, reply, consumed_state}
  end

  defp handle_authenticated_request(
         {:authorize_capability_mutation, authority, operation, cap},
         {owner, _tag},
         state
       ) do
    state = prune_capability_mutation_attestations(state)

    result =
      with :ok <- validate_capability_mutation_request(operation, cap),
           true <-
             map_size(Map.get(state, :capability_mutation_attestations, %{})) <
               @max_capability_mutation_attestations,
           consumer when is_pid(consumer) <-
             supervised_registered_child_pid(state, CapabilityStore, CapabilityStore),
           {:ok, %{principal_id: actor_id}} <-
             recorded_signing_identity(state, authority, owner),
           true <- capability_granter_id(cap) == actor_id,
           :ok <- authorize_capability_mutation_actor(actor_id, operation, cap, state) do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        expires_at = DateTime.add(now, @capability_mutation_attestation_ttl_seconds, :second)
        token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        digest = capability_mutation_digest(cap)

        proof = %{
          v: 1,
          token: token,
          actor_id: actor_id,
          operation: operation,
          capability_digest: digest,
          authority_fingerprint: authority_fingerprint(state.identity),
          issued_at: DateTime.to_iso8601(now),
          expires_at: DateTime.to_iso8601(expires_at)
        }

        signature =
          Crypto.sign(capability_mutation_attestation_payload(proof), state.identity.private_key)

        signed_proof = Map.put(proof, :signature, signature)

        entry = %{
          proof: signed_proof,
          consumer: consumer,
          expires_mono:
            System.monotonic_time(:millisecond) +
              @capability_mutation_attestation_ttl_seconds * 1_000
        }

        {:ok, cap, signed_proof, put_capability_mutation_attestation(state, token, entry)}
      else
        false -> {:error, :capability_mutation_unauthorized}
        nil -> {:error, :capability_store_unavailable}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :capability_mutation_unauthorized}
      end

    case result do
      {:ok, authorized_cap, proof, next_state} ->
        {:reply, {:ok, authorized_cap, proof}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_authenticated_request(
         {:authorize_capability_mutation_proof, actor_proof, operation, cap},
         _from,
         state
       ) do
    state = prune_capability_mutation_attestations(state)

    result =
      with :ok <- validate_capability_mutation_request(operation, cap),
           {:ok, canonical_proof} <- SignedRequest.canonicalize(actor_proof),
           {:ok, expected_payload} <- capability_mutation_request_payload(operation, cap),
           true <- canonical_proof.payload == expected_payload,
           {:ok, actor_id} <- Verifier.verify(canonical_proof),
           true <- capability_granter_id(cap) == actor_id,
           true <-
             map_size(Map.get(state, :capability_mutation_attestations, %{})) <
               @max_capability_mutation_attestations,
           consumer when is_pid(consumer) <-
             supervised_registered_child_pid(state, CapabilityStore, CapabilityStore),
           :ok <- authorize_capability_mutation_actor(actor_id, operation, cap, state) do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        expires_at = DateTime.add(now, @capability_mutation_attestation_ttl_seconds, :second)
        token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        digest = capability_mutation_digest(cap)

        proof = %{
          v: 1,
          token: token,
          actor_id: actor_id,
          operation: operation,
          capability_digest: digest,
          authority_fingerprint: authority_fingerprint(state.identity),
          issued_at: DateTime.to_iso8601(now),
          expires_at: DateTime.to_iso8601(expires_at)
        }

        signature =
          Crypto.sign(capability_mutation_attestation_payload(proof), state.identity.private_key)

        signed_proof = Map.put(proof, :signature, signature)

        entry = %{
          proof: signed_proof,
          consumer: consumer,
          expires_mono:
            System.monotonic_time(:millisecond) +
              @capability_mutation_attestation_ttl_seconds * 1_000
        }

        {:ok, cap, signed_proof, put_capability_mutation_attestation(state, token, entry)}
      else
        false -> {:error, :capability_mutation_unauthorized}
        nil -> {:error, :capability_store_unavailable}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :capability_mutation_unauthorized}
      end

    case result do
      {:ok, authorized_cap, proof, next_state} ->
        {:reply, {:ok, authorized_cap, proof}, next_state}

      {:error, _reason} ->
        {:reply, {:error, :capability_mutation_unauthorized}, state}
    end
  end

  defp handle_authenticated_request(
         {:consume_capability_mutation_attestation, proof, operation, cap},
         {consumer, _tag},
         state
       ) do
    state = prune_capability_mutation_attestations(state)
    token = if is_map(proof), do: Map.get(proof, :token), else: nil

    {entry, attestations} =
      Map.pop(Map.get(state, :capability_mutation_attestations, %{}), token)

    consumed_state = Map.put(state, :capability_mutation_attestations, attestations)

    reply =
      with :ok <- validate_capability_mutation_request(operation, cap),
           %{proof: expected, consumer: expected_consumer} <- entry,
           true <- consumer == expected_consumer,
           true <-
             supervised_registered_child?(state, CapabilityStore, CapabilityStore, consumer),
           true <- proof == expected,
           true <- Map.get(proof, :operation) == operation,
           true <- Map.get(proof, :capability_digest) == capability_mutation_digest(cap),
           true <- Map.get(proof, :actor_id) == capability_granter_id(cap),
           true <-
             Map.get(proof, :authority_fingerprint) == authority_fingerprint(state.identity),
           signature when is_binary(signature) <- Map.get(proof, :signature),
           payload when is_binary(payload) <-
             capability_mutation_attestation_payload(Map.delete(proof, :signature)),
           true <- Crypto.verify(payload, signature, state.identity.public_key) do
        :ok
      else
        _ -> {:error, :capability_mutation_unauthorized}
      end

    {:reply, reply, consumed_state}
  end

  defp handle_authenticated_request(
         {:issue_capability_revocation_attestation, authority, operation, target},
         {owner, _tag},
         state
       ) do
    state = prune_capability_revocation_attestations(state)

    result =
      with {:ok, target_digest, authorization_resource} <-
             canonical_capability_revocation_target(operation, target),
           true <-
             map_size(Map.get(state, :capability_revocation_attestations, %{})) <
               @max_capability_revocation_attestations,
           consumer when is_pid(consumer) <-
             supervised_registered_child_pid(state, CapabilityStore, CapabilityStore),
           {:ok, %{principal_id: actor_id}} <-
             recorded_signing_identity(state, authority, owner),
           :ok <-
             authorize_capability_revocation_actor(
               actor_id,
               authorization_resource,
               state
             ) do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        expires_at = DateTime.add(now, @capability_revocation_attestation_ttl_seconds, :second)
        token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        proof = %{
          v: 1,
          token: token,
          actor_id: actor_id,
          operation: operation,
          target_digest: target_digest,
          authorization_resource: authorization_resource,
          authority_fingerprint: authority_fingerprint(state.identity),
          issued_at: DateTime.to_iso8601(now),
          expires_at: DateTime.to_iso8601(expires_at)
        }

        signature =
          Crypto.sign(
            capability_revocation_attestation_payload(proof),
            state.identity.private_key
          )

        signed_proof = Map.put(proof, :signature, signature)

        entry = %{
          proof: signed_proof,
          consumer: consumer,
          expires_mono:
            System.monotonic_time(:millisecond) +
              @capability_revocation_attestation_ttl_seconds * 1_000
        }

        {:ok, signed_proof, put_capability_revocation_attestation(state, token, entry)}
      else
        false -> {:error, :capability_revocation_attestation_capacity_exceeded}
        nil -> {:error, :capability_store_unavailable}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :capability_revocation_unauthorized}
      end

    case result do
      {:ok, proof, next_state} -> {:reply, {:ok, proof}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_authenticated_request(
         {:consume_capability_revocation_attestation, proof, operation, target},
         {consumer, _tag},
         state
       ) do
    state = prune_capability_revocation_attestations(state)
    token = if is_map(proof), do: Map.get(proof, :token), else: nil

    {entry, attestations} =
      Map.pop(Map.get(state, :capability_revocation_attestations, %{}), token)

    consumed_state = Map.put(state, :capability_revocation_attestations, attestations)

    reply =
      with {:ok, target_digest, authorization_resource} <-
             canonical_capability_revocation_target(operation, target),
           %{proof: expected, consumer: expected_consumer} <- entry,
           true <- consumer == expected_consumer,
           true <-
             supervised_registered_child?(state, CapabilityStore, CapabilityStore, consumer),
           true <- proof == expected,
           true <- Map.get(proof, :operation) == operation,
           true <- Map.get(proof, :target_digest) == target_digest,
           true <- Map.get(proof, :authorization_resource) == authorization_resource,
           true <-
             Map.get(proof, :authority_fingerprint) == authority_fingerprint(state.identity),
           signature when is_binary(signature) <- Map.get(proof, :signature),
           payload when is_binary(payload) <-
             capability_revocation_attestation_payload(Map.delete(proof, :signature)),
           true <- Crypto.verify(payload, signature, state.identity.public_key) do
        :ok
      else
        _ -> {:error, :capability_revocation_unauthorized}
      end

    {:reply, reply, consumed_state}
  end

  defp handle_authenticated_request(
         {:sign_capability_from_store, cap},
         {caller, _reply_to},
         %{identity: identity} = state
       ) do
    if supervised_registered_child?(state, CapabilityStore, CapabilityStore, caller) do
      {:reply, {:ok, sign_capability_with_identity(cap, identity)}, state}
    else
      {:reply, {:error, :capability_signing_unauthorized}, state}
    end
  end

  defp handle_authenticated_request(
         {:sign_receipt_from_broker, receipt},
         {caller, _reply_to},
         %{identity: identity} = state
       ) do
    if supervised_registered_child?(
         state,
         Arbor.Security.InvocationReceiptBroker,
         Arbor.Security.InvocationReceiptBroker,
         caller
       ) do
      # Set issuer_id before computing the payload so the signature covers it.
      receipt = Map.put(receipt, :issuer_id, identity.agent_id)
      payload = InvocationReceipt.signing_payload(receipt)
      signature = Crypto.sign(payload, identity.private_key)
      {:reply, {:ok, Map.put(receipt, :signature, signature)}, state}
    else
      {:reply, {:error, :receipt_signing_unauthorized}, state}
    end
  end

  defp handle_authenticated_request(_request, _caller, state),
    do: {:reply, {:error, :system_authority_unauthorized}, state}

  defp handle_private_info({:private_memory_authorized, reference, worker, result}, state) do
    case Map.get(Map.get(state, :memory_attestations, %{}), reference) do
      %{worker: ^worker} = job ->
        reply = finish_memory_attestation(state, job, result)
        complete_memory_attestation(state, reference, reply)

      _ ->
        {:noreply, state}
    end
  end

  defp handle_private_info({:private_memory_deadline, reference}, state),
    do: complete_memory_attestation(state, reference, {:error, :memory_attestation_unavailable})

  defp handle_private_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(Map.get(state, :memory_attestations, %{}), fn {_ref, job} ->
           monitor in [job.worker_monitor, job.owner_monitor]
         end) do
      {reference, _job} ->
        complete_memory_attestation(state, reference, {:error, :memory_attestation_unavailable})

      nil ->
        {:noreply, state}
    end
  end

  defp handle_private_info({:EXIT, _worker, _reason}, state), do: {:noreply, state}

  defp handle_private_info(message, %{initialization: :pending} = state) do
    case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
      {:authenticated, _caller, _request, reply_to} ->
        :ok =
          Arbor.Common.reply_authenticated_call(
            reply_to,
            {:error, :system_authority_unavailable}
          )

        {:noreply, state}

      result when result in [:pending, :expired, :rejected, :unrecognized] ->
        {:noreply, state}
    end
  end

  defp handle_private_info(message, state) do
    case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
      {:authenticated, caller, request, reply_to} ->
        case handle_authenticated_request(request, {caller, reply_to}, state) do
          {:reply, reply, next_state} ->
            :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
            {:noreply, next_state}

          {:noreply, next_state} ->
            {:noreply, next_state}

          {:stop, reason, reply, next_state} ->
            :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
            {:stop, reason, next_state}
        end

      result when result in [:pending, :expired, :rejected, :unrecognized] ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(message, private_state) do
    with {:ok, state} <- private_state(private_state) do
      case handle_private_info(message, state) do
        {:noreply, next_state} ->
          case put_private_state(private_state, next_state) do
            :ok -> {:noreply, private_state}
            {:error, _reason} -> {:stop, :invalid_private_state, private_state}
          end

        {:stop, reason, next_state} ->
          _ = put_private_state(private_state, next_state)
          {:stop, reason, private_state}
      end
    else
      {:error, _reason} -> {:stop, :invalid_private_state, private_state}
    end
  end

  @impl true
  def terminate(_reason, private_state) do
    case private_state(private_state) do
      {:ok, state} ->
        Enum.each(Map.get(state, :memory_attestations, %{}), fn {_ref, job} ->
          cleanup_memory_attestation(job)
        end)

      {:error, _reason} ->
        :ok
    end

    PrivateState.delete(private_state, @private_state_anchor)
    :ok
  end

  @impl true
  def format_status(status) when is_map(status) do
    Map.new(status, fn
      {:state, _} -> {:state, %{system_authority: :redacted}}
      {key, _} when key in [:message, :reason, :log] -> {key, :redacted}
      entry -> entry
    end)
  end

  defp private_state(state) do
    PrivateState.fetch(
      state,
      @private_state_anchor,
      @private_state_schema,
      &valid_private_state?/1
    )
  end

  defp put_private_state(handle, state) do
    PrivateState.replace(
      handle,
      @private_state_anchor,
      @private_state_schema,
      state,
      &valid_private_state?/1
    )
  end

  defp valid_private_state?(
         %{
           authenticated_calls: authenticated_calls,
           initialization: :pending,
           registration_token_source: source,
           security_supervisor_pid: supervisor
         } = state
       ) do
    Map.keys(state) |> Enum.sort() ==
      [
        :authenticated_calls,
        :initialization,
        :registration_token_source,
        :security_supervisor_pid
      ] and
      is_reference(authenticated_calls) and
      (is_reference(source) or source == :test_registry_lookup) and is_pid(supervisor)
  end

  defp valid_private_state?(
         %{
           identity: %Identity{} = identity,
           private_memory_root_ready: root_ready,
           security_supervisor_pid: supervisor,
           system_authority_registration_token: registration_token,
           authenticated_calls: authenticated_calls
         } = state
       ) do
    allowed_keys =
      MapSet.new([
        :authenticated_calls,
        :capability_mutation_attestations,
        :capability_revocation_attestations,
        :identity,
        :identity_registration_attestations,
        :identity_status_attestations,
        :issuer_mutation_attestations,
        :memory_attestations,
        :private_memory_root_ready,
        :security_supervisor_pid,
        :system_authority_registration_token
      ])

    MapSet.subset?(MapSet.new(Map.keys(state)), allowed_keys) and
      is_binary(identity.private_key) and
      (is_nil(identity.encryption_private_key) or is_binary(identity.encryption_private_key)) and
      is_boolean(root_ready) and is_pid(supervisor) and is_reference(registration_token) and
      is_reference(authenticated_calls) and
      Enum.all?(
        [
          :capability_mutation_attestations,
          :capability_revocation_attestations,
          :identity_registration_attestations,
          :identity_status_attestations,
          :issuer_mutation_attestations,
          :memory_attestations
        ],
        fn key -> not Map.has_key?(state, key) or is_map(Map.fetch!(state, key)) end
      )
  end

  defp valid_private_state?(_state), do: false

  # Normal capability authorization verifies signatures through this GenServer.
  # A bounded linked worker keeps the root responsive during that check; only
  # this owner retains the key and performs the eventual signature.
  defp start_memory_attestation(state, from, token, scope, descriptor, purpose \\ :record)

  defp start_memory_attestation(state, {owner, _} = from, token, scope, descriptor, purpose) do
    root = self()
    reference = make_ref()

    {worker, worker_monitor} =
      :erlang.spawn_opt(
        fn ->
          result = authorize_memory_attestation(scope, purpose)
          send(root, {:private_memory_authorized, reference, self(), result})
        end,
        [:link, :monitor]
      )

    timeout = Config.private_memory_attestation_timeout_ms()

    job = %{
      from: from,
      owner: owner,
      token: token,
      scope: scope,
      descriptor: descriptor,
      purpose: purpose,
      issuer_id: state.identity.agent_id,
      worker: worker,
      worker_monitor: worker_monitor,
      owner_monitor: Process.monitor(owner),
      deadline: System.monotonic_time(:millisecond) + timeout,
      timer: Process.send_after(self(), {:private_memory_deadline, reference}, timeout)
    }

    pending = Map.put(Map.get(state, :memory_attestations, %{}), reference, job)
    {:noreply, Map.put(state, :memory_attestations, pending)}
  end

  defp finish_memory_attestation(state, job, :ok) do
    with true <- System.monotonic_time(:millisecond) < job.deadline,
         true <- state.identity.agent_id == job.issuer_id,
         true <- Map.get(state, :private_memory_root_ready, false),
         {:ok, scope} <- DeliveryReceiptBroker.memory_attestation_scope(job.token, job.owner),
         true <- scope == job.scope do
      sign_memory_attestation(job, scope, state.identity)
    else
      _ -> {:error, :memory_attestation_unavailable}
    end
  end

  defp finish_memory_attestation(_state, _job, error), do: error

  defp authorize_memory_attestation(scope, {:from_source, source, stamp}) do
    with :ok <- PrivateMemory.authorize_scope(scope, :write),
         do: PrivateMemory.verify_source(source, stamp)
  end

  defp authorize_memory_attestation(scope, _purpose),
    do: PrivateMemory.authorize_scope(scope, :write)

  defp sign_memory_attestation(
         %{purpose: :relationship_snapshot, descriptor: descriptor},
         scope,
         identity
       ) do
    if PrivateRelationshipSnapshot.scope_matches?(descriptor, scope),
      do: PrivateRelationshipSnapshot.sign(descriptor, identity),
      else: {:error, :invalid_private_relationship_snapshot}
  end

  defp sign_memory_attestation(%{purpose: :source, descriptor: descriptor}, scope, identity) do
    if PrivateMemorySource.scope_matches?(descriptor, scope),
      do: PrivateMemorySource.sign(descriptor, identity),
      else: {:error, :invalid_memory_source}
  end

  defp sign_memory_attestation(
         %{purpose: {:from_source, source, stamp}, descriptor: descriptor},
         scope,
         identity
       ) do
    # Recheck the original proof against this exact root after the correlated
    # worker returns. No public verification call re-enters this GenServer.
    with true <- PrivateMemorySource.pair_matches?(source, scope),
         true <- PrivateMemorySource.binds_record?(source, descriptor),
         :ok <- PrivateMemorySource.verify(source, stamp, identity) do
      PrivateMemoryRecord.sign(descriptor, identity)
    else
      _ -> {:error, :invalid_memory_source}
    end
  end

  defp sign_memory_attestation(%{purpose: :goal_snapshot} = job, scope, identity) do
    if PrivateGoalSnapshot.scope_matches?(job.descriptor, scope),
      do: PrivateGoalSnapshot.sign(job.descriptor, identity),
      else: {:error, :invalid_private_goal_snapshot}
  end

  defp sign_memory_attestation(%{purpose: :record, descriptor: descriptor}, scope, identity) do
    if PrivateMemoryRecord.scope_matches?(descriptor, scope),
      do: PrivateMemoryRecord.sign(descriptor, identity),
      else: {:error, :invalid_memory_record}
  end

  defp complete_memory_attestation(state, reference, reply) do
    case Map.pop(Map.get(state, :memory_attestations, %{}), reference) do
      {nil, _} ->
        {:noreply, state}

      {job, pending} ->
        cleanup_memory_attestation(job)
        {_caller, reply_to} = job.from
        :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
        {:noreply, Map.put(state, :memory_attestations, pending)}
    end
  end

  defp cleanup_memory_attestation(job) do
    Process.cancel_timer(job.timer)
    if Process.alive?(job.worker), do: Process.exit(job.worker, :kill)
    Process.unlink(job.worker)
    Process.demonitor(job.worker_monitor, [:flush])
    Process.demonitor(job.owner_monitor, [:flush])
  end

  defp rotate_identity(old_identity, new_identity, state) do
    with :ok <-
           register_public_identity(
             new_identity,
             state.system_authority_registration_token,
             state.security_supervisor_pid
           ),
         :ok <- maybe_persist_rotation(new_identity) do
      result = %{
        old_agent_id: old_identity.agent_id,
        new_agent_id: new_identity.agent_id
      }

      state =
        Map.merge(state, %{
          identity: new_identity,
          issuer_mutation_attestations: %{},
          identity_registration_attestations: %{},
          identity_status_attestations: %{},
          capability_mutation_attestations: %{},
          capability_revocation_attestations: %{},
          private_memory_root_ready:
            Config.system_authority_mode() == :persistent and
              durable_root_store?()
        })

      {:reply, {:ok, result}, state}
    else
      {:error, :outcome_unknown} ->
        # The bundle may have committed. Stop after replying so supervision
        # reloads the authoritative record instead of continuing with a live
        # root that may differ from restart truth.
        {:stop, :authority_rotation_outcome_unknown,
         {:error, {:rotation_failed, :outcome_unknown}}, state}

      {:error, reason} ->
        {:reply, {:error, {:rotation_failed, normalize_rotation_error(reason)}}, state}
    end
  end

  defp maybe_persist_rotation(identity) do
    if Config.system_authority_mode() == :persistent,
      do: persist_keypair(identity),
      else: :ok
  end

  defp normalize_rotation_error(reason)
       when reason in [
              :store_unavailable,
              :invalid_store_record,
              :store_capacity_exceeded,
              :key_encryption_unavailable,
              :invalid_authority_identity,
              :registration_unavailable,
              :registration_conflict
            ],
       do: reason

  defp normalize_rotation_error(_reason), do: :rotation_unavailable

  defp validate_issuer_mutation_request(operation, payload_digest)
       when operation in [:register, :update, :revoke] and is_binary(payload_digest) do
    if byte_size(payload_digest) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, payload_digest),
      do: :ok,
      else: {:error, :issuer_mutation_unauthorized}
  end

  defp validate_issuer_mutation_request(_operation, _payload_digest),
    do: {:error, :issuer_mutation_unauthorized}

  defp rotate_to_fresh_identity(old_identity, state) do
    case Identity.generate() do
      {:ok, new_identity} -> rotate_identity(old_identity, new_identity, state)
      {:error, reason} -> {:reply, {:error, {:rotation_failed, reason}}, state}
    end
  end

  defp authorize_security_mutation_actor(actor_id, resource, state)
       when is_binary(actor_id) and is_binary(resource) do
    with {:ok, :active} <- registry_identity_status(state, actor_id),
         {:ok, capabilities} <- capability_store_list_for_principal(state, actor_id),
         true <-
           Enum.any?(capabilities, fn cap ->
             Capability.valid?(cap) and Capability.grants_access?(cap, resource) and
               verify_capability_signature_safe(cap, state) == :ok and
               Signer.verify_delegation_chain(cap, &registry_lookup(state, &1)) == :ok
           end) do
      :ok
    else
      _ -> {:error, :security_mutation_unauthorized}
    end
  rescue
    _ -> {:error, :security_mutation_unauthorized}
  catch
    _, _ -> {:error, :security_mutation_unauthorized}
  end

  defp authorize_security_mutation_actor(_actor_id, _resource, _state),
    do: {:error, :security_mutation_unauthorized}

  defp authorize_capability_revocation_actor(actor_id, resource, state) do
    case authorize_security_mutation_actor(actor_id, resource, state) do
      :ok -> :ok
      _ -> {:error, :capability_revocation_unauthorized}
    end
  end

  defp supervised_registered_child_pid(state, child_id, registered_name) do
    with supervisor when is_pid(supervisor) <- Map.get(state, :security_supervisor_pid),
         true <- Process.alive?(supervisor),
         {^child_id, child_pid, _type, _modules} when is_pid(child_pid) <-
           Enum.find(Supervisor.which_children(supervisor), fn
             {id, _pid, _type, _modules} -> id == child_id
             _ -> false
           end),
         true <- Process.whereis(registered_name) == child_pid do
      child_pid
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp supervised_registered_child?(state, child_id, registered_name, caller)
       when is_pid(caller) do
    supervised_registered_child_pid(state, child_id, registered_name) == caller
  end

  defp supervised_registered_child?(_state, _child_id, _registered_name, _caller), do: false

  defp registry_lookup(state, agent_id) do
    case supervised_registered_child_pid(state, Registry, Registry) do
      pid when is_pid(pid) -> GenServer.call(pid, {:lookup, agent_id})
      _ -> {:error, :not_found}
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  defp registry_identity_status(state, agent_id) do
    case supervised_registered_child_pid(state, Registry, Registry) do
      pid when is_pid(pid) -> GenServer.call(pid, {:get_status, agent_id})
      _ -> {:error, :not_found}
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  defp capability_store_get(state, capability_id) do
    case supervised_registered_child_pid(state, CapabilityStore, CapabilityStore) do
      pid when is_pid(pid) -> GenServer.call(pid, {:get, capability_id})
      _ -> {:error, :not_found}
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  defp capability_store_list_for_principal(state, principal_id) do
    case supervised_registered_child_pid(state, CapabilityStore, CapabilityStore) do
      pid when is_pid(pid) -> GenServer.call(pid, {:list_for_principal, principal_id, []})
      _ -> {:error, :capability_store_unavailable}
    end
  catch
    :exit, _ -> {:error, :capability_store_unavailable}
  end

  defp issuer_registry_lookup(state, issuer_id) do
    case supervised_registered_child_pid(state, IssuerRegistry, IssuerRegistry) do
      pid when is_pid(pid) -> GenServer.call(pid, {:lookup, issuer_id})
      _ -> {:error, :not_found}
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  defp recorded_signing_identity(state, authority, owner) when is_pid(owner) do
    with {:ok, canonical} <- SigningAuthority.canonicalize(authority),
         broker when is_pid(broker) <-
           supervised_registered_child_pid(
             state,
             SigningAuthorityBroker,
             SigningAuthorityBroker
           ) do
      SigningAuthorityBroker.recorded_identity(canonical, owner)
    else
      _ -> {:error, :invalid_signing_authority}
    end
  catch
    :exit, _ -> {:error, :invalid_signing_authority}
  end

  defp recorded_signing_identity(_state, _authority, _owner),
    do: {:error, :invalid_signing_authority}

  defp validate_endorsement_target(%Identity{agent_id: agent_id, public_key: public_key})
       when is_binary(agent_id) and is_binary(public_key) and byte_size(public_key) == 32 do
    if Identity.derive_agent_id(public_key) == agent_id,
      do: :ok,
      else: {:error, :identity_endorsement_unauthorized}
  end

  defp validate_endorsement_target(_identity),
    do: {:error, :identity_endorsement_unauthorized}

  defp authorize_endorsement_actor(actor_id, target_id, state) do
    resource =
      if actor_id == target_id,
        do: "arbor://agent/identity",
        else: "arbor://security/identity/endorse/#{target_id}"

    case authorize_security_mutation_actor(actor_id, resource, state) do
      :ok -> :ok
      _ -> {:error, :identity_endorsement_unauthorized}
    end
  end

  defp put_issuer_mutation_attestation(state, token, entry) do
    attestations =
      state
      |> Map.get(:issuer_mutation_attestations, %{})
      |> Map.put(token, entry)

    Map.put(state, :issuer_mutation_attestations, attestations)
  end

  defp prune_issuer_mutation_attestations(state) do
    now = System.monotonic_time(:millisecond)

    attestations =
      state
      |> Map.get(:issuer_mutation_attestations, %{})
      |> Map.reject(fn {_token, entry} ->
        not is_map(entry) or not is_integer(Map.get(entry, :expires_mono)) or
          entry.expires_mono <= now
      end)

    Map.put(state, :issuer_mutation_attestations, attestations)
  end

  defp put_identity_registration_attestation(state, token, entry) do
    attestations =
      state
      |> Map.get(:identity_registration_attestations, %{})
      |> Map.put(token, entry)

    Map.put(state, :identity_registration_attestations, attestations)
  end

  defp prune_identity_registration_attestations(state) do
    now = System.monotonic_time(:millisecond)

    attestations =
      state
      |> Map.get(:identity_registration_attestations, %{})
      |> Map.reject(fn {_token, entry} ->
        not is_map(entry) or not is_integer(Map.get(entry, :expires_mono)) or
          entry.expires_mono <= now
      end)

    Map.put(state, :identity_registration_attestations, attestations)
  end

  defp put_identity_status_attestation(state, token, entry) do
    attestations =
      state
      |> Map.get(:identity_status_attestations, %{})
      |> Map.put(token, entry)

    Map.put(state, :identity_status_attestations, attestations)
  end

  defp prune_identity_status_attestations(state) do
    now = System.monotonic_time(:millisecond)

    attestations =
      state
      |> Map.get(:identity_status_attestations, %{})
      |> Map.reject(fn {_token, entry} ->
        not is_map(entry) or not is_integer(Map.get(entry, :expires_mono)) or
          entry.expires_mono <= now
      end)

    Map.put(state, :identity_status_attestations, attestations)
  end

  defp issuer_mutation_attestation_payload(proof) when is_map(proof) do
    values = [
      @issuer_mutation_attestation_version,
      Map.get(proof, :token),
      Map.get(proof, :actor_id),
      proof |> Map.get(:operation) |> encode_operation(),
      Map.get(proof, :payload_digest),
      Map.get(proof, :authority_fingerprint),
      Map.get(proof, :issued_at),
      Map.get(proof, :expires_at)
    ]

    if Enum.all?(values, &(is_binary(&1) and byte_size(&1) > 0)) do
      Enum.map_join(values, &issuer_attestation_length_prefix/1)
    else
      :invalid_issuer_mutation_attestation
    end
  end

  defp issuer_mutation_attestation_payload(_proof),
    do: :invalid_issuer_mutation_attestation

  defp identity_registration_attestation_payload(proof) when is_map(proof) do
    values = [
      @identity_registration_attestation_version,
      Map.get(proof, :token),
      Map.get(proof, :actor_id),
      Map.get(proof, :target_digest),
      Map.get(proof, :authority_fingerprint),
      Map.get(proof, :issued_at),
      Map.get(proof, :expires_at)
    ]

    if Enum.all?(values, &(is_binary(&1) and byte_size(&1) > 0)) do
      Enum.map_join(values, &issuer_attestation_length_prefix/1)
    else
      :invalid_identity_registration_attestation
    end
  end

  defp identity_registration_attestation_payload(_proof),
    do: :invalid_identity_registration_attestation

  defp identity_status_attestation_payload(proof) when is_map(proof) do
    values = [
      @identity_status_attestation_version,
      Map.get(proof, :token),
      Map.get(proof, :actor_id),
      proof |> Map.get(:operation) |> encode_identity_status_operation(),
      Map.get(proof, :agent_id),
      Map.get(proof, :payload_digest),
      Map.get(proof, :authority_fingerprint),
      Map.get(proof, :issued_at),
      Map.get(proof, :expires_at)
    ]

    if Enum.all?(values, &(is_binary(&1) and byte_size(&1) > 0)) do
      Enum.map_join(values, &issuer_attestation_length_prefix/1)
    else
      :invalid_identity_status_attestation
    end
  end

  defp identity_status_attestation_payload(_proof),
    do: :invalid_identity_status_attestation

  defp validate_identity_status_mutation_request(operation, agent_id, payload_digest)
       when operation in [:deregister, :revoke, :suspend, :resume] and is_binary(agent_id) do
    with true <- valid_principal_id?(agent_id),
         :ok <- validate_sha256_digest(payload_digest) do
      :ok
    else
      _ -> {:error, :identity_status_mutation_unauthorized}
    end
  end

  defp validate_identity_status_mutation_request(_operation, _agent_id, _payload_digest),
    do: {:error, :identity_status_mutation_unauthorized}

  defp encode_identity_status_operation(operation)
       when operation in [:deregister, :revoke, :suspend, :resume],
       do: Atom.to_string(operation)

  defp encode_identity_status_operation(_operation), do: ""

  defp validate_sha256_digest(digest) when is_binary(digest) do
    if byte_size(digest) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
      do: :ok,
      else: {:error, :invalid_digest}
  end

  defp validate_sha256_digest(_digest), do: {:error, :invalid_digest}

  defp validate_capability_mutation_request(operation, %Capability{} = cap)
       when operation in [:grant, :acknowledged_grant, :delegate] do
    cond do
      not is_nil(cap.issuer_id) or not is_nil(cap.issuer_signature) ->
        {:error, :capability_mutation_unauthorized}

      not is_map(cap.metadata) ->
        {:error, :capability_mutation_unauthorized}

      Map.has_key?(cap.metadata, :granter_id) ->
        {:error, :capability_mutation_unauthorized}

      not valid_principal_id?(capability_granter_id(cap)) ->
        {:error, :capability_mutation_unauthorized}

      true ->
        :ok
    end
  end

  defp validate_capability_mutation_request(_operation, _cap),
    do: {:error, :capability_mutation_unauthorized}

  defp authorize_capability_mutation_actor(actor_id, operation, cap, state)
       when operation in [:grant, :acknowledged_grant] do
    case authorize_security_mutation_actor(
           actor_id,
           "arbor://security/grant/#{cap.principal_id}",
           state
         ) do
      :ok -> :ok
      _ -> {:error, :capability_mutation_unauthorized}
    end
  end

  defp authorize_capability_mutation_actor(actor_id, :delegate, cap, state) do
    with %{delegator_id: ^actor_id} <- normalize_final_delegation_record(cap.delegation_chain),
         {:ok, parent} <- capability_store_get(state, cap.parent_capability_id),
         true <- parent.id == cap.parent_capability_id,
         true <- parent.principal_id == actor_id,
         true <- Capability.valid?(parent),
         true <- Capability.envelope_subset?(cap, parent),
         true <- delegation_scope_attenuated?(cap, parent),
         :ok <- verify_capability_signature_safe(parent, state),
         :ok <- Signer.verify_delegation_chain(parent, &registry_lookup(state, &1)),
         :ok <- Signer.verify_delegation_chain(cap, &registry_lookup(state, &1)) do
      :ok
    else
      _ -> {:error, :capability_mutation_unauthorized}
    end
  rescue
    _ -> {:error, :capability_mutation_unauthorized}
  catch
    _, _ -> {:error, :capability_mutation_unauthorized}
  end

  defp authorize_capability_mutation_actor(_actor_id, _operation, _cap, _state),
    do: {:error, :capability_mutation_unauthorized}

  defp normalize_final_delegation_record(records) when is_list(records) and records != [] do
    case List.last(records) do
      %{delegator_id: delegator_id} -> %{delegator_id: delegator_id}
      %{"delegator_id" => delegator_id} -> %{delegator_id: delegator_id}
      _ -> nil
    end
  end

  defp normalize_final_delegation_record(_records), do: nil

  # Capability.delegate/3 applies these rules during ordinary construction, but
  # the authority boundary rechecks every signed field independently. That
  # prevents a caller from constructing a Capability struct by hand and using a
  # correctly signed delegation link to widen a session/task/principal binding
  # or the downstream delegatee allowlist.
  defp delegation_scope_attenuated?(%Capability{} = child, %Capability{} = parent) do
    child.parent_capability_id == parent.id and
      child.delegation_depth >= 0 and
      child.delegation_depth < parent.delegation_depth and
      datetime_not_earlier?(child.not_before, parent.not_before) and
      datetime_not_later?(child.expires_at, parent.expires_at) and
      integer_limit_attenuated?(child.max_uses, parent.max_uses) and
      binding_attenuated?(child.session_id, parent.session_id) and
      binding_attenuated?(child.task_id, parent.task_id) and
      binding_attenuated?(child.principal_scope, parent.principal_scope) and
      delegatees_attenuated?(child.allowed_delegatees, parent.allowed_delegatees)
  end

  defp datetime_not_earlier?(_child, nil), do: true
  defp datetime_not_earlier?(nil, %DateTime{}), do: false

  defp datetime_not_earlier?(%DateTime{} = child, %DateTime{} = parent),
    do: DateTime.compare(child, parent) in [:eq, :gt]

  defp datetime_not_earlier?(_child, _parent), do: false

  defp datetime_not_later?(_child, nil), do: true
  defp datetime_not_later?(nil, %DateTime{}), do: false

  defp datetime_not_later?(%DateTime{} = child, %DateTime{} = parent),
    do: DateTime.compare(child, parent) in [:eq, :lt]

  defp datetime_not_later?(_child, _parent), do: false

  defp integer_limit_attenuated?(_child, nil), do: true

  defp integer_limit_attenuated?(child, parent)
       when is_integer(child) and is_integer(parent),
       do: child > 0 and child <= parent

  defp integer_limit_attenuated?(_child, _parent), do: false

  defp binding_attenuated?(_child, nil), do: true
  defp binding_attenuated?(binding, binding) when is_binary(binding), do: true
  defp binding_attenuated?(_child, _parent), do: false

  defp delegatees_attenuated?(_child, nil), do: true
  defp delegatees_attenuated?(nil, parent) when is_list(parent), do: false

  defp delegatees_attenuated?(child, parent) when is_list(child) and is_list(parent) do
    child_set = MapSet.new(child)
    parent_set = MapSet.new(parent)
    MapSet.subset?(child_set, parent_set)
  end

  defp delegatees_attenuated?(_child, _parent), do: false

  defp capability_granter_id(%Capability{metadata: metadata}) when is_map(metadata),
    do: Map.get(metadata, "granter_id")

  defp capability_granter_id(_cap), do: nil

  defp valid_principal_id?(value) when is_binary(value) and byte_size(value) in 1..256,
    do: String.valid?(value)

  defp valid_principal_id?(_value), do: false

  defp capability_mutation_digest(%Capability{} = cap) do
    cap
    |> Capability.signing_payload()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp put_capability_mutation_attestation(state, token, entry) do
    attestations =
      state
      |> Map.get(:capability_mutation_attestations, %{})
      |> Map.put(token, entry)

    Map.put(state, :capability_mutation_attestations, attestations)
  end

  defp prune_capability_mutation_attestations(state) do
    now = System.monotonic_time(:millisecond)

    attestations =
      state
      |> Map.get(:capability_mutation_attestations, %{})
      |> Map.reject(fn {_token, entry} ->
        not is_map(entry) or not is_integer(Map.get(entry, :expires_mono)) or
          entry.expires_mono <= now
      end)

    Map.put(state, :capability_mutation_attestations, attestations)
  end

  defp capability_mutation_attestation_payload(proof) when is_map(proof) do
    values = [
      @capability_mutation_attestation_version,
      Map.get(proof, :token),
      Map.get(proof, :actor_id),
      proof |> Map.get(:operation) |> encode_capability_mutation_operation(),
      Map.get(proof, :capability_digest),
      Map.get(proof, :authority_fingerprint),
      Map.get(proof, :issued_at),
      Map.get(proof, :expires_at)
    ]

    if Enum.all?(values, &(is_binary(&1) and byte_size(&1) > 0)) do
      Enum.map_join(values, &issuer_attestation_length_prefix/1)
    else
      :invalid_capability_mutation_attestation
    end
  end

  defp capability_mutation_attestation_payload(_proof),
    do: :invalid_capability_mutation_attestation

  defp encode_capability_mutation_operation(operation)
       when operation in [:grant, :acknowledged_grant, :delegate],
       do: Atom.to_string(operation)

  defp encode_capability_mutation_operation(_operation), do: ""

  defp canonical_capability_revocation_target(operation, target)
       when operation in [:revoke, :cascade_revoke] and is_map(target) do
    with true <-
           Map.keys(target) |> Enum.sort() ==
             [:capability_digest, :capability_id, :principal_id],
         capability_id when is_binary(capability_id) <- Map.get(target, :capability_id),
         principal_id when is_binary(principal_id) <- Map.get(target, :principal_id),
         capability_digest when is_binary(capability_digest) <-
           Map.get(target, :capability_digest),
         :ok <- validate_sha256_digest(capability_digest),
         true <- valid_principal_id?(principal_id),
         true <- byte_size(capability_id) in 1..256 do
      digest =
        capability_revocation_target_digest(operation, [
          capability_id,
          principal_id,
          capability_digest
        ])

      {:ok, digest, "arbor://security/revoke/#{principal_id}"}
    else
      _ -> {:error, :capability_revocation_unauthorized}
    end
  end

  defp canonical_capability_revocation_target(:revoke_all, principal_id)
       when is_binary(principal_id) do
    if valid_principal_id?(principal_id) do
      {:ok, capability_revocation_target_digest(:revoke_all, [principal_id]),
       "arbor://security/revoke/#{principal_id}"}
    else
      {:error, :capability_revocation_unauthorized}
    end
  end

  defp canonical_capability_revocation_target(:revoke_by_scope, {scope_key, scope_value})
       when scope_key in [:session_id, :task_id] and is_binary(scope_value) do
    if byte_size(scope_value) in 1..256 and String.valid?(scope_value) do
      {:ok,
       capability_revocation_target_digest(:revoke_by_scope, [
         Atom.to_string(scope_key),
         scope_value
       ]), "arbor://security/revoke/scope"}
    else
      {:error, :capability_revocation_unauthorized}
    end
  end

  defp canonical_capability_revocation_target(_operation, _target),
    do: {:error, :capability_revocation_unauthorized}

  defp capability_revocation_target_digest(operation, fields) do
    ([
       @capability_revocation_attestation_version,
       Atom.to_string(operation)
     ] ++ fields)
    |> Enum.map_join(&issuer_attestation_length_prefix/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp put_capability_revocation_attestation(state, token, entry) do
    attestations =
      state
      |> Map.get(:capability_revocation_attestations, %{})
      |> Map.put(token, entry)

    Map.put(state, :capability_revocation_attestations, attestations)
  end

  defp prune_capability_revocation_attestations(state) do
    now = System.monotonic_time(:millisecond)

    attestations =
      state
      |> Map.get(:capability_revocation_attestations, %{})
      |> Map.reject(fn {_token, entry} ->
        not is_map(entry) or not is_integer(Map.get(entry, :expires_mono)) or
          entry.expires_mono <= now
      end)

    Map.put(state, :capability_revocation_attestations, attestations)
  end

  defp capability_revocation_attestation_payload(proof) when is_map(proof) do
    values = [
      @capability_revocation_attestation_version,
      Map.get(proof, :token),
      Map.get(proof, :actor_id),
      proof |> Map.get(:operation) |> encode_capability_revocation_operation(),
      Map.get(proof, :target_digest),
      Map.get(proof, :authorization_resource),
      Map.get(proof, :authority_fingerprint),
      Map.get(proof, :issued_at),
      Map.get(proof, :expires_at)
    ]

    if Enum.all?(values, &(is_binary(&1) and byte_size(&1) > 0)) do
      Enum.map_join(values, &issuer_attestation_length_prefix/1)
    else
      :invalid_capability_revocation_attestation
    end
  end

  defp capability_revocation_attestation_payload(_proof),
    do: :invalid_capability_revocation_attestation

  defp encode_capability_revocation_operation(operation)
       when operation in [:revoke, :revoke_all, :cascade_revoke, :revoke_by_scope],
       do: Atom.to_string(operation)

  defp encode_capability_revocation_operation(_operation), do: ""

  defp sign_capability_with_identity(%Capability{} = cap, %Identity{} = identity) do
    cap
    |> Map.put(:issuer_id, identity.agent_id)
    |> Signer.sign(identity.private_key)
  end

  defp encode_operation(operation) when operation in [:register, :update, :revoke],
    do: Atom.to_string(operation)

  defp encode_operation(_operation), do: ""

  defp issuer_attestation_length_prefix(value),
    do: <<byte_size(value)::32, value::binary>>

  defp authority_fingerprint(%Identity{public_key: public_key}) do
    :crypto.hash(:sha256, public_key)
    |> Base.encode16(case: :lower)
  end

  defp verify_capability_signature_safe(cap, %{identity: identity} = state) do
    with true <- valid_capability_signature_shape?(cap),
         {:ok, issuer_record} <- capability_issuer_record(cap.issuer_id, identity, state),
         {:ok, public_key} <- issuer_record_public_key(issuer_record, cap),
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

  defp verify_capability_signatures_safe(caps, %{identity: identity} = state) do
    {valid_ids, _issuer_cache} =
      Enum.reduce(caps, {[], %{}}, fn cap, accumulator ->
        verify_capability_with_cache(cap, accumulator, identity, state)
      end)

    Enum.reverse(valid_ids)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp verify_capability_with_cache(cap, {valid_ids, issuer_cache}, identity, state) do
    if valid_capability_signature_shape?(cap) do
      {issuer_result, updated_cache} =
        cached_capability_issuer_record(cap.issuer_id, identity, state, issuer_cache)

      case issuer_result do
        {:ok, issuer_record} ->
          maybe_collect_verified_id(issuer_record, cap, valid_ids, updated_cache)

        {:error, _reason} ->
          {valid_ids, updated_cache}
      end
    else
      {valid_ids, issuer_cache}
    end
  end

  defp maybe_collect_verified_id(issuer_record, cap, valid_ids, cache) do
    with {:ok, public_key} <- issuer_record_public_key(issuer_record, cap),
         :ok <- safe_signer_verify(cap, public_key) do
      {[cap.id | valid_ids], cache}
    else
      _ -> {valid_ids, cache}
    end
  end

  defp valid_capability_signature_shape?(%Capability{
         issuer_id: issuer_id,
         issuer_signature: signature
       }) do
    is_binary(issuer_id) and is_binary(signature) and byte_size(signature) == 64
  end

  defp capability_issuer_record(
         issuer_id,
         %{agent_id: issuer_id, public_key: public_key},
         _state
       ),
       do: {:ok, {:system_authority, public_key}}

  defp capability_issuer_record(issuer_id, _identity, state) when is_binary(issuer_id) do
    with {:ok, %{public_key: public_key, max_envelope_caps: envelopes}} <-
           issuer_registry_lookup(state, issuer_id) do
      {:ok, {:enrolled_issuer, public_key, envelopes}}
    else
      _ -> {:error, :issuer_not_authorized}
    end
  end

  defp capability_issuer_record(_issuer_id, _identity, _state), do: {:error, :not_found}

  defp issuer_record_public_key({:system_authority, public_key}, _cap), do: {:ok, public_key}

  defp issuer_record_public_key({:enrolled_issuer, public_key, envelopes}, cap) do
    if Enum.any?(envelopes, &Capability.envelope_subset?(cap, &1)),
      do: {:ok, public_key},
      else: {:error, :exceeds_issuer_envelope}
  end

  defp cached_capability_issuer_record(issuer_id, identity, state, cache) do
    case Map.fetch(cache, issuer_id) do
      {:ok, result} ->
        {result, cache}

      :error ->
        result = capability_issuer_record(issuer_id, identity, state)
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
  # The v3 layout stores one atomic authority bundle:
  #
  #   * Private Ed25519 + X25519 keys are inside one AES-GCM envelope.
  #   * Public identity metadata is alongside that envelope in the same Record.
  #
  # V2 split these fields across @authority_signing_id and
  # @authority_metadata_key. It is read only for validated migration. The
  # pre-v2 layout serialized plaintext private material under
  # @legacy_plaintext_key and is cleanup-only.

  # Public (@doc false) for the P0-5 regression test, which corrupts the
  # persisted metadata and asserts the load returns {:error, _} rather than
  # silently regenerating the trust root.
  @doc false
  def load_persisted_keypair do
    if SigningKeyStore.available?() do
      case SigningKeyStore.get_authority_bundle(@authority_signing_id) do
        {:ok, identity} ->
          {:ok, identity}

        {:error, :legacy_keypair} ->
          load_and_migrate_legacy_v2()

        {:error, :no_signing_key} ->
          classify_missing_bundle()

        {:error, reason} ->
          {:error, reason}
      end
    else
      :not_found
    end
  catch
    _, _reason ->
      {:error, :store_unavailable}
  end

  defp load_persisted_keypair(supervisor_pid) when is_pid(supervisor_pid) do
    if SupervisedOwner.child_pid(supervisor_pid, @key_store_name) do
      case SigningKeyStore.Owner.get_authority_bundle_from_supervisor(
             supervisor_pid,
             @authority_signing_id
           ) do
        {:ok, identity} ->
          {:ok, identity}

        {:error, :legacy_keypair} ->
          load_and_migrate_legacy_v2(supervisor_pid)

        {:error, :no_signing_key} ->
          classify_missing_bundle(supervisor_pid)

        {:error, reason} ->
          {:error, reason}
      end
    else
      :not_found
    end
  catch
    _, _reason -> {:error, :store_unavailable}
  end

  defp load_public_metadata do
    case AuthorityStore.authoritative_get(@authority_metadata_key, name: @key_store_name) do
      {:ok, %Record{data: data}} when is_map(data) -> {:ok, data}
      {:error, :not_found} -> :not_found
      {:error, _reason} -> {:error, :store_unavailable}
      _ -> {:error, :invalid_metadata_format}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp load_public_metadata(supervisor_pid) do
    case AuthorityStore.authoritative_get_from_supervisor(
           supervisor_pid,
           @authority_metadata_key,
           name: @key_store_name
         ) do
      {:ok, %Record{data: data}} when is_map(data) -> {:ok, data}
      {:error, :not_found} -> :not_found
      {:error, _reason} -> {:error, :store_unavailable}
      _other -> {:error, :invalid_metadata_format}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp classify_missing_bundle do
    case load_public_metadata() do
      :not_found -> :not_found
      {:ok, _metadata} -> {:error, :metadata_without_keypair}
      {:error, reason} -> {:error, {:metadata_load_failed, reason}}
    end
  end

  defp classify_missing_bundle(supervisor_pid) do
    case load_public_metadata(supervisor_pid) do
      :not_found -> :not_found
      {:ok, _metadata} -> {:error, :metadata_without_keypair}
      {:error, reason} -> {:error, {:metadata_load_failed, reason}}
    end
  end

  defp load_and_migrate_legacy_v2 do
    with {:ok, metadata} <- require_legacy_metadata(),
         {:ok, identity} <- load_private_and_reconstruct(metadata),
         :ok <- persist_keypair(identity) do
      cleanup_legacy_public_metadata()
      {:ok, identity}
    else
      {:error, :outcome_unknown} -> {:error, {:legacy_migration_failed, :outcome_unknown}}
      {:error, reason} -> {:error, reason}
      :not_found -> {:error, :keypair_without_metadata}
    end
  end

  defp load_and_migrate_legacy_v2(supervisor_pid) do
    with {:ok, metadata} <- require_legacy_metadata(supervisor_pid),
         {:ok, identity} <- load_private_and_reconstruct(metadata, supervisor_pid),
         :ok <- persist_keypair(identity, supervisor_pid) do
      cleanup_legacy_public_metadata(supervisor_pid)
      {:ok, identity}
    else
      {:error, :outcome_unknown} -> {:error, {:legacy_migration_failed, :outcome_unknown}}
      {:error, reason} -> {:error, reason}
      :not_found -> {:error, :keypair_without_metadata}
    end
  end

  defp require_legacy_metadata do
    case load_public_metadata() do
      {:ok, %{"v" => 2} = metadata} -> {:ok, metadata}
      {:ok, _malformed} -> {:error, :invalid_metadata_format}
      other -> other
    end
  end

  defp require_legacy_metadata(supervisor_pid) do
    case load_public_metadata(supervisor_pid) do
      {:ok, %{"v" => 2} = metadata} -> {:ok, metadata}
      {:ok, _malformed} -> {:error, :invalid_metadata_format}
      other -> other
    end
  end

  defp load_private_and_reconstruct(metadata) do
    with {:ok, agent_id} <- decode_agent_id(metadata["agent_id"]),
         {:ok, public_key} <- decode_b64(metadata["public_key"]),
         {:ok, enc_public_key} <- decode_b64(metadata["encryption_public_key"]),
         {:ok, created_at} <- decode_created_at(metadata["created_at"]),
         {:ok, keypair} <- SigningKeyStore.get_keypair(@authority_signing_id),
         {:ok, private_key} <- fetch_signing(keypair),
         {:ok, enc_private_key} <- fetch_encryption(keypair),
         {:ok, identity} <-
           Identity.new(
             public_key: public_key,
             private_key: private_key,
             encryption_public_key: enc_public_key,
             encryption_private_key: enc_private_key,
             name: metadata["name"],
             created_at: created_at
           ),
         true <- agent_id == identity.agent_id,
         :ok <- validate_keypair_correspondence(identity) do
      {:ok, identity}
    else
      {:error, :no_signing_key} ->
        {:error, :metadata_without_keypair}

      _ ->
        {:error, :invalid_persisted_authority}
    end
  end

  defp load_private_and_reconstruct(metadata, supervisor_pid) do
    with {:ok, agent_id} <- decode_agent_id(metadata["agent_id"]),
         {:ok, public_key} <- decode_b64(metadata["public_key"]),
         {:ok, enc_public_key} <- decode_b64(metadata["encryption_public_key"]),
         {:ok, created_at} <- decode_created_at(metadata["created_at"]),
         {:ok, keypair} <-
           SigningKeyStore.Owner.get_keypair_from_supervisor(
             supervisor_pid,
             @authority_signing_id
           ),
         {:ok, private_key} <- fetch_signing(keypair),
         {:ok, enc_private_key} <- fetch_encryption(keypair),
         {:ok, identity} <-
           Identity.new(
             public_key: public_key,
             private_key: private_key,
             encryption_public_key: enc_public_key,
             encryption_private_key: enc_private_key,
             name: metadata["name"],
             created_at: created_at
           ),
         true <- agent_id == identity.agent_id,
         :ok <- validate_keypair_correspondence(identity) do
      {:ok, identity}
    else
      {:error, :no_signing_key} -> {:error, :metadata_without_keypair}
      _other -> {:error, :invalid_persisted_authority}
    end
  end

  # Public (@doc false) for the P0-5 regression test, which calls it directly
  # with a generated identity to verify the persisted record layout. The test
  # environment uses :ephemeral mode, so the live SystemAuthority never
  # exercises this path.
  @doc false
  def persist_keypair(%Identity{} = identity),
    do: SigningKeyStore.put_authority_bundle(@authority_signing_id, identity)

  defp persist_keypair(%Identity{} = identity, supervisor_pid),
    do:
      SigningKeyStore.Owner.put_authority_bundle_from_supervisor(
        supervisor_pid,
        @authority_signing_id,
        identity
      )

  # Public (@doc false) for the P0-5 regression test.
  @doc false
  def cleanup_legacy_plaintext_record do
    if SigningKeyStore.available?() do
      case AuthorityStore.authoritative_get(@legacy_plaintext_key, name: @key_store_name) do
        {:ok, _} ->
          case SigningKeyStore.delete_authority_record(@legacy_plaintext_key) do
            :ok ->
              Logger.warning(
                "[SystemAuthority] Deleted pre-v2 plaintext authority keypair record. " <>
                  "Existing capabilities signed by the old key will not verify under the new authority."
              )

              :ok

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    else
      :ok
    end
  catch
    _, _ -> :ok
  end

  defp cleanup_legacy_plaintext_record(supervisor_pid) do
    case AuthorityStore.authoritative_get_from_supervisor(
           supervisor_pid,
           @legacy_plaintext_key,
           name: @key_store_name
         ) do
      {:ok, _record} ->
        case SigningKeyStore.Owner.delete_authority_record_from_supervisor(
               supervisor_pid,
               @legacy_plaintext_key
             ) do
          :ok ->
            Logger.warning(
              "[SystemAuthority] Deleted pre-v2 plaintext authority keypair record. " <>
                "Existing capabilities signed by the old key will not verify under the new authority."
            )

            :ok

          _other ->
            :ok
        end

      _other ->
        :ok
    end
  catch
    _, _ -> :ok
  end

  defp cleanup_legacy_public_metadata do
    case SigningKeyStore.delete_authority_record(@authority_metadata_key) do
      :ok -> :ok
      _ -> :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp cleanup_legacy_public_metadata(supervisor_pid) do
    case SigningKeyStore.Owner.delete_authority_record_from_supervisor(
           supervisor_pid,
           @authority_metadata_key
         ) do
      :ok -> :ok
      _other -> :ok
    end
  rescue
    _ -> :ok
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

  defp decode_agent_id(agent_id) when is_binary(agent_id) and byte_size(agent_id) > 0,
    do: {:ok, agent_id}

  defp decode_agent_id(_agent_id), do: {:error, :invalid_agent_id}

  defp decode_created_at(nil), do: {:error, :missing_created_at}

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

  defp fetch_encryption(_), do: {:error, :missing_encryption_key}

  defp validate_keypair_correspondence(identity) do
    with {public_key, _} <- :crypto.generate_key(:eddsa, :ed25519, identity.private_key),
         {encryption_public_key, _} <-
           :crypto.generate_key(:ecdh, :x25519, identity.encryption_private_key),
         true <- public_key == identity.public_key,
         true <- encryption_public_key == identity.encryption_public_key do
      :ok
    else
      _ -> {:error, :keypair_mismatch}
    end
  rescue
    _ -> {:error, :keypair_mismatch}
  catch
    _, _ -> {:error, :keypair_mismatch}
  end

  defp register_public_identity(identity, registration_token, supervisor_pid) do
    with {:ok, possession_proof} <- Registry.registration_proof(identity) do
      Registry.register_system_authority_from_supervisor(
        supervisor_pid,
        Identity.public_only(identity),
        possession_proof,
        registration_token
      )
    end
    |> case do
      :ok ->
        :ok

      {:error, {:already_registered, agent_id}} when agent_id == identity.agent_id ->
        verify_registered_identity(identity)

      {:error, :registration_unavailable} ->
        {:error, :registration_unavailable}

      {:error, _reason} ->
        {:error, :registration_conflict}
    end
  rescue
    _ -> {:error, :registration_unavailable}
  catch
    _, _ -> {:error, :registration_unavailable}
  end

  defp verify_registered_identity(identity) do
    with {:ok, public_key} <- Registry.lookup(identity.agent_id),
         true <- public_key == identity.public_key,
         {:ok, encryption_public_key} <- Registry.lookup_encryption_key(identity.agent_id),
         true <- encryption_public_key == identity.encryption_public_key do
      :ok
    else
      _ -> {:error, :registration_conflict}
    end
  end

  defp claim_owner_directory do
    table = :ets.new(@owner_table, [:named_table, :protected, :set, read_concurrency: true])
    true = :ets.insert(table, {:owner, self()})
    :ok
  rescue
    _ -> {:error, :system_authority_directory_unavailable}
  end

  defp owner_pid do
    case SupervisedOwner.protected_directory_owner(
           @owner_table,
           :owner,
           :arbor_security,
           [__MODULE__]
         ) do
      pid when is_pid(pid) -> pid
      nil -> raise "system authority unavailable"
    end
  end
end
