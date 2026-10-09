defmodule Arbor.Security.SigningAuthorityBroker.KeyHolder do
  @moduledoc false

  use GenServer

  alias Arbor.Security.PrivateState

  @take_timeout_ms 1_000
  @private_state_anchor {__MODULE__, :private_state}
  @private_state_schema :signing_key_holder_v1

  @spec start(binary(), pid(), pid(), pos_integer()) ::
          {:ok, pid(), reference()} | {:error, :key_handoff_unavailable}
  def start(private_key, owner_pid, broker_pid, ttl_ms)
      when is_binary(private_key) and is_pid(owner_pid) and is_pid(broker_pid) and
             is_integer(ttl_ms) and ttl_ms > 0 do
    transfer_ref = make_ref()

    case GenServer.start(__MODULE__, {private_key, owner_pid, broker_pid, transfer_ref, ttl_ms}) do
      {:ok, pid} -> {:ok, pid, transfer_ref}
      {:error, _reason} -> {:error, :key_handoff_unavailable}
    end
  end

  def start(_, _, _, _), do: {:error, :key_handoff_unavailable}

  @spec take(pid(), reference()) :: {:ok, binary()} | {:error, atom()}
  def take(holder_pid, transfer_ref) when is_pid(holder_pid) and is_reference(transfer_ref) do
    try do
      Arbor.Common.authenticated_call(holder_pid, {:take, transfer_ref}, @take_timeout_ms)
    catch
      :exit, {:timeout, _details} -> {:error, :key_handoff_expired}
      :exit, _reason -> {:error, :key_handoff_unavailable}
    end
  end

  def take(_, _), do: {:error, :key_handoff_unavailable}

  @spec cancel(pid(), reference()) :: :ok
  def cancel(holder_pid, transfer_ref) when is_pid(holder_pid) and is_reference(transfer_ref) do
    try do
      _ = Arbor.Common.authenticated_call(holder_pid, {:cancel, transfer_ref}, @take_timeout_ms)
    catch
      :exit, _reason -> :ok
    end

    :ok
  end

  def cancel(_, _), do: :ok

  @impl true
  def init({private_key, owner_pid, broker_pid, transfer_ref, ttl_ms}) do
    Process.flag(:sensitive, true)
    owner_monitor = Process.monitor(owner_pid)
    broker_monitor = Process.monitor(broker_pid)
    expiry_timer = Process.send_after(self(), :expire, ttl_ms)

    state = %{
      private_key: private_key,
      owner_pid: owner_pid,
      broker_pid: broker_pid,
      transfer_ref: transfer_ref,
      owner_monitor: owner_monitor,
      broker_monitor: broker_monitor,
      authenticated_calls: Arbor.Common.new_authenticated_call_custody(),
      expiry_timer: expiry_timer
    }

    {:ok, PrivateState.new(@private_state_anchor, @private_state_schema, state)}
  end

  @impl true
  def handle_call(_request, _from, private_state),
    do: {:reply, {:error, :key_handoff_unavailable}, private_state}

  defp handle_authenticated_call({:take, transfer_ref}, requester_pid, state) do
    cond do
      transfer_ref != state.transfer_ref ->
        {:reply, {:error, :key_handoff_unavailable}, state}

      requester_pid != state.broker_pid ->
        {:reply, {:error, :key_handoff_unavailable}, state}

      true ->
        private_key = state.private_key
        {:stop, :normal, {:ok, private_key}, %{state | private_key: nil}}
    end
  end

  defp handle_authenticated_call(
         {:cancel, transfer_ref},
         owner_pid,
         %{transfer_ref: transfer_ref, owner_pid: owner_pid} = state
       ) do
    {:stop, :normal, :ok, state}
  end

  defp handle_authenticated_call(_request, _caller, state),
    do: {:reply, {:error, :key_handoff_unavailable}, state}

  defp handle_private_info(:expire, state), do: {:stop, :normal, state}

  defp handle_private_info({:DOWN, ref, :process, _pid, _reason}, state)
       when ref == state.owner_monitor or ref == state.broker_monitor do
    {:stop, :normal, state}
  end

  defp handle_private_info(message, state) do
    case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
      {:authenticated, caller, request, reply_to} ->
        case handle_authenticated_call(request, caller, state) do
          {:reply, reply, next_state} ->
            :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
            {:noreply, next_state}

          {:stop, reason, reply, next_state} ->
            :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
            {:stop, reason, next_state}
        end

      result when result in [:pending, :expired, :rejected] ->
        {:noreply, state}

      :unrecognized ->
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
  def format_status(status) when is_map(status) do
    redacted =
      status
      |> Map.put(:message, :redacted)
      |> Map.put(:state, %{key_holder: :redacted})
      |> maybe_redact_status_field(:reason)

    maybe_redact_status_field(redacted, :log)
  end

  @impl true
  def terminate(_reason, private_state) do
    case private_state(private_state) do
      {:ok, state} ->
        Process.demonitor(state.owner_monitor, [:flush])
        Process.demonitor(state.broker_monitor, [:flush])
        Process.cancel_timer(state.expiry_timer, async: false, info: false)

      {:error, _reason} ->
        :ok
    end

    PrivateState.delete(private_state, @private_state_anchor)
    :ok
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

  defp valid_private_state?(state) when is_map(state) do
    Map.keys(state) |> Enum.sort() ==
      [
        :authenticated_calls,
        :broker_monitor,
        :broker_pid,
        :expiry_timer,
        :owner_monitor,
        :owner_pid,
        :private_key,
        :transfer_ref
      ] and
      (is_binary(state.private_key) or is_nil(state.private_key)) and is_pid(state.owner_pid) and
      is_pid(state.broker_pid) and is_reference(state.transfer_ref) and
      is_reference(state.owner_monitor) and is_reference(state.broker_monitor) and
      is_reference(state.authenticated_calls) and is_reference(state.expiry_timer)
  end

  defp valid_private_state?(_state), do: false

  defp maybe_redact_status_field(status, key) do
    if Map.has_key?(status, key), do: Map.put(status, key, :redacted), else: status
  end
end

