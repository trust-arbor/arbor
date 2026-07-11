defmodule Arbor.Security.SigningAuthorityBroker do
  @moduledoc """
  Supervised broker for reload-stable signing-authority tokens.

  Owns unguessable authority tokens and maps each to:

  - principal (agent id)
  - open-time purpose label
  - monitored owner PID
  - lifecycle metadata (`opened_at`)

  ## Security invariants

  - Never stores a long-lived anonymous signer function
  - Never retains a decrypted persistent private key in GenServer state
  - Loads/decrypts the key inside each sign/derive operation, uses it, drops it
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
  alias Arbor.Security.SigningKeyStore

  require Logger

  @token_bytes 32
  @derive_domain_prefix "arbor.signing_authority.v1/"

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
  # Client API
  # ---------------------------------------------------------------------------

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Open a signing authority for `principal_id` owned by `owner_pid`.

  Fails closed unless the identity is active and SigningKeyStore still has
  the principal's key. The decrypted key is not retained in broker state.
  """
  @spec open(String.t(), pid(), open_purpose()) ::
          {:ok, SigningAuthority.t()}
          | {:error,
             :invalid_principal_id
             | :invalid_owner
             | :invalid_purpose
             | :identity_not_active
             | :identity_suspended
             | :identity_revoked
             | :identity_not_found
             | :no_signing_key
             | :broker_unavailable
             | term()}
  def open(principal_id, owner_pid, purpose)
      when is_binary(principal_id) and is_pid(owner_pid) do
    call({:open, principal_id, owner_pid, purpose})
  end

  def open(principal_id, _owner_pid, _purpose) when not is_binary(principal_id) do
    {:error, :invalid_principal_id}
  end

  def open(_principal_id, owner_pid, _purpose) when not is_pid(owner_pid) do
    {:error, :invalid_owner}
  end

  @doc """
  Sign `payload` with the authority's principal key.

  Re-validates existence, principal binding, owner liveness, identity status,
  and key presence on every call. Loads the key for the duration of the call
  only.
  """
  @spec sign(SigningAuthority.t(), binary()) ::
          {:ok, SignedRequest.t()}
          | {:error,
             :invalid_authority
             | :authority_not_found
             | :principal_mismatch
             | :owner_dead
             | :identity_not_active
             | :identity_suspended
             | :identity_revoked
             | :identity_not_found
             | :no_signing_key
             | :invalid_payload
             | :broker_unavailable
             | term()}
  def sign(%SigningAuthority{} = authority, payload) when is_binary(payload) do
    call({:sign, authority, payload})
  end

  def sign(%SigningAuthority{}, _payload), do: {:error, :invalid_payload}
  def sign(_, _), do: {:error, :invalid_authority}

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
             | :owner_dead
             | :identity_not_active
             | :identity_suspended
             | :identity_revoked
             | :identity_not_found
             | :no_signing_key
             | :invalid_purpose
             | :broker_unavailable
             | term()}
  def derive_secret(%SigningAuthority{} = authority, purpose) do
    call({:derive_secret, authority, purpose})
  end

  def derive_secret(_, _), do: {:error, :invalid_authority}

  @doc """
  Explicitly revoke an authority token.
  """
  @spec close(SigningAuthority.t()) ::
          :ok | {:error, :invalid_authority | :authority_not_found | :broker_unavailable | term()}
  def close(%SigningAuthority{} = authority) do
    call({:close, authority})
  end

  def close(_), do: {:error, :invalid_authority}

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
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       # token => entry (never includes private keys or functions)
       authorities: %{},
       # monitor_ref => token
       monitors: %{}
     }}
  end

  @impl true
  def handle_call({:open, principal_id, owner_pid, purpose}, _from, state) do
    with :ok <- validate_open_purpose(purpose),
         :ok <- ensure_identity_active(principal_id),
         :ok <- ensure_signing_key_present(principal_id) do
      token = :crypto.strong_rand_bytes(@token_bytes)
      owner_ref = Process.monitor(owner_pid)

      entry = %{
        principal_id: principal_id,
        purpose: purpose,
        owner_pid: owner_pid,
        owner_ref: owner_ref,
        opened_at: DateTime.utc_now()
      }

      state =
        state
        |> put_in([:authorities, token], entry)
        |> put_in([:monitors, owner_ref], token)

      case SigningAuthority.new(
             token: token,
             principal_id: principal_id,
             purpose: purpose
           ) do
        {:ok, authority} ->
          {:reply, {:ok, authority}, state}

        {:error, reason} ->
          Process.demonitor(owner_ref, [:flush])

          state =
            state
            |> update_in([:authorities], &Map.delete(&1, token))
            |> update_in([:monitors], &Map.delete(&1, owner_ref))

          {:reply, {:error, reason}, state}
      end
    else
      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:sign, authority, payload}, _from, state) do
    reply =
      with {:ok, entry} <- authorize_authority(authority, state),
           {:ok, private_key} <- load_private_key(entry.principal_id) do
        # Key used only for this call — never written into state or the reply envelope.
        SignedRequest.sign(payload, entry.principal_id, private_key)
      end

    {:reply, reply, state}
  end

  def handle_call({:derive_secret, authority, purpose}, _from, state) do
    reply =
      with {:ok, info} <- derive_info(purpose),
           {:ok, entry} <- authorize_authority(authority, state),
           {:ok, private_key} <- load_private_key(entry.principal_id) do
        secret = Crypto.derive_key(private_key, info, 32)
        {:ok, secret}
      end

    {:reply, reply, state}
  end

  def handle_call({:close, authority}, _from, state) do
    case Map.fetch(state.authorities, authority.token) do
      {:ok, entry} ->
        if entry.principal_id == authority.principal_id do
          {:reply, :ok, revoke_token(state, authority.token, entry)}
        else
          {:reply, {:error, :principal_mismatch}, state}
        end

      :error ->
        {:reply, {:error, :authority_not_found}, state}
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
            has_function?: Enum.any?(entry, fn {_k, v} -> is_function(v) end)
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

  defp authorize_authority(%SigningAuthority{} = authority, state) do
    case Map.fetch(state.authorities, authority.token) do
      :error ->
        {:error, :authority_not_found}

      {:ok, entry} ->
        cond do
          entry.principal_id != authority.principal_id ->
            {:error, :principal_mismatch}

          not Process.alive?(entry.owner_pid) ->
            {:error, :owner_dead}

          true ->
            with :ok <- ensure_identity_active(entry.principal_id) do
              {:ok, entry}
            end
        end
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

  defp validate_open_purpose(purpose) when is_atom(purpose) and not is_nil(purpose), do: :ok

  defp validate_open_purpose(purpose) when is_binary(purpose) and byte_size(purpose) > 0, do: :ok

  defp validate_open_purpose(_), do: {:error, :invalid_purpose}

  defp derive_info(purpose) when is_atom(purpose) and not is_nil(purpose) do
    {:ok, @derive_domain_prefix <> Atom.to_string(purpose)}
  end

  defp derive_info(purpose) when is_binary(purpose) and byte_size(purpose) > 0 do
    # Reject attempts to smuggle an undomained / raw derivation path.
    if String.starts_with?(purpose, @derive_domain_prefix) or
         String.contains?(purpose, "..") or
         purpose == "raw" or
         purpose == "private_key" do
      {:error, :invalid_purpose}
    else
      {:ok, @derive_domain_prefix <> purpose}
    end
  end

  defp derive_info(_), do: {:error, :invalid_purpose}
end
