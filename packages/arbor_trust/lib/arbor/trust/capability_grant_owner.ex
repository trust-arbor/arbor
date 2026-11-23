defmodule Arbor.Trust.CapabilityGrantOwner do
  @moduledoc """
  Supervised owner for trust-policy JIT capability grants.

  The process owns a dedicated Security identity and opaque signing authority.
  Its identity may be created and registered at startup, but its mutation
  capability is never self-granted. Until an operator grants the exact
  `arbor://security/grant/**` capability, the process remains dormant and every
  request fails closed.

  Agents submit one-use signed requests. The owner verifies the request through
  Security, checks that the signer is the target principal, re-evaluates the
  current Trust policy itself, and only then spends its own mutation authority.
  Neither authority is returned to the caller.

  ## Revoking what a profile change made stale

  The owner is also the one actor that takes back what it minted. After a
  trust profile write, delete or disable commits, `Arbor.Trust.Store` casts
  `request_sync/2` and the owner runs `PolicyEnforcer.sync_capabilities/2` with
  its own authority. No signal is in that path, and the governed agent takes
  no part in it.

  The owner holds no revoke right. The security kernel lets a granter revoke
  the exact capability it granted, and that is all the owner ever revokes. A
  trust-marked capability someone else granted is left in place and reported
  (a warning and the `[:arbor, :trust, :capability_sync, :failed]` telemetry
  event), never swallowed.
  """

  use GenServer

  require Logger

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Trust.CapabilityGrantRequest
  alias Arbor.Trust.PolicyEnforcer

  @identity_name "trust_capability_grant_owner"
  @required_capability "arbor://security/grant/**"
  @sync_reasons [:profile_updated, :profile_deleted, :profile_disabled]
  # A sync requested by the profile store that fails is tried again after
  # these delays. The security kernel's authority and store call each other
  # synchronously, so a revocation that collides with other kernel traffic can
  # time out; without a retry that one collision would leave the grant alive
  # until the next profile change.
  @sync_retry_delays_ms [2_000, 10_000]
  @max_pending_sync_retries 256
  @purpose :trust_capability_grant
  @max_seen_nonces 8_192
  @custody_table Arbor.Trust.CapabilityGrantOwner.Custody
  @custody_tag :arbor_trust_capability_grant_owner_custody_v1

  @type status :: %{
          state: :ready | :dormant,
          principal_id: String.t() | nil,
          required_capability: String.t(),
          reason: term() | nil
        }

  @type sync_reason :: :profile_updated | :profile_deleted | :profile_disabled

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @spec request(SignedRequest.t(), GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def request(signed_request, server \\ __MODULE__) do
    GenServer.call(server, {:grant, signed_request}, 30_000)
  catch
    :exit, _ -> {:error, :capability_grant_owner_unavailable}
  end

  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status, 5_000)
  catch
    :exit, _ -> dormant_status(:capability_grant_owner_unavailable)
  end

  @doc """
  Ask the owner to revoke the trust-minted capabilities a profile change made
  stale for `agent_id`. Asynchronous and never blocks the caller: the profile
  store calls this from inside its own write.
  """
  @spec request_sync(String.t(), sync_reason(), GenServer.server()) :: :ok
  def request_sync(agent_id, reason, server \\ __MODULE__)
      when is_binary(agent_id) and reason in @sync_reasons do
    GenServer.cast(server, {:sync, agent_id, reason})
  end

  @doc """
  Run the same sync and wait for its result. For operators and tests.
  """
  @spec sync(String.t(), sync_reason(), GenServer.server()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def sync(agent_id, reason, server \\ __MODULE__)
      when is_binary(agent_id) and reason in @sync_reasons do
    GenServer.call(server, {:sync, agent_id, reason}, 30_000)
  catch
    :exit, _ -> {:error, :capability_grant_owner_unavailable}
  end

  @doc false
  def identity_name, do: @identity_name

  @doc false
  def required_capability_uri, do: @required_capability

  @impl true
  def init(opts) do
    Process.flag(:sensitive, true)

    dependencies = %{
      security: Keyword.get(opts, :security_facade, Arbor.Security),
      policy: Keyword.get(opts, :policy_enforcer, PolicyEnforcer),
      nonce_capacity: nonce_capacity(opts)
    }

    @custody_table = :ets.new(@custody_table, [:named_table, :set, :private])
    true = :ets.insert(@custody_table, {@custody_tag, :bootstrap, dependencies})

    {:ok, %{mode: :pending, principal_id: nil, dormant_reason: nil}, {:continue, :initialize}}
  end

  @impl true
  def handle_continue(:initialize, state) do
    # SigningKeyStore authenticates this owner through its exact Trust
    # supervisor path. The continuation runs after this child has acknowledged
    # startup, so the parent can answer that provenance check.
    case read_bootstrap_custody() do
      {:ok, dependencies} -> {:noreply, initialize(dependencies)}
      {:error, reason} -> {:noreply, dormant_state(state, reason)}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call({:grant, signed_request}, _from, %{mode: :ready} = state) do
    case read_ready_custody() do
      {:ok, custody} ->
        {reply, next_custody} = grant_from_signed_request(signed_request, custody)
        :ok = put_ready_custody(next_custody)
        {:reply, reply, state}

      {:error, reason} ->
        next_state = dormant_state(state, reason)
        {:reply, {:error, :capability_grant_owner_unprovisioned}, next_state}
    end
  end

  def handle_call({:grant, _signed_request}, _from, state) do
    {:reply, {:error, :capability_grant_owner_unprovisioned}, state}
  end

  def handle_call({:sync, agent_id, reason}, _from, state)
      when is_binary(agent_id) and reason in @sync_reasons do
    {result, state} = run_sync(agent_id, reason, state)
    {:reply, result, state}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :capability_grant_owner_unauthorized}, state}
  end

  @impl true
  def handle_cast({:sync, agent_id, reason}, state)
      when is_binary(agent_id) and reason in @sync_reasons do
    {:noreply, sync_with_retry(agent_id, reason, 0, state)}
  end

  def handle_cast(_request, state), do: {:noreply, state}

  # Only a reference this process issued is honoured, so a raw message cannot
  # drive a sync.
  @impl true
  def handle_info({:retry_sync, ref}, state) when is_reference(ref) do
    case Map.pop(Map.get(state, :sync_retries, %{}), ref) do
      {{agent_id, reason, attempt}, retries} ->
        state = Map.put(state, :sync_retries, retries)
        {:noreply, sync_with_retry(agent_id, reason, attempt, state)}

      {nil, _retries} ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    close_authority()
    :ok
  end

  @impl true
  def format_status(status) when is_map(status) do
    case Map.fetch(status, :state) do
      {:ok, state} when is_map(state) -> Map.put(status, :state, public_status(state))
      _ -> status
    end
  end

  defp initialize(%{security: security} = dependencies) do
    result =
      with {:ok, identity} <- load_or_create_identity(security),
           :ok <- ensure_registered(identity, security),
           :ok <- ensure_operator_provisioned(identity.agent_id, security),
           {:ok, authority} <- open_authority(identity.agent_id, security) do
        {:ok, identity.agent_id, authority}
      end

    case result do
      {:ok, principal_id, authority} ->
        Logger.info("[Trust.CapabilityGrantOwner] ready as #{principal_id}")

        :ok =
          put_ready_custody(%{
            security: dependencies.security,
            policy: dependencies.policy,
            nonce_capacity: dependencies.nonce_capacity,
            authority: authority,
            seen_nonces: %{}
          })

        %{
          mode: :ready,
          principal_id: principal_id,
          dormant_reason: nil
        }

      {:error, reason} ->
        Logger.warning("[Trust.CapabilityGrantOwner] dormant: #{inspect(reason)}")

        clear_custody()

        %{
          mode: :dormant,
          principal_id: principal_from_error(reason),
          dormant_reason: reason
        }
    end
  rescue
    error -> dormant_state(dependencies, {:initialization_exception, Exception.message(error)})
  catch
    :exit, reason -> dormant_state(dependencies, {:initialization_exit, reason})
  end

  defp sync_with_retry(agent_id, reason, attempt, state) do
    case run_sync(agent_id, reason, state) do
      {{:error, error}, %{mode: :ready} = state} ->
        if retriable_sync_error?(error),
          do: schedule_sync_retry(agent_id, reason, attempt, state),
          else: state

      {_result, state} ->
        state
    end
  end

  # The kernel reports a refusal and a transient failure (deadline, queue
  # full, store restart, stale view) with the same error, and the enforcer
  # returns only the first failure of a pass, so there is nothing reliable to
  # tell them apart by. Every failure is retried. The cost of retrying a real
  # refusal is small: the delays are fixed, one retry is pending per agent and
  # reason, and the table is bounded.
  defp retriable_sync_error?(_error), do: true

  # One pending retry per agent and reason, and a bound on the whole table, so
  # a burst of profile writes cannot grow it without limit.
  defp schedule_sync_retry(agent_id, reason, attempt, state) do
    retries = Map.get(state, :sync_retries, %{})

    pending? =
      Enum.any?(retries, fn {_ref, {id, why, _n}} -> id == agent_id and why == reason end)

    case Enum.at(@sync_retry_delays_ms, attempt) do
      delay
      when is_integer(delay) and not pending? and map_size(retries) < @max_pending_sync_retries ->
        ref = make_ref()
        Process.send_after(self(), {:retry_sync, ref}, delay)
        Map.put(state, :sync_retries, Map.put(retries, ref, {agent_id, reason, attempt + 1}))

      _ ->
        state
    end
  end

  # A deleted or disabled profile leaves nothing to compare a minted mode
  # with, so everything this owner minted for the agent goes.
  defp sync_scope(:profile_updated), do: :stale
  defp sync_scope(reason) when reason in [:profile_deleted, :profile_disabled], do: :all

  defp run_sync(agent_id, reason, %{mode: :ready} = state) do
    result =
      case read_ready_custody() do
        {:ok, custody} ->
          custody.policy.sync_capabilities(agent_id,
            actor_authority: custody.authority,
            scope: sync_scope(reason)
          )

        {:error, custody_error} ->
          {:error, custody_error}
      end

    {report_sync(result, agent_id, reason), state}
  rescue
    error -> {report_sync({:error, {:sync_raised, error.__struct__}}, agent_id, reason), state}
  catch
    :exit, _reason -> {report_sync({:error, :sync_exited}, agent_id, reason), state}
  end

  # A dormant owner has no authority to revoke with. Every refusal is counted
  # in telemetry; the log line is written once per owner lifetime, because a
  # default install is dormant and would otherwise warn on every profile write.
  # An owner that minted and was later de-provisioned is in this state too,
  # and its earlier grants stay in the store.
  defp run_sync(agent_id, reason, state) do
    :telemetry.execute(
      [:arbor, :trust, :capability_sync, :failed],
      %{count: 1},
      %{agent_id: agent_id, reason: reason, error: :capability_grant_owner_unprovisioned}
    )

    unless Map.get(state, :dormant_sync_warned, false) do
      Logger.warning(
        "[Trust.CapabilityGrantOwner] dormant (#{inspect(state.dormant_reason)}): trust-minted " <>
          "capabilities are not being revoked on trust profile changes. Further occurrences " <>
          "are counted in telemetry only."
      )
    end

    {{:error, :capability_grant_owner_unprovisioned}, Map.put(state, :dormant_sync_warned, true)}
  end

  defp report_sync({:ok, revoked} = result, agent_id, reason) when is_integer(revoked) do
    :telemetry.execute(
      [:arbor, :trust, :capability_sync, :completed],
      %{revoked: revoked},
      %{agent_id: agent_id, reason: reason}
    )

    result
  end

  defp report_sync({:error, error} = result, agent_id, reason) do
    :telemetry.execute(
      [:arbor, :trust, :capability_sync, :failed],
      %{count: 1},
      %{agent_id: agent_id, reason: reason, error: error}
    )

    Logger.warning(
      "[Trust.CapabilityGrantOwner] capabilities minted under the old trust profile were not " <>
        "all revoked for #{agent_id} after #{reason}: #{inspect(error)}. The owner can " <>
        "revoke only what it granted."
    )

    result
  end

  defp report_sync(other, agent_id, reason),
    do: report_sync({:error, {:unexpected_sync_result, other}}, agent_id, reason)

  defp grant_from_signed_request(signed_request, state) do
    now = System.system_time(:second)
    state = prune_seen_nonces(state, now)

    with {:ok, canonical_signed} <- SignedRequest.canonicalize(signed_request),
         {:ok, request} <- CapabilityGrantRequest.decode(canonical_signed.payload),
         :ok <- require_target_signer(canonical_signed.agent_id, request.target_agent_id),
         :ok <- require_fresh_request(request, now),
         :ok <- require_nonce_capacity(state, request.nonce),
         {:ok, signer_id} <- state.security.verify_request(canonical_signed),
         :ok <- require_target_signer(signer_id, request.target_agent_id) do
      state = remember_nonce(state, request.nonce, request.expires_at)

      reply =
        with {:ok, grant_spec} <-
               state.policy.grant_spec(
                 request.target_agent_id,
                 request.resource_uri,
                 session_id: request.session_id
               ),
             {:ok, capability} <- grant(request, grant_spec, state) do
          {:ok, capability}
        else
          _ -> {:error, :capability_grant_request_denied}
        end

      {reply, state}
    else
      {:error, :capability_grant_request_replayed} = error -> {error, state}
      {:error, :capability_grant_request_capacity} = error -> {error, state}
      {:error, :replayed_nonce} -> {{:error, :capability_grant_request_replayed}, state}
      {:error, _reason} -> {{:error, :capability_grant_request_denied}, state}
      _ -> {{:error, :capability_grant_request_denied}, state}
    end
  rescue
    _ -> {{:error, :capability_grant_request_denied}, state}
  catch
    :exit, _ -> {{:error, :capability_grant_request_denied}, state}
  end

  defp grant(request, grant_spec, state) do
    state.security.grant(
      principal: request.target_agent_id,
      resource: request.resource_uri,
      constraints: grant_spec.constraints,
      session_id: request.session_id,
      # Not delegable. A delegated copy names the delegating agent as its
      # granter, so this owner could no longer revoke it when the profile
      # changes; the risk profiles also declare these grants non-delegable.
      delegation_depth: 0,
      metadata: %{
        source: :trust_policy_enforcer,
        legacy_source: :policy_enforcer,
        mode: grant_spec.mode,
        granted_by: __MODULE__,
        granted_at: DateTime.to_iso8601(DateTime.utc_now()),
        profile_uri: grant_spec.profile.uri_prefix,
        profile_effect_class: grant_spec.profile.effect_class,
        profile_blast_radius: grant_spec.profile.blast_radius,
        profile_reversibility: grant_spec.profile.reversibility,
        profile_default_approval: grant_spec.profile.default_approval
      },
      actor_authority: state.authority
    )
  end

  defp load_or_create_identity(security) do
    case security.lookup_identity_ids_by_display_name(@identity_name) do
      {:ok, principal_ids} when is_list(principal_ids) ->
        find_named_identity(principal_ids, security)

      {:error, :not_found} ->
        create_identity(security)

      {:error, reason} ->
        {:error, {:identity_lookup_failed, reason}}

      _ ->
        {:error, :identity_lookup_failed}
    end
  end

  defp find_named_identity(principal_ids, security) do
    Enum.find_value(principal_ids, fn principal_id ->
      with {:ok, %Identity{} = identity} <-
             security.signing_key_public_identity(principal_id, name: @identity_name),
           {:ok, public_key} <- security.lookup_public_key(principal_id),
           true <- public_key == identity.public_key do
        {:ok, Identity.public_only(identity)}
      else
        _ -> nil
      end
    end) || {:error, :named_grant_owner_key_unavailable}
  end

  defp create_identity(security) do
    with {:ok, %Identity{} = identity} <- security.generate_identity(name: @identity_name),
         :ok <- security.store_signing_key(identity.agent_id, identity.private_key),
         :ok <- register_new_identity(identity, security) do
      {:ok, Identity.public_only(identity)}
    else
      {:error, reason} -> {:error, {:identity_creation_failed, reason}}
      _ -> {:error, :identity_creation_failed}
    end
  end

  defp register_new_identity(identity, security) do
    with {:ok, proof} <- security.build_stored_identity_registration_proof(identity),
         :ok <- security.register_trust_capability_grant_identity(identity, proof) do
      :ok
    else
      {:error, reason} ->
        _ = security.delete_signing_key(identity.agent_id)
        {:error, reason}

      other ->
        _ = security.delete_signing_key(identity.agent_id)
        {:error, other}
    end
  end

  defp ensure_registered(identity, security) do
    case security.lookup_public_key(identity.agent_id) do
      {:ok, public_key} when public_key == identity.public_key ->
        :ok

      {:ok, _other_public_key} ->
        {:error, :registered_public_key_mismatch}

      {:error, :not_found} ->
        with {:ok, proof} <- security.build_stored_identity_registration_proof(identity) do
          security.register_trust_capability_grant_identity(identity, proof)
        end

      {:error, reason} ->
        {:error, {:identity_lookup_failed, reason}}
    end
  end

  defp ensure_operator_provisioned(principal_id, security) do
    with {:ok, capabilities} <- security.list_capabilities(principal_id),
         true <-
           Enum.any?(capabilities, fn capability ->
             capability.resource_uri == @required_capability and
               Arbor.Contracts.Security.Capability.valid?(capability)
           end),
         {:ok, :authorized} <-
           security.authorize(
             principal_id,
             "arbor://security/grant/#{principal_id}",
             :execute,
             verify_identity: false
           ) do
      :ok
    else
      false -> {:error, {:grant_owner_capability_not_provisioned, principal_id}}
      {:error, reason} -> {:error, {:capability_lookup_failed, principal_id, reason}}
      _ -> {:error, {:grant_owner_capability_not_provisioned, principal_id}}
    end
  end

  defp open_authority(principal_id, security) do
    with {:ok, proof} <-
           security.build_stored_signing_authority_acquisition_proof(
             principal_id,
             @purpose,
             self(),
             __MODULE__
           ) do
      security.open_signing_authority(proof)
    end
  end

  defp remember_nonce(state, nonce, expires_at) do
    %{state | seen_nonces: Map.put(state.seen_nonces, nonce, expires_at)}
  end

  defp prune_seen_nonces(state, now) do
    seen_nonces = Map.reject(state.seen_nonces, fn {_nonce, expires_at} -> expires_at <= now end)
    %{state | seen_nonces: seen_nonces}
  end

  defp require_target_signer(signer_id, target_agent_id) do
    if signer_id == target_agent_id,
      do: :ok,
      else: {:error, :capability_grant_request_denied}
  end

  defp require_fresh_request(request, now) do
    if CapabilityGrantRequest.fresh?(request, now),
      do: :ok,
      else: {:error, :capability_grant_request_denied}
  end

  defp require_nonce_capacity(state, nonce) do
    cond do
      Map.has_key?(state.seen_nonces, nonce) ->
        {:error, :capability_grant_request_replayed}

      map_size(state.seen_nonces) >= state.nonce_capacity ->
        {:error, :capability_grant_request_capacity}

      true ->
        :ok
    end
  end

  defp public_status(state) do
    %{
      state: state.mode,
      principal_id: state.principal_id,
      required_capability: @required_capability,
      reason: state.dormant_reason
    }
  end

  defp close_authority do
    case read_ready_custody() do
      {:ok, %{authority: authority, security: security}} ->
        _ = security.close_signing_authority(authority)

      _error ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp put_ready_custody(%{
         security: security,
         policy: policy,
         nonce_capacity: nonce_capacity,
         authority: %Arbor.Contracts.Security.SigningAuthority{} = authority,
         seen_nonces: seen_nonces
       })
       when is_atom(security) and is_atom(policy) and is_integer(nonce_capacity) and
              is_map(seen_nonces) do
    if valid_custody_owner?() and nonce_capacity in 1..@max_seen_nonces do
      true =
        :ets.insert(
          @custody_table,
          {@custody_tag, :ready, security, policy, nonce_capacity, authority, seen_nonces}
        )

      :ok
    else
      {:error, :capability_grant_owner_custody_invalid}
    end
  rescue
    ArgumentError -> {:error, :capability_grant_owner_custody_invalid}
  end

  defp put_ready_custody(_custody), do: {:error, :capability_grant_owner_custody_invalid}

  defp read_bootstrap_custody do
    if valid_custody_owner?() and :ets.info(@custody_table, :size) == 1 do
      case :ets.lookup(@custody_table, @custody_tag) do
        [
          {@custody_tag, :bootstrap,
           %{security: security, policy: policy, nonce_capacity: nonce_capacity} = dependencies}
        ]
        when is_atom(security) and is_atom(policy) and is_integer(nonce_capacity) and
               nonce_capacity in 1..@max_seen_nonces ->
          {:ok, dependencies}

        _other ->
          {:error, :capability_grant_owner_custody_invalid}
      end
    else
      {:error, :capability_grant_owner_custody_invalid}
    end
  rescue
    ArgumentError -> {:error, :capability_grant_owner_custody_invalid}
  end

  defp read_ready_custody do
    if valid_custody_owner?() and :ets.info(@custody_table, :size) == 1 do
      case :ets.lookup(@custody_table, @custody_tag) do
        [
          {@custody_tag, :ready, security, policy, nonce_capacity,
           %Arbor.Contracts.Security.SigningAuthority{} = authority, seen_nonces}
        ]
        when is_atom(security) and is_atom(policy) and is_integer(nonce_capacity) and
               nonce_capacity in 1..@max_seen_nonces and is_map(seen_nonces) ->
          {:ok,
           %{
             security: security,
             policy: policy,
             nonce_capacity: nonce_capacity,
             authority: authority,
             seen_nonces: seen_nonces
           }}

        _other ->
          {:error, :capability_grant_owner_custody_invalid}
      end
    else
      {:error, :capability_grant_owner_custody_invalid}
    end
  rescue
    ArgumentError -> {:error, :capability_grant_owner_custody_invalid}
  end

  defp clear_custody do
    if valid_custody_owner?(), do: :ets.delete_all_objects(@custody_table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp valid_custody_owner? do
    :ets.info(@custody_table, :owner) == self() and
      :ets.info(@custody_table, :protection) == :private and
      :ets.info(@custody_table, :type) == :set and
      :ets.info(@custody_table, :named_table) == true
  rescue
    ArgumentError -> false
  end

  defp dormant_state(_state, reason) do
    clear_custody()

    %{
      mode: :dormant,
      principal_id: principal_from_error(reason),
      dormant_reason: reason
    }
  end

  defp principal_from_error({:grant_owner_capability_not_provisioned, principal_id}),
    do: principal_id

  defp principal_from_error({:capability_lookup_failed, principal_id, _reason}),
    do: principal_id

  defp principal_from_error(_reason), do: nil

  defp nonce_capacity(opts) do
    case Keyword.get(opts, :nonce_capacity, @max_seen_nonces) do
      capacity when is_integer(capacity) and capacity in 1..@max_seen_nonces -> capacity
      _ -> @max_seen_nonces
    end
  end

  defp dormant_status(reason) do
    %{
      state: :dormant,
      principal_id: nil,
      required_capability: @required_capability,
      reason: reason
    }
  end
end