defmodule Arbor.Security.SigningAuthorityBroker do
  @moduledoc """
  Supervised broker for reload-stable signing-authority tokens.

  Persistent authorities may be opened directly from an owner-bound possession
  proof or claimed from an expiring bootstrap restart slot. Ephemeral
  authorities require the same proof plus a caller-supplied private key; that
  key is AES-GCM wrapped under a broker-local random key and is never written to
  `SigningKeyStore`.

  ## Security invariants

  - Acquisition always requires a one-shot `SignedRequest`; an id is insufficient
  - The proof principal and bound owner must match the verified signer and caller
  - Persistent bootstrap issuance requires an active identity and stored key
  - A bootstrap slot has at most one live claimed authority
  - Owner DOWN revokes the live token immediately; persistent slots then have a
    bounded reclaim grace, while ephemeral wrapped data is removed permanently
  - Ephemeral state stores ciphertext, IV, and tag, never a plaintext private key
  - Caller plaintext reaches the broker only through a monitored, expiring,
    one-shot key holder; it is never part of the broker GenServer call request
  - Ephemeral opens use request-scoped acknowledgement and ordered cancellation;
    a timed-out caller cannot leave a hidden committed authority behind
  - Persistent authorities and restart slots are held by a separate supervised
    metadata owner so broker-only restarts recover finalized live leases
  - Persistent opens and claims commit through request-scoped acknowledgement;
    timeout or broker restart revokes every unfinalized authority fail-closed
  - The broker-local wrapping key and all ephemeral entries disappear on restart
  - Decrypted key material is scoped to one sign/derive call; BEAM zeroization is
    not claimed
  - Broker state never retains proofs, functions, MFA tuples, or signer callbacks
  - OTP status formatting redacts current messages, reasons, logs, bearer
    tokens, wrapping material, and wrapped-key fields from diagnostics

  A `SigningAuthority` is intentionally a bearer reference so Engine helper
  processes may use it. It is usable only while the owner PID recorded by the
  broker remains alive; callers do not become owners merely by holding the token.

  Callers outside `arbor_security` must use the `Arbor.Security` facade.
  """

  use GenServer

  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.SigningAuthority.Validator
  alias Arbor.Contracts.Security.SigningAuthorityBootstrap
  alias Arbor.Contracts.Extension.Envelope
  alias Arbor.Security.Config
  alias Arbor.Security.Crypto
  alias Arbor.Security.Capability.Signer
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.Identity.Verifier
  alias Arbor.Security.SessionToken
  alias Arbor.Security.PrivateState
  alias Arbor.Security.SigningKeyStore
  alias Arbor.Security.SigningAuthorityBroker.KeyHolder
  alias Arbor.Security.SigningAuthorityStateOwner
  alias Arbor.Security.SupervisedOwner

  @token_bytes 32
  @wrapping_key_bytes 32
  @private_state_anchor {__MODULE__, :private_state}
  @private_state_schema :signing_authority_broker_v1
  @signed_request_nonce_bytes 16
  @derive_domain_prefix "arbor.signing_authority.v1/"
  @identity_endorsement_domain "arbor.identity.endorsement.v1"
  @identity_endorsement_purposes [:session, :heartbeat, :action_cycle]
  @max_identity_id_bytes 256
  @owner_table :arbor_security_signing_authority_broker_directory
  @acquisition_v1 "arbor.signing_authority.acquire.v1"
  @ephemeral_aad_v1 "arbor.signing_authority.ephemeral.v1"
  @ephemeral_key_check_v1 "arbor.signing_authority.ephemeral.key_check.v1"
  @persistent_key_check_v1 "arbor.signing_authority.persistent.key_check.v1"
  @key_holder_ttl_margin_ms 1_000
  @ephemeral_request_ttl_margin_ms 1_000
  @ephemeral_finalize_timeout_ms 100
  @persistent_request_ttl_margin_ms 1_000
  @persistent_finalize_timeout_ms 100
  @platform_activation_ttl_seconds 60
  @max_activation_nonces 4_096

  @type open_purpose :: atom() | String.t()
  @type derive_purpose :: atom() | String.t()

  # ---------------------------------------------------------------------------
  # Acquisition payload (canonical, pure)
  # ---------------------------------------------------------------------------

  @doc """
  Build the canonical acquisition payload bound into a one-shot SignedRequest.

  Binds principal, purpose, and intended owner process. The broker re-checks
  the owner against the GenServer caller for every acquisition operation.
  """
  @spec acquisition_payload(String.t(), open_purpose(), pid()) :: binary()
  def acquisition_payload(principal_id, purpose, owner_pid)
      when is_binary(principal_id) and is_pid(owner_pid) do
    purpose_bin = :erlang.term_to_binary(purpose)
    owner_bin = :erlang.term_to_binary(owner_pid)

    @acquisition_v1 <>
      length_prefix(principal_id) <>
      length_prefix(purpose_bin) <>
      length_prefix(owner_bin)
  end

  @doc false
  @spec parse_acquisition_payload(binary()) ::
          {:ok, %{principal_id: String.t(), purpose: open_purpose(), owner_pid: pid()}}
          | {:error, :invalid_acquisition_proof}
  def parse_acquisition_payload(<<@acquisition_v1, rest::binary>>) do
    with <<p_len::32, principal_id::binary-size(p_len), rest::binary>> <- rest,
         <<u_len::32, purpose_bin::binary-size(u_len), rest::binary>> <- rest,
         <<o_len::32, owner_bin::binary-size(o_len)>> <- rest,
         true <- p_len > 0 and u_len > 0 and o_len > 0,
         {:ok, purpose} <- safe_term(purpose_bin),
         {:ok, owner_pid} when is_pid(owner_pid) <- safe_term(owner_bin),
         :ok <- Validator.validate_principal_id(principal_id),
         :ok <- Validator.validate_purpose(purpose) do
      {:ok, %{principal_id: principal_id, purpose: purpose, owner_pid: owner_pid}}
    else
      _ -> {:error, :invalid_acquisition_proof}
    end
  end

  def parse_acquisition_payload(_), do: {:error, :invalid_acquisition_proof}

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  @spec complete_startup(pid(), reference()) :: :ok | {:error, term()}
  def complete_startup(supervisor, state_owner_token) do
    with {:ok, timeout} <- Arbor.Security.Config.startup_timeout_ms() do
      complete_startup(supervisor, state_owner_token, timeout)
    end
  end

  @spec complete_startup(pid(), reference(), timeout()) :: :ok | {:error, term()}

  def complete_startup(supervisor, state_owner_token, timeout)
      when is_pid(supervisor) and is_reference(state_owner_token) and is_integer(timeout) and
             timeout > 0 do
    case SupervisedOwner.child_pid(supervisor, __MODULE__) do
      broker when is_pid(broker) ->
        GenServer.call(broker, {:complete_startup, supervisor, state_owner_token}, timeout)

      nil ->
        {:error, :broker_unavailable}
    end
  rescue
    _ -> {:error, :broker_unavailable}
  catch
    :exit, {:timeout, _} -> {:error, :broker_startup_timeout}
    :exit, _ -> {:error, :broker_unavailable}
  end

  def complete_startup(_supervisor, _state_owner_token, _timeout),
    do: {:error, :invalid_broker_startup}

  @doc false
  def owned_identity(authority) do
    with {:ok, canonical} <- SigningAuthority.canonicalize(authority) do
      call({:owned_identity, canonical, self()})
    end
  end

  @doc false
  def recorded_identity(authority, owner) when is_pid(owner) do
    with {:ok, canonical} <- SigningAuthority.canonicalize(authority) do
      call({:owned_identity, canonical, owner})
    end
  end

  @doc false
  @spec channel_identity(SigningAuthority.t()) ::
          {:ok, %{principal_id: String.t(), purpose: term(), owner_pid: pid()}}
          | {:error, :channel_authority_unauthorized}
  def channel_identity(authority) do
    with {:ok, canonical} <- SigningAuthority.canonicalize(authority) do
      call({:channel_identity, canonical})
    else
      _ -> {:error, :channel_authority_unauthorized}
    end
  end

  @doc """
  Open a persistent signing authority directly from a possession proof.
  """
  @spec open(SignedRequest.t()) :: {:ok, SigningAuthority.t()} | {:error, term()}
  def open(%SignedRequest{} = proof) do
    case broker_pid() do
      broker_pid when is_pid(broker_pid) ->
        timeout_ms = Config.signing_authority_broker_call_timeout_ms()
        request_id = make_ref()
        result = call(broker_pid, {:open, request_id, proof}, timeout_ms)
        complete_persistent_open(broker_pid, request_id, result, timeout_ms)

      nil ->
        {:error, :broker_unavailable}
    end
  end

  def open(_), do: {:error, :invalid_acquisition_proof}

  @doc false
  @spec open_agent_lifecycle_session(binary()) ::
          {:ok, SigningAuthority.t()} | {:error, term()}
  def open_agent_lifecycle_session(session_token) when is_binary(session_token) do
    call({:open_agent_lifecycle_session, session_token})
  end

  def open_agent_lifecycle_session(_session_token), do: {:error, :invalid_session_token}

  @doc false
  # Verify one inbound signed request over exactly `expected_payload`
  # (consuming its nonce) and open an `:agent_lifecycle` authority for its
  # verified human principal in the same broker call. Verification runs here,
  # never in the caller, so no caller can obtain an authority by claiming it
  # verified a request elsewhere.
  @spec open_agent_lifecycle_request(SignedRequest.t(), binary()) ::
          {:ok, SigningAuthority.t()} | {:error, term()}
  def open_agent_lifecycle_request(%SignedRequest{} = request, expected_payload)
      when is_binary(expected_payload) and byte_size(expected_payload) > 0 do
    call({:open_agent_lifecycle_request, request, expected_payload})
  end

  def open_agent_lifecycle_request(_request, _expected_payload),
    do: {:error, :invalid_signed_request}

  @doc """
  Issue an expiring persistent-backed restart slot from a possession proof.
  """
  @spec issue_bootstrap(SignedRequest.t(), keyword() | map()) ::
          {:ok, SigningAuthorityBootstrap.t()} | {:error, term()}
  def issue_bootstrap(%SignedRequest{} = proof, opts) when is_list(opts) or is_map(opts) do
    with {:ok, grace_ms} <- validate_issue_options(opts) do
      call({:issue_bootstrap, proof, grace_ms})
    end
  end

  def issue_bootstrap(%SignedRequest{}, _), do: {:error, :invalid_options}
  def issue_bootstrap(_, _), do: {:error, :possession_proof_required}

  @doc """
  Claim an unclaimed or reclaimable bootstrap for the GenServer caller.
  """
  @spec claim_bootstrap(SigningAuthorityBootstrap.t()) ::
          {:ok, SigningAuthority.t()} | {:error, term()}
  def claim_bootstrap(bootstrap) do
    case SigningAuthorityBootstrap.canonicalize(bootstrap) do
      {:ok, canonical} ->
        case broker_pid() do
          broker_pid when is_pid(broker_pid) ->
            timeout_ms = Config.signing_authority_broker_call_timeout_ms()
            request_id = make_ref()
            result = call(broker_pid, {:claim_bootstrap, request_id, canonical}, timeout_ms)
            complete_persistent_open(broker_pid, request_id, result, timeout_ms)

          nil ->
            {:error, :broker_unavailable}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Close a bootstrap and any authority currently claimed from it.
  """
  @spec close_bootstrap(SigningAuthorityBootstrap.t()) :: :ok | {:error, term()}
  def close_bootstrap(bootstrap) do
    case SigningAuthorityBootstrap.canonicalize(bootstrap) do
      {:ok, canonical} -> call({:close_bootstrap, canonical})
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Open an ephemeral authority from proof and caller-supplied private key.

  The key is checked against the proof principal's registered public identity,
  wrapped before insertion into broker state, and never persisted.
  """
  @spec open_ephemeral(SignedRequest.t(), binary()) ::
          {:ok, SigningAuthority.t()} | {:error, term()}
  def open_ephemeral(%SignedRequest{} = proof, private_key) do
    with :ok <- validate_private_key(private_key) do
      case broker_pid() do
        broker_pid when is_pid(broker_pid) ->
          timeout_ms = Config.signing_authority_broker_call_timeout_ms()
          holder_ttl_ms = timeout_ms + @key_holder_ttl_margin_ms
          request_id = make_ref()

          with {:ok, holder_pid, transfer_ref} <-
                 KeyHolder.start(private_key, self(), broker_pid, holder_ttl_ms) do
            try do
              result =
                call(
                  broker_pid,
                  {:open_ephemeral, request_id, proof, holder_pid, transfer_ref},
                  timeout_ms
                )

              complete_ephemeral_open(broker_pid, request_id, result, timeout_ms)
            after
              KeyHolder.cancel(holder_pid, transfer_ref)
            end
          end

        nil ->
          {:error, :broker_unavailable}
      end
    end
  end

  def open_ephemeral(_, _), do: {:error, :possession_proof_required}

  @doc """
  Sign a payload with a live authority.

  The caller may be an Engine helper rather than the recorded owner. The
  broker checks owner liveness before loading or decrypting any key material.
  """
  @spec sign(SigningAuthority.t(), binary()) ::
          {:ok, SignedRequest.t()} | {:error, term()}
  def sign(authority, payload) when is_binary(payload) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, canonical} -> call({:sign, canonical, payload})
      {:error, reason} -> {:error, reason}
    end
  end

  def sign(authority, _payload) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, _canonical} -> {:error, :invalid_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec sign_native_notice_source(SigningAuthority.t(), binary()) ::
          {:ok, SignedRequest.t()} | {:error, term()}
  def sign_native_notice_source(authority, payload) when is_binary(payload) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, canonical} -> call({:sign_native_notice_source, canonical, payload})
      {:error, reason} -> {:error, reason}
    end
  end

  def sign_native_notice_source(authority, _payload) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, _canonical} -> {:error, :native_notice_source_required}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec sign_native_notice_publication(SigningAuthority.t(), binary()) ::
          {:ok, SignedRequest.t()} | {:error, term()}
  def sign_native_notice_publication(authority, payload) when is_binary(payload) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, canonical} -> call({:sign_native_notice_publication, canonical, payload})
      {:error, reason} -> {:error, reason}
    end
  end

  def sign_native_notice_publication(authority, _payload) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, _canonical} -> {:error, :native_notice_source_required}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec sign_delegation(SigningAuthority.t(), Capability.t(), Capability.t()) ::
          {:ok, map()} | {:error, term()}
  def sign_delegation(authority, %Capability{} = parent, %Capability{} = child) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, canonical} -> call({:sign_delegation, canonical, parent, child})
      {:error, reason} -> {:error, reason}
    end
  end

  def sign_delegation(_authority, _parent, _child),
    do: {:error, :capability_mutation_unauthorized}

  @doc false
  @spec sign_identity_endorsement(SigningAuthority.t(), String.t(), String.t(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def sign_identity_endorsement(authority, signer_id, target_id, target_public_key)
      when is_binary(signer_id) and is_binary(target_id) and is_binary(target_public_key) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, canonical} ->
        call({:sign_identity_endorsement, canonical, signer_id, target_id, target_public_key})

      {:error, reason} ->
        {:error, reason}
    end
  end

  def sign_identity_endorsement(_authority, _signer_id, _target_id, _target_public_key),
    do: {:error, :identity_endorsement_unauthorized}

  @doc false
  @spec identity_endorsement_payload(String.t(), String.t(), binary()) ::
          {:ok, binary()} | {:error, :invalid_identity_endorsement}
  def identity_endorsement_payload(signer_id, target_id, target_public_key)
      when is_binary(signer_id) and is_binary(target_id) and is_binary(target_public_key) do
    with :ok <- validate_identity_id(signer_id),
         :ok <- validate_identity_id(target_id),
         true <- signer_id != target_id,
         true <- byte_size(target_public_key) == 32 do
      {:ok,
       identity_endorsement_field(@identity_endorsement_domain) <>
         identity_endorsement_field(signer_id) <>
         identity_endorsement_field(target_id) <>
         identity_endorsement_field(target_public_key)}
    else
      _ -> {:error, :invalid_identity_endorsement}
    end
  end

  def identity_endorsement_payload(_signer_id, _target_id, _target_public_key),
    do: {:error, :invalid_identity_endorsement}

  @doc false
  @spec reserve_platform_activation_window(
          SigningAuthority.t(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          {:ok, %{issued_at: String.t(), expires_at: String.t()}} | {:error, term()}
  def reserve_platform_activation_window(authority, nonce, valid_from, valid_until)
      when is_binary(nonce) and is_binary(valid_from) and is_binary(valid_until) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, canonical} ->
        call({:reserve_platform_activation_window, canonical, nonce, valid_from, valid_until})

      {:error, reason} ->
        {:error, reason}
    end
  end

  def reserve_platform_activation_window(authority, _nonce, _valid_from, _valid_until) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, _canonical} -> {:error, :invalid_activation_window}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec sign_platform_activation(SigningAuthority.t(), map(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def sign_platform_activation(authority, unsigned_envelope, nonce)
      when is_map(unsigned_envelope) and is_binary(nonce) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, canonical} ->
        call({:sign_platform_activation, canonical, unsigned_envelope, nonce})

      {:error, reason} ->
        {:error, reason}
    end
  end

  def sign_platform_activation(authority, _unsigned_envelope, _nonce) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, _canonical} -> {:error, :invalid_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Detached Ed25519 signature over a domain-tagged message.

  The authority's purpose must be allowed to sign `domain_tag`
  (`:coding_task_executor` may sign only `arbor-forge-projection-v1`), and the
  message must begin with the 32-bit length-prefixed tag.
  """
  @spec sign_detached_with_domain(SigningAuthority.t(), String.t(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def sign_detached_with_domain(authority, domain_tag, message)
      when is_binary(domain_tag) and is_binary(message) and byte_size(message) > 0 do
    case SigningAuthority.canonicalize(authority) do
      {:ok, canonical} -> call({:sign_detached, canonical, domain_tag, message})
      {:error, reason} -> {:error, reason}
    end
  end

  def sign_detached_with_domain(authority, _domain_tag, _message) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, _canonical} -> {:error, :invalid_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Derive a domain-separated secret from a live authority.
  """
  @spec derive_secret(SigningAuthority.t(), derive_purpose()) ::
          {:ok, binary()} | {:error, term()}
  def derive_secret(authority, purpose) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, canonical} -> call({:derive_secret, canonical, purpose})
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Explicitly revoke an authority token.

  Closing a bootstrap-backed authority releases its live claim into the
  bounded reclaim grace. Use `close_bootstrap/1` to remove the slot itself.
  """
  @spec close(SigningAuthority.t()) :: :ok | {:error, term()}
  def close(authority) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, canonical} -> call({:close, canonical})
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec debug_state() :: map()
  def debug_state, do: call(:debug_state)

  @doc false
  @spec validate_issue_options(keyword() | map()) :: {:ok, pos_integer()} | {:error, atom()}
  def validate_issue_options(opts) when is_list(opts) or is_map(opts) do
    with {:ok, pairs} <- issue_option_pairs(opts),
         :ok <- validate_issue_option_keys(pairs),
         :ok <- reject_duplicate_issue_options(pairs) do
      case pairs do
        [] ->
          {:ok, Config.signing_authority_bootstrap_grace_ms()}

        [{:grace_ms, grace_ms}] ->
          validate_grace_ms(grace_ms)
      end
    end
  end

  def validate_issue_options(_), do: {:error, :invalid_options}

  defp call(message) do
    case broker_pid() do
      pid when is_pid(pid) ->
        call(pid, message, Config.signing_authority_broker_call_timeout_ms())

      _ ->
        {:error, :broker_unavailable}
    end
  end

  defp call(server, message, timeout_ms) do
    try do
      Arbor.Common.authenticated_call(server, message, timeout_ms)
    rescue
      _ -> {:error, :broker_unavailable}
    catch
      :exit, {:timeout, _details} -> {:error, :broker_timeout}
      :exit, _reason -> {:error, :broker_unavailable}
    end
  end

  defp complete_persistent_open(
         broker_pid,
         request_id,
         {:ok, %SigningAuthority{} = authority},
         timeout_ms
       ) do
    case call(
           broker_pid,
           {:prepare_persistent_open_finalize, request_id},
           min(timeout_ms, @persistent_finalize_timeout_ms)
         ) do
      :ok ->
        case call(
               broker_pid,
               {:ack_persistent_open, request_id},
               min(timeout_ms, @persistent_finalize_timeout_ms)
             ) do
          :ok -> {:ok, authority}
          {:error, _reason} = error -> error
          _unexpected -> {:error, :broker_unavailable}
        end

      {:error, _reason} = error ->
        request_persistent_open_cancel(broker_pid, request_id)
        error

      _unexpected ->
        request_persistent_open_cancel(broker_pid, request_id)
        {:error, :broker_unavailable}
    end
  end

  defp complete_persistent_open(broker_pid, request_id, {:error, _reason} = error, _timeout_ms) do
    request_persistent_open_cancel(broker_pid, request_id)
    error
  end

  defp complete_persistent_open(broker_pid, request_id, _unexpected, _timeout_ms) do
    request_persistent_open_cancel(broker_pid, request_id)
    {:error, :broker_unavailable}
  end

  defp request_persistent_open_cancel(broker_pid, request_id) do
    _ =
      call(
        broker_pid,
        {:cancel_persistent_open, request_id},
        @persistent_finalize_timeout_ms
      )

    :ok
  end

  defp complete_ephemeral_open(
         broker_pid,
         request_id,
         {:ok, %SigningAuthority{} = authority},
         timeout_ms
       ) do
    case call(broker_pid, {:ack_ephemeral_open, request_id}, timeout_ms) do
      :ok ->
        _ =
          call(
            broker_pid,
            {:finalize_ephemeral_open, request_id},
            min(timeout_ms, @ephemeral_finalize_timeout_ms)
          )

        {:ok, authority}

      {:error, _reason} = error ->
        request_ephemeral_open_cancel(broker_pid, request_id, timeout_ms)
        error

      _unexpected ->
        request_ephemeral_open_cancel(broker_pid, request_id, timeout_ms)
        {:error, :broker_unavailable}
    end
  end

  defp complete_ephemeral_open(broker_pid, request_id, {:error, _reason} = error, timeout_ms) do
    request_ephemeral_open_cancel(broker_pid, request_id, timeout_ms)
    error
  end

  defp complete_ephemeral_open(broker_pid, request_id, _unexpected, timeout_ms) do
    request_ephemeral_open_cancel(broker_pid, request_id, timeout_ms)
    {:error, :broker_unavailable}
  end

  defp request_ephemeral_open_cancel(broker_pid, request_id, timeout_ms) do
    _ =
      call(
        broker_pid,
        {:cancel_ephemeral_open, request_id},
        min(timeout_ms, @ephemeral_finalize_timeout_ms)
      )

    :ok
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:sensitive, true)

    with {:ok, state_owner_token} <- Keyword.fetch(opts, :state_owner_token),
         true <- is_reference(state_owner_token),
         {:ok, supervisor_pid} <- startup_supervisor_pid(),
         {:ok, defer_initialization?} <- defer_initialization(opts),
         :ok <- claim_owner_directory() do
      # StateOwner authenticates this broker against Security.Supervisor.
      # Defer that call until init/1 has acknowledged startup so a dynamic
      # Supervisor.start_child/2 does not make the parent wait on a child that
      # is synchronously asking the same parent for its child inventory.
      private_state =
        PrivateState.new(
          @private_state_anchor,
          @private_state_schema,
          pending_state(state_owner_token, supervisor_pid)
        )

      if defer_initialization? and not SupervisedOwner.application_started?(:arbor_security),
        do: {:ok, private_state},
        else: {:ok, private_state, {:continue, :initialize}}
    else
      _ -> {:stop, :state_owner_unavailable}
    end
  end

  @impl true
  def handle_continue(:initialize, private_state) do
    with {:ok, pending_state} <- private_state(private_state) do
      case initialize_private_state(pending_state) do
        {:noreply, state} ->
          case put_private_state(private_state, state) do
            :ok -> {:noreply, private_state}
            {:error, _reason} -> {:stop, :state_owner_unavailable, private_state}
          end

        {:stop, reason, state} ->
          _ = put_private_state(private_state, state)
          {:stop, reason, private_state}
      end
    else
      {:error, _reason} -> {:stop, :state_owner_unavailable, private_state}
    end
  end

  defp initialize_private_state(pending_state) do
    state_owner_token = pending_state.state_owner_token
    supervisor_pid = pending_state.security_supervisor_pid

    with state_owner_pid when is_pid(state_owner_pid) <-
           SigningAuthorityStateOwner.pid_from_supervisor(supervisor_pid),
         {:ok, snapshot} <-
           SigningAuthorityStateOwner.load_from_supervisor(supervisor_pid, state_owner_token),
         {:ok, recovered_state} <- recover_persistent_state(snapshot) do
      state =
        Map.merge(recovered_state, %{
          authenticated_calls: pending_state.authenticated_calls,
          ephemeral_open_requests: %{},
          wrapping_key: :crypto.strong_rand_bytes(@wrapping_key_bytes),
          state_owner_token: state_owner_token,
          state_owner_monitor: Process.monitor(state_owner_pid),
          security_supervisor_pid: supervisor_pid
        })

      case persist_state(state) do
        :ok -> {:noreply, state}
        {:error, reason} -> {:stop, reason, state}
      end
    else
      _ -> {:stop, :state_owner_unavailable, pending_state}
    end
  end

  defp pending_state(state_owner_token, supervisor_pid) do
    %{
      authorities: %{},
      bootstraps: %{},
      persistent_open_requests: %{},
      ephemeral_open_requests: %{},
      monitors: %{},
      activation_nonces: %{},
      authenticated_calls: Arbor.Common.new_authenticated_call_custody(),
      wrapping_key: nil,
      state_owner_token: state_owner_token,
      state_owner_monitor: nil,
      security_supervisor_pid: supervisor_pid
    }
  end

  defp defer_initialization(opts) when is_list(opts) do
    case Keyword.get(opts, :defer_initialization, false) do
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, :invalid_broker_startup}
    end
  rescue
    _ -> {:error, :invalid_broker_startup}
  end

  defp defer_initialization(_opts), do: {:error, :invalid_broker_startup}

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
        if pid in links,
          do: {:ok, pid},
          else: {:error, :security_supervisor_unavailable}

      _other ->
        {:error, :security_supervisor_unavailable}
    end
  end

  defp linked_supervisor(_pid), do: {:error, :security_supervisor_unavailable}

  @impl true
  def handle_call(
        {:complete_startup, supervisor, state_owner_token},
        _from,
        private_state
      ) do
    with {:ok, state} <- private_state(private_state),
         true <- supervisor === state.security_supervisor_pid,
         true <- state_owner_token === state.state_owner_token do
      if initialized_state?(state) do
        {:reply, :ok, private_state}
      else
        case initialize_private_state(state) do
          {:noreply, initialized_state} ->
            case put_private_state(private_state, initialized_state) do
              :ok -> {:reply, :ok, private_state}
              {:error, _reason} -> {:reply, {:error, :invalid_private_state}, private_state}
            end

          {:stop, reason, _state} ->
            {:reply, {:error, reason}, private_state}
        end
      end
    else
      _other -> {:reply, {:error, :signing_authority_unauthorized}, private_state}
    end
  end

  @impl true
  def handle_call(_request, _from, private_state),
    do: {:reply, {:error, :signing_authority_unauthorized}, private_state}

  defp handle_authenticated_call({:open, request_id, proof}, caller_pid, state) do
    case verify_persistent_acquisition(proof, caller_pid) do
      {:ok, bound} ->
        with :ok <- validate_persistent_request_id(request_id, state) do
          case create_authority(state, bound, caller_pid, :persistent, nil) do
            {:reply, {:ok, authority}, committed_state} ->
              tracked_state =
                track_persistent_open_request(
                  committed_state,
                  request_id,
                  authority.token,
                  caller_pid,
                  :committed
                )

              with_persistent_commit({:ok, authority}, tracked_state, fn ->
                Config.run_signing_authority_persistent_open_test_seam(request_id)
              end)

            other ->
              other
          end
        else
          {:error, _} = error -> {:reply, error, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp handle_authenticated_call(
         {:open_agent_lifecycle_session, session_token},
         caller_pid,
         state
       ) do
    with {:ok, principal_id} <-
           SessionToken.verify_for(
             session_token,
             "arbor://agent/lifecycle/create",
             :create
           ),
         true <- String.starts_with?(principal_id, "human_"),
         :ok <- ensure_owner_alive(caller_pid),
         :ok <- ensure_identity_active(principal_id),
         :ok <- ensure_signing_key_present(principal_id) do
      bound = %{principal_id: principal_id, purpose: :agent_lifecycle, owner_pid: caller_pid}

      state
      |> create_authority(bound, caller_pid, :persistent, nil)
      |> commit_persistent_result()
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :invalid_session_token}, state}
    end
  end

  # Decision 2026-10-08 D2. The checks that need no proof run first (the
  # request covers exactly the expected payload, a human principal, an active
  # identity, a server-held key), so an ineligible request is refused without
  # consuming its nonce. Then the inbound verifier (cluster replay gate,
  # freshness, registered key, signature, single-use nonce) runs exactly once,
  # here, and the authority is bound to the calling process.
  defp handle_authenticated_call(
         {:open_agent_lifecycle_request, request, expected_payload},
         caller_pid,
         state
       ) do
    with {:ok, request} <- canonicalize_lifecycle_request(request),
         :ok <- match_lifecycle_payload(request, expected_payload),
         :ok <- require_human_principal(request.agent_id),
         :ok <- ensure_owner_alive(caller_pid),
         :ok <- ensure_identity_active(request.agent_id),
         :ok <- ensure_signing_key_present(request.agent_id),
         {:ok, verified_principal_id} <- verify_inbound_request(request),
         :ok <- match_claimed_principal(verified_principal_id, request.agent_id),
         :ok <- ensure_identity_active(verified_principal_id),
         :ok <- ensure_owner_alive(caller_pid) do
      bound = %{
        principal_id: verified_principal_id,
        purpose: :agent_lifecycle,
        owner_pid: caller_pid
      }

      state
      |> create_authority(bound, caller_pid, :persistent, nil)
      |> commit_persistent_result()
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :invalid_signed_request}, state}
    end
  end

  defp handle_authenticated_call(
         {:prepare_persistent_open_finalize, request_id},
         caller_pid,
         state
       ) do
    case fetch_persistent_open_request(state, request_id, caller_pid) do
      {:ok, %{status: :committed} = request} ->
        state =
          track_persistent_open_request(
            state,
            request_id,
            request.authority_token,
            caller_pid,
            :prepared
          )

        with_persistent_commit(:ok, state, fn ->
          Config.run_signing_authority_persistent_finalize_test_seam(request_id)
        end)

      {:ok, _request} ->
        {:reply, {:error, :persistent_open_already_prepared}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_authenticated_call({:issue_bootstrap, proof, grace_ms}, caller_pid, state) do
    with {:ok, validated_grace_ms} <- validate_grace_ms(grace_ms),
         {:ok, bound} <- verify_persistent_acquisition(proof, caller_pid) do
      state
      |> create_bootstrap(bound, validated_grace_ms)
      |> commit_persistent_result()
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  defp handle_authenticated_call({:claim_bootstrap, request_id, bootstrap}, caller_pid, state) do
    case SigningAuthorityBootstrap.canonicalize(bootstrap) do
      {:ok, bootstrap} ->
        with :ok <- validate_persistent_request_id(request_id, state) do
          case claim_bootstrap_for_caller(state, bootstrap, caller_pid) do
            {:reply, {:ok, authority}, committed_state} ->
              tracked_state =
                track_persistent_open_request(
                  committed_state,
                  request_id,
                  authority.token,
                  caller_pid,
                  :committed
                )

              with_persistent_commit({:ok, authority}, tracked_state, fn ->
                Config.run_signing_authority_persistent_open_test_seam(request_id)
              end)

            other ->
              commit_persistent_result(other)
          end
        else
          {:error, _} = error -> {:reply, error, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_authenticated_call({:close_bootstrap, bootstrap}, _caller, state) do
    case SigningAuthorityBootstrap.canonicalize(bootstrap) do
      {:ok, bootstrap} ->
        state
        |> close_bootstrap_entry(bootstrap)
        |> commit_persistent_result()

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_authenticated_call(
         {:open_ephemeral, request_id, proof, holder_pid, transfer_ref},
         caller_pid,
         state
       ) do
    result =
      with :ok <- validate_ephemeral_request_id(request_id, state),
           {:ok, bound} <- verify_acquisition(proof, caller_pid),
           {:ok, private_key} <- KeyHolder.take(holder_pid, transfer_ref),
           :ok <- validate_private_key(private_key),
           :ok <- verify_private_key_matches(bound.principal_id, proof, private_key),
           token = random_token(),
           aad = ephemeral_aad(bound.principal_id, bound.purpose, token),
           {:ok, key_source} <- wrap_ephemeral_key(private_key, state.wrapping_key, aad) do
        {:ok, bound, token, key_source}
      end

    case result do
      {:ok, bound, token, key_source} ->
        case create_authority(state, bound, caller_pid, key_source, nil, token) do
          {:reply, {:ok, authority}, committed_state} ->
            tracked_state =
              track_ephemeral_open_request(
                committed_state,
                request_id,
                authority.token,
                caller_pid,
                :committed
              )

            run_ephemeral_open_test_seam(request_id)
            {:reply, {:ok, authority}, tracked_state}

          other ->
            other
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp handle_authenticated_call({:ack_ephemeral_open, request_id}, caller_pid, state) do
    case fetch_ephemeral_open_request(state, request_id, caller_pid) do
      {:ok, request} ->
        state =
          track_ephemeral_open_request(
            state,
            request_id,
            request.authority_token,
            caller_pid,
            :acknowledged
          )

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_authenticated_call({:finalize_ephemeral_open, request_id}, caller_pid, state) do
    case fetch_ephemeral_open_request(state, request_id, caller_pid) do
      {:ok, %{status: :acknowledged}} ->
        {:reply, :ok, remove_ephemeral_open_request(state, request_id)}

      {:ok, _request} ->
        {:reply, {:error, :ephemeral_open_not_acknowledged}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_authenticated_call({:cancel_ephemeral_open, request_id}, caller_pid, state) do
    case fetch_ephemeral_open_request(state, request_id, caller_pid) do
      {:ok, request} ->
        {:reply, :ok, revoke_ephemeral_open_request(state, request_id, request)}

      {:error, :ephemeral_open_not_pending} ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_authenticated_call({:owned_identity, authority, owner}, _caller, state) do
    reply =
      with {:ok, authority} <- SigningAuthority.canonicalize(authority),
           {:ok, %{owner_pid: ^owner} = entry} <- authorize_authority(authority, state) do
        {:ok, %{principal_id: entry.principal_id, purpose: entry.purpose}}
      else
        _ -> {:error, :native_notice_source_required}
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_call({:channel_identity, authority}, _caller, state) do
    reply =
      with {:ok, authority} <- SigningAuthority.canonicalize(authority),
           {:ok, entry} <- authorize_authority(authority, state) do
        {:ok,
         %{
           principal_id: entry.principal_id,
           purpose: entry.purpose,
           owner_pid: entry.owner_pid
         }}
      else
        _ -> {:error, :channel_authority_unauthorized}
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_call({:sign, authority, payload}, _caller, state) do
    reply =
      with {:ok, authority} <- SigningAuthority.canonicalize(authority),
           :ok <- validate_resource_binding(payload),
           {:ok, entry} <- authorize_authority(authority, state),
           {:ok, private_key} <- private_key_for(entry, authority.token, state) do
        safely_sign_request(payload, entry.principal_id, private_key)
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_call(
         {:sign_native_notice_source, authority, payload},
         caller,
         state
       ) do
    reply =
      with {:ok, authority} <- SigningAuthority.canonicalize(authority),
           {:ok, %{owner_pid: ^caller} = entry} <- authorize_authority(authority, state),
           :ok <- validate_native_notice_source_payload(payload, entry, caller),
           {:ok, private_key} <- private_key_for(entry, authority.token, state) do
        safely_sign_request(payload, entry.principal_id, private_key)
      else
        _ -> {:error, :native_notice_source_required}
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_call(
         {:sign_native_notice_publication, authority, payload},
         caller,
         state
       ) do
    reply =
      with true <-
             SupervisedOwner.authorized?(
               caller,
               :arbor_security,
               [Arbor.Security.NativeNoticeBroker]
             ),
           {:ok, authority} <- SigningAuthority.canonicalize(authority),
           {:ok, entry} <- authorize_authority(authority, state),
           :ok <- validate_native_notice_publication_payload(payload, entry),
           {:ok, private_key} <- private_key_for(entry, authority.token, state) do
        safely_sign_request(payload, entry.principal_id, private_key)
      else
        _ -> {:error, :native_notice_source_required}
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_call(
         {:sign_delegation, authority, parent, child},
         caller,
         state
       ) do
    reply =
      with {:ok, authority} <- SigningAuthority.canonicalize(authority),
           {:ok, %{owner_pid: ^caller} = entry} <- authorize_authority(authority, state),
           true <- entry.principal_id == parent.principal_id,
           {:ok, private_key} <- private_key_for(entry, authority.token, state) do
        {:ok, Signer.sign_delegation(parent, child, private_key)}
      else
        _ -> {:error, :capability_mutation_unauthorized}
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_call(
         {:sign_identity_endorsement, authority, signer_id, target_id, target_public_key},
         caller,
         state
       ) do
    reply =
      with {:ok, payload} <-
             identity_endorsement_payload(signer_id, target_id, target_public_key),
           {:ok, authority} <- SigningAuthority.canonicalize(authority),
           {:ok, %{owner_pid: ^caller, principal_id: ^signer_id} = entry} <-
             authorize_authority(authority, state),
           true <- entry.purpose in @identity_endorsement_purposes,
           {:ok, ^target_public_key} <- Registry.lookup(target_id),
           {:ok, private_key} <- private_key_for(entry, authority.token, state) do
        safely_sign_detached(payload, private_key)
      else
        _ -> {:error, :identity_endorsement_unauthorized}
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_call(
         {:reserve_platform_activation_window, authority, nonce, valid_from, valid_until},
         _caller,
         state
       ) do
    state = prune_activation_nonces(state)

    result =
      with {:ok, authority} <- SigningAuthority.canonicalize(authority),
           {:ok, entry} <- authorize_authority(authority, state),
           :ok <- require_platform_activation_purpose(entry.purpose),
           :ok <- validate_activation_nonce(nonce),
           false <- Map.has_key?(state.activation_nonces, nonce),
           true <- map_size(state.activation_nonces) < @max_activation_nonces,
           {:ok, window} <- activation_window(valid_from, valid_until) do
        reservation = %{
          authority_token: authority.token,
          issued_at: window.issued_at,
          expires_at: window.expires_at,
          expires_at_unix: window.expires_at_unix,
          status: :reserved
        }

        {:ok, Map.drop(window, [:expires_at_unix]),
         put_in(state, [:activation_nonces, nonce], reservation)}
      else
        true -> {:error, :activation_nonce_reused}
        false -> {:error, :activation_nonce_capacity_exceeded}
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, window, next_state} -> with_persistent_commit({:ok, window}, next_state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_authenticated_call(
         {:sign_platform_activation, authority, unsigned_envelope, nonce},
         _caller,
         state
       ) do
    reservation = Map.get(state.activation_nonces, nonce)

    consumed_state =
      case reservation do
        %{status: :reserved} = entry ->
          put_in(state, [:activation_nonces, nonce], %{entry | status: :consumed})

        _ ->
          state
      end

    reply =
      with {:ok, authority} <- SigningAuthority.canonicalize(authority),
           {:ok, entry} <- authorize_authority(authority, state),
           :ok <- require_platform_activation_purpose(entry.purpose),
           :ok <- match_activation_reservation(reservation, authority, unsigned_envelope, nonce),
           {:ok, message} <- Envelope.signing_message(unsigned_envelope),
           :ok <- verify_platform_activation_message(message),
           {:ok, private_key} <- private_key_for(entry, authority.token, state) do
        safely_sign_detached(message, private_key)
      end

    with_persistent_commit(reply, consumed_state)
  end

  defp handle_authenticated_call({:sign_detached, authority, domain_tag, message}, _caller, state) do
    reply =
      with {:ok, authority} <- SigningAuthority.canonicalize(authority),
           {:ok, entry} <- authorize_authority(authority, state),
           :ok <- require_detached_domain_purpose(entry.purpose, domain_tag),
           :ok <- verify_domain_tag_prefix(message, domain_tag),
           {:ok, private_key} <- private_key_for(entry, authority.token, state) do
        safely_sign_detached(message, private_key)
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_call({:derive_secret, authority, purpose}, _caller, state) do
    reply =
      with {:ok, authority} <- SigningAuthority.canonicalize(authority),
           {:ok, info} <- derive_info(purpose),
           {:ok, entry} <- authorize_authority(authority, state),
           {:ok, private_key} <- private_key_for(entry, authority.token, state) do
        safely_derive_secret(private_key, info)
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_call({:close, authority}, _caller, state) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, authority} ->
        state
        |> close_authority_entry(authority)
        |> commit_persistent_result()

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_authenticated_call(:debug_state, _caller, state) do
    entries =
      Enum.map(state.authorities, fn {_token, entry} ->
        %{
          token_present?: true,
          principal_id: entry.principal_id,
          purpose: entry.purpose,
          owner_pid: entry.owner_pid,
          owner_alive?: Process.alive?(entry.owner_pid),
          opened_at: entry.opened_at,
          key_source: key_source_name(entry.key_source),
          has_wrapped_key?: ephemeral_key_source?(entry.key_source),
          has_private_key?: Map.has_key?(entry, :private_key),
          has_function?: Enum.any?(entry, fn {_key, value} -> is_function(value) end),
          has_proof?: Map.has_key?(entry, :proof) or Map.has_key?(entry, :signed_request)
        }
      end)

    bootstrap_entries =
      Enum.map(state.bootstraps, fn {_token, slot} ->
        %{
          token_present?: true,
          principal_id: slot.principal_id,
          purpose: slot.purpose,
          status: slot.status,
          grace_ms: slot.grace_ms,
          has_private_key?: Map.has_key?(slot, :private_key),
          has_function?: Enum.any?(slot, fn {_key, value} -> is_function(value) end),
          has_proof?: Map.has_key?(slot, :proof) or Map.has_key?(slot, :signed_request)
        }
      end)

    snapshot = %{
      authority_count: map_size(state.authorities),
      bootstrap_count: map_size(state.bootstraps),
      activation_nonce_count: map_size(state.activation_nonces),
      persistent_open_request_count: map_size(state.persistent_open_requests),
      ephemeral_open_request_count: map_size(state.ephemeral_open_requests),
      wrapping_key_present?: is_binary(state.wrapping_key),
      entries: entries,
      bootstrap_entries: bootstrap_entries
    }

    {:reply, snapshot, state}
  end

  defp handle_authenticated_call({:ack_persistent_open, request_id}, caller_pid, state) do
    case fetch_persistent_open_request(state, request_id, caller_pid) do
      {:ok, %{status: :prepared}} ->
        state = remove_persistent_open_request(state, request_id)
        with_persistent_commit(:ok, state)

      {:ok, _request} ->
        {:reply, {:error, :persistent_open_not_prepared}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_authenticated_call({:cancel_persistent_open, request_id}, caller_pid, state) do
    case fetch_persistent_open_request(state, request_id, caller_pid) do
      {:ok, request} ->
        state = revoke_persistent_open_request(state, request_id, request)
        with_persistent_commit(:ok, state)

      {:error, :persistent_open_not_pending} ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_authenticated_call(_request, _caller, state),
    do: {:reply, {:error, :signing_authority_unauthorized}, state}

  @impl true
  def handle_cast(_request, private_state), do: {:noreply, private_state}

  defp handle_private_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cond do
      ref == state.state_owner_monitor ->
        {:stop, :state_owner_unavailable, state}

      true ->
        handle_owner_down(ref, state)
    end
  end

  defp handle_private_info({:expire_bootstrap, token, expiry_id}, state) do
    case Map.get(state.bootstraps, token) do
      %{expiry_id: ^expiry_id, status: status} = slot when status in [:unclaimed, :reclaimable] ->
        state = remove_bootstrap(state, token, slot)
        noreply_with_persistent_commit(state)

      _ ->
        {:noreply, state}
    end
  end

  defp handle_private_info({:expire_persistent_open_request, request_id, expiry_id}, state) do
    case Map.get(state.persistent_open_requests, request_id) do
      %{expiry_id: ^expiry_id} = request ->
        state = revoke_persistent_open_request(state, request_id, request)
        noreply_with_persistent_commit(state)

      _ ->
        {:noreply, state}
    end
  end

  defp handle_private_info({:expire_ephemeral_open_request, request_id, expiry_id}, state) do
    case Map.get(state.ephemeral_open_requests, request_id) do
      %{expiry_id: ^expiry_id, status: :committed} = request ->
        {:noreply, revoke_ephemeral_open_request(state, request_id, request)}

      %{expiry_id: ^expiry_id, status: :acknowledged} ->
        {:noreply, remove_ephemeral_open_request(state, request_id)}

      _ ->
        {:noreply, state}
    end
  end

  defp handle_private_info(message, state) do
    case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
      {:authenticated, caller, request, reply_to} ->
        if initialized_state?(state) do
          case handle_authenticated_call(request, caller, state) do
            {:reply, reply, next_state} ->
              :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
              {:noreply, next_state}

            {:stop, reason, reply, next_state} ->
              :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
              {:stop, reason, next_state}
          end
        else
          :ok = Arbor.Common.reply_authenticated_call(reply_to, {:error, :broker_unavailable})
          {:noreply, state}
        end

      result when result in [:pending, :expired, :rejected] ->
        {:noreply, state}

      :unrecognized ->
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

  defp handle_owner_down(ref, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {authority_token, monitors} ->
        state = %{state | monitors: monitors}

        case Map.pop(state.authorities, authority_token) do
          {nil, _authorities} ->
            {:noreply, state}

          {entry, authorities} ->
            state =
              state
              |> Map.put(:authorities, authorities)
              |> remove_ephemeral_open_requests_for_authority(authority_token)
              |> remove_persistent_open_requests_for_authority(authority_token)
              |> maybe_make_bootstrap_reclaimable(entry, authority_token)

            noreply_with_persistent_commit(state)
        end
    end
  end

  @impl true
  def format_status(status) when is_map(status) do
    state =
      case private_state(Map.get(status, :state, %{})) do
        {:ok, value} -> value
        {:error, _reason} -> %{}
      end

    redacted_state = %{
      authority_count: map_count(state, :authorities),
      bootstrap_count: map_count(state, :bootstraps),
      persistent_open_request_count: map_count(state, :persistent_open_requests),
      ephemeral_open_request_count: map_count(state, :ephemeral_open_requests),
      monitor_count: map_count(state, :monitors)
    }

    status
    |> Map.put(:message, :redacted)
    |> Map.put(:state, redacted_state)
    |> redact_status_field(:reason)
    |> redact_status_field(:log)
  end

  @impl true
  def terminate(_reason, private_state) do
    case private_state(private_state) do
      {:ok, state} -> cleanup_private_state(state)
      {:error, _reason} -> :ok
    end

    PrivateState.delete(private_state, @private_state_anchor)
    :ok
  end

  defp cleanup_private_state(state) do
    Enum.each(state.monitors, fn {ref, _token} -> Process.demonitor(ref, [:flush]) end)

    Enum.each(state.bootstraps, fn {_token, slot} ->
      cancel_expiry_timer(slot)
    end)

    Enum.each(state.ephemeral_open_requests, fn {_request_id, request} ->
      cancel_ephemeral_open_request_timer(request)
    end)

    Enum.each(state.persistent_open_requests, fn {_request_id, request} ->
      cancel_open_request_timer(request)
    end)

    if is_reference(state.state_owner_monitor) do
      Process.demonitor(state.state_owner_monitor, [:flush])
    end

    :ok
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

  defp valid_private_state?(state) when is_map(state) do
    Map.keys(state) |> Enum.sort() ==
      [
        :activation_nonces,
        :authenticated_calls,
        :authorities,
        :bootstraps,
        :ephemeral_open_requests,
        :monitors,
        :persistent_open_requests,
        :security_supervisor_pid,
        :state_owner_monitor,
        :state_owner_token,
        :wrapping_key
      ] and
      Enum.all?(
        [
          state.activation_nonces,
          state.authorities,
          state.bootstraps,
          state.ephemeral_open_requests,
          state.monitors,
          state.persistent_open_requests
        ],
        &is_map/1
      ) and
      is_reference(state.authenticated_calls) and is_reference(state.state_owner_token) and
      is_pid(state.security_supervisor_pid) and valid_initialization_state?(state)
  end

  defp valid_private_state?(_state), do: false

  defp valid_initialization_state?(%{state_owner_monitor: nil, wrapping_key: nil}), do: true

  defp valid_initialization_state?(%{
         state_owner_monitor: monitor,
         wrapping_key: wrapping_key
       }) do
    is_reference(monitor) and is_binary(wrapping_key) and
      byte_size(wrapping_key) == @wrapping_key_bytes
  end

  defp initialized_state?(state),
    do: valid_initialization_state?(state) and is_binary(state.wrapping_key)

  # ---------------------------------------------------------------------------
  # Acquisition and creation
  # ---------------------------------------------------------------------------

  defp verify_persistent_acquisition(proof, caller_pid) do
    with {:ok, bound} <- verify_acquisition(proof, caller_pid),
         :ok <- ensure_signing_key_present(bound.principal_id) do
      {:ok, bound}
    end
  end

  defp verify_acquisition(proof, caller_pid) do
    with {:ok, proof} <- canonicalize_proof(proof),
         {:ok, bound} <- parse_acquisition_payload(proof.payload),
         :ok <- match_claimed_principal(proof.agent_id, bound.principal_id),
         :ok <- match_owner(bound.owner_pid, caller_pid),
         :ok <- ensure_owner_alive(caller_pid),
         {:ok, verified_principal_id} <- safe_verify(proof),
         :ok <- match_principal(verified_principal_id, bound.principal_id, proof.agent_id),
         :ok <- match_owner(bound.owner_pid, caller_pid),
         :ok <- ensure_owner_alive(caller_pid),
         :ok <- ensure_identity_active(bound.principal_id) do
      {:ok, bound}
    end
  end

  defp create_authority(state, bound, owner_pid, key_source, bootstrap_token, token \\ nil) do
    token = token || random_token()
    owner_ref = Process.monitor(owner_pid)

    entry = %{
      principal_id: bound.principal_id,
      purpose: bound.purpose,
      owner_pid: owner_pid,
      owner_ref: owner_ref,
      opened_at: DateTime.utc_now(),
      key_source: key_source,
      bootstrap_token: bootstrap_token
    }

    case SigningAuthority.new(
           token: token,
           principal_id: bound.principal_id,
           purpose: bound.purpose
         ) do
      {:ok, authority} ->
        state =
          state
          |> put_in([:authorities, token], entry)
          |> put_in([:monitors, owner_ref], token)
          |> mark_bootstrap_claimed(bootstrap_token, token)

        {:reply, {:ok, authority}, state}

      {:error, reason} ->
        Process.demonitor(owner_ref, [:flush])
        {:reply, {:error, reason}, state}
    end
  end

  defp create_bootstrap(state, bound, grace_ms) do
    token = random_token()
    slot = new_expiring_slot(bound, token, :unclaimed, grace_ms)

    case SigningAuthorityBootstrap.new(
           token: token,
           principal_id: bound.principal_id,
           purpose: bound.purpose
         ) do
      {:ok, bootstrap} ->
        {:reply, {:ok, bootstrap}, put_in(state, [:bootstraps, token], slot)}

      {:error, reason} ->
        cancel_expiry_timer(slot)
        {:reply, {:error, reason}, state}
    end
  end

  defp claim_bootstrap_for_caller(state, bootstrap, caller_pid) do
    case fetch_bound_bootstrap(state, bootstrap) do
      {:ok, slot} ->
        state = release_dead_claim_if_needed(state, bootstrap.token, slot)
        slot = Map.get(state.bootstraps, bootstrap.token)

        cond do
          is_nil(slot) ->
            {:reply, {:error, :bootstrap_not_found}, state}

          slot.status == :claimed ->
            {:reply, {:error, :authority_already_claimed}, state}

          bootstrap_expired?(slot) ->
            state = remove_bootstrap(state, bootstrap.token, slot)
            {:reply, {:error, :bootstrap_expired}, state}

          true ->
            bound = %{principal_id: slot.principal_id, purpose: slot.purpose}

            with :ok <- ensure_identity_active(bound.principal_id),
                 :ok <- ensure_signing_key_present(bound.principal_id) do
              create_authority(state, bound, caller_pid, :persistent, bootstrap.token)
            else
              {:error, _} = error -> {:reply, error, state}
            end
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp close_bootstrap_entry(state, bootstrap) do
    case fetch_bound_bootstrap(state, bootstrap) do
      {:ok, slot} -> {:reply, :ok, remove_bootstrap(state, bootstrap.token, slot)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Authority use and lifecycle
  # ---------------------------------------------------------------------------

  defp authorize_authority(authority, state) do
    token = Map.get(authority, :token)
    principal_id = Map.get(authority, :principal_id)
    purpose = Map.get(authority, :purpose)

    case Map.fetch(state.authorities, token) do
      :error ->
        {:error, :authority_not_found}

      {:ok, entry} ->
        cond do
          entry.principal_id != principal_id ->
            {:error, :principal_mismatch}

          entry.purpose != purpose ->
            {:error, :purpose_mismatch}

          not Process.alive?(entry.owner_pid) ->
            {:error, :owner_dead}

          true ->
            with :ok <- ensure_identity_active(entry.principal_id), do: {:ok, entry}
        end
    end
  end

  defp close_authority_entry(state, authority) do
    case Map.fetch(state.authorities, authority.token) do
      :error ->
        {:reply, {:error, :authority_not_found}, state}

      {:ok, entry} ->
        cond do
          entry.principal_id != authority.principal_id ->
            {:reply, {:error, :principal_mismatch}, state}

          entry.purpose != authority.purpose ->
            {:reply, {:error, :purpose_mismatch}, state}

          true ->
            state =
              state
              |> remove_authority(authority.token, entry)
              |> maybe_make_bootstrap_reclaimable(entry, authority.token)

            {:reply, :ok, state}
        end
    end
  end

  defp private_key_for(%{key_source: :persistent, principal_id: principal_id}, _token, _state) do
    load_validated_persistent_key(principal_id)
  end

  defp private_key_for(%{key_source: key_source} = entry, token, state) do
    if ephemeral_key_source?(key_source) do
      aad = ephemeral_aad(entry.principal_id, entry.purpose, token)

      safely_decrypt_ephemeral_key(key_source, state.wrapping_key, aad)
    else
      {:error, :invalid_key_source}
    end
  end

  defp remove_authority(state, token, entry, demonitor? \\ true) do
    if demonitor?, do: Process.demonitor(entry.owner_ref, [:flush])

    state
    |> update_in([:authorities], &Map.delete(&1, token))
    |> update_in([:monitors], &Map.delete(&1, entry.owner_ref))
    |> remove_ephemeral_open_requests_for_authority(token)
    |> remove_persistent_open_requests_for_authority(token)
  end

  defp validate_persistent_request_id(request_id, state) when is_reference(request_id) do
    if Map.has_key?(state.persistent_open_requests, request_id) do
      {:error, :duplicate_persistent_open_request}
    else
      :ok
    end
  end

  defp validate_persistent_request_id(_request_id, _state),
    do: {:error, :invalid_persistent_open_request}

  defp fetch_persistent_open_request(state, request_id, caller_pid) do
    case Map.get(state.persistent_open_requests, request_id) do
      nil ->
        {:error, :persistent_open_not_pending}

      %{owner_pid: ^caller_pid} = request ->
        {:ok, request}

      _other_owner ->
        {:error, :owner_mismatch}
    end
  end

  defp track_persistent_open_request(state, request_id, authority_token, owner_pid, status)
       when status in [:committed, :prepared] do
    state = remove_persistent_open_request(state, request_id)
    expiry_id = make_ref()

    ttl_ms =
      Config.signing_authority_broker_call_timeout_ms() + @persistent_request_ttl_margin_ms

    expires_at_ms = monotonic_ms() + ttl_ms

    timer_ref =
      Process.send_after(
        self(),
        {:expire_persistent_open_request, request_id, expiry_id},
        ttl_ms
      )

    request = %{
      authority_token: authority_token,
      owner_pid: owner_pid,
      status: status,
      expiry_id: expiry_id,
      expiry_timer: timer_ref,
      expires_at_ms: expires_at_ms
    }

    put_in(state, [:persistent_open_requests, request_id], request)
  end

  defp remove_persistent_open_request(state, request_id) do
    case Map.pop(state.persistent_open_requests, request_id) do
      {nil, _requests} ->
        state

      {request, requests} ->
        cancel_open_request_timer(request)
        %{state | persistent_open_requests: requests}
    end
  end

  defp revoke_persistent_open_request(state, request_id, request) do
    state = remove_persistent_open_request(state, request_id)

    case Map.get(state.authorities, request.authority_token) do
      nil ->
        state

      entry ->
        state
        |> remove_authority(request.authority_token, entry)
        |> maybe_make_bootstrap_reclaimable(entry, request.authority_token)
    end
  end

  defp remove_persistent_open_requests_for_authority(state, authority_token) do
    request_ids =
      for {request_id, %{authority_token: ^authority_token}} <- state.persistent_open_requests,
          do: request_id

    Enum.reduce(request_ids, state, &remove_persistent_open_request(&2, &1))
  end

  defp validate_ephemeral_request_id(request_id, state) when is_reference(request_id) do
    if Map.has_key?(state.ephemeral_open_requests, request_id) do
      {:error, :duplicate_ephemeral_open_request}
    else
      :ok
    end
  end

  defp validate_ephemeral_request_id(_request_id, _state),
    do: {:error, :invalid_ephemeral_open_request}

  defp fetch_ephemeral_open_request(state, request_id, caller_pid) do
    case Map.get(state.ephemeral_open_requests, request_id) do
      nil ->
        {:error, :ephemeral_open_not_pending}

      %{owner_pid: ^caller_pid} = request ->
        {:ok, request}

      _other_owner ->
        {:error, :owner_mismatch}
    end
  end

  defp track_ephemeral_open_request(
         state,
         request_id,
         authority_token,
         owner_pid,
         status
       )
       when status in [:committed, :acknowledged] do
    state = remove_ephemeral_open_request(state, request_id)
    expiry_id = make_ref()

    ttl_ms =
      Config.signing_authority_broker_call_timeout_ms() + @ephemeral_request_ttl_margin_ms

    timer_ref =
      Process.send_after(
        self(),
        {:expire_ephemeral_open_request, request_id, expiry_id},
        ttl_ms
      )

    request = %{
      authority_token: authority_token,
      owner_pid: owner_pid,
      status: status,
      expiry_id: expiry_id,
      expiry_timer: timer_ref
    }

    put_in(state, [:ephemeral_open_requests, request_id], request)
  end

  defp remove_ephemeral_open_request(state, request_id) do
    case Map.pop(state.ephemeral_open_requests, request_id) do
      {nil, _requests} ->
        state

      {request, requests} ->
        cancel_ephemeral_open_request_timer(request)
        %{state | ephemeral_open_requests: requests}
    end
  end

  defp revoke_ephemeral_open_request(state, request_id, request) do
    state = remove_ephemeral_open_request(state, request_id)

    case Map.get(state.authorities, request.authority_token) do
      nil -> state
      entry -> remove_authority(state, request.authority_token, entry)
    end
  end

  defp remove_ephemeral_open_requests_for_authority(state, authority_token) do
    request_ids =
      for {request_id, %{authority_token: ^authority_token}} <- state.ephemeral_open_requests,
          do: request_id

    Enum.reduce(request_ids, state, &remove_ephemeral_open_request(&2, &1))
  end

  defp cancel_ephemeral_open_request_timer(%{expiry_timer: timer_ref})
       when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref, async: false, info: false)
    :ok
  end

  defp cancel_ephemeral_open_request_timer(_request), do: :ok

  defp cancel_open_request_timer(%{expiry_timer: timer_ref}) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref, async: false, info: false)
    :ok
  end

  defp cancel_open_request_timer(_request), do: :ok

  defp run_ephemeral_open_test_seam(request_id) do
    Config.run_signing_authority_ephemeral_open_test_seam(request_id)
  end

  defp maybe_make_bootstrap_reclaimable(state, %{bootstrap_token: nil}, _authority_token),
    do: state

  defp maybe_make_bootstrap_reclaimable(state, entry, authority_token) do
    case Map.get(state.bootstraps, entry.bootstrap_token) do
      %{status: :claimed, authority_token: ^authority_token} = slot ->
        reclaimable =
          slot
          |> Map.drop([:authority_token])
          |> schedule_expiry(entry.bootstrap_token, :reclaimable, slot.grace_ms)

        put_in(state, [:bootstraps, entry.bootstrap_token], reclaimable)

      _ ->
        state
    end
  end

  defp release_dead_claim_if_needed(state, token, %{status: :claimed} = slot) do
    case Map.get(state.authorities, slot.authority_token) do
      %{owner_pid: owner_pid} = entry ->
        if Process.alive?(owner_pid) do
          state
        else
          state
          |> remove_authority(slot.authority_token, entry)
          |> maybe_make_bootstrap_reclaimable(entry, slot.authority_token)
        end

      nil ->
        reclaimable =
          slot
          |> Map.drop([:authority_token])
          |> schedule_expiry(token, :reclaimable, slot.grace_ms)

        put_in(state, [:bootstraps, token], reclaimable)
    end
  end

  defp release_dead_claim_if_needed(state, _token, _slot), do: state

  # ---------------------------------------------------------------------------
  # Bootstrap lifecycle
  # ---------------------------------------------------------------------------

  defp new_expiring_slot(bound, token, status, grace_ms) do
    %{
      principal_id: bound.principal_id,
      purpose: bound.purpose,
      status: status,
      grace_ms: grace_ms
    }
    |> schedule_expiry(token, status, grace_ms)
  end

  defp schedule_expiry(slot, token, status, grace_ms) do
    cancel_expiry_timer(slot)
    expiry_id = make_ref()
    timer_ref = Process.send_after(self(), {:expire_bootstrap, token, expiry_id}, grace_ms)

    Map.merge(slot, %{
      status: status,
      expiry_id: expiry_id,
      expiry_timer: timer_ref,
      expires_at_ms: monotonic_ms() + grace_ms
    })
  end

  defp mark_bootstrap_claimed(state, nil, _authority_token), do: state

  defp mark_bootstrap_claimed(state, bootstrap_token, authority_token) do
    case Map.get(state.bootstraps, bootstrap_token) do
      nil ->
        state

      slot ->
        cancel_expiry_timer(slot)

        claimed =
          slot
          |> Map.drop([:expiry_id, :expiry_timer, :expires_at_ms])
          |> Map.merge(%{status: :claimed, authority_token: authority_token})

        put_in(state, [:bootstraps, bootstrap_token], claimed)
    end
  end

  defp fetch_bound_bootstrap(state, bootstrap) do
    case Map.fetch(state.bootstraps, bootstrap.token) do
      :error ->
        {:error, :bootstrap_not_found}

      {:ok, slot} ->
        cond do
          slot.principal_id != bootstrap.principal_id -> {:error, :principal_mismatch}
          slot.purpose != bootstrap.purpose -> {:error, :purpose_mismatch}
          true -> {:ok, slot}
        end
    end
  end

  defp remove_bootstrap(state, token, slot) do
    cancel_expiry_timer(slot)

    state =
      case Map.get(slot, :authority_token) do
        nil ->
          state

        authority_token ->
          case Map.get(state.authorities, authority_token) do
            nil -> state
            entry -> remove_authority(state, authority_token, entry)
          end
      end

    update_in(state, [:bootstraps], &Map.delete(&1, token))
  end

  defp bootstrap_expired?(slot) do
    expires_at_ms = Map.get(slot, :expires_at_ms)
    is_integer(expires_at_ms) and monotonic_ms() >= expires_at_ms
  end

  defp cancel_expiry_timer(%{expiry_timer: timer_ref}) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref, async: false, info: false)
    :ok
  end

  defp cancel_expiry_timer(_slot), do: :ok

  # ---------------------------------------------------------------------------
  # Restart-safe persistent state
  # ---------------------------------------------------------------------------

  defp with_persistent_commit(reply, state, after_commit \\ fn -> :ok end) do
    case persist_state(state) do
      :ok ->
        after_commit.()
        {:reply, reply, state}

      {:error, _reason} ->
        {:stop, :state_owner_unavailable, {:error, :broker_unavailable}, state}
    end
  end

  defp commit_persistent_result({:reply, reply, state}) do
    with_persistent_commit(reply, state)
  end

  defp commit_persistent_result(other), do: other

  defp noreply_with_persistent_commit(state) do
    case persist_state(state) do
      :ok -> {:noreply, state}
      {:error, _reason} -> {:stop, :state_owner_unavailable, state}
    end
  end

  defp persist_state(state) do
    SigningAuthorityStateOwner.replace_from_supervisor(
      state.security_supervisor_pid,
      persistent_snapshot(state),
      state.state_owner_token
    )
  end

  defp claim_owner_directory do
    table = :ets.new(@owner_table, [:named_table, :protected, :set, read_concurrency: true])
    true = :ets.insert(table, {:owner, self()})
    :ok
  rescue
    _ -> {:error, :broker_owner_directory_unavailable}
  end

  defp broker_pid do
    SupervisedOwner.protected_directory_owner(
      @owner_table,
      :owner,
      :arbor_security,
      [__MODULE__]
    )
  end

  defp persistent_snapshot(state) do
    authorities =
      state.authorities
      |> Enum.filter(fn {_token, entry} -> entry.key_source == :persistent end)
      |> Map.new(fn {token, entry} -> {token, Map.drop(entry, [:owner_ref])} end)

    bootstraps =
      Map.new(state.bootstraps, fn {token, slot} ->
        {token, Map.drop(slot, [:expiry_id, :expiry_timer])}
      end)

    open_requests =
      state.persistent_open_requests
      |> Enum.filter(fn {_request_id, request} ->
        Map.has_key?(authorities, request.authority_token)
      end)
      |> Map.new(fn {request_id, request} ->
        {request_id, Map.drop(request, [:expiry_id, :expiry_timer])}
      end)

    %{
      authorities: authorities,
      bootstraps: bootstraps,
      open_requests: open_requests,
      activation_nonces: state.activation_nonces
    }
  end

  defp recover_persistent_state(%{
         authorities: authorities,
         bootstraps: bootstraps,
         open_requests: open_requests,
         activation_nonces: activation_nonces
       })
       when is_map(authorities) and is_map(bootstraps) and is_map(open_requests) and
              is_map(activation_nonces) do
    state = %{
      authorities: %{},
      bootstraps: %{},
      persistent_open_requests: %{},
      ephemeral_open_requests: %{},
      monitors: %{},
      activation_nonces: admit_activation_nonces(activation_nonces)
    }

    with {:ok, state} <- recover_authorities(state, authorities),
         {:ok, state} <- recover_bootstraps(state, bootstraps) do
      state =
        Enum.reduce(open_requests, state, fn {_request_id, request}, acc ->
          revoke_recovered_open_request(acc, request)
        end)

      {:ok, state}
    end
  end

  defp recover_persistent_state(_snapshot), do: {:error, :invalid_persistent_state}

  defp recover_authorities(state, authorities) do
    Enum.reduce_while(authorities, {:ok, state}, fn
      {token,
       %{
         principal_id: principal_id,
         purpose: _,
         owner_pid: owner_pid,
         opened_at: %DateTime{},
         key_source: :persistent,
         bootstrap_token: _
       } = entry},
      {:ok, acc}
      when is_binary(token) and is_binary(principal_id) and is_pid(owner_pid) ->
        if Process.alive?(owner_pid) do
          owner_ref = Process.monitor(owner_pid)
          recovered_entry = Map.put(entry, :owner_ref, owner_ref)

          acc =
            acc
            |> put_in([:authorities, token], recovered_entry)
            |> put_in([:monitors, owner_ref], token)

          {:cont, {:ok, acc}}
        else
          {:cont, {:ok, acc}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_persistent_state}}
    end)
  end

  defp recover_bootstraps(state, bootstraps) do
    Enum.reduce_while(bootstraps, {:ok, state}, fn
      {token,
       %{
         principal_id: principal_id,
         purpose: _purpose,
         status: status,
         grace_ms: grace_ms
       } = slot},
      {:ok, acc}
      when is_binary(token) and is_binary(principal_id) and
             status in [:unclaimed, :claimed, :reclaimable] and is_integer(grace_ms) and
             grace_ms > 0 ->
        case recover_bootstrap_slot(acc, token, slot) do
          {:ok, recovered} -> {:cont, {:ok, recovered}}
          :expired -> {:cont, {:ok, acc}}
          :invalid -> {:halt, {:error, :invalid_persistent_state}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_persistent_state}}
    end)
  end

  defp recover_bootstrap_slot(state, token, %{status: :claimed} = slot) do
    case Map.get(slot, :authority_token) do
      authority_token when is_binary(authority_token) ->
        if Map.has_key?(state.authorities, authority_token) do
          {:ok, put_in(state, [:bootstraps, token], slot)}
        else
          reclaimable =
            slot
            |> Map.drop([:authority_token, :expires_at_ms])
            |> schedule_expiry(token, :reclaimable, slot.grace_ms)

          {:ok, put_in(state, [:bootstraps, token], reclaimable)}
        end

      _ ->
        :invalid
    end
  end

  defp recover_bootstrap_slot(state, token, %{status: status} = slot)
       when status in [:unclaimed, :reclaimable] do
    case Map.get(slot, :expires_at_ms) do
      expires_at_ms when is_integer(expires_at_ms) ->
        remaining_ms = expires_at_ms - monotonic_ms()

        if remaining_ms > 0 do
          recovered = schedule_expiry(slot, token, status, remaining_ms)
          {:ok, put_in(state, [:bootstraps, token], recovered)}
        else
          :expired
        end

      _ ->
        :invalid
    end
  end

  defp revoke_recovered_open_request(state, %{authority_token: authority_token})
       when is_binary(authority_token) do
    case Map.get(state.authorities, authority_token) do
      nil ->
        state

      entry ->
        state
        |> remove_authority(authority_token, entry)
        |> maybe_make_bootstrap_reclaimable(entry, authority_token)
    end
  end

  defp revoke_recovered_open_request(state, _invalid), do: state

  # ---------------------------------------------------------------------------
  # Verification and crypto helpers
  # ---------------------------------------------------------------------------

  defp canonicalize_proof(%SignedRequest{} = proof) do
    payload = Map.get(proof, :payload)
    principal_id = Map.get(proof, :agent_id)
    timestamp = Map.get(proof, :timestamp)
    nonce = Map.get(proof, :nonce)
    signature = Map.get(proof, :signature)

    with true <- is_binary(payload) and byte_size(payload) > 0,
         :ok <- Validator.validate_principal_id(principal_id),
         true <- valid_datetime?(timestamp),
         true <- valid_nonce?(nonce),
         true <- is_binary(signature) and byte_size(signature) > 0 do
      {:ok, proof}
    else
      _ -> {:error, :invalid_acquisition_proof}
    end
  end

  defp canonicalize_proof(_), do: {:error, :invalid_acquisition_proof}

  # Local proof: minted in-process and bound to a purpose + owner pid on this
  # node, so it is not replayable against a peer. See
  # `Verifier.verify_local_possession_proof/1` — using the inbound `verify/1`
  # here made a connected peer (even an ephemeral mix node) fail startup.
  defp safe_verify(proof) do
    Verifier.verify_local_possession_proof(proof)
  rescue
    _ -> {:error, :verification_failed}
  catch
    :exit, _ -> {:error, :verification_failed}
  end

  # An inbound request (e.g. a Gateway HTTP request) crossed the network, so
  # it gets the full inbound verifier, including the cluster replay gate.
  defp verify_inbound_request(request) do
    Verifier.verify(request)
  rescue
    _ -> {:error, :verification_failed}
  catch
    :exit, _ -> {:error, :verification_failed}
  end

  defp canonicalize_lifecycle_request(request) do
    case SignedRequest.canonicalize(request) do
      {:ok, %SignedRequest{agent_id: agent_id} = canonical} when is_binary(agent_id) ->
        {:ok, canonical}

      _ ->
        {:error, :invalid_signed_request}
    end
  rescue
    _ -> {:error, :invalid_signed_request}
  end

  defp match_lifecycle_payload(%SignedRequest{payload: payload}, expected_payload)
       when is_binary(payload) and payload == expected_payload,
       do: :ok

  defp match_lifecycle_payload(_request, _expected_payload), do: {:error, :payload_mismatch}

  defp require_human_principal("human_" <> rest) when byte_size(rest) > 0, do: :ok
  defp require_human_principal(_principal_id), do: {:error, :human_principal_required}

  defp verify_private_key_matches(principal_id, proof, private_key) do
    with {:ok, public_key} <- lookup_public_key(principal_id),
         {:ok, signature} <-
           safely_crypto_sign(key_check_payload(proof), private_key, :invalid_private_key),
         {:ok, true} <-
           safely_crypto_verify(
             key_check_payload(proof),
             signature,
             public_key,
             :verification_failed
           ) do
      :ok
    else
      {:ok, false} -> {:error, :private_key_mismatch}
      {:error, _} = error -> error
    end
  end

  defp key_check_payload(proof) do
    @ephemeral_key_check_v1 <> length_prefix(proof.agent_id) <> length_prefix(proof.nonce)
  end

  defp lookup_public_key(principal_id) do
    case Registry.lookup(principal_id) do
      {:ok, public_key} -> {:ok, public_key}
      {:error, :not_found} -> {:error, :identity_not_found}
      {:error, :identity_suspended} -> {:error, :identity_suspended}
      {:error, :identity_revoked} -> {:error, :identity_revoked}
      {:error, _} -> {:error, :identity_not_active}
    end
  catch
    :exit, {:noproc, _} -> {:error, :identity_not_found}
  end

  defp ensure_identity_active(principal_id) do
    case Registry.identity_status(principal_id) do
      {:ok, :active} -> :ok
      {:ok, :suspended} -> {:error, :identity_suspended}
      {:ok, :revoked} -> {:error, :identity_revoked}
      {:ok, _other} -> {:error, :identity_not_active}
      {:error, :not_found} -> {:error, :identity_not_found}
    end
  catch
    :exit, {:noproc, _} -> {:error, :identity_not_found}
  end

  defp ensure_signing_key_present(principal_id) do
    case load_validated_persistent_key(principal_id) do
      {:ok, _private_key} -> :ok
      {:error, _} = error -> error
    end
  end

  defp load_private_key(principal_id) do
    try do
      case SigningKeyStore.get(principal_id) do
        {:ok, private_key} when is_binary(private_key) and byte_size(private_key) in [32, 64] ->
          {:ok, private_key}

        {:ok, _invalid_key} ->
          {:error, :signing_key_invalid}

        {:error, :no_signing_key} ->
          {:error, :no_signing_key}

        {:error, _reason} ->
          {:error, :signing_key_unavailable}
      end
    rescue
      _ -> {:error, :signing_key_unavailable}
    catch
      :exit, _ -> {:error, :signing_key_unavailable}
    end
  end

  defp load_validated_persistent_key(principal_id) do
    with {:ok, private_key} <- load_private_key(principal_id),
         {:ok, public_key} <- lookup_public_key(principal_id),
         payload = persistent_key_check_payload(principal_id),
         {:ok, signature} <- safely_crypto_sign(payload, private_key, :signing_key_invalid),
         {:ok, matches?} <-
           safely_crypto_verify(payload, signature, public_key, :signing_key_invalid),
         true <- matches? do
      {:ok, private_key}
    else
      false -> {:error, :signing_key_mismatch}
      {:error, _} = error -> error
    end
  end

  defp validate_private_key(key) when is_binary(key) and byte_size(key) in [32, 64], do: :ok
  defp validate_private_key(_), do: {:error, :invalid_private_key}

  defp match_principal(verified_principal_id, bound_principal_id, proof_principal_id) do
    if verified_principal_id == bound_principal_id and proof_principal_id == bound_principal_id do
      :ok
    else
      {:error, :principal_mismatch}
    end
  end

  defp match_claimed_principal(proof_principal_id, bound_principal_id) do
    if proof_principal_id == bound_principal_id,
      do: :ok,
      else: {:error, :principal_mismatch}
  end

  defp match_owner(bound_owner, caller_pid) do
    if bound_owner == caller_pid, do: :ok, else: {:error, :owner_mismatch}
  end

  defp ensure_owner_alive(owner_pid) do
    if Process.alive?(owner_pid), do: :ok, else: {:error, :owner_dead}
  end

  defp derive_info(purpose) when is_boolean(purpose), do: {:error, :invalid_purpose}

  defp derive_info(purpose) when is_atom(purpose) and not is_nil(purpose) do
    {:ok, @derive_domain_prefix <> Atom.to_string(purpose)}
  end

  defp derive_info(purpose) when is_binary(purpose) do
    cond do
      String.trim(purpose) == "" ->
        {:error, :invalid_purpose}

      String.starts_with?(purpose, @derive_domain_prefix) or
        String.contains?(purpose, "..") or purpose in ["raw", "private_key"] ->
        {:error, :invalid_purpose}

      true ->
        {:ok, @derive_domain_prefix <> purpose}
    end
  end

  defp derive_info(_), do: {:error, :invalid_purpose}

  defp ephemeral_aad(principal_id, purpose, token) do
    purpose_bin = :erlang.term_to_binary(purpose, [:deterministic])

    @ephemeral_aad_v1 <>
      length_prefix(principal_id) <>
      length_prefix(purpose_bin) <>
      length_prefix(token)
  end

  defp persistent_key_check_payload(principal_id) do
    @persistent_key_check_v1 <> length_prefix(principal_id)
  end

  defp wrap_ephemeral_key(private_key, wrapping_key, aad) do
    try do
      {ciphertext, iv, tag} = Crypto.encrypt(private_key, wrapping_key, aad)

      {:ok,
       %{
         kind: :ephemeral,
         ciphertext: ciphertext,
         iv: iv,
         tag: tag
       }}
    rescue
      _ -> {:error, :key_wrapping_failed}
    catch
      :exit, _ -> {:error, :key_wrapping_failed}
    end
  end

  defp safely_decrypt_ephemeral_key(key_source, wrapping_key, aad) do
    try do
      case Crypto.decrypt(
             key_source.ciphertext,
             wrapping_key,
             key_source.iv,
             key_source.tag,
             aad
           ) do
        {:ok, private_key} -> {:ok, private_key}
        {:error, _reason} -> {:error, :key_decryption_failed}
      end
    rescue
      _ -> {:error, :key_decryption_failed}
    catch
      :exit, _ -> {:error, :key_decryption_failed}
    end
  end

  defp require_platform_activation_purpose(:platform_activation), do: :ok

  defp require_platform_activation_purpose(_purpose), do: {:error, :purpose_mismatch}

  defp validate_resource_binding(payload) when is_binary(payload) do
    cond do
      byte_size(payload) <= 2_048 and Arbor.Contracts.Security.CapabilityUri.valid?(payload) ->
        :ok

      Arbor.Security.RoutineOwnerRequest.valid?(payload) ->
        :ok

      true ->
        {:error, :invalid_resource_binding}
    end
  end

  defp validate_resource_binding(_payload), do: {:error, :invalid_resource_binding}

  defp validate_native_notice_source_payload(payload, entry, caller)
       when is_binary(payload) and byte_size(payload) <= 16_384 and is_pid(caller) do
    with ["arbor.native.notice.source.v1", source] <-
           :erlang.binary_to_term(payload, [:safe]),
         true <- is_map(source) and not is_struct(source),
         [:branch_pid, :mailboxes, :owner_pid, :principal_id, :role] <-
           Map.keys(source) |> Enum.sort(),
         ^caller <- source.owner_pid,
         true <- source.principal_id == entry.principal_id,
         true <- Process.alive?(source.branch_pid),
         true <- native_notice_purpose_matches?(entry.purpose, source.role),
         true <- is_list(source.mailboxes) and length(source.mailboxes) in 1..16,
         true <-
           Enum.all?(
             source.mailboxes,
             &match?(
               {:ok, _},
               Arbor.Security.validate_native_notice_mailbox(source.principal_id, &1)
             )
           ) do
      :ok
    else
      _ -> {:error, :native_notice_source_required}
    end
  rescue
    _ -> {:error, :native_notice_source_required}
  catch
    _, _ -> {:error, :native_notice_source_required}
  end

  defp validate_native_notice_source_payload(_payload, _entry, _caller),
    do: {:error, :native_notice_source_required}

  defp native_notice_purpose_matches?(:session, :session), do: true
  defp native_notice_purpose_matches?(:heartbeat, :heartbeat_service), do: true
  defp native_notice_purpose_matches?(_purpose, _role), do: false

  defp validate_native_notice_publication_payload(payload, entry)
       when is_binary(payload) and byte_size(payload) <= 130_000 do
    with {:ok,
          [
            "arbor.conversation.notice.publication.v1",
            owner_id,
            target_agent_id,
            engagement_id,
            recipient_subject_id,
            notice_id,
            kind,
            text,
            provenance
          ]} <- Jason.decode(payload),
         true <- target_agent_id == entry.principal_id,
         true <- entry.purpose in [:session, :heartbeat],
         scope = %{
           owner_id: owner_id,
           target_agent_id: target_agent_id,
           engagement_id: engagement_id
         },
         value = %{
           recipient_subject_id: recipient_subject_id,
           notice_id: notice_id,
           kind: kind,
           text: text,
           provenance: provenance
         },
         {:ok, ^payload} <- Arbor.Security.ConversationNoticeCore.payload(scope, value) do
      :ok
    else
      _ -> {:error, :native_notice_source_required}
    end
  rescue
    _ -> {:error, :native_notice_source_required}
  catch
    _, _ -> {:error, :native_notice_source_required}
  end

  defp validate_native_notice_publication_payload(_payload, _entry),
    do: {:error, :native_notice_source_required}

  defp validate_identity_id(value) when is_binary(value) do
    if byte_size(value) in 1..@max_identity_id_bytes//1 and String.valid?(value) and
         not String.contains?(value, <<0>>),
       do: :ok,
       else: {:error, :invalid_identity_endorsement}
  end

  defp identity_endorsement_field(value),
    do: <<byte_size(value)::32-big-unsigned-integer, value::binary>>

  defp validate_activation_nonce(nonce) when is_binary(nonce) do
    if byte_size(nonce) == 32 and Regex.match?(~r/\A[0-9a-f]{32}\z/, nonce),
      do: :ok,
      else: {:error, :invalid_nonce}
  end

  defp validate_activation_nonce(_nonce), do: {:error, :invalid_nonce}

  defp activation_window(valid_from, valid_until) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    with {:ok, starts, 0} <- DateTime.from_iso8601(valid_from),
         {:ok, ends, 0} <- DateTime.from_iso8601(valid_until),
         start_order when start_order in [:lt, :eq] <- DateTime.compare(starts, now),
         ordering when ordering in [:gt, :eq] <- DateTime.compare(ends, now) do
      requested_end = DateTime.add(now, @platform_activation_ttl_seconds, :second)
      expires = if DateTime.compare(requested_end, ends) == :gt, do: ends, else: requested_end

      if DateTime.compare(expires, now) == :gt do
        {:ok,
         %{
           issued_at: DateTime.to_iso8601(now),
           expires_at: DateTime.to_iso8601(expires),
           expires_at_unix: DateTime.to_unix(expires)
         }}
      else
        {:error, :invalid_validity_window}
      end
    else
      _ -> {:error, :invalid_validity_window}
    end
  end

  defp match_activation_reservation(
         %{
           authority_token: token,
           issued_at: issued_at,
           expires_at: expires_at,
           status: :reserved
         },
         %{token: token},
         %{"payload" => payload},
         nonce
       )
       when is_map(payload) do
    if payload["nonce"] == nonce and payload["issued_at"] == issued_at and
         payload["expires_at"] == expires_at,
       do: :ok,
       else: {:error, :activation_reservation_mismatch}
  end

  defp match_activation_reservation(_, _, _, _),
    do: {:error, :activation_reservation_missing}

  defp prune_activation_nonces(state) do
    now = System.system_time(:second)

    nonces =
      Map.reject(state.activation_nonces, fn {_nonce, reservation} ->
        not is_map(reservation) or Map.get(reservation, :expires_at_unix, 0) <= now
      end)

    %{state | activation_nonces: nonces}
  end

  defp admit_activation_nonces(nonces) do
    now = System.system_time(:second)

    nonces
    |> Enum.filter(fn
      {nonce,
       %{
         authority_token: token,
         issued_at: issued,
         expires_at: expires,
         expires_at_unix: expiry,
         status: status
       }} ->
        is_binary(nonce) and is_binary(token) and is_binary(issued) and is_binary(expires) and
          is_integer(expiry) and expiry > now and status in [:reserved, :consumed]

      _ ->
        false
    end)
    |> Enum.take(@max_activation_nonces)
    |> Map.new()
  end

  @forge_projection_domain "arbor-forge-projection-v1"
  @platform_activation_domain "arbor.extension.activation_authorization.v1"

  defp require_detached_domain_purpose(:coding_task_executor, @forge_projection_domain), do: :ok

  defp require_detached_domain_purpose(_purpose, _domain_tag), do: {:error, :purpose_mismatch}

  defp verify_platform_activation_message(message) when is_binary(message) do
    if String.starts_with?(message, @platform_activation_domain <> <<0>>),
      do: :ok,
      else: {:error, :domain_tag_mismatch}
  end

  defp verify_platform_activation_message(_message), do: {:error, :domain_tag_mismatch}

  defp verify_domain_tag_prefix(message, domain_tag)
       when is_binary(message) and is_binary(domain_tag) do
    size = byte_size(domain_tag)

    case message do
      <<^size::32-big-unsigned-integer, ^domain_tag::binary-size(size), _rest::binary>> -> :ok
      _ -> {:error, :domain_tag_mismatch}
    end
  end

  defp verify_domain_tag_prefix(_message, _domain_tag), do: {:error, :domain_tag_mismatch}

  defp safely_sign_request(payload, principal_id, private_key) do
    try do
      case SignedRequest.sign(payload, principal_id, private_key) do
        {:ok, %SignedRequest{} = signed} -> {:ok, signed}
        {:error, _reason} -> {:error, :signing_failed}
        _unexpected -> {:error, :signing_failed}
      end
    rescue
      _ -> {:error, :signing_failed}
    catch
      :exit, _ -> {:error, :signing_failed}
    end
  end

  defp safely_sign_detached(message, private_key) do
    try do
      signature = Crypto.sign(message, private_key)

      if is_binary(signature) and byte_size(signature) == 64 do
        {:ok, signature}
      else
        {:error, :signing_failed}
      end
    rescue
      _ -> {:error, :signing_failed}
    catch
      :exit, _ -> {:error, :signing_failed}
    end
  end

  defp safely_derive_secret(private_key, info) do
    try do
      {:ok, Crypto.derive_key(private_key, info, 32)}
    rescue
      _ -> {:error, :derivation_failed}
    catch
      :exit, _ -> {:error, :derivation_failed}
    end
  end

  defp safely_crypto_sign(payload, private_key, error_reason) do
    try do
      {:ok, Crypto.sign(payload, private_key)}
    rescue
      _ -> {:error, error_reason}
    catch
      :exit, _ -> {:error, error_reason}
    end
  end

  defp safely_crypto_verify(payload, signature, public_key, error_reason) do
    try do
      {:ok, Crypto.verify(payload, signature, public_key)}
    rescue
      _ -> {:error, error_reason}
    catch
      :exit, _ -> {:error, error_reason}
    end
  end

  defp key_source_name(:persistent), do: :persistent
  defp key_source_name(key_source) when is_map(key_source), do: Map.get(key_source, :kind)

  defp ephemeral_key_source?(%{
         kind: :ephemeral,
         ciphertext: ciphertext,
         iv: iv,
         tag: tag
       })
       when is_binary(ciphertext) and is_binary(iv) and is_binary(tag),
       do: true

  defp ephemeral_key_source?(_), do: false

  defp valid_nonce?(nonce)
       when is_binary(nonce) and byte_size(nonce) == @signed_request_nonce_bytes do
    nonce != :binary.copy(<<0>>, @signed_request_nonce_bytes)
  end

  defp valid_nonce?(_), do: false

  defp valid_datetime?(%DateTime{} = datetime) do
    _ = DateTime.to_iso8601(datetime)
    true
  rescue
    _ -> false
  end

  defp valid_datetime?(_), do: false

  defp issue_option_pairs(opts) when is_map(opts), do: {:ok, Map.to_list(opts)}

  defp issue_option_pairs(opts) when is_list(opts) do
    if Enum.all?(opts, &match?({_key, _value}, &1)) do
      {:ok, opts}
    else
      {:error, :invalid_options}
    end
  end

  defp validate_issue_option_keys(pairs) do
    cond do
      Enum.any?(pairs, fn {key, _value} -> not is_atom(key) end) ->
        {:error, :mixed_option_keys}

      Enum.any?(pairs, fn {key, _value} -> key != :grace_ms end) ->
        {:error, :unknown_option}

      true ->
        :ok
    end
  end

  defp reject_duplicate_issue_options(pairs) do
    if length(pairs) == length(Enum.uniq_by(pairs, &elem(&1, 0))) do
      :ok
    else
      {:error, :duplicate_option}
    end
  end

  defp validate_grace_ms(grace_ms) when is_integer(grace_ms) and grace_ms > 0 do
    if grace_ms <= Config.signing_authority_bootstrap_max_grace_ms() do
      {:ok, grace_ms}
    else
      {:error, :invalid_grace_ms}
    end
  end

  defp validate_grace_ms(_), do: {:error, :invalid_grace_ms}

  defp map_count(state, key) when is_map(state) do
    case Map.get(state, key) do
      value when is_map(value) -> map_size(value)
      _ -> 0
    end
  end

  defp map_count(_state, _key), do: 0

  defp redact_status_field(status, key) do
    if Map.has_key?(status, key), do: Map.put(status, key, :redacted), else: status
  end

  defp safe_term(bin) when is_binary(bin) do
    try do
      {:ok, :erlang.binary_to_term(bin, [:safe])}
    rescue
      ArgumentError -> {:error, :invalid_acquisition_proof}
    end
  end

  defp safe_term(_), do: {:error, :invalid_acquisition_proof}

  defp random_token, do: :crypto.strong_rand_bytes(@token_bytes)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp length_prefix(binary), do: <<byte_size(binary)::32, binary::binary>>
end
