defmodule Arbor.Security.Identity.Registry do
  @moduledoc """
  Registry for agent identities with pluggable persistence.

  Stores public keys indexed by agent ID for fast lookup during signature
  verification. Private keys are never stored — only the public portion
  of an identity is retained.

  Identity entries are persisted via a configurable storage backend
  (implementing `Arbor.Contracts.Persistence.Store`) and restored on startup.

  ## Configuration

      config :arbor_security, :storage_backend, Arbor.Security.Store.JSONFile

  Set to `nil` to disable persistence (in-memory only).

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
  - **Registration authorization.** `register/2` consults an optional
    `Config.registration_policy/0` before creating a NEW identity. Default
    `nil` (allow) — every current caller is internal (agent lifecycle,
    scheduler); there is no external registration endpoint. The policy seam is
    the place to require an enrollment token / operator approval WHEN an
    external registration path is added.
  - **Store integrity.** Persisted entries (public keys only) are within the
    conceded same-UID/file-access threat (T4). A signed/HMAC'd identity store
    is a Layer 3 follow-up.
  """

  use GenServer

  require Logger

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Config
  alias Arbor.Security.Crypto
  alias Arbor.Security.OIDC.IdentityStore
  alias Arbor.Security.OIDC.TokenVerifier
  alias Arbor.Security.SignalSync
  alias Arbor.Signals

  # Runtime bridge — arbor_persistence is Level 1 peer, no compile-time dep
  @buffered_store Arbor.Persistence.BufferedStore
  @id_store :arbor_security_identities
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

  @doc """
  Register an identity (public key only).

  The identity's private key is stripped before storage. This path accepts
  self-certifying `agent_` identities only; `human_` identities require
  `register_oidc/3` with the original signed token and provider configuration.

  `opts` is passed to the configured registration policy (see
  `register/2`) — e.g. `enrollment_token:` or `requested_by:` for an external
  enrollment flow.
  """
  @spec register(Identity.t()) :: :ok | {:error, term()}
  def register(%Identity{} = identity), do: register(identity, [])

  @doc """
  Register an identity, passing `opts` to the registration policy.

  ## Registration authorization (C10)

  Before the self-certifying check, the registry consults an optional
  **registration policy** — `Arbor.Security.Config.registration_policy/0`, a
  module implementing `authorize_registration/2`. The default is `nil`
  (allow), preserving today's behavior: every caller is internal (agent
  lifecycle, scheduler) and trusted.

  This is the chokepoint to enforce *who may mint identities* when an
  external registration path is added (e.g. require a signed enrollment
  token, or operator approval). The self-certifying check (`agent_id ==
  hash(pubkey)`) prevents impersonating an existing key regardless of policy;
  the policy governs whether a NEW identity may be created at all.
  """
  @spec register(Identity.t(), keyword()) :: :ok | {:error, term()}
  def register(%Identity{agent_id: "human_" <> _rest}, _opts),
    do: {:error, :oidc_proof_required}

  def register(%Identity{} = identity, opts) when is_list(opts) do
    GenServer.call(__MODULE__, {:register, identity, opts})
  end

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
    GenServer.call(__MODULE__, {:register_oidc, identity, id_token, provider_config})
  end

  def register_oidc(_identity, _id_token, _provider_config),
    do: {:error, :invalid_oidc_registration}

  @doc """
  Look up the public key for an agent.
  """
  @spec lookup(String.t()) :: {:ok, binary()} | {:error, :not_found}
  def lookup(agent_id) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:lookup, agent_id})
  end

  @doc """
  Look up the encryption public key (X25519) for an agent.

  Returns `{:error, :not_found}` if the agent is not registered, and
  `{:error, :no_encryption_key}` if registered but has no encryption key.
  """
  @spec lookup_encryption_key(String.t()) ::
          {:ok, binary()} | {:error, :not_found | :no_encryption_key}
  def lookup_encryption_key(agent_id) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:lookup_encryption_key, agent_id})
  end

  @doc """
  Check if an agent is registered.
  """
  @spec registered?(String.t()) :: boolean()
  def registered?(agent_id) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:registered?, agent_id})
  end

  @doc """
  Remove a registered identity.
  """
  @spec deregister(String.t()) :: :ok | {:error, :not_found}
  def deregister(agent_id) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:deregister, agent_id})
  end

  @doc """
  Look up agent IDs by human-readable name.

  Names are not unique — returns all agent IDs registered with the given name.
  """
  @spec lookup_by_name(String.t()) :: {:ok, [String.t()]} | {:error, :not_found}
  def lookup_by_name(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:lookup_by_name, name})
  end

  @doc """
  Get registry statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ===========================================================================
  # Identity Lifecycle Management
  # ===========================================================================

  @doc """
  Suspend an identity.

  Sets status to `:suspended`, recording the timestamp and optional reason.
  Suspended identities cannot be looked up (lookup returns error) but
  can be resumed later.

  ## Examples

      :ok = Registry.suspend("agent_001", "Suspicious activity detected")
  """
  @spec suspend(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def suspend(agent_id, reason \\ nil) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:suspend, agent_id, reason})
  end

  @doc """
  Resume a suspended identity.

  Sets status back to `:active`. Only works for `:suspended` identities.
  Returns error if the identity is `:revoked` (terminal state).

  ## Examples

      :ok = Registry.resume("agent_001")
  """
  @spec resume(String.t()) :: :ok | {:error, term()}
  def resume(agent_id) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:resume, agent_id})
  end

  @doc """
  Revoke an identity.

  Sets status to `:revoked` (terminal state). The identity entry remains
  for audit trail but cannot be used. This also triggers capability
  revocation via the CapabilityStore.

  Returns `{:ok, count}` where count is the number of capabilities that
  were revoked as a result of this identity revocation.

  ## Examples

      {:ok, 3} = Registry.revoke_identity("agent_001", "Account compromised")
  """
  @spec revoke_identity(String.t(), String.t() | nil) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def revoke_identity(agent_id, reason \\ nil) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:revoke_identity, agent_id, reason})
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
    GenServer.call(__MODULE__, {:get_status, agent_id})
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
  def init(_opts) do
    case subscribe_to_distributed_signals() do
      {:ok, signal_sync} ->
        state = %{
          by_agent_id: %{},
          by_public_key_hash: %{},
          by_name: %{},
          signal_sync: signal_sync,
          stats: %{total_registered: 0, total_deregistered: 0}
        }

        {:ok, restore_from_store(state)}

      {:error, reason} ->
        {:stop, {:security_sync_subscription_failed, reason}}
    end
  end

  @impl true
  def handle_call({:register, %Identity{} = identity, opts}, _from, state) do
    cond do
      human_identity?(identity) ->
        {:reply, {:error, :oidc_proof_required}, state}

      true ->
        expected_id = Crypto.derive_agent_id(identity.public_key)

        if identity.agent_id == expected_id do
          register_validated_identity(state, identity, opts)
        else
          {:reply, {:error, {:agent_id_mismatch, identity.agent_id, :expected, expected_id}},
           state}
        end
    end
  rescue
    _ -> {:reply, {:error, :invalid_identity}, state}
  catch
    :exit, _ -> {:reply, {:error, :registration_unavailable}, state}
  end

  @impl true
  def handle_call(
        {:register_oidc, %Identity{} = identity, id_token, provider_config},
        _from,
        state
      ) do
    with true <- human_identity?(identity),
         {:ok, claims} <- verify_oidc_token(id_token, provider_config),
         {:ok, expected_id} <- derive_verified_human_id(claims),
         :ok <- match_human_identity(identity.agent_id, expected_id) do
      registration_opts = [oidc_issuer: Map.get(claims, "iss")]
      register_validated_identity(state, identity, registration_opts)
    else
      false -> {:reply, {:error, :invalid_human_identity}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:lookup, agent_id}, _from, state) do
    result =
      case Map.get(state.by_agent_id, agent_id) do
        nil -> {:error, :not_found}
        %{status: :suspended} -> {:error, :identity_suspended}
        %{status: :revoked} -> {:error, :identity_revoked}
        %{public_key: pk} -> {:ok, pk}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:lookup_encryption_key, agent_id}, _from, state) do
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

  @impl true
  def handle_call({:registered?, agent_id}, _from, state) do
    {:reply, Map.has_key?(state.by_agent_id, agent_id), state}
  end

  @impl true
  def handle_call({:deregister, agent_id}, _from, state) do
    case Map.get(state.by_agent_id, agent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{public_key: pk, name: name} ->
        pk_hash = Crypto.hash(pk)

        state =
          state
          |> update_in([:by_agent_id], &Map.delete(&1, agent_id))
          |> update_in([:by_public_key_hash], &Map.delete(&1, pk_hash))
          |> deindex_by_name(name, agent_id)
          |> update_in([:stats, :total_deregistered], &(&1 + 1))

        delete_from_store(agent_id)
        emit_identity_signal(:identity_deregistered, agent_id)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:lookup_by_name, name}, _from, state) do
    case Map.get(state.by_name, name) do
      nil -> {:reply, {:error, :not_found}, state}
      [] -> {:reply, {:error, :not_found}, state}
      agent_ids -> {:reply, {:ok, agent_ids}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
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

  @impl true
  def handle_call({:suspend, agent_id, reason}, _from, state) do
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

        state = put_in(state, [:by_agent_id, agent_id], updated_entry)
        persist_to_store(agent_id, updated_entry)
        emit_identity_signal(:identity_suspended, agent_id)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:resume, agent_id}, _from, state) do
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

        state = put_in(state, [:by_agent_id, agent_id], updated_entry)
        persist_to_store(agent_id, updated_entry)
        emit_identity_signal(:identity_resumed, agent_id)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:revoke_identity, agent_id, reason}, _from, state) do
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

        state = put_in(state, [:by_agent_id, agent_id], updated_entry)
        persist_to_store(agent_id, updated_entry)

        # Revoke all capabilities for this agent
        {:ok, revoked_count} = CapabilityStore.revoke_all(agent_id)

        emit_identity_signal(:identity_revoked, agent_id)
        {:reply, {:ok, revoked_count}, state}
    end
  end

  @impl true
  def handle_call({:get_status, agent_id}, _from, state) do
    result =
      case Map.get(state.by_agent_id, agent_id) do
        nil -> {:error, :not_found}
        %{status: status} -> {:ok, status}
        # Old entries without status field default to :unknown
        _entry -> {:ok, :unknown}
      end

    {:reply, result, state}
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp register_validated_identity(state, identity, opts) do
    with :ok <- validate_public_identity(identity),
         :ok <- authorize_registration(identity, opts) do
      if Map.has_key?(state.by_agent_id, identity.agent_id) do
        {:reply, {:error, {:already_registered, identity.agent_id}}, state}
      else
        pk_hash = Crypto.hash(identity.public_key)

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

        state =
          state
          |> put_in([:by_agent_id, identity.agent_id], entry)
          |> put_in([:by_public_key_hash, pk_hash], identity.agent_id)
          |> index_by_name(identity.name, identity.agent_id)
          |> update_in([:stats, :total_registered], &(&1 + 1))

        persist_to_store(identity.agent_id, entry)
        emit_identity_signal(:identity_registered, identity.agent_id)
        {:reply, :ok, state}
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
    cond do
      not is_binary(Map.get(identity, :agent_id)) -> {:error, :invalid_identity}
      not is_binary(Map.get(identity, :public_key)) -> {:error, :invalid_identity}
      byte_size(identity.public_key) != 32 -> {:error, :invalid_identity}
      not is_map(Map.get(identity, :metadata)) -> {:error, :invalid_identity}
      true -> :ok
    end
  end

  defp authorize_registration(identity, opts) do
    case registration_authorized(identity, opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:registration_denied, reason}}
      _ -> {:error, {:registration_denied, :invalid_policy_result}}
    end
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
  def handle_info({:signal_received, signal}, state) do
    state = handle_distributed_signal(signal, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(message, state) do
    case SignalSync.handle_info(message, state.signal_sync) do
      {:ok, signal_sync} ->
        {:noreply, %{state | signal_sync: signal_sync}}

      {:stop, reason, signal_sync} ->
        {:stop, reason, %{state | signal_sync: signal_sync}}

      :unhandled ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    SignalSync.release(Map.get(state, :signal_sync))
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

  # C10 registration-authorization seam. A configured policy module
  # (Config.registration_policy/0) implementing authorize_registration/2 can
  # gate who may create a new identity. Default (nil) = allow — every current
  # caller is internal/trusted. Fails CLOSED if a configured policy crashes.
  defp registration_authorized(identity, opts) do
    case registration_policy_module() do
      nil ->
        :ok

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

    if origin_node in [node(), Atom.to_string(node())] do
      state
    else
      handle_remote_identity_signal(signal.type, signal.data, state)
    end
  catch
    _, reason ->
      Logger.warning("[IdentityRegistry] Failed to handle distributed signal: #{inspect(reason)}")
      state
  end

  defp handle_remote_identity_signal(:identity_registered, data, state) do
    agent_id = data[:agent_id] || data["agent_id"]

    if agent_id && not Map.has_key?(state.by_agent_id, agent_id) do
      # Load from shared backend
      case load_identity_from_backend(agent_id) do
        {:ok, entry} ->
          pk_hash = Crypto.hash(entry.public_key)

          Logger.debug("[IdentityRegistry] Synced remote identity #{agent_id}")

          state
          |> put_in([:by_agent_id, agent_id], entry)
          |> put_in([:by_public_key_hash, pk_hash], agent_id)
          |> index_by_name(entry[:name], agent_id)

        {:error, _} ->
          state
      end
    else
      state
    end
  end

  defp handle_remote_identity_signal(type, data, state)
       when type in [
              :identity_deregistered,
              :identity_suspended,
              :identity_resumed,
              :identity_revoked
            ] do
    agent_id = data[:agent_id] || data["agent_id"]

    if agent_id && Map.has_key?(state.by_agent_id, agent_id) do
      case type do
        :identity_deregistered ->
          case Map.get(state.by_agent_id, agent_id) do
            %{public_key: pk, name: name} ->
              pk_hash = Crypto.hash(pk)

              state
              |> update_in([:by_agent_id], &Map.delete(&1, agent_id))
              |> update_in([:by_public_key_hash], &Map.delete(&1, pk_hash))
              |> deindex_by_name(name, agent_id)

            _ ->
              update_in(state, [:by_agent_id], &Map.delete(&1, agent_id))
          end

        :identity_suspended ->
          update_in(state, [:by_agent_id, agent_id], fn entry ->
            %{entry | status: :suspended, status_changed_at: DateTime.utc_now()}
          end)

        :identity_resumed ->
          update_in(state, [:by_agent_id, agent_id], fn entry ->
            %{entry | status: :active, status_changed_at: DateTime.utc_now(), status_reason: nil}
          end)

        :identity_revoked ->
          update_in(state, [:by_agent_id, agent_id], fn entry ->
            %{entry | status: :revoked, status_changed_at: DateTime.utc_now()}
          end)
      end
    else
      state
    end
  end

  defp handle_remote_identity_signal(_type, _data, state), do: state

  defp load_identity_from_backend(agent_id) do
    if Process.whereis(@id_store) do
      case apply(@buffered_store, :get, [agent_id, [name: @id_store]]) do
        {:ok, %Record{data: data}} ->
          {:ok, deserialize_entry(data)}

        error ->
          error
      end
    else
      {:error, :store_unavailable}
    end
  catch
    _, reason -> {:error, reason}
  end

  # ===========================================================================
  # Persistence via BufferedStore
  # ===========================================================================

  @id_store :arbor_security_identities

  defp persist_to_store(agent_id, entry) do
    if Process.whereis(@id_store) do
      data = serialize_entry(agent_id, entry)
      record = Record.new(agent_id, data)
      apply(@buffered_store, :put, [agent_id, record, [name: @id_store]])
    end

    :ok
  catch
    _, reason ->
      Logger.warning("Failed to persist identity #{agent_id}: #{inspect(reason)}")
      :ok
  end

  defp delete_from_store(agent_id) do
    if Process.whereis(@id_store) do
      apply(@buffered_store, :delete, [agent_id, [name: @id_store]])
    end

    :ok
  catch
    _, reason ->
      Logger.warning("Failed to delete persisted identity #{agent_id}: #{inspect(reason)}")
      :ok
  end

  defp restore_from_store(state) do
    if Process.whereis(@id_store) do
      case apply(@buffered_store, :list, [[name: @id_store]]) do
        {:ok, keys} ->
          Enum.reduce(keys, state, &restore_key_from_store/2)

        {:error, _reason} ->
          state
      end
    else
      state
    end
  catch
    _, reason ->
      Logger.warning("Failed to restore identities: #{inspect(reason)}")
      state
  end

  defp restore_key_from_store(key, acc) do
    case apply(@buffered_store, :get, [key, [name: @id_store]]) do
      {:ok, %Record{data: data}} ->
        restore_entry(acc, data)

      {:error, reason} ->
        Logger.warning("Failed to restore identity #{key}: #{inspect(reason)}")
        acc
    end
  end

  defp restore_entry(state, data) do
    case deserialize_entry(data) do
      {:ok, agent_id, entry} ->
        pk_hash = Crypto.hash(entry.public_key)

        state
        |> put_in([:by_agent_id, agent_id], entry)
        |> put_in([:by_public_key_hash, pk_hash], agent_id)
        |> index_by_name(entry.name, agent_id)
        |> update_in([:stats, :total_registered], &(&1 + 1))

      {:error, reason} ->
        Logger.warning("Failed to deserialize identity: #{inspect(reason)}")
        state
    end
  rescue
    e ->
      Logger.warning("Failed to restore identity entry: #{inspect(e)}")
      state
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
    entry = %{
      public_key: Base.decode16!(data["public_key"], case: :mixed),
      encryption_public_key: decode_optional_key(data["encryption_public_key"]),
      name: data["name"],
      key_version: data["key_version"] || 1,
      created_at: parse_datetime(data["created_at"]),
      metadata: data["metadata"] || %{},
      status: String.to_existing_atom(data["status"] || "active"),
      status_changed_at: parse_optional_datetime(data["status_changed_at"]),
      status_reason: data["status_reason"]
    }

    {:ok, data["agent_id"], entry}
  rescue
    e -> {:error, e}
  end

  defp encode_optional_key(nil), do: nil
  defp encode_optional_key(key) when is_binary(key), do: Base.encode16(key, case: :lower)

  defp decode_optional_key(nil), do: nil
  defp decode_optional_key(hex) when is_binary(hex), do: Base.decode16!(hex, case: :mixed)

  defp encode_optional_datetime(nil), do: nil
  defp encode_optional_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_optional_datetime(nil), do: nil

  defp parse_optional_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
