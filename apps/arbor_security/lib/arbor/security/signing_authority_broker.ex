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
  - The broker-local wrapping key and all ephemeral entries disappear on restart
  - Decrypted key material is scoped to one sign/derive call; BEAM zeroization is
    not claimed
  - Broker state never retains proofs, functions, MFA tuples, or signer callbacks

  A `SigningAuthority` is intentionally a bearer reference so Engine helper
  processes may use it. It is usable only while the owner PID recorded by the
  broker remains alive; callers do not become owners merely by holding the token.

  Callers outside `arbor_security` must use the `Arbor.Security` facade.
  """

  use GenServer

  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Contracts.Security.SigningAuthority.Validator
  alias Arbor.Contracts.Security.SigningAuthorityBootstrap
  alias Arbor.Security.Config
  alias Arbor.Security.Crypto
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.Identity.Verifier
  alias Arbor.Security.SigningKeyStore

  @token_bytes 32
  @wrapping_key_bytes 32
  @signed_request_nonce_bytes 16
  @derive_domain_prefix "arbor.signing_authority.v1/"
  @acquisition_v1 "arbor.signing_authority.acquire.v1"
  @ephemeral_aad_v1 "arbor.signing_authority.ephemeral.v1"
  @ephemeral_key_check_v1 "arbor.signing_authority.ephemeral.key_check.v1"

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

  @doc """
  Open a persistent signing authority directly from a possession proof.
  """
  @spec open(SignedRequest.t()) :: {:ok, SigningAuthority.t()} | {:error, term()}
  def open(%SignedRequest{} = proof), do: call({:open, proof})
  def open(_), do: {:error, :invalid_acquisition_proof}

  @doc """
  Issue an expiring persistent-backed restart slot from a possession proof.
  """
  @spec issue_bootstrap(SignedRequest.t(), keyword() | map()) ::
          {:ok, SigningAuthorityBootstrap.t()} | {:error, term()}
  def issue_bootstrap(%SignedRequest{} = proof, opts) when is_list(opts) or is_map(opts) do
    call({:issue_bootstrap, proof, opts})
  end

  def issue_bootstrap(_, _), do: {:error, :possession_proof_required}

  @doc """
  Claim an unclaimed or reclaimable bootstrap for the GenServer caller.
  """
  @spec claim_bootstrap(SigningAuthorityBootstrap.t()) ::
          {:ok, SigningAuthority.t()} | {:error, term()}
  def claim_bootstrap(bootstrap) do
    case SigningAuthorityBootstrap.canonicalize(bootstrap) do
      {:ok, canonical} -> call({:claim_bootstrap, canonical})
      {:error, reason} -> {:error, reason}
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
    call({:open_ephemeral, proof, private_key})
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

  defp call(message) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, {:noproc, _} -> {:error, :broker_unavailable}
    :exit, {:normal, _} -> {:error, :broker_unavailable}
    :exit, {:shutdown, _} -> {:error, :broker_unavailable}
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    configured_grace_ms =
      Keyword.get(opts, :bootstrap_grace_ms, Config.signing_authority_bootstrap_grace_ms())

    grace_ms =
      if is_integer(configured_grace_ms) and configured_grace_ms > 0,
        do: configured_grace_ms,
        else: Config.signing_authority_bootstrap_grace_ms()

    {:ok,
     %{
       authorities: %{},
       bootstraps: %{},
       monitors: %{},
       wrapping_key: :crypto.strong_rand_bytes(@wrapping_key_bytes),
       bootstrap_grace_ms: grace_ms
     }}
  end

  @impl true
  def handle_call({:open, proof}, {caller_pid, _tag}, state) do
    case verify_persistent_acquisition(proof, caller_pid) do
      {:ok, bound} -> create_authority(state, bound, caller_pid, :persistent, nil)
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:issue_bootstrap, proof, _opts}, {caller_pid, _tag}, state) do
    case verify_persistent_acquisition(proof, caller_pid) do
      {:ok, bound} -> create_bootstrap(state, bound)
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:claim_bootstrap, bootstrap}, {caller_pid, _tag}, state) do
    case SigningAuthorityBootstrap.canonicalize(bootstrap) do
      {:ok, bootstrap} -> claim_bootstrap_for_caller(state, bootstrap, caller_pid)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:close_bootstrap, bootstrap}, _from, state) do
    case SigningAuthorityBootstrap.canonicalize(bootstrap) do
      {:ok, bootstrap} -> close_bootstrap_entry(state, bootstrap)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:open_ephemeral, proof, private_key}, {caller_pid, _tag}, state) do
    result =
      with :ok <- validate_private_key(private_key),
           {:ok, bound} <- verify_acquisition(proof, caller_pid),
           :ok <- verify_private_key_matches(bound.principal_id, proof, private_key) do
        token = random_token()
        aad = ephemeral_aad(bound.principal_id, bound.purpose, token)
        {ciphertext, iv, tag} = Crypto.encrypt(private_key, state.wrapping_key, aad)

        key_source = %{
          kind: :ephemeral,
          ciphertext: ciphertext,
          iv: iv,
          tag: tag
        }

        {:ok, bound, token, key_source}
      end

    case result do
      {:ok, bound, token, key_source} ->
        create_authority(state, bound, caller_pid, key_source, nil, token)

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:sign, authority, payload}, _from, state) do
    reply =
      with {:ok, authority} <- SigningAuthority.canonicalize(authority),
           {:ok, entry} <- authorize_authority(authority, state),
           {:ok, private_key} <- private_key_for(entry, authority.token, state) do
        SignedRequest.sign(payload, entry.principal_id, private_key)
      end

    {:reply, reply, state}
  end

  def handle_call({:derive_secret, authority, purpose}, _from, state) do
    reply =
      with {:ok, authority} <- SigningAuthority.canonicalize(authority),
           {:ok, info} <- derive_info(purpose),
           {:ok, entry} <- authorize_authority(authority, state),
           {:ok, private_key} <- private_key_for(entry, authority.token, state) do
        {:ok, Crypto.derive_key(private_key, info, 32)}
      end

    {:reply, reply, state}
  end

  def handle_call({:close, authority}, _from, state) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, authority} -> close_authority_entry(state, authority)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:debug_state, _from, state) do
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
          has_private_key?: Map.has_key?(slot, :private_key),
          has_function?: Enum.any?(slot, fn {_key, value} -> is_function(value) end),
          has_proof?: Map.has_key?(slot, :proof) or Map.has_key?(slot, :signed_request)
        }
      end)

    snapshot = %{
      authority_count: map_size(state.authorities),
      bootstrap_count: map_size(state.bootstraps),
      wrapping_key_present?: is_binary(state.wrapping_key),
      entries: entries,
      bootstrap_entries: bootstrap_entries
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {authority_token, monitors} ->
        state = %{state | monitors: monitors}

        case Map.pop(state.authorities, authority_token) do
          {nil, _authorities} ->
            {:noreply, state}

          {entry, authorities} ->
            state = %{state | authorities: authorities}
            {:noreply, maybe_make_bootstrap_reclaimable(state, entry, authority_token)}
        end
    end
  end

  def handle_info({:expire_bootstrap, token, expiry_id}, state) do
    case Map.get(state.bootstraps, token) do
      %{expiry_id: ^expiry_id, status: status} = slot when status in [:unclaimed, :reclaimable] ->
        {:noreply, remove_bootstrap(state, token, slot)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.monitors, fn {ref, _token} -> Process.demonitor(ref, [:flush]) end)

    Enum.each(state.bootstraps, fn {_token, slot} ->
      cancel_expiry_timer(slot)
    end)

    :ok
  end

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
         {:ok, verified_principal_id} <- safe_verify(proof),
         {:ok, bound} <- parse_acquisition_payload(proof.payload),
         :ok <- match_principal(verified_principal_id, bound.principal_id, proof.agent_id),
         :ok <- match_owner(bound.owner_pid, caller_pid),
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

  defp create_bootstrap(state, bound) do
    token = random_token()
    slot = new_expiring_slot(bound, token, :unclaimed, state.bootstrap_grace_ms)

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
    load_private_key(principal_id)
  end

  defp private_key_for(%{key_source: key_source} = entry, token, state) do
    if ephemeral_key_source?(key_source) do
      aad = ephemeral_aad(entry.principal_id, entry.purpose, token)

      Crypto.decrypt(
        key_source.ciphertext,
        state.wrapping_key,
        key_source.iv,
        key_source.tag,
        aad
      )
    else
      {:error, :invalid_key_source}
    end
  end

  defp remove_authority(state, token, entry, demonitor? \\ true) do
    if demonitor?, do: Process.demonitor(entry.owner_ref, [:flush])

    state
    |> update_in([:authorities], &Map.delete(&1, token))
    |> update_in([:monitors], &Map.delete(&1, entry.owner_ref))
  end

  defp maybe_make_bootstrap_reclaimable(state, %{bootstrap_token: nil}, _authority_token),
    do: state

  defp maybe_make_bootstrap_reclaimable(state, entry, authority_token) do
    case Map.get(state.bootstraps, entry.bootstrap_token) do
      %{status: :claimed, authority_token: ^authority_token} = slot ->
        reclaimable =
          slot
          |> Map.drop([:authority_token])
          |> schedule_expiry(entry.bootstrap_token, :reclaimable, state.bootstrap_grace_ms)

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
          |> schedule_expiry(token, :reclaimable, state.bootstrap_grace_ms)

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
      status: status
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

  defp safe_verify(proof) do
    Verifier.verify(proof)
  rescue
    _ -> {:error, :verification_failed}
  catch
    :exit, _ -> {:error, :verification_failed}
  end

  defp verify_private_key_matches(principal_id, proof, private_key) do
    with {:ok, public_key} <- lookup_public_key(principal_id),
         {:ok, signature} <- sign_key_check(proof, private_key),
         true <- Crypto.verify(key_check_payload(proof), signature, public_key) do
      :ok
    else
      false -> {:error, :private_key_mismatch}
      {:error, _} = error -> error
    end
  end

  defp sign_key_check(proof, private_key) do
    {:ok, Crypto.sign(key_check_payload(proof), private_key)}
  rescue
    ErlangError -> {:error, :invalid_private_key}
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
    case SigningKeyStore.get(principal_id) do
      {:ok, private_key} when is_binary(private_key) and byte_size(private_key) in [32, 64] -> :ok
      {:ok, _invalid_key} -> {:error, :signing_key_unavailable}
      {:error, :no_signing_key} -> {:error, :no_signing_key}
      {:error, _reason} -> {:error, :signing_key_unavailable}
    end
  end

  defp load_private_key(principal_id) do
    case SigningKeyStore.get(principal_id) do
      {:ok, private_key} when is_binary(private_key) and byte_size(private_key) in [32, 64] ->
        {:ok, private_key}

      {:ok, _invalid_key} ->
        {:error, :signing_key_unavailable}

      {:error, :no_signing_key} ->
        {:error, :no_signing_key}

      {:error, _reason} ->
        {:error, :signing_key_unavailable}
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

  defp match_owner(bound_owner, caller_pid) do
    if bound_owner == caller_pid, do: :ok, else: {:error, :owner_mismatch}
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
