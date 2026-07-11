defmodule Arbor.Security.SigningAuthorityBroker do
  @moduledoc """
  Supervised broker for reload-stable signing-authority tokens.

  Owns unguessable authority tokens and maps each to:

  - principal (agent id)
  - open-time purpose label
  - monitored owner PID
  - lifecycle metadata (`opened_at`)

  ## Security invariants

  - Acquisition requires a one-shot `SignedRequest` possession proof (not agent_id alone)
  - Never stores a long-lived anonymous signer function
  - Never retains a decrypted persistent private key in GenServer state
  - Never retains acquisition proofs, MFA, modules, or raw keys in broker state
  - Loads/decrypts the key inside each sign/derive operation, uses it, drops it
  - Owner is the GenServer caller; proof must bind that same owner
  - Principal and purpose on the bearer reference are rebound on every use
  - Owner DOWN and explicit close revoke the token
  - Broker restart invalidates all outstanding references (in-memory only)

  Callers must use the public `Arbor.Security` facade — not this module —
  from outside `arbor_security`.
  """

  use GenServer

  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Security.Crypto
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.Identity.Verifier
  alias Arbor.Security.SigningKeyStore

  require Logger

  @token_bytes 32
  @derive_domain_prefix "arbor.signing_authority.v1/"
  @acquisition_v1 "arbor.signing_authority.acquire.v1"

  @type open_purpose :: atom() | String.t()
  @type derive_purpose :: atom() | String.t()

  @type entry :: %{
          principal_id: String.t(),
          purpose: open_purpose(),
          owner_pid: pid(),
          owner_ref: reference(),
          opened_at: DateTime.t()
        }

  # ---------------------------------------------------------------------------
  # Acquisition payload (canonical, pure)
  # ---------------------------------------------------------------------------

  @doc """
  Build the canonical acquisition payload bound into a one-shot SignedRequest.

  Binds principal, purpose, and intended owner process. The broker re-checks
  the owner against the GenServer caller at open time.
  """
  @spec acquisition_payload(String.t(), open_purpose(), pid()) :: binary()
  def acquisition_payload(principal_id, purpose, owner_pid)
      when is_binary(principal_id) and is_pid(owner_pid) do
    purpose_bin = :erlang.term_to_binary(purpose)
    owner_bin = :erlang.term_to_binary(owner_pid)

    @acquisition_v1 <>
      <<byte_size(principal_id)::32, principal_id::binary>> <>
      <<byte_size(purpose_bin)::32, purpose_bin::binary>> <>
      <<byte_size(owner_bin)::32, owner_bin::binary>>
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
         :ok <- validate_open_purpose(purpose),
         true <- is_binary(principal_id) and principal_id != "" do
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
  Open a signing authority after verifying a one-shot SignedRequest possession proof.

  Owner is always the GenServer caller — not caller-supplied metadata. The proof
  payload must bind the same owner process, principal, and purpose.
  """
  @spec open(SignedRequest.t()) ::
          {:ok, SigningAuthority.t()}
          | {:error,
             :invalid_acquisition_proof
             | :invalid_purpose
             | :owner_mismatch
             | :principal_mismatch
             | :identity_not_active
             | :identity_suspended
             | :identity_revoked
             | :identity_not_found
             | :no_signing_key
             | :broker_unavailable
             | :invalid_signature
             | :replayed_nonce
             | :expired_timestamp
             | :unknown_agent
             | term()}
  def open(%SignedRequest{} = proof) do
    call({:open, proof})
  end

  def open(_), do: {:error, :invalid_acquisition_proof}

  @doc """
  Sign `payload` with the authority's principal key.

  Re-validates existence, principal binding, purpose binding, owner liveness,
  identity status, and key presence on every call. Loads the key for the
  duration of the call only.
  """
  @spec sign(SigningAuthority.t(), binary()) ::
          {:ok, SignedRequest.t()}
          | {:error,
             :invalid_authority
             | :authority_not_found
             | :principal_mismatch
             | :purpose_mismatch
             | :owner_dead
             | :identity_not_active
             | :identity_suspended
             | :identity_revoked
             | :identity_not_found
             | :no_signing_key
             | :invalid_payload
             | :broker_unavailable
             | term()}
  def sign(authority, payload) when is_binary(payload) do
    # Canonicalize before GenServer.call — partial struct-tagged maps match
    # `%SigningAuthority{}` but crash on missing-field access inside handle_call.
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
  Derive a domain-separated secret from the authority's principal key.

  `purpose` is mandatory domain separation material. The broker always
  prefixes a fixed namespace (`#{@derive_domain_prefix}`) so callers cannot
  request an undomained raw-key export. The persistent private key is never
  returned.
  """
  @spec derive_secret(SigningAuthority.t(), derive_purpose()) ::
          {:ok, binary()}
          | {:error,
             :invalid_authority
             | :authority_not_found
             | :principal_mismatch
             | :purpose_mismatch
             | :owner_dead
             | :identity_not_active
             | :identity_suspended
             | :identity_revoked
             | :identity_not_found
             | :no_signing_key
             | :invalid_purpose
             | :broker_unavailable
             | term()}
  def derive_secret(authority, purpose) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, canonical} -> call({:derive_secret, canonical, purpose})
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Explicitly revoke an authority token.
  """
  @spec close(SigningAuthority.t()) ::
          :ok
          | {:error,
             :invalid_authority
             | :authority_not_found
             | :principal_mismatch
             | :purpose_mismatch
             | :broker_unavailable
             | term()}
  def close(authority) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, canonical} -> call({:close, canonical})
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec debug_state() :: map()
  def debug_state do
    call(:debug_state)
  end

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
  def init(_opts) do
    # Owner monitoring uses Process.monitor/1 only — no trap_exit required.
    # Trapping exits would delay supervisor shutdown for linked children.
    {:ok,
     %{
       # token => entry (never includes private keys, functions, proofs, or MFA)
       authorities: %{},
       # monitor_ref => token
       monitors: %{}
     }}
  end

  @impl true
  def handle_call({:open, %SignedRequest{} = proof}, {caller_pid, _tag}, state) do
    reply_and_state =
      with {:ok, verified_agent_id} <- Verifier.verify(proof),
           {:ok, bound} <- parse_acquisition_payload(proof.payload),
           :ok <- match_principal(verified_agent_id, bound.principal_id, proof.agent_id),
           :ok <- match_owner(bound.owner_pid, caller_pid),
           :ok <- validate_open_purpose(bound.purpose),
           :ok <- ensure_identity_active(bound.principal_id),
           :ok <- ensure_signing_key_present(bound.principal_id) do
        token = :crypto.strong_rand_bytes(@token_bytes)
        owner_ref = Process.monitor(caller_pid)

        entry = %{
          principal_id: bound.principal_id,
          purpose: bound.purpose,
          owner_pid: caller_pid,
          owner_ref: owner_ref,
          opened_at: DateTime.utc_now()
        }

        state =
          state
          |> put_in([:authorities, token], entry)
          |> put_in([:monitors, owner_ref], token)

        case SigningAuthority.new(
               token: token,
               principal_id: bound.principal_id,
               purpose: bound.purpose
             ) do
          {:ok, authority} ->
            {{:ok, authority}, state}

          {:error, reason} ->
            Process.demonitor(owner_ref, [:flush])

            state =
              state
              |> update_in([:authorities], &Map.delete(&1, token))
              |> update_in([:monitors], &Map.delete(&1, owner_ref))

            {{:error, reason}, state}
        end
      else
        {:error, _} = error ->
          {error, state}
      end

    {reply, new_state} = reply_and_state
    {:reply, reply, new_state}
  end

  def handle_call({:sign, authority, payload}, _from, state) do
    # Re-canonicalize inside the server so a hostile message never KeyError-crashes
    # the broker (and invalidates live leases).
    reply =
      with {:ok, authority} <- SigningAuthority.canonicalize(authority),
           {:ok, entry} <- authorize_authority(authority, state),
           {:ok, private_key} <- load_private_key(entry.principal_id) do
        # Key used only for this call — never written into state or the reply envelope.
        SignedRequest.sign(payload, entry.principal_id, private_key)
      end

    {:reply, reply, state}
  end

  def handle_call({:derive_secret, authority, purpose}, _from, state) do
    reply =
      with {:ok, authority} <- SigningAuthority.canonicalize(authority),
           {:ok, info} <- derive_info(purpose),
           {:ok, entry} <- authorize_authority(authority, state),
           {:ok, private_key} <- load_private_key(entry.principal_id) do
        secret = Crypto.derive_key(private_key, info, 32)
        {:ok, secret}
      end

    {:reply, reply, state}
  end

  def handle_call({:close, authority}, _from, state) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, authority} ->
        case Map.fetch(state.authorities, authority.token) do
          {:ok, entry} ->
            cond do
              entry.principal_id != authority.principal_id ->
                {:reply, {:error, :principal_mismatch}, state}

              entry.purpose != authority.purpose ->
                {:reply, {:error, :purpose_mismatch}, state}

              true ->
                {:reply, :ok, revoke_token(state, authority.token, entry)}
            end

          :error ->
            {:reply, {:error, :authority_not_found}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:debug_state, _from, state) do
    # Test/introspection helper — never includes private keys or functions.
    snapshot = %{
      authority_count: map_size(state.authorities),
      entries:
        Enum.map(state.authorities, fn {token, entry} ->
          %{
            token_present?: is_binary(token) and byte_size(token) > 0,
            principal_id: entry.principal_id,
            purpose: entry.purpose,
            owner_pid: entry.owner_pid,
            owner_alive?: Process.alive?(entry.owner_pid),
            opened_at: entry.opened_at,
            has_private_key?: Map.has_key?(entry, :private_key),
            has_function?: Enum.any?(entry, fn {_k, v} -> is_function(v) end),
            has_proof?: Map.has_key?(entry, :proof) or Map.has_key?(entry, :signed_request)
          }
        end)
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {token, monitors} ->
        authorities = Map.delete(state.authorities, token)
        {:noreply, %{state | authorities: authorities, monitors: monitors}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.monitors, fn {ref, _token} ->
      Process.demonitor(ref, [:flush])
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Authorization helpers
  # ---------------------------------------------------------------------------

  defp authorize_authority(authority, state) do
    # Map.get avoids KeyError on residual partial maps; callers should have
    # already canonicalized, but this is the GenServer fail-closed last line.
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
            with :ok <- ensure_identity_active(entry.principal_id) do
              {:ok, entry}
            end
        end
    end
  end

  defp match_principal(verified_agent_id, bound_principal_id, proof_agent_id) do
    if verified_agent_id == bound_principal_id and proof_agent_id == bound_principal_id do
      :ok
    else
      {:error, :principal_mismatch}
    end
  end

  defp match_owner(bound_owner, caller_pid) do
    if bound_owner == caller_pid do
      :ok
    else
      {:error, :owner_mismatch}
    end
  end

  defp ensure_identity_active(principal_id) do
    case Registry.identity_status(principal_id) do
      {:ok, :active} ->
        :ok

      {:ok, :suspended} ->
        {:error, :identity_suspended}

      {:ok, :revoked} ->
        {:error, :identity_revoked}

      {:ok, _other} ->
        {:error, :identity_not_active}

      {:error, :not_found} ->
        {:error, :identity_not_found}
    end
  catch
    :exit, {:noproc, _} ->
      {:error, :identity_not_found}
  end

  defp ensure_signing_key_present(principal_id) do
    case SigningKeyStore.get(principal_id) do
      {:ok, _key} ->
        # Intentionally discard — never store in broker state.
        :ok

      {:error, :no_signing_key} ->
        {:error, :no_signing_key}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_private_key(principal_id) do
    case SigningKeyStore.get(principal_id) do
      {:ok, private_key} when is_binary(private_key) ->
        {:ok, private_key}

      {:error, :no_signing_key} ->
        {:error, :no_signing_key}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revoke_token(state, token, entry) do
    Process.demonitor(entry.owner_ref, [:flush])

    state
    |> update_in([:authorities], &Map.delete(&1, token))
    |> update_in([:monitors], &Map.delete(&1, entry.owner_ref))
  end

  defp validate_open_purpose(purpose) when is_boolean(purpose), do: {:error, :invalid_purpose}

  defp validate_open_purpose(purpose) when is_atom(purpose) and not is_nil(purpose), do: :ok

  defp validate_open_purpose(purpose) when is_binary(purpose) do
    if String.trim(purpose) == "" do
      {:error, :invalid_purpose}
    else
      :ok
    end
  end

  defp validate_open_purpose(_), do: {:error, :invalid_purpose}

  defp derive_info(purpose) when is_boolean(purpose), do: {:error, :invalid_purpose}

  defp derive_info(purpose) when is_atom(purpose) and not is_nil(purpose) do
    {:ok, @derive_domain_prefix <> Atom.to_string(purpose)}
  end

  defp derive_info(purpose) when is_binary(purpose) do
    cond do
      String.trim(purpose) == "" ->
        {:error, :invalid_purpose}

      String.starts_with?(purpose, @derive_domain_prefix) or
        String.contains?(purpose, "..") or
        purpose == "raw" or
          purpose == "private_key" ->
        {:error, :invalid_purpose}

      true ->
        {:ok, @derive_domain_prefix <> purpose}
    end
  end

  defp derive_info(_), do: {:error, :invalid_purpose}

  defp safe_term(bin) when is_binary(bin) do
    try do
      {:ok, :erlang.binary_to_term(bin, [:safe])}
    rescue
      ArgumentError -> {:error, :invalid_acquisition_proof}
    end
  end

  defp safe_term(_), do: {:error, :invalid_acquisition_proof}
end
