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

  # Issuer stamped on identities minted by `mix arbor.user.init`. Must match
  # `Arbor.Security.local_human_claims/1`.
  @local_pseudo_issuer "arbor://local"

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Config
  alias Arbor.Security.Crypto
  alias Arbor.Security.OIDC.IdentityStore
  alias Arbor.Security.OIDC.TokenVerifier
  alias Arbor.Security.SignalSync
  alias Arbor.Signals

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
    GenServer.call(__MODULE__, {:register_local_human, identity})
  end

  def register_local_human(_identity), do: {:error, :invalid_local_registration}

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

  Durable mode may also return a bounded identity-store error when the exact
  delete cannot be acknowledged. In that case the hot identity is unchanged.
  """
  @spec deregister(String.t()) ::
          :ok
          | {:error,
             :not_found
             | :identity_store_conflict
             | :identity_store_outcome_unknown
             | :identity_store_unavailable}
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
    state = %{
      by_agent_id: %{},
      by_public_key_hash: %{},
      by_name: %{},
      authority_records: %{},
      authority_mode: :hot_only,
      signal_sync: nil,
      stats: %{total_registered: 0, total_deregistered: 0}
    }

    with {:ok, state} <- restore_authority(state),
         {:ok, signal_sync} <- subscribe_to_distributed_signals() do
      {:ok, %{state | signal_sync: signal_sync}}
    else
      {:error, {:identity_authority, _reason} = reason} ->
        {:stop, reason}

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
      metadata =
        if is_map(identity.metadata) do
          identity.metadata
          |> Map.put("oidc_issuer", claims["iss"])
          |> Map.put("oidc_sub", claims["sub"])
          |> Map.put("identity_type", "human")
        else
          identity.metadata
        end

      identity =
        %{
          identity
          | metadata: metadata
        }

      registration_opts = [oidc_issuer: Map.get(claims, "iss")]
      register_validated_identity(state, identity, registration_opts)
    else
      false -> {:reply, {:error, :invalid_human_identity}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:register_local_human, %Identity{} = identity}, _from, state) do
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

        commit_identity_status(state, agent_id, updated_entry, :identity_suspended)
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

        commit_identity_status(state, agent_id, updated_entry, :identity_resumed)
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

        case commit_identity_update(state, agent_id, updated_entry) do
          {:ok, state} ->
            state = put_in(state, [:by_agent_id, agent_id], updated_entry)
            emit_identity_signal(:identity_revoked, agent_id)

            case CapabilityStore.revoke_all(agent_id) do
              {:ok, revoked_count} ->
                {:reply, {:ok, revoked_count}, state}

              {:error, reason} ->
                {:reply, {:error, {:capability_revocation_failed, reason}}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:get_status, agent_id}, _from, state) do
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

        case commit_new_identity(state, identity.agent_id, entry) do
          {:ok, state} ->
            state =
              state
              |> put_in([:by_agent_id, identity.agent_id], entry)
              |> put_in([:by_public_key_hash, pk_hash], identity.agent_id)
              |> index_by_name(identity.name, identity.agent_id)
              |> update_in([:stats, :total_registered], &(&1 + 1))

            emit_identity_signal(:identity_registered, identity.agent_id)
            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
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
    permanent_audit? = (signal.data[:permanent] || signal.data["permanent"]) == true

    cond do
      # The telemetry bridge reflects permanent audit observations onto the
      # signal bus. They are observability, not distributed mutation transport.
      permanent_audit? ->
        state

      origin_node in [node(), Atom.to_string(node())] ->
        state

      # Per-type. Suspension/revocation/deregistration apply unconditionally;
      # :identity_registered and :identity_resumed stay gated because they
      # restore authority (note :identity_resumed shares an apply clause with
      # suspend/revoke — the split has to happen here, before dispatch).
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
    case authority_get(agent_id) do
      {:ok, record, entry} ->
        case remote_entry_for_event(type, entry) do
          {:ok, event_entry} ->
            if remote_public_key_available?(state, agent_id, event_entry) do
              replace_hot_identity(state, agent_id, event_entry, record)
            else
              fail_closed_remote(type, agent_id, state)
            end

          :remove ->
            remove_hot_identity(state, agent_id)

          :reject ->
            fail_closed_remote(type, agent_id, state)
        end

      {:error, :not_found} ->
        if type == :identity_deregistered,
          do: remove_hot_identity(state, agent_id),
          else: fail_closed_remote(type, agent_id, state)

      {:error, _reason} ->
        fail_closed_remote(type, agent_id, state)
    end
  end

  defp reconcile_remote_identity(type, agent_id, %{authority_mode: :hot_only} = state) do
    case type do
      :identity_deregistered -> remove_hot_identity(state, agent_id)
      :identity_suspended -> reduce_hot_identity(state, agent_id, :suspended)
      :identity_revoked -> reduce_hot_identity(state, agent_id, :revoked)
      _authority_restoring -> state
    end
  end

  defp remote_entry_for_event(:identity_registered, entry), do: {:ok, entry}
  defp remote_entry_for_event(:identity_resumed, %{status: :active} = entry), do: {:ok, entry}

  defp remote_entry_for_event(:identity_suspended, entry) do
    {:ok, %{entry | status: :suspended, status_changed_at: DateTime.utc_now()}}
  end

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
      case safe_authority_call(fn -> AuthorityStore.take_hydrated_entries(name: @id_store) end) do
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
           AuthorityStore.acknowledged_compare_and_swap(
             agent_id,
             :not_found,
             replacement,
             name: @id_store
           )
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
             AuthorityStore.acknowledged_compare_and_swap(
               agent_id,
               {:value, current},
               replacement,
               name: @id_store
             )
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
             AuthorityStore.acknowledged_compare_and_delete(
               agent_id,
               current,
               name: @id_store
             )
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

  defp authority_get(agent_id) do
    case safe_authority_call(fn ->
           AuthorityStore.authoritative_get(agent_id, name: @id_store)
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
