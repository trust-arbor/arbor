defmodule Arbor.Security.Identity.Registry do
  @moduledoc """
  Registry for public agent identities backed by Security-owned authority.

  Stores public keys indexed by agent ID for fast lookup during signature
  verification. Private keys are never stored — only the public portion
  of an identity is retained.

  In the full start profile, `Arbor.Security.AuthorityStore` owns the complete
  durable identity inventory. In the activation-only profile that named store
  is intentionally absent and this process is an explicit hot-only owner.

  ## Trust model (C10)

  - **Self-certifying agent IDs.** An `agent_id` MUST equal `hash(public_key)` —
    enforced in `register/2`. Ordinary registration always rejects `human_`
    IDs.
  - **OIDC-proven human IDs.** First registration of a `human_` identity must
    use `register_oidc/3`. The registry verifies the original signed ID token,
    derives the expected ID from the verified `iss:sub`, and rejects any
    identity whose ID differs. Unverified claims are never registration proof.
  - **No overwrite.** Re-registering an existing `agent_id` is rejected.
  - **Names are not security-relevant.** `lookup_by_name/1` is explicitly
    non-unique and is NEVER used in an authorization decision — identity
    authorization is always by `agent_id`. Name squatting is therefore a
    display nuisance, not an auth risk. (Keep it that way: do not add
    authz-by-name.)
  - **Registration authorization.** `register/2` consults
    `Config.registration_policy/0` before creating a NEW identity. The default
    policy admits self-certifying agent identities, while OIDC human identities
    require an allowlisted subject or verified email domain unless an explicitly
    local/test configuration opts into open registration.
  - **Store integrity.** Persisted entries (public keys only) are within the
    conceded same-UID/file-access threat (T4). A signed/HMAC'd identity store
    is a Layer 3 follow-up.
  """

  use GenServer

  require Logger

  # Issuer stamped on identities minted by `mix arbor.user.init`. Must match
  # `Arbor.Security.local_human_claims/1`.
  @local_pseudo_issuer "arbor://local"
  @registration_domain "arbor.security.identity.registration.v1" <> <<0>>
  @status_mutation_domain "arbor.security.identity.status-mutation.v1" <> <<0>>
  @status_mutation_operations [:deregister, :revoke, :suspend, :resume]

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.Config
  alias Arbor.Security.Crypto
  alias Arbor.Security.OIDC.IdentityStore
  alias Arbor.Security.OIDC.TokenVerifier
  alias Arbor.Security.PrivateState
  alias Arbor.Security.SignalSync
  alias Arbor.Security.SupervisedOwner
  alias Arbor.Signals

  @id_store :arbor_security_identities
  @owner_directory :arbor_security_identity_registry_owner_directory
  @registration_custody_anchor {__MODULE__, :registration_custody}
  @registration_custody_schema :identity_registry_registration_v1
  @test_env Mix.env() == :test
  @signal_events [
    :identity_registered,
    :identity_deregistered,
    :identity_suspended,
    :identity_resumed,
    :identity_revoked
  ]

  # Client API

  @doc """
  Start the identity registry.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Refuse the retired unauthenticated agent-registration API."
  @spec register(term()) :: {:error, :identity_registration_unauthorized}
  def register(_identity), do: {:error, :identity_registration_unauthorized}

  @doc "Refuse the retired policy-option/proof registration API."
  @spec register(term(), term()) :: {:error, :identity_registration_unauthorized}
  def register(_identity, _proof_or_opts), do: {:error, :identity_registration_unauthorized}

  @doc false
  @spec register_authorized(Identity.t(), binary(), map()) :: :ok | {:error, term()}
  def register_authorized(%Identity{} = identity, possession_proof, actor_attestation)
      when is_binary(possession_proof) and is_map(actor_attestation) do
    server_call(
      {:register_authorized, Identity.public_only(identity), possession_proof, actor_attestation}
    )
  end

  def register_authorized(_identity, _possession_proof, _actor_attestation),
    do: {:error, :identity_registration_unauthorized}

  @doc "Refuse system-authority registration without the startup capability."
  @spec register_system_authority(term(), term()) ::
          {:error, :identity_registration_unauthorized}
  def register_system_authority(_identity, _possession_proof),
    do: {:error, :identity_registration_unauthorized}

  @doc false
  @spec register_system_authority(Identity.t(), binary(), reference()) ::
          :ok | {:error, term()}
  def register_system_authority(%Identity{} = identity, possession_proof, registration_token)
      when is_binary(possession_proof) and is_reference(registration_token) do
    server_call(
      {:register_system_authority, Identity.public_only(identity), possession_proof,
       registration_token}
    )
  end

  def register_system_authority(_identity, _possession_proof, _registration_token),
    do: {:error, :identity_registration_unauthorized}

  @doc false
  @spec register_system_authority_from_supervisor(
          pid(),
          Identity.t(),
          binary(),
          reference()
        ) :: :ok | {:error, term()}
  def register_system_authority_from_supervisor(
        supervisor,
        %Identity{} = identity,
        possession_proof,
        registration_token
      )
      when is_pid(supervisor) and is_binary(possession_proof) and
             is_reference(registration_token) do
    case SupervisedOwner.child_pid(supervisor, __MODULE__) do
      registry when is_pid(registry) ->
        Arbor.Common.authenticated_call(
          registry,
          {:register_system_authority_from_supervisor, supervisor, Identity.public_only(identity),
           possession_proof, registration_token}
        )

      nil ->
        {:error, :registration_unavailable}
    end
  rescue
    _ -> {:error, :registration_unavailable}
  catch
    :exit, _ -> {:error, :registration_unavailable}
  end

  def register_system_authority_from_supervisor(
        _supervisor,
        _identity,
        _possession_proof,
        _registration_token
      ),
      do: {:error, :identity_registration_unauthorized}

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
      registry when is_pid(registry) ->
        GenServer.call(
          registry,
          {:complete_startup, supervisor, registration_token},
          timeout
        )

      nil ->
        {:error, :registration_unavailable}
    end
  rescue
    _ -> {:error, :registration_unavailable}
  catch
    :exit, {:timeout, _} -> {:error, :registry_startup_timeout}
    :exit, _ -> {:error, :registration_unavailable}
  end

  def complete_startup(_supervisor, _registration_token, _timeout),
    do: {:error, :invalid_registry_startup}

  @doc false
  @spec register_scheduler_identity(Identity.t(), binary()) :: :ok | {:error, term()}
  def register_scheduler_identity(%Identity{} = identity, possession_proof)
      when is_binary(possession_proof) do
    server_call({:register_scheduler_identity, Identity.public_only(identity), possession_proof})
  end

  def register_scheduler_identity(_identity, _possession_proof),
    do: {:error, :identity_registration_unauthorized}

  @doc false
  @spec register_trust_capability_grant_identity(Identity.t(), binary()) ::
          :ok | {:error, term()}
  def register_trust_capability_grant_identity(%Identity{} = identity, possession_proof)
      when is_binary(possession_proof) do
    server_call(
      {:register_trust_capability_grant_identity, Identity.public_only(identity),
       possession_proof}
    )
  end

  def register_trust_capability_grant_identity(_identity, _possession_proof),
    do: {:error, :identity_registration_unauthorized}

  @doc false
  # D4 system lifecycle principal. Admitted only from the configured
  # `:system_lifecycle_owner` process (exact supervised path + registered name)
  # with a possession proof for the identity's own key. Like the scheduler and
  # trust-grant paths, it needs no `arbor://security/identity/register` right.
  @spec register_system_lifecycle_identity(Identity.t(), binary()) :: :ok | {:error, term()}
  def register_system_lifecycle_identity(%Identity{} = identity, possession_proof)
      when is_binary(possession_proof) do
    server_call(
      {:register_system_lifecycle_identity, Identity.public_only(identity), possession_proof}
    )
  end

  def register_system_lifecycle_identity(_identity, _possession_proof),
    do: {:error, :identity_registration_unauthorized}

  if Mix.env() == :test do
    @doc false
    def test_system_authority_registration_token do
      server_call(:test_system_authority_registration_token)
    end

    @doc false
    @spec register_fixture(Identity.t()) :: :ok | {:error, term()}
    def register_fixture(%Identity{} = identity) do
      server_call({:register_fixture, Identity.public_only(identity)})
    end

    @doc false
    def reconcile_remote_authority_result_fixture(type, agent_id, authority_result) do
      server_call({:reconcile_remote_authority_result_fixture, type, agent_id, authority_result})
    end
  end

  @doc """
  Build a domain-separated proof that the registering caller possesses the
  Ed25519 private key for an agent identity.

  The proof binds the self-certifying id, signing public key, encryption public
  key, and key version. Registries store only `Identity.public_only/1`; the
  private key never crosses the GenServer boundary.
  """
  @spec registration_proof(Identity.t()) :: {:ok, binary()} | {:error, atom()}
  def registration_proof(%Identity{agent_id: "human_" <> _rest}),
    do: {:error, :oidc_proof_required}

  def registration_proof(%Identity{private_key: private_key} = identity)
      when is_binary(private_key) do
    payload = registration_payload(identity)
    signature = Crypto.sign(payload, private_key)

    if byte_size(signature) == 64 and Crypto.verify(payload, signature, identity.public_key),
      do: {:ok, signature},
      else: {:error, :invalid_identity_proof}
  rescue
    _ -> {:error, :invalid_identity_proof}
  catch
    _, _ -> {:error, :invalid_identity_proof}
  end

  def registration_proof(%Identity{}), do: {:error, :identity_proof_required}
  def registration_proof(_identity), do: {:error, :invalid_identity}

  @doc "Return the canonical SHA-256 digest bound into actor authorization."
  @spec registration_payload_digest(Identity.t()) :: {:ok, String.t()} | {:error, atom()}
  def registration_payload_digest(%Identity{} = identity) do
    public_identity = Identity.public_only(identity)

    with :ok <- validate_public_identity(public_identity),
         false <- human_identity?(public_identity) do
      digest = :crypto.hash(:sha256, registration_payload(public_identity))
      {:ok, Base.encode16(digest, case: :lower)}
    else
      _ -> {:error, :invalid_identity}
    end
  rescue
    _ -> {:error, :invalid_identity}
  catch
    _, _ -> {:error, :invalid_identity}
  end

  def registration_payload_digest(_identity), do: {:error, :invalid_identity}

  @doc """
  Register a human identity after verifying its original OIDC ID token.

  The token is verified against the supplied provider configuration inside
  the registry. The verified issuer and subject are deterministically mapped
  to the expected `human_` ID, which must exactly match the identity.
  Pre-decoded claims or other maps are not accepted as provenance.
  """
  @spec register_oidc(Identity.t(), String.t(), map()) :: :ok | {:error, term()}
  def register_oidc(%Identity{} = identity, id_token, provider_config)
      when is_binary(id_token) and is_map(provider_config) do
    with {:ok, proof} <- build_oidc_key_possession_proof(identity, id_token) do
      register_oidc_proven(Identity.public_only(identity), id_token, provider_config, proof)
    end
  end

  def register_oidc(_identity, _id_token, _provider_config),
    do: {:error, :invalid_oidc_registration}

  @doc false
  @spec register_oidc_proven(Identity.t(), String.t(), map(), binary()) ::
          :ok | {:error, term()}
  def register_oidc_proven(%Identity{} = identity, id_token, provider_config, proof)
      when is_binary(id_token) and is_map(provider_config) and is_binary(proof) do
    server_call(
      {:register_oidc, Identity.public_only(identity), id_token, provider_config, proof}
    )
  end

  def register_oidc_proven(_identity, _id_token, _provider_config, _proof),
    do: {:error, :invalid_oidc_registration}

  @doc """
  Register a LOCAL human identity — development installs only.

  `register/2` refuses `human_` identities with `:oidc_proof_required` so a
  human principal cannot be minted without an authenticated login. This is the
  third and last piece of the deliberate dev carve-out behind
  `mix arbor.user.init`: without registration the identity exists and holds
  capabilities it can never exercise, because `AuthDecision` resolves every
  principal through `identity_status/1`.

  It preserves the invariant `register_oidc/3` actually enforces — that
  `agent_id` equals the derivation from its claims — which IS checkable here.
  What cannot be checked is the issuer, because the issuer is this machine.
  That is precisely what the gates authorize, so they are re-checked at this
  boundary rather than trusted from the caller:

    * `config :arbor_security, :allow_local_human_identity` must be `true`
    * the identity's issuer must be exactly `"arbor://local"`

  A local-issuer identity registered here is still refused by
  `identity_status/1` in any environment where that flag is not set, so even a
  copied authority store cannot make it authenticate in production.
  """
  @spec register_local_human(Identity.t()) :: :ok | {:error, term()}
  def register_local_human(%Identity{} = identity) do
    server_call({:register_local_human, identity})
  end

  def register_local_human(_identity), do: {:error, :invalid_local_registration}

  @doc """
  Look up the public key for an agent.
  """
  @spec lookup(String.t()) :: {:ok, binary()} | {:error, :not_found}
  def lookup(agent_id) when is_binary(agent_id) do
    server_call({:lookup, agent_id})
  end

  @doc """
  Look up the encryption public key (X25519) for an agent.

  Returns `{:error, :not_found}` if the agent is not registered, and
  `{:error, :no_encryption_key}` if registered but has no encryption key.
  """
  @spec lookup_encryption_key(String.t()) ::
          {:ok, binary()} | {:error, :not_found | :no_encryption_key}
  def lookup_encryption_key(agent_id) when is_binary(agent_id) do
    server_call({:lookup_encryption_key, agent_id})
  end

  @doc """
  Check if an agent is registered.
  """
  @spec registered?(String.t()) :: boolean()
  def registered?(agent_id) when is_binary(agent_id) do
    server_call({:registered?, agent_id})
  end

  @doc "Refuse the retired unauthenticated identity-removal API."
  @spec deregister(term()) :: {:error, :identity_status_mutation_unauthorized}
  def deregister(_agent_id), do: {:error, :identity_status_mutation_unauthorized}

  @doc false
  @spec deregister_authorized(String.t(), map()) :: :ok | {:error, term()}
  def deregister_authorized(agent_id, attestation)
      when is_binary(agent_id) and is_map(attestation) do
    server_call({:deregister_authorized, agent_id, attestation})
  end

  def deregister_authorized(_agent_id, _attestation),
    do: {:error, :identity_status_mutation_unauthorized}

  @doc """
  Look up agent IDs by human-readable name.

  Names are not unique — returns all agent IDs registered with the given name.
  """
  @spec lookup_by_name(String.t()) :: {:ok, [String.t()]} | {:error, :not_found}
  def lookup_by_name(name) when is_binary(name) do
    server_call({:lookup_by_name, name})
  end

  @doc """
  Get registry statistics.
  """
  @spec stats() :: map()
  def stats do
    server_call(:stats)
  end

  # ===========================================================================
  # Identity Lifecycle Management
  # ===========================================================================

  @doc "Refuse the retired unauthenticated suspension API."
  @spec suspend(term(), term()) :: {:error, :identity_status_mutation_unauthorized}
  def suspend(_agent_id, _reason \\ nil),
    do: {:error, :identity_status_mutation_unauthorized}

  @doc false
  @spec suspend_authorized(String.t(), String.t() | nil, map()) :: :ok | {:error, term()}
  def suspend_authorized(agent_id, reason, attestation)
      when is_binary(agent_id) and (is_binary(reason) or is_nil(reason)) and is_map(attestation) do
    server_call({:suspend_authorized, agent_id, reason, attestation})
  end

  def suspend_authorized(_agent_id, _reason, _attestation),
    do: {:error, :identity_status_mutation_unauthorized}

  @doc "Refuse the retired unauthenticated resume API."
  @spec resume(term()) :: {:error, :identity_status_mutation_unauthorized}
  def resume(_agent_id), do: {:error, :identity_status_mutation_unauthorized}

  @doc false
  @spec resume_authorized(String.t(), map()) :: :ok | {:error, term()}
  def resume_authorized(agent_id, attestation)
      when is_binary(agent_id) and is_map(attestation) do
    server_call({:resume_authorized, agent_id, attestation})
  end

  def resume_authorized(_agent_id, _attestation),
    do: {:error, :identity_status_mutation_unauthorized}

  @doc "Refuse the retired unauthenticated identity-revocation API."
  @spec revoke_identity(term(), term()) :: {:error, :identity_status_mutation_unauthorized}
  def revoke_identity(_agent_id, _reason \\ nil),
    do: {:error, :identity_status_mutation_unauthorized}

  @doc false
  @spec revoke_identity_authorized(String.t(), String.t() | nil, map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def revoke_identity_authorized(agent_id, reason, attestation)
      when is_binary(agent_id) and (is_binary(reason) or is_nil(reason)) and is_map(attestation) do
    server_call({:revoke_identity_authorized, agent_id, reason, attestation})
  end

  def revoke_identity_authorized(_agent_id, _reason, _attestation),
    do: {:error, :identity_status_mutation_unauthorized}

  @doc "Return the digest of the exact current identity snapshot a status mutation will consume."
  @spec identity_status_payload_digest(String.t(), atom(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def identity_status_payload_digest(agent_id, operation, reason \\ nil)

  def identity_status_payload_digest(agent_id, operation, reason)
      when is_binary(agent_id) and operation in @status_mutation_operations and
             (is_binary(reason) or is_nil(reason)) do
    server_call({:identity_status_payload_digest, agent_id, operation, reason})
  end

  def identity_status_payload_digest(_agent_id, _operation, _reason),
    do: {:error, :identity_status_mutation_unauthorized}

  if Mix.env() == :test do
    @doc false
    def deregister_fixture(agent_id) when is_binary(agent_id),
      do: server_call({:deregister_fixture, agent_id})

    @doc false
    def suspend_fixture(agent_id, reason \\ nil) when is_binary(agent_id),
      do: server_call({:suspend_fixture, agent_id, reason})

    @doc false
    def resume_fixture(agent_id) when is_binary(agent_id),
      do: server_call({:resume_fixture, agent_id})

    @doc false
    def revoke_identity_fixture(agent_id, reason \\ nil) when is_binary(agent_id),
      do: server_call({:revoke_identity_fixture, agent_id, reason})
  end

  @doc """
  Get the current status of an identity atomically.

  Returns the status (`:active`, `:suspended`, `:revoked`, or `:unknown`) for
  a registered identity.

  ## Examples

      {:ok, :active} = Registry.identity_status("agent_001")
      {:ok, :suspended} = Registry.identity_status("agent_002")
  """
  @spec identity_status(String.t()) :: {:ok, Identity.status()} | {:error, :not_found}
  def identity_status(agent_id) when is_binary(agent_id) do
    server_call({:get_status, agent_id})
  end

  # DEPRECATED: get_status creates a TOCTOU race with separate lookup+status check.
  # Use identity_status/1 instead. Kept for backward compatibility.
  @doc """
  Get the current status of an identity.

  **Deprecated**: Use `identity_status/1` instead. This function creates a
  TOCTOU (time-of-check-time-of-use) race condition when used in combination
  with `lookup/1`.
  """
  @deprecated "Use identity_status/1 instead"
  @spec get_status(String.t()) :: {:ok, Identity.status()} | {:error, :not_found}
  def get_status(agent_id) when is_binary(agent_id) do
    identity_status(agent_id)
  end

  @doc """
  Check if an identity is active.

  Returns `true` only if the identity exists AND has status `:active`.
  Returns `false` for suspended, revoked, or non-existent identities.

  ## Examples

      true = Registry.active?("agent_001")
      false = Registry.active?("suspended_agent")
  """
  @spec active?(String.t()) :: boolean()
  def active?(agent_id) when is_binary(agent_id) do
    case identity_status(agent_id) do
      {:ok, :active} -> true
      _ -> false
    end
  end

  # Server callbacks

  @impl true
  def init(opts) do
    Process.flag(:sensitive, true)

    with {:ok, supervisor_pid} <- startup_supervisor_pid(),
         :ok <- claim_owner_directory(),
         {:ok, registration_token} <- registration_token(opts),
         {:ok, registration_role_specs} <- registration_role_specs(opts),
         {:ok, defer_initialization?} <- defer_initialization(opts) do
      state = initialize_registry(registration_token, registration_role_specs, supervisor_pid)

      if defer_initialization? and not SupervisedOwner.application_started?(:arbor_security),
        do: {:ok, state},
        else: {:ok, state, {:continue, :restore_authority}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp initialize_registry(registration_token, registration_role_specs, supervisor_pid) do
    registration_custody =
      PrivateState.new(
        @registration_custody_anchor,
        @registration_custody_schema,
        %{
          registration_token: registration_token,
          security_supervisor_pid: supervisor_pid,
          role_specs: registration_role_specs,
          system_authority_pid: nil,
          scheduler_identity_pid: nil,
          trust_capability_grant_owner_pid: nil,
          system_lifecycle_owner_pid: nil
        }
      )

    state = %{
      by_agent_id: %{},
      by_public_key_hash: %{},
      by_name: %{},
      authority_records: %{},
      authority_mode: :hot_only,
      registration_custody: registration_custody,
      authenticated_calls: Arbor.Common.new_authenticated_call_custody(),
      initialization: :pending,
      security_supervisor_pid: supervisor_pid,
      signal_sync: nil,
      stats: %{total_registered: 0, total_deregistered: 0}
    }

    state
  end

  @impl true
  def handle_continue(:restore_authority, state) do
    case restore_authority(state) do
      {:ok, state} ->
        {:noreply, %{state | initialization: :hydrated}, {:continue, :establish_signal_sync}}

      {:error, {:identity_authority, _reason} = reason} ->
        {:stop, reason, state}
    end
  end

  def handle_continue(:establish_signal_sync, state) do
    case subscribe_to_distributed_signals() do
      {:ok, signal_sync} ->
        {:noreply, %{state | signal_sync: signal_sync, initialization: :ready}}

      {:error, reason} ->
        {:stop, {:security_sync_subscription_failed, reason}, state}
    end
  end

  @impl true
  def handle_call({:complete_startup, supervisor, registration_token}, _from, state) do
    with {:ok, custody} <- registration_custody(state),
         true <- supervisor === custody.security_supervisor_pid,
         true <- registration_token === custody.registration_token do
      case state.initialization do
        :ready ->
          {:reply, :ok, state}

        :pending ->
          with {:ok, restored} <- restore_authority(state),
               {:ok, signal_sync} <- subscribe_to_distributed_signals() do
            {:reply, :ok, %{restored | signal_sync: signal_sync, initialization: :ready}}
          else
            {:error, reason} -> {:stop, reason, {:error, reason}, state}
          end

        _other ->
          {:reply, {:error, :invalid_registry_startup}, state}
      end
    else
      _other -> {:reply, {:error, :identity_registration_unauthorized}, state}
    end
  end

  def handle_call(_request, _from, %{initialization: initialization} = state)
      when initialization != :ready do
    {:reply, {:error, :registration_unavailable}, state}
  end

  def handle_call(request, from, state) do
    if raw_read_request?(request) do
      dispatch_call(request, from, state)
    else
      {:reply, {:error, :identity_registration_unauthorized}, state}
    end
  end

  defp dispatch_call({:register, _identity, _proof, _opts}, _from, state) do
    {:reply, {:error, :identity_registration_unauthorized}, state}
  end

  defp dispatch_call(
         {:register_authorized, %Identity{} = identity, proof, actor_attestation},
         _from,
         state
       ) do
    if human_identity?(identity) do
      {:reply, {:error, :oidc_proof_required}, state}
    else
      expected_id = Crypto.derive_agent_id(identity.public_key)

      with :ok <- verify_registration_proof(identity, proof),
           true <- identity.agent_id == expected_id,
           {:ok, target_digest} <- registration_payload_digest(identity) do
        register_validated_identity(
          state,
          identity,
          [registration_actor_verified: true],
          fn -> consume_registration_attestation(actor_attestation, target_digest) end
        )
      else
        false ->
          {:reply, {:error, {:agent_id_mismatch, identity.agent_id, :expected, expected_id}},
           state}

        {:error, _reason} = error ->
          {:reply, error, state}
      end
    end
  rescue
    _ -> {:reply, {:error, :invalid_identity}, state}
  catch
    :exit, _ -> {:reply, {:error, :registration_unavailable}, state}
  end

  defp dispatch_call(
         {:register_system_authority, %Identity{} = identity, proof, registration_token},
         {caller, _tag},
         state
       ) do
    expected_id = Crypto.derive_agent_id(identity.public_key)

    with {:ok, state} <-
           admit_system_authority_registration(state, caller, registration_token),
         :ok <- verify_registration_proof(identity, proof),
         true <- identity.agent_id == expected_id do
      register_validated_identity(state, identity, system_authority_bootstrap: true)
    else
      false -> {:reply, {:error, :identity_registration_unauthorized}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  rescue
    _ -> {:reply, {:error, :identity_registration_unauthorized}, state}
  catch
    _, _ -> {:reply, {:error, :identity_registration_unauthorized}, state}
  end

  defp dispatch_call({:register_system_authority, _identity, _proof}, _from, state),
    do: {:reply, {:error, :identity_registration_unauthorized}, state}

  defp dispatch_call(
         {:register_system_authority_from_supervisor, supervisor, %Identity{} = identity, proof,
          registration_token},
         {caller, _tag},
         state
       ) do
    expected_id = Crypto.derive_agent_id(identity.public_key)

    with {:ok, state} <-
           admit_system_authority_registration(
             state,
             caller,
             registration_token,
             supervisor
           ),
         :ok <- verify_registration_proof(identity, proof),
         true <- identity.agent_id == expected_id do
      ensure_system_authority_identity(state, identity)
    else
      false -> {:reply, {:error, :identity_registration_unauthorized}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  rescue
    _ -> {:reply, {:error, :identity_registration_unauthorized}, state}
  catch
    _, _ -> {:reply, {:error, :identity_registration_unauthorized}, state}
  end

  defp dispatch_call(
         {:register_scheduler_identity, %Identity{} = identity, proof},
         {caller, _tag},
         state
       ) do
    expected_id = Crypto.derive_agent_id(identity.public_key)

    with {:ok, state} <- admit_scheduler_identity_registration(state, caller),
         :ok <- verify_registration_proof(identity, proof),
         true <- identity.agent_id == expected_id do
      register_validated_identity(state, identity, scheduler_identity_bootstrap: true)
    else
      false -> {:reply, {:error, :identity_registration_unauthorized}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  rescue
    _ -> {:reply, {:error, :identity_registration_unauthorized}, state}
  catch
    _, _ -> {:reply, {:error, :identity_registration_unauthorized}, state}
  end

  defp dispatch_call(
         {:register_trust_capability_grant_identity, %Identity{} = identity, proof},
         {caller, _tag},
         state
       ) do
    expected_id = Crypto.derive_agent_id(identity.public_key)

    with {:ok, state} <- admit_trust_capability_grant_identity_registration(state, caller),
         :ok <- verify_registration_proof(identity, proof),
         true <- identity.agent_id == expected_id do
      register_validated_identity(state, identity, trust_capability_grant_owner_bootstrap: true)
    else
      false -> {:reply, {:error, :identity_registration_unauthorized}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  rescue
    _ -> {:reply, {:error, :identity_registration_unauthorized}, state}
  catch
    _, _ -> {:reply, {:error, :identity_registration_unauthorized}, state}
  end

  defp dispatch_call(
         {:register_system_lifecycle_identity, %Identity{} = identity, proof},
         {caller, _tag},
         state
       ) do
    expected_id = Crypto.derive_agent_id(identity.public_key)

    with {:ok, state} <- admit_system_lifecycle_identity_registration(state, caller),
         :ok <- verify_registration_proof(identity, proof),
         true <- identity.agent_id == expected_id do
      register_validated_identity(state, identity, system_lifecycle_identity_bootstrap: true)
    else
      false -> {:reply, {:error, :identity_registration_unauthorized}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  rescue
    _ -> {:reply, {:error, :identity_registration_unauthorized}, state}
  catch
    _, _ -> {:reply, {:error, :identity_registration_unauthorized}, state}
  end

  defp dispatch_call(
         {:register_oidc, %Identity{} = identity, id_token, provider_config, possession_proof},
         _from,
         state
       ) do
    with true <- human_identity?(identity),
         {:ok, claims} <- verify_oidc_token(id_token, provider_config),
         {:ok, expected_id} <- derive_verified_human_id(claims),
         :ok <- match_human_identity(identity.agent_id, expected_id),
         :ok <- verify_oidc_key_possession(identity, id_token, possession_proof) do
      metadata =
        if is_map(identity.metadata) do
          identity.metadata
          |> Map.put("oidc_issuer", claims["iss"])
          |> Map.put("oidc_sub", claims["sub"])
          |> Map.put("oidc_email", claims["email"])
          |> Map.put("oidc_email_verified", claims["email_verified"] == true)
          |> Map.put("identity_type", "human")
        else
          identity.metadata
        end

      identity =
        %{
          identity
          | metadata: metadata
        }

      registration_opts = [
        oidc_issuer: Map.get(claims, "iss"),
        oidc_subject: Map.get(claims, "sub"),
        oidc_email: Map.get(claims, "email"),
        oidc_email_verified: Map.get(claims, "email_verified") == true
      ]

      register_validated_identity(state, identity, registration_opts)
    else
      false -> {:reply, {:error, :invalid_human_identity}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  defp dispatch_call({:register_local_human, %Identity{} = identity}, _from, state) do
    with :ok <- admit_local_human_registration(identity),
         true <- human_identity?(identity),
         {:ok, expected_id} <- derive_local_human_id(identity),
         :ok <- match_human_identity(identity.agent_id, expected_id) do
      register_validated_identity(state, identity, oidc_issuer: @local_pseudo_issuer)
    else
      false -> {:reply, {:error, :invalid_human_identity}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  defp dispatch_call({:lookup, agent_id}, _from, state) do
    result =
      case Map.get(state.by_agent_id, agent_id) do
        nil -> {:error, :not_found}
        %{status: :suspended} -> {:error, :identity_suspended}
        %{status: :revoked} -> {:error, :identity_revoked}
        %{public_key: pk} -> {:ok, pk}
      end

    {:reply, result, state}
  end

  defp dispatch_call({:lookup_encryption_key, agent_id}, _from, state) do
    result =
      case Map.get(state.by_agent_id, agent_id) do
        nil -> {:error, :not_found}
        %{status: :suspended} -> {:error, :identity_suspended}
        %{status: :revoked} -> {:error, :identity_revoked}
        %{encryption_public_key: nil} -> {:error, :no_encryption_key}
        %{encryption_public_key: key} -> {:ok, key}
      end

    {:reply, result, state}
  end

  defp dispatch_call({:registered?, agent_id}, _from, state) do
    {:reply, Map.has_key?(state.by_agent_id, agent_id), state}
  end

  defp dispatch_call({:deregister, _agent_id}, _from, state),
    do: {:reply, {:error, :identity_status_mutation_unauthorized}, state}

  defp dispatch_call({:identity_status_payload_digest, agent_id, operation, reason}, _from, state) do
    {:reply, status_payload_digest(state, agent_id, operation, reason), state}
  end

  defp dispatch_call({:deregister_authorized, agent_id, attestation}, _from, state) do
    with {:ok, digest} <- status_payload_digest(state, agent_id, :deregister, nil),
         :ok <- consume_status_attestation(attestation, :deregister, digest) do
      deregister_identity(state, agent_id)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp dispatch_call({:lookup_by_name, name}, _from, state) do
    case Map.get(state.by_name, name) do
      nil -> {:reply, {:error, :not_found}, state}
      [] -> {:reply, {:error, :not_found}, state}
      agent_ids -> {:reply, {:ok, agent_ids}, state}
    end
  end

  defp dispatch_call(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        active_identities: map_size(state.by_agent_id),
        named_identities: map_size(state.by_name)
      })

    {:reply, stats, state}
  end

  # ===========================================================================
  # Lifecycle Callbacks
  # ===========================================================================

  defp dispatch_call({:suspend, _agent_id, _reason}, _from, state),
    do: {:reply, {:error, :identity_status_mutation_unauthorized}, state}

  defp dispatch_call({:suspend_authorized, agent_id, reason, attestation}, _from, state) do
    with {:ok, digest} <- status_payload_digest(state, agent_id, :suspend, reason),
         :ok <- consume_status_attestation(attestation, :suspend, digest) do
      suspend_identity(state, agent_id, reason)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp dispatch_call({:resume, _agent_id}, _from, state),
    do: {:reply, {:error, :identity_status_mutation_unauthorized}, state}

  defp dispatch_call({:resume_authorized, agent_id, attestation}, _from, state) do
    with {:ok, digest} <- status_payload_digest(state, agent_id, :resume, nil),
         :ok <- consume_status_attestation(attestation, :resume, digest) do
      resume_identity(state, agent_id)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp dispatch_call({:revoke_identity, _agent_id, _reason}, _from, state),
    do: {:reply, {:error, :identity_status_mutation_unauthorized}, state}

  defp dispatch_call({:revoke_identity_authorized, agent_id, reason, attestation}, _from, state) do
    with {:ok, digest} <- status_payload_digest(state, agent_id, :revoke, reason),
         :ok <- consume_status_attestation(attestation, :revoke, digest) do
      revoke_identity(state, agent_id, reason)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp dispatch_call({:get_status, agent_id}, _from, state) do
    entry = Map.get(state.by_agent_id, agent_id)

    result =
      cond do
        is_nil(entry) ->
          {:error, :not_found}

        local_identity_rejected?(entry) ->
          Logger.error(
            "[IdentityRegistry] REFUSING local-issuer human principal #{agent_id} " <>
              "in a non-dev environment. Its recorded oidc_issuer is " <>
              "#{inspect(@local_pseudo_issuer)}, meaning it was minted by " <>
              "mix arbor.user.init on a development install and must never " <>
              "authenticate here. This should be unreachable — the security " <>
              "state root is environment-specific — so a shared or copied " <>
              "authority store is the likely cause."
          )

          {:error, :not_found}

        true ->
          case entry do
            %{status: status} -> {:ok, status}
            # Old entries without status field default to :unknown
            _ -> {:ok, :unknown}
          end
      end

    {:reply, result, state}
  end

  if Mix.env() == :test do
    defp dispatch_call(:test_system_authority_registration_token, _from, state) do
      reply =
        case registration_custody(state) do
          {:ok, %{registration_token: token}} -> token
          {:error, _reason} -> nil
        end

      {:reply, reply, state}
    end

    defp dispatch_call({:register_fixture, %Identity{} = identity}, _from, state) do
      expected_id = Crypto.derive_agent_id(identity.public_key)

      if not human_identity?(identity) and identity.agent_id == expected_id do
        register_validated_identity(state, identity, test_fixture_registration: true)
      else
        {:reply, {:error, :invalid_identity}, state}
      end
    end

    defp dispatch_call(
           {:reconcile_remote_authority_result_fixture, type, agent_id, authority_result},
           _from,
           state
         ) do
      {:reply, :ok, reconcile_remote_authority_result(type, agent_id, authority_result, state)}
    end

    defp dispatch_call({:deregister_fixture, agent_id}, _from, state),
      do: deregister_identity(state, agent_id)

    defp dispatch_call({:suspend_fixture, agent_id, reason}, _from, state),
      do: suspend_identity(state, agent_id, reason)

    defp dispatch_call({:resume_fixture, agent_id}, _from, state),
      do: resume_identity(state, agent_id)

    defp dispatch_call({:revoke_identity_fixture, agent_id, reason}, _from, state),
      do: revoke_identity(state, agent_id, reason)
  end

  defp raw_read_request?(:stats), do: true
  defp raw_read_request?({:lookup, _agent_id}), do: true
  defp raw_read_request?({:lookup_encryption_key, _agent_id}), do: true
  defp raw_read_request?({:registered?, _agent_id}), do: true

  defp raw_read_request?({:identity_status_payload_digest, _agent_id, _operation, _reason}),
    do: true

  defp raw_read_request?({:lookup_by_name, _name}), do: true
  defp raw_read_request?({:get_status, _agent_id}), do: true
  defp raw_read_request?(_request), do: false

  # DETECTIVE control, complementing the preventive ones.
  #
  # `mix arbor.user.init` can only MINT a local-issuer human identity under
  # three dev gates, and prod uses a different `authority_state_root` (it fails
  # closed at freeze without an explicit one), so such a record should never be
  # visible here. Those are both preventive: if the roots are ever merged — a
  # copied store, a restored backup, an operator pointing
  # ARBOR_SECURITY_STATE_DIR at the dev directory — nothing would notice.
  #
  # The provenance is recorded on the identity, so notice. Refuse to resolve
  # any human principal whose issuer is the local pseudo-issuer unless this
  # really is a dev install. Returning `:not_found` is the honest answer for
  # authorization purposes — as far as this environment is concerned, that
  # principal does not exist — and `AuthDecision` already fails it closed as
  # `:unknown_identity` under strict identity mode.
  defp local_identity_rejected?(%{metadata: metadata}) when is_map(metadata) do
    issuer = Map.get(metadata, "oidc_issuer") || Map.get(metadata, :oidc_issuer)

    issuer == @local_pseudo_issuer and
      Application.get_env(:arbor_security, :allow_local_human_identity, false) != true
  end

  defp local_identity_rejected?(_entry), do: false

  defp deregister_identity(state, agent_id) do
    case Map.get(state.by_agent_id, agent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{public_key: pk, name: name} ->
        case commit_identity_delete(state, agent_id) do
          {:ok, state} ->
            pk_hash = Crypto.hash(pk)

            state =
              state
              |> update_in([:by_agent_id], &Map.delete(&1, agent_id))
              |> update_in([:by_public_key_hash], &Map.delete(&1, pk_hash))
              |> deindex_by_name(name, agent_id)
              |> update_in([:authority_records], &Map.delete(&1, agent_id))
              |> update_in([:stats, :total_deregistered], &(&1 + 1))

            emit_identity_signal(:identity_deregistered, agent_id)
            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  defp suspend_identity(state, agent_id, reason) do
    case Map.get(state.by_agent_id, agent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: :revoked} ->
        {:reply, {:error, :cannot_suspend_revoked}, state}

      entry ->
        updated_entry = %{
          entry
          | status: :suspended,
            status_changed_at: DateTime.utc_now(),
            status_reason: reason
        }

        commit_identity_status(state, agent_id, updated_entry, :identity_suspended)
    end
  end

  defp resume_identity(state, agent_id) do
    case Map.get(state.by_agent_id, agent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: :revoked} ->
        {:reply, {:error, :cannot_resume_revoked}, state}

      entry ->
        updated_entry = %{
          entry
          | status: :active,
            status_changed_at: DateTime.utc_now(),
            status_reason: nil
        }

        commit_identity_status(state, agent_id, updated_entry, :identity_resumed)
    end
  end

  defp revoke_identity(state, agent_id, reason) do
    case Map.get(state.by_agent_id, agent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        updated_entry = %{
          entry
          | status: :revoked,
            status_changed_at: DateTime.utc_now(),
            status_reason: reason
        }

        case commit_identity_update(state, agent_id, updated_entry) do
          {:ok, state} ->
            state = put_in(state, [:by_agent_id, agent_id], updated_entry)
            emit_identity_signal(:identity_revoked, agent_id)

            # Capability cleanup uses its own independently authorized receipt
            # at the Security facade. Status becomes terminal first so any
            # residual capability is unusable even if cleanup is interrupted.
            {:reply, {:ok, 0}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp register_validated_identity(
         state,
         identity,
         opts,
         authorize_commit \\ fn -> :ok end
       ) do
    with :ok <- validate_public_identity(identity),
         :ok <- authorize_registration(identity, opts) do
      if Map.has_key?(state.by_agent_id, identity.agent_id) do
        {:reply, {:error, {:already_registered, identity.agent_id}}, state}
      else
        pk_hash = Crypto.hash(identity.public_key)

        case Map.fetch(state.by_public_key_hash, pk_hash) do
          {:ok, existing_agent_id} ->
            {:reply, {:error, {:public_key_already_registered, existing_agent_id}}, state}

          :error ->
            entry = %{
              public_key: identity.public_key,
              encryption_public_key: identity.encryption_public_key,
              name: identity.name,
              key_version: identity.key_version,
              created_at: identity.created_at,
              metadata: identity.metadata,
              status: Map.get(identity, :status, :active),
              status_changed_at: Map.get(identity, :status_changed_at),
              status_reason: Map.get(identity, :status_reason)
            }

            with :ok <- authorize_commit.(),
                 {:ok, state} <- commit_new_identity(state, identity.agent_id, entry) do
              state =
                state
                |> put_in([:by_agent_id, identity.agent_id], entry)
                |> put_in([:by_public_key_hash, pk_hash], identity.agent_id)
                |> index_by_name(identity.name, identity.agent_id)
                |> update_in([:stats, :total_registered], &(&1 + 1))

              emit_identity_signal(:identity_registered, identity.agent_id)
              {:reply, :ok, state}
            else
              {:error, reason} -> {:reply, {:error, reason}, state}
            end
        end
      end
    else
      {:error, _} = error -> {:reply, error, state}
    end
  rescue
    _ -> {:reply, {:error, :invalid_identity}, state}
  catch
    :exit, _ -> {:reply, {:error, :registration_unavailable}, state}
  end

  defp validate_public_identity(%Identity{} = identity) do
    with true <- is_binary(identity.agent_id),
         true <- is_binary(identity.public_key) and byte_size(identity.public_key) == 32,
         true <-
           is_nil(identity.encryption_public_key) or
             valid_public_key?(identity.encryption_public_key),
         true <- is_nil(identity.name) or is_binary(identity.name),
         true <- is_integer(identity.key_version) and identity.key_version > 0,
         true <- match?(%DateTime{}, identity.created_at),
         true <- is_map(identity.metadata),
         true <- Identity.valid_status?(identity.status),
         true <-
           is_nil(identity.status_changed_at) or match?(%DateTime{}, identity.status_changed_at),
         true <- is_nil(identity.status_reason) or is_binary(identity.status_reason),
         :ok <-
           validate_identity_binding(identity.agent_id, identity.public_key, identity.metadata) do
      :ok
    else
      _ -> {:error, :invalid_identity}
    end
  end

  defp valid_public_key?(key), do: is_binary(key) and byte_size(key) == 32

  defp validate_identity_binding("agent_" <> _rest = agent_id, public_key, _metadata) do
    if Crypto.derive_agent_id(public_key) == agent_id, do: :ok, else: {:error, :invalid_identity}
  end

  defp validate_identity_binding("human_" <> _rest = agent_id, _public_key, metadata) do
    issuer = metadata["oidc_issuer"] || metadata[:oidc_issuer]
    subject = metadata["oidc_sub"] || metadata[:oidc_sub]

    if is_binary(issuer) and issuer != "" and is_binary(subject) and subject != "" and
         IdentityStore.derive_agent_id(%{iss: issuer, sub: subject}) == agent_id do
      :ok
    else
      {:error, :invalid_identity}
    end
  rescue
    _ -> {:error, :invalid_identity}
  end

  defp validate_identity_binding(_agent_id, _public_key, _metadata),
    do: {:error, :invalid_identity}

  defp authorize_registration(identity, opts) do
    case registration_authorized(identity, opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:registration_denied, reason}}
      _ -> {:error, {:registration_denied, :invalid_policy_result}}
    end
  end

  defp consume_registration_attestation(attestation, target_digest) do
    case Arbor.Security.SystemAuthority.consume_identity_registration_attestation(
           attestation,
           target_digest
         ) do
      :ok -> :ok
      {:error, _reason} -> {:error, :identity_registration_unauthorized}
      _ -> {:error, :identity_registration_unauthorized}
    end
  rescue
    _ -> {:error, :identity_registration_unauthorized}
  catch
    _, _ -> {:error, :identity_registration_unauthorized}
  end

  defp admit_system_authority_registration(state, caller, supplied) when is_pid(caller) do
    with {:ok, custody} <- registration_custody(state),
         true <- supplied === custody.registration_token,
         {:ok, next_custody} <- admit_registered_role(custody, :system_authority, caller),
         :ok <- put_registration_custody(state, next_custody) do
      {:ok, state}
    else
      _ -> {:error, :identity_registration_unauthorized}
    end
  end

  defp admit_system_authority_registration(_state, _caller, _registration_token),
    do: {:error, :identity_registration_unauthorized}

  defp admit_system_authority_registration(state, caller, supplied, supervisor)
       when is_pid(caller) and is_pid(supervisor) do
    with {:ok, custody} <- registration_custody(state),
         true <- supplied === custody.registration_token,
         true <- supervisor === custody.security_supervisor_pid,
         {:ok, spec} <- Map.fetch(custody.role_specs, :system_authority),
         true <- startup_registration_owner?(supervisor, caller, spec),
         {:ok, next_custody} <- bind_registered_role(custody, :system_authority, caller),
         :ok <- put_registration_custody(state, next_custody) do
      {:ok, state}
    else
      _ -> {:error, :identity_registration_unauthorized}
    end
  end

  defp admit_system_authority_registration(_state, _caller, _supplied, _supervisor),
    do: {:error, :identity_registration_unauthorized}

  defp admit_registered_role(custody, role, caller) do
    with {:ok, pid_key} <- registration_role_pid_key(role),
         {:ok, spec} <- Map.fetch(custody.role_specs, role),
         true <- legitimate_registration_owner?(caller, spec) do
      bind_registered_role_pid(custody, pid_key, caller)
    else
      _ -> {:error, :identity_registration_unauthorized}
    end
  end

  defp bind_registered_role(custody, role, caller) when is_atom(role) do
    with {:ok, pid_key} <- registration_role_pid_key(role) do
      bind_registered_role_pid(custody, pid_key, caller)
    end
  end

  defp bind_registered_role_pid(custody, pid_key, caller) do
    case Map.fetch!(custody, pid_key) do
      ^caller ->
        {:ok, custody}

      nil ->
        {:ok, Map.put(custody, pid_key, caller)}

      bound when is_pid(bound) ->
        if Process.alive?(bound),
          do: {:error, :identity_registration_unauthorized},
          else: {:ok, Map.put(custody, pid_key, caller)}
    end
  end

  defp registration_role_pid_key(:system_authority), do: {:ok, :system_authority_pid}
  defp registration_role_pid_key(:scheduler_owner), do: {:ok, :scheduler_identity_pid}

  defp registration_role_pid_key(:trust_grant_owner),
    do: {:ok, :trust_capability_grant_owner_pid}

  defp registration_role_pid_key(:system_lifecycle_owner),
    do: {:ok, :system_lifecycle_owner_pid}

  defp registration_role_pid_key(_role), do: {:error, :invalid_role}

  defp registration_custody(%{registration_custody: custody}) do
    PrivateState.fetch(
      custody,
      @registration_custody_anchor,
      @registration_custody_schema,
      &valid_registration_custody?/1
    )
  end

  defp registration_custody(_state), do: {:error, :invalid_private_state}

  defp put_registration_custody(%{registration_custody: custody}, value) do
    PrivateState.replace(
      custody,
      @registration_custody_anchor,
      @registration_custody_schema,
      value,
      &valid_registration_custody?/1
    )
  end

  defp put_registration_custody(_state, _value), do: {:error, :invalid_private_state}

  defp valid_registration_custody?(
         %{
           registration_token: token,
           security_supervisor_pid: supervisor_pid,
           role_specs: role_specs,
           system_authority_pid: authority_pid,
           scheduler_identity_pid: scheduler_pid,
           trust_capability_grant_owner_pid: trust_pid,
           system_lifecycle_owner_pid: lifecycle_pid
         } = custody
       ) do
    Map.keys(custody) |> Enum.sort() ==
      [
        :registration_token,
        :role_specs,
        :scheduler_identity_pid,
        :security_supervisor_pid,
        :system_authority_pid,
        :system_lifecycle_owner_pid,
        :trust_capability_grant_owner_pid
      ] and
      is_reference(token) and is_pid(supervisor_pid) and
      valid_registration_role_specs?(role_specs) and
      Enum.all?(
        [authority_pid, scheduler_pid, trust_pid, lifecycle_pid],
        &(is_nil(&1) or is_pid(&1))
      )
  end

  defp valid_registration_custody?(_custody), do: false

  defp admit_scheduler_identity_registration(state, caller) when is_pid(caller) do
    with {:ok, custody} <- registration_custody(state),
         {:ok, next_custody} <- admit_registered_role(custody, :scheduler_owner, caller),
         :ok <- put_registration_custody(state, next_custody) do
      {:ok, state}
    else
      _ -> {:error, :identity_registration_unauthorized}
    end
  end

  defp admit_scheduler_identity_registration(_state, _caller),
    do: {:error, :identity_registration_unauthorized}

  defp admit_trust_capability_grant_identity_registration(state, caller) when is_pid(caller) do
    with {:ok, custody} <- registration_custody(state),
         {:ok, next_custody} <- admit_registered_role(custody, :trust_grant_owner, caller),
         :ok <- put_registration_custody(state, next_custody) do
      {:ok, state}
    else
      _ -> {:error, :identity_registration_unauthorized}
    end
  end

  defp admit_trust_capability_grant_identity_registration(_state, _caller),
    do: {:error, :identity_registration_unauthorized}

  defp admit_system_lifecycle_identity_registration(state, caller) when is_pid(caller) do
    with {:ok, custody} <- registration_custody(state),
         {:ok, next_custody} <- admit_registered_role(custody, :system_lifecycle_owner, caller),
         :ok <- put_registration_custody(state, next_custody) do
      {:ok, state}
    else
      _ -> {:error, :identity_registration_unauthorized}
    end
  end

  defp admit_system_lifecycle_identity_registration(_state, _caller),
    do: {:error, :identity_registration_unauthorized}

  defp legitimate_registration_owner?(caller, spec) do
    registered_name(caller) == spec.registered_name and
      SupervisedOwner.authorized?(caller, spec.application, spec.path)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp startup_registration_owner?(supervisor, caller, spec) do
    registered_name(caller) == spec.registered_name and
      SupervisedOwner.child_pid(supervisor, __MODULE__) == self() and
      supervised_child_at_path(supervisor, spec.path) == caller
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp supervised_child_at_path(supervisor, child_path) do
    Enum.reduce_while(child_path, supervisor, fn child_id, parent ->
      case SupervisedOwner.child_pid(parent, child_id) do
        child when is_pid(child) -> {:cont, child}
        _ -> {:halt, nil}
      end
    end)
  end

  defp ensure_system_authority_identity(state, identity) do
    case Map.get(state.by_agent_id, identity.agent_id) do
      nil ->
        register_validated_identity(state, identity, system_authority_bootstrap: true)

      %{
        public_key: public_key,
        encryption_public_key: encryption_public_key,
        status: :active
      }
      when public_key == identity.public_key and
             encryption_public_key == identity.encryption_public_key ->
        {:reply, :ok, state}

      _existing ->
        {:reply, {:error, :registration_conflict}, state}
    end
  end

  defp valid_registration_role_specs?(specs) when is_map(specs) do
    Map.keys(specs) |> Enum.sort() == Enum.sort(Config.identity_registration_roles()) and
      Enum.all?(specs, fn {_role, spec} -> valid_registration_role_spec?(spec) end)
  end

  defp valid_registration_role_specs?(_specs), do: false

  defp valid_registration_role_spec?(%{
         application: application,
         path: path,
         registered_name: registered_name
       }) do
    is_atom(application) and not is_nil(application) and is_list(path) and path != [] and
      Enum.all?(path, &(is_atom(&1) and not is_nil(&1))) and is_atom(registered_name) and
      not is_nil(registered_name)
  end

  defp valid_registration_role_spec?(_spec), do: false

  defp registered_name(pid) when is_pid(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) -> name
      _ -> nil
    end
  end

  defp status_payload_digest(state, agent_id, operation, reason)
       when operation in @status_mutation_operations do
    with %{public_key: public_key} = entry when is_binary(public_key) <-
           Map.get(state.by_agent_id, agent_id),
         {:ok, canonical} <-
           TaintEnvelope.canonical_json(%{
             "agent_id" => agent_id,
             "current" => serialize_entry(agent_id, entry),
             "operation" => Atom.to_string(operation),
             "reason" => reason
           }) do
      digest = :crypto.hash(:sha256, @status_mutation_domain <> canonical)
      {:ok, Base.encode16(digest, case: :lower)}
    else
      nil -> {:error, :not_found}
      _ -> {:error, :identity_status_mutation_unauthorized}
    end
  rescue
    _ -> {:error, :identity_status_mutation_unauthorized}
  catch
    _, _ -> {:error, :identity_status_mutation_unauthorized}
  end

  defp status_payload_digest(_state, _agent_id, _operation, _reason),
    do: {:error, :identity_status_mutation_unauthorized}

  defp consume_status_attestation(attestation, operation, payload_digest) do
    case Arbor.Security.SystemAuthority.consume_identity_status_mutation_attestation(
           attestation,
           operation,
           payload_digest
         ) do
      :ok -> :ok
      _ -> {:error, :identity_status_mutation_unauthorized}
    end
  rescue
    _ -> {:error, :identity_status_mutation_unauthorized}
  catch
    _, _ -> {:error, :identity_status_mutation_unauthorized}
  end

  defp verify_oidc_token(id_token, provider_config) do
    case TokenVerifier.verify(id_token, provider_config) do
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      {:error, reason} -> {:error, {:oidc_verification_failed, reason}}
      _ -> {:error, {:oidc_verification_failed, :invalid_verifier_result}}
    end
  rescue
    _ -> {:error, {:oidc_verification_failed, :invalid_provenance}}
  catch
    :exit, _ -> {:error, {:oidc_verification_failed, :verification_unavailable}}
  end

  defp derive_verified_human_id(%{"iss" => issuer, "sub" => subject} = claims)
       when is_binary(issuer) and issuer != "" and is_binary(subject) and subject != "" do
    {:ok, IdentityStore.derive_agent_id(claims)}
  rescue
    _ -> {:error, :invalid_oidc_claims}
  end

  defp derive_verified_human_id(_claims), do: {:error, :invalid_oidc_claims}

  defp match_human_identity(actual_id, expected_id) when actual_id == expected_id, do: :ok

  defp match_human_identity(actual_id, expected_id),
    do: {:error, {:oidc_identity_mismatch, actual_id, :expected, expected_id}}

  defp verify_registration_proof(identity, proof)
       when is_binary(proof) and byte_size(proof) == 64 do
    if Crypto.verify(registration_payload(identity), proof, identity.public_key),
      do: :ok,
      else: {:error, :invalid_identity_proof}
  rescue
    _ -> {:error, :invalid_identity_proof}
  catch
    _, _ -> {:error, :invalid_identity_proof}
  end

  defp verify_registration_proof(_identity, _proof),
    do: {:error, :identity_proof_required}

  defp registration_payload(%Identity{} = identity) do
    @registration_domain <>
      length_prefix(identity.agent_id) <>
      length_prefix(identity.public_key) <>
      length_prefix(identity.encryption_public_key || <<>>) <>
      <<identity.key_version::unsigned-big-64>>
  end

  defp length_prefix(value) when is_binary(value),
    do: <<byte_size(value)::unsigned-big-32, value::binary>>

  defp build_oidc_key_possession_proof(
         %Identity{private_key: private_key} = identity,
         id_token
       )
       when is_binary(private_key) do
    {:ok, Crypto.sign(oidc_key_possession_payload(identity, id_token), private_key)}
  rescue
    _ -> {:error, :invalid_key_possession}
  catch
    _, _ -> {:error, :invalid_key_possession}
  end

  defp build_oidc_key_possession_proof(_identity, _id_token),
    do: {:error, :key_possession_proof_required}

  defp verify_oidc_key_possession(identity, id_token, proof)
       when is_binary(proof) and byte_size(proof) == 64 do
    if Crypto.verify(oidc_key_possession_payload(identity, id_token), proof, identity.public_key),
      do: :ok,
      else: {:error, :invalid_key_possession}
  rescue
    _ -> {:error, :invalid_key_possession}
  catch
    _, _ -> {:error, :invalid_key_possession}
  end

  defp verify_oidc_key_possession(_identity, _id_token, _proof),
    do: {:error, :invalid_key_possession}

  @doc false
  def oidc_key_possession_payload(%Identity{} = identity, id_token) when is_binary(id_token) do
    agent_id = identity.agent_id
    token_hash = :crypto.hash(:sha256, id_token)

    "arbor:oidc-human-key-possession:v1" <>
      <<byte_size(agent_id)::unsigned-big-32>> <>
      agent_id <>
      identity.public_key <>
      token_hash
  end

  # Re-check the gate at this boundary. The facade checks it too; a security
  # kernel should not rely on its caller having done so.
  defp admit_local_human_registration(identity) do
    issuer = identity_issuer(identity)

    cond do
      Application.get_env(:arbor_security, :allow_local_human_identity, false) != true ->
        {:error, :local_human_identity_disabled}

      issuer != @local_pseudo_issuer ->
        {:error, {:not_a_local_identity, issuer}}

      true ->
        :ok
    end
  end

  defp identity_issuer(%Identity{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "oidc_issuer") || Map.get(metadata, :oidc_issuer)
  end

  defp identity_issuer(_identity), do: nil

  # The same derivation `register_oidc/3` verifies, over the identity's own
  # recorded claims. This proves the id was not hand-chosen; it does not prove
  # the issuer, which is the part the dev gates deliberately stand in for.
  defp derive_local_human_id(%Identity{metadata: metadata}) when is_map(metadata) do
    issuer = Map.get(metadata, "oidc_issuer") || Map.get(metadata, :oidc_issuer)
    subject = Map.get(metadata, "oidc_sub") || Map.get(metadata, :oidc_sub)

    derive_verified_human_id(%{"iss" => issuer, "sub" => subject})
  end

  defp derive_local_human_id(_identity), do: {:error, :invalid_oidc_claims}

  defp human_identity?(identity) do
    case Map.get(identity, :agent_id) do
      "human_" <> _rest -> true
      _ -> false
    end
  end

  defp nested_map_count(state, key) when is_map(state) do
    case Map.get(state, key) do
      value when is_map(value) -> map_size(value)
      _ -> 0
    end
  end

  defp nested_map_count(_state, _key), do: 0

  defp server_call(message, timeout \\ 5_000) do
    case server_pid() do
      pid when is_pid(pid) -> Arbor.Common.authenticated_call(pid, message, timeout)
      nil -> exit({:noproc, {Arbor.Common, :authenticated_call, [__MODULE__, message, timeout]}})
    end
  end

  defp server_pid do
    SupervisedOwner.protected_directory_owner(
      @owner_directory,
      :owner,
      :arbor_security,
      [__MODULE__]
    )
  end

  defp claim_owner_directory do
    table = :ets.new(@owner_directory, [:named_table, :protected, :set, read_concurrency: true])
    true = :ets.insert(table, {:owner, self()})
    :ok
  rescue
    _ -> {:error, :identity_registry_owner_directory_unavailable}
  end

  defp defer_initialization(opts) when is_list(opts) do
    case Keyword.get(opts, :defer_initialization, false) do
      value when is_boolean(value) -> {:ok, value}
      _invalid -> {:error, :invalid_registry_startup}
    end
  rescue
    _ -> {:error, :invalid_registry_startup}
  end

  defp defer_initialization(_opts), do: {:error, :invalid_registry_startup}

  defp startup_supervisor_pid do
    case Process.get(:"$ancestors") do
      [pid | _] when is_pid(pid) -> linked_supervisor(pid)
      [name | _] when is_atom(name) -> name |> Process.whereis() |> linked_supervisor()
      _other -> {:error, :security_supervisor_unavailable}
    end
  end

  defp linked_supervisor(pid) when is_pid(pid) do
    case Process.info(self(), :links) do
      {:links, links} when is_list(links) ->
        if pid in links, do: {:ok, pid}, else: {:error, :security_supervisor_unavailable}

      _other ->
        {:error, :security_supervisor_unavailable}
    end
  end

  defp linked_supervisor(_pid), do: {:error, :security_supervisor_unavailable}

  defp registration_token(opts) do
    case Keyword.get(opts, :system_authority_registration_token) do
      token when is_reference(token) -> {:ok, token}
      nil when @test_env -> {:ok, make_ref()}
      _ -> {:error, :system_authority_registration_token_required}
    end
  rescue
    _ -> {:error, :system_authority_registration_token_required}
  end

  defp registration_role_specs(opts) do
    case Keyword.get(opts, :registration_role_specs) do
      specs when is_map(specs) ->
        if valid_registration_role_specs?(specs),
          do: {:ok, specs},
          else: {:error, :invalid_registration_role_specs}

      nil when @test_env ->
        with {:ok, roles} <- Config.signing_key_owner_roles(),
             specs <- Map.take(roles, Config.identity_registration_roles()),
             true <- valid_registration_role_specs?(specs) do
          {:ok, specs}
        else
          _ -> {:error, :invalid_registration_role_specs}
        end

      _ ->
        {:error, :invalid_registration_role_specs}
    end
  rescue
    _ -> {:error, :invalid_registration_role_specs}
  end

  defp redact_status_field(status, key) do
    if Map.has_key?(status, key), do: Map.put(status, key, :redacted), else: status
  end

  defp index_by_name(state, nil, _agent_id), do: state

  defp index_by_name(state, name, agent_id) do
    update_in(state, [:by_name, name], fn
      nil -> [agent_id]
      ids -> [agent_id | ids]
    end)
  end

  defp deindex_by_name(state, nil, _agent_id), do: state

  defp deindex_by_name(state, name, agent_id) do
    update_in(state, [:by_name, name], fn
      nil -> nil
      ids -> List.delete(ids, agent_id)
    end)
  end

  # ===========================================================================
  # Distributed Signal Handling
  # ===========================================================================

  @impl true
  def handle_info({:signal_received, delivery_ref, signal}, state) do
    if state.initialization == :ready and
         SignalSync.admit_delivery?(state.signal_sync, delivery_ref, signal) do
      {:noreply, handle_distributed_signal(signal, state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(message, state) do
    case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
      {:authenticated, caller, request, reply_to} ->
        if state.initialization == :ready do
          case dispatch_call(request, {caller, reply_to}, state) do
            {:reply, reply, next_state} ->
              :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
              {:noreply, next_state}

            {:stop, reason, reply, next_state} ->
              :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
              {:stop, reason, next_state}
          end
        else
          :ok =
            Arbor.Common.reply_authenticated_call(
              reply_to,
              {:error, :identity_registration_unauthorized}
            )

          {:noreply, state}
        end

      result when result in [:pending, :expired, :rejected] ->
        {:noreply, state}

      :unrecognized ->
        if state.initialization == :ready do
          case SignalSync.handle_info(message, state.signal_sync) do
            {:ok, signal_sync} ->
              {:noreply, %{state | signal_sync: signal_sync}}

            {:stop, reason, signal_sync} ->
              {:stop, reason, %{state | signal_sync: signal_sync}}

            :unhandled ->
              {:noreply, state}
          end
        else
          {:noreply, state}
        end
    end
  end

  @impl true
  def terminate(_reason, state) do
    SignalSync.release(Map.get(state, :signal_sync))
    PrivateState.delete(Map.get(state, :registration_custody), @registration_custody_anchor)
  end

  @impl true
  def format_status(status) when is_map(status) do
    state = Map.get(status, :state, %{})

    redacted_state = %{
      identity_count: nested_map_count(state, :by_agent_id),
      name_index_count: nested_map_count(state, :by_name)
    }

    status
    |> Map.put(:message, :redacted)
    |> Map.put(:state, redacted_state)
    |> redact_status_field(:reason)
    |> redact_status_field(:log)
  end

  # C10 registration-authorization seam. Config.registration_policy/0 returns
  # a module implementing authorize_registration/2. The default policy admits
  # self-certifying agents and allowlisted OIDC humans. A configured policy
  # that is missing or crashes fails closed.
  defp registration_authorized(identity, opts) do
    case registration_policy_module() do
      nil ->
        {:error, :registration_policy_unavailable}

      policy when is_atom(policy) ->
        if Code.ensure_loaded?(policy) and function_exported?(policy, :authorize_registration, 2) do
          apply(policy, :authorize_registration, [identity, opts])
        else
          # Misconfigured policy — fail closed rather than silently allow.
          {:error, :registration_policy_unavailable}
        end
    end
  rescue
    _ -> {:error, :registration_policy_error}
  catch
    :exit, _ -> {:error, :registration_policy_error}
  end

  defp registration_policy_module do
    config = Arbor.Security.Config

    if Code.ensure_loaded?(config) and function_exported?(config, :registration_policy, 0) do
      apply(config, :registration_policy, [])
    else
      nil
    end
  end

  defp subscribe_to_distributed_signals do
    SignalSync.establish(
      :identity_registry,
      @signal_events,
      Config.distributed_signals_enabled?()
    )
  end

  defp emit_identity_signal(type, agent_id) do
    if Config.distributed_signals_enabled?() do
      Signals.emit(
        :security,
        type,
        %{
          agent_id: agent_id,
          origin_node: node()
        },
        scope: :cluster
      )
    end
  catch
    _, _ -> :ok
  end

  defp handle_distributed_signal(signal, state) do
    origin_node = signal.data[:origin_node] || signal.data["origin_node"]
    permanent_audit? = (signal.data[:permanent] || signal.data["permanent"]) == true

    cond do
      # The telemetry bridge reflects permanent audit observations onto the
      # signal bus. They are observability, not distributed mutation transport.
      permanent_audit? ->
        state

      origin_node in [node(), Atom.to_string(node())] ->
        state

      not Signals.admit_remote_security_mutation?(signal.type) ->
        state

      true ->
        handle_remote_identity_signal(signal.type, signal.data, state)
    end
  catch
    _, reason ->
      Logger.warning("[IdentityRegistry] Failed to handle distributed signal: #{inspect(reason)}")
      state
  end

  defp handle_remote_identity_signal(type, data, state)
       when type in @signal_events do
    case data[:agent_id] || data["agent_id"] do
      agent_id when is_binary(agent_id) -> reconcile_remote_identity(type, agent_id, state)
      _invalid -> state
    end
  end

  defp handle_remote_identity_signal(_type, _data, state), do: state

  defp reconcile_remote_identity(type, agent_id, %{authority_mode: :durable} = state) do
    reconcile_remote_authority_result(type, agent_id, authority_get(state, agent_id), state)
  end

  defp reconcile_remote_identity(type, agent_id, %{authority_mode: :hot_only} = state) do
    case type do
      :identity_deregistered -> remove_hot_identity(state, agent_id)
      :identity_suspended -> reduce_hot_identity(state, agent_id, :suspended)
      :identity_revoked -> reduce_hot_identity(state, agent_id, :revoked)
      _authority_restoring -> state
    end
  end

  defp reconcile_remote_authority_result(type, agent_id, authority_result, state) do
    case authority_result do
      {:ok, record, entry} ->
        # The authoritative record may already contain the mutation when nodes
        # share a backend. Refresh the local CAS baseline first; otherwise make
        # the monotonic reduction durable on this node before changing the hot
        # view. A transient write failure removes the hot identity so the event
        # cannot fail open for the lifetime of this Registry process.
        state = put_in(state, [:authority_records, agent_id], record)
        persist_remote_identity_reduction(type, agent_id, entry, record, state)

      {:error, :not_found} ->
        if type == :identity_deregistered,
          do: remove_hot_identity(state, agent_id),
          else: state

      {:error, _reason} ->
        # A transport event is only a hint to re-read durable authority. A
        # transient/unparseable read cannot prove revocation or absence and
        # must not erase a previously admitted hot identity.
        state
    end
  end

  defp persist_remote_identity_reduction(type, agent_id, entry, record, state) do
    case remote_entry_for_event(type, entry) do
      {:ok, ^entry} ->
        if remote_public_key_available?(state, agent_id, entry),
          do: replace_hot_identity(state, agent_id, entry, record),
          else: fail_closed_remote(type, agent_id, state)

      {:ok, event_entry} ->
        if remote_public_key_available?(state, agent_id, event_entry) do
          case commit_identity_update(state, agent_id, event_entry) do
            {:ok, persisted_state} ->
              put_in(persisted_state, [:by_agent_id, agent_id], event_entry)

            {:error, _reason} ->
              fail_closed_remote(type, agent_id, state)
          end
        else
          fail_closed_remote(type, agent_id, state)
        end

      :remove ->
        case commit_identity_delete(state, agent_id) do
          {:ok, persisted_state} -> remove_hot_identity(persisted_state, agent_id)
          {:error, _reason} -> fail_closed_remote(type, agent_id, state)
        end

      :reject ->
        fail_closed_remote(type, agent_id, state)
    end
  end

  defp remote_entry_for_event(:identity_registered, entry), do: {:ok, entry}
  defp remote_entry_for_event(:identity_resumed, %{status: :active} = entry), do: {:ok, entry}

  defp remote_entry_for_event(:identity_suspended, %{status: status} = entry)
       when status in [:suspended, :revoked],
       do: {:ok, entry}

  defp remote_entry_for_event(:identity_suspended, entry) do
    {:ok, %{entry | status: :suspended, status_changed_at: DateTime.utc_now()}}
  end

  defp remote_entry_for_event(:identity_revoked, %{status: :revoked} = entry),
    do: {:ok, entry}

  defp remote_entry_for_event(:identity_revoked, entry) do
    {:ok, %{entry | status: :revoked, status_changed_at: DateTime.utc_now()}}
  end

  defp remote_entry_for_event(:identity_deregistered, _entry), do: :remove
  defp remote_entry_for_event(_type, _entry), do: :reject

  defp remote_public_key_available?(state, agent_id, entry) do
    case Map.get(state.by_public_key_hash, Crypto.hash(entry.public_key)) do
      nil -> true
      ^agent_id -> true
      _other_agent -> false
    end
  end

  defp fail_closed_remote(type, agent_id, state)
       when type in [:identity_deregistered, :identity_suspended, :identity_revoked],
       do: remove_hot_identity(state, agent_id)

  defp fail_closed_remote(_authority_restoring, _agent_id, state), do: state

  defp reduce_hot_identity(state, agent_id, status) do
    case Map.get(state.by_agent_id, agent_id) do
      nil -> state
      entry -> put_in(state, [:by_agent_id, agent_id], %{entry | status: status})
    end
  end

  # ===========================================================================
  # Security-owned authority
  # ===========================================================================

  defp restore_authority(state) do
    if Process.whereis(@id_store) do
      case safe_authority_call(fn -> take_hydrated_entries(state) end) do
        {:ok, entries} -> build_authoritative_state(state, entries)
        {:error, reason} -> {:error, {:identity_authority, bounded_hydration_error(reason)}}
        _invalid -> {:error, {:identity_authority, :malformed_inventory}}
      end
    else
      {:ok, %{state | authority_mode: :hot_only}}
    end
  end

  defp build_authoritative_state(state, entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{state | authority_mode: :durable}, MapSet.new()}, fn
      {key, %Record{} = record}, {:ok, acc, public_keys} when is_binary(key) ->
        with {:ok, ^key, entry} <- deserialize_identity_record(key, record),
             public_key_hash <- Crypto.hash(entry.public_key),
             false <- MapSet.member?(public_keys, public_key_hash) do
          acc =
            acc
            |> admit_hot_identity(key, entry, record)
            |> update_in([:stats, :total_registered], &(&1 + 1))

          {:cont, {:ok, acc, MapSet.put(public_keys, public_key_hash)}}
        else
          _ -> {:halt, {:error, {:identity_authority, :malformed_inventory}}}
        end

      _malformed, _acc ->
        {:halt, {:error, {:identity_authority, :malformed_inventory}}}
    end)
    |> case do
      {:ok, restored, _public_keys} -> {:ok, restored}
      {:error, _reason} = error -> error
    end
  end

  defp build_authoritative_state(_state, _entries),
    do: {:error, {:identity_authority, :malformed_inventory}}

  defp bounded_hydration_error(reason)
       when reason in [
              :hydration_limit_exceeded,
              :inventory_limit_exceeded,
              :bounded_inventory_unsupported
            ],
       do: :inventory_limit_exceeded

  defp bounded_hydration_error(reason)
       when reason in [
              :backend_unavailable,
              :outcome_unknown,
              :not_hydrated,
              :hydration_unavailable
            ],
       do: :inventory_unavailable

  defp bounded_hydration_error(_reason), do: :malformed_inventory

  defp commit_new_identity(%{authority_mode: :hot_only} = state, _agent_id, _entry),
    do: {:ok, state}

  defp commit_new_identity(state, agent_id, entry) do
    replacement = Record.new(agent_id, serialize_entry(agent_id, entry))

    case safe_authority_call(fn ->
           acknowledged_compare_and_swap(state, agent_id, :not_found, replacement)
         end) do
      {:ok, %Record{} = stored} ->
        {:ok, put_in(state, [:authority_records, agent_id], stored)}

      {:error, reason} ->
        {:error, identity_store_error(reason)}

      _invalid ->
        {:error, :identity_store_outcome_unknown}
    end
  end

  defp commit_identity_update(%{authority_mode: :hot_only} = state, _agent_id, _entry),
    do: {:ok, state}

  defp commit_identity_update(state, agent_id, entry) do
    with {:ok, current} <- Map.fetch(state.authority_records, agent_id) do
      replacement = Record.new(agent_id, serialize_entry(agent_id, entry))

      case safe_authority_call(fn ->
             acknowledged_compare_and_swap(state, agent_id, {:value, current}, replacement)
           end) do
        {:ok, %Record{} = stored} ->
          {:ok, put_in(state, [:authority_records, agent_id], stored)}

        {:error, reason} ->
          {:error, identity_store_error(reason)}

        _invalid ->
          {:error, :identity_store_outcome_unknown}
      end
    else
      :error -> {:error, :identity_store_conflict}
    end
  end

  defp commit_identity_delete(%{authority_mode: :hot_only} = state, _agent_id),
    do: {:ok, state}

  defp commit_identity_delete(state, agent_id) do
    with {:ok, current} <- Map.fetch(state.authority_records, agent_id) do
      case safe_authority_call(fn ->
             acknowledged_compare_and_delete(state, agent_id, current)
           end) do
        :ok -> {:ok, state}
        {:error, reason} -> {:error, identity_store_error(reason)}
        _invalid -> {:error, :identity_store_outcome_unknown}
      end
    else
      :error -> {:error, :identity_store_conflict}
    end
  end

  defp commit_identity_status(state, agent_id, updated_entry, signal_type) do
    case commit_identity_update(state, agent_id, updated_entry) do
      {:ok, state} ->
        state = put_in(state, [:by_agent_id, agent_id], updated_entry)
        emit_identity_signal(signal_type, agent_id)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp identity_store_error(:conflict), do: :identity_store_conflict
  defp identity_store_error(:outcome_unknown), do: :identity_store_outcome_unknown
  defp identity_store_error(:key_mismatch), do: :identity_store_malformed
  defp identity_store_error(_reason), do: :identity_store_unavailable

  defp authority_get(state, agent_id) do
    case safe_authority_call(fn ->
           authoritative_get(state, agent_id)
         end) do
      {:ok, %Record{} = record} ->
        case deserialize_identity_record(agent_id, record) do
          {:ok, ^agent_id, entry} -> {:ok, record, entry}
          {:error, _reason} -> {:error, :malformed_identity}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :store_unavailable}

      _invalid ->
        {:error, :malformed_identity}
    end
  end

  defp take_hydrated_entries(%{security_supervisor_pid: supervisor}) when is_pid(supervisor),
    do: AuthorityStore.take_hydrated_entries_from_supervisor(supervisor, name: @id_store)

  defp take_hydrated_entries(_state),
    do: AuthorityStore.take_hydrated_entries(name: @id_store)

  defp authoritative_get(%{security_supervisor_pid: supervisor}, agent_id)
       when is_pid(supervisor),
       do: AuthorityStore.authoritative_get_from_supervisor(supervisor, agent_id, name: @id_store)

  defp authoritative_get(_state, agent_id),
    do: AuthorityStore.authoritative_get(agent_id, name: @id_store)

  defp acknowledged_compare_and_swap(
         %{security_supervisor_pid: supervisor},
         agent_id,
         expected,
         replacement
       )
       when is_pid(supervisor),
       do:
         AuthorityStore.acknowledged_compare_and_swap_from_supervisor(
           supervisor,
           agent_id,
           expected,
           replacement,
           name: @id_store
         )

  defp acknowledged_compare_and_swap(_state, agent_id, expected, replacement),
    do:
      AuthorityStore.acknowledged_compare_and_swap(
        agent_id,
        expected,
        replacement,
        name: @id_store
      )

  defp acknowledged_compare_and_delete(
         %{security_supervisor_pid: supervisor},
         agent_id,
         current
       )
       when is_pid(supervisor),
       do:
         AuthorityStore.acknowledged_compare_and_delete_from_supervisor(
           supervisor,
           agent_id,
           current,
           name: @id_store
         )

  defp acknowledged_compare_and_delete(_state, agent_id, current),
    do: AuthorityStore.acknowledged_compare_and_delete(agent_id, current, name: @id_store)

  defp safe_authority_call(fun) do
    fun.()
  rescue
    _ -> {:error, :backend_unavailable}
  catch
    _, _ -> {:error, :backend_unavailable}
  end

  defp admit_hot_identity(state, agent_id, entry, record) do
    pk_hash = Crypto.hash(entry.public_key)

    state
    |> put_in([:by_agent_id, agent_id], entry)
    |> put_in([:by_public_key_hash, pk_hash], agent_id)
    |> put_in([:authority_records, agent_id], record)
    |> index_by_name(entry.name, agent_id)
  end

  defp replace_hot_identity(state, agent_id, entry, record) do
    state
    |> remove_hot_identity(agent_id)
    |> admit_hot_identity(agent_id, entry, record)
  end

  defp remove_hot_identity(state, agent_id) do
    case Map.get(state.by_agent_id, agent_id) do
      %{public_key: public_key, name: name} ->
        state
        |> update_in([:by_agent_id], &Map.delete(&1, agent_id))
        |> update_in([:by_public_key_hash], &Map.delete(&1, Crypto.hash(public_key)))
        |> update_in([:authority_records], &Map.delete(&1, agent_id))
        |> deindex_by_name(name, agent_id)

      _missing ->
        state
        |> update_in([:by_agent_id], &Map.delete(&1, agent_id))
        |> update_in([:authority_records], &Map.delete(&1, agent_id))
    end
  end

  defp deserialize_identity_record(key, %Record{key: key, data: data}) when is_map(data) do
    with {:ok, agent_id, entry} <- deserialize_entry(data),
         true <- agent_id == key,
         :ok <- validate_restored_entry(agent_id, entry) do
      {:ok, agent_id, entry}
    else
      _ -> {:error, :malformed_identity}
    end
  end

  defp deserialize_identity_record(_key, _record), do: {:error, :malformed_identity}

  defp validate_restored_entry(agent_id, entry) do
    identity = %Identity{
      agent_id: agent_id,
      public_key: entry.public_key,
      private_key: nil,
      encryption_public_key: entry.encryption_public_key,
      encryption_private_key: nil,
      name: entry.name,
      key_version: entry.key_version,
      created_at: entry.created_at,
      metadata: entry.metadata,
      status: entry.status,
      status_changed_at: entry.status_changed_at,
      status_reason: entry.status_reason
    }

    validate_public_identity(identity)
  end

  # ===========================================================================
  # Serialization (binary keys ↔ hex strings for JSON)
  # ===========================================================================

  defp serialize_entry(agent_id, entry) do
    %{
      "agent_id" => agent_id,
      "public_key" => Base.encode16(entry.public_key, case: :lower),
      "encryption_public_key" => encode_optional_key(entry.encryption_public_key),
      "name" => entry.name,
      "key_version" => entry.key_version,
      "created_at" => DateTime.to_iso8601(entry.created_at),
      "metadata" => entry.metadata,
      "status" => Atom.to_string(entry.status),
      "status_changed_at" => encode_optional_datetime(entry.status_changed_at),
      "status_reason" => entry.status_reason
    }
  end

  defp deserialize_entry(data) when is_map(data) do
    with {:ok, agent_id} <- required_binary(data, "agent_id"),
         {:ok, public_key_hex} <- required_binary(data, "public_key"),
         {:ok, public_key} <- decode_key(public_key_hex),
         {:ok, encryption_public_key} <- decode_optional_key(data["encryption_public_key"]),
         {:ok, created_at} <- parse_datetime(data["created_at"]),
         {:ok, status} <- parse_status(data["status"]),
         {:ok, status_changed_at} <- parse_optional_datetime(data["status_changed_at"]),
         :ok <- validate_serialized_fields(data) do
      entry = %{
        public_key: public_key,
        encryption_public_key: encryption_public_key,
        name: data["name"],
        key_version: data["key_version"],
        created_at: created_at,
        metadata: data["metadata"],
        status: status,
        status_changed_at: status_changed_at,
        status_reason: data["status_reason"]
      }

      {:ok, agent_id, entry}
    else
      _ -> {:error, :malformed_identity}
    end
  end

  defp deserialize_entry(_data), do: {:error, :malformed_identity}

  defp required_binary(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :malformed_identity}
    end
  end

  defp validate_serialized_fields(data) do
    cond do
      not Map.has_key?(data, "encryption_public_key") ->
        {:error, :malformed_identity}

      not Map.has_key?(data, "name") ->
        {:error, :malformed_identity}

      not is_nil(data["name"]) and not is_binary(data["name"]) ->
        {:error, :malformed_identity}

      not is_integer(data["key_version"]) or data["key_version"] <= 0 ->
        {:error, :malformed_identity}

      not is_map(data["metadata"]) ->
        {:error, :malformed_identity}

      not Map.has_key?(data, "status_changed_at") ->
        {:error, :malformed_identity}

      not Map.has_key?(data, "status_reason") ->
        {:error, :malformed_identity}

      not is_nil(data["status_reason"]) and not is_binary(data["status_reason"]) ->
        {:error, :malformed_identity}

      Map.has_key?(data, "private_key") or Map.has_key?(data, "encryption_private_key") ->
        {:error, :malformed_identity}

      true ->
        :ok
    end
  end

  defp encode_optional_key(nil), do: nil
  defp encode_optional_key(key) when is_binary(key), do: Base.encode16(key, case: :lower)

  defp decode_key(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, key} when byte_size(key) == 32 -> {:ok, key}
      _ -> {:error, :malformed_identity}
    end
  end

  defp decode_key(_hex), do: {:error, :malformed_identity}

  defp decode_optional_key(nil), do: {:ok, nil}
  defp decode_optional_key(hex) when is_binary(hex), do: decode_key(hex)
  defp decode_optional_key(_hex), do: {:error, :malformed_identity}

  defp encode_optional_datetime(nil), do: nil
  defp encode_optional_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, :malformed_identity}
    end
  end

  defp parse_datetime(_iso), do: {:error, :malformed_identity}

  defp parse_optional_datetime(nil), do: {:ok, nil}

  defp parse_optional_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, :malformed_identity}
    end
  end

  defp parse_optional_datetime(_iso), do: {:error, :malformed_identity}

  defp parse_status("active"), do: {:ok, :active}
  defp parse_status("suspended"), do: {:ok, :suspended}
  defp parse_status("revoked"), do: {:ok, :revoked}
  defp parse_status(_status), do: {:error, :malformed_identity}
end
