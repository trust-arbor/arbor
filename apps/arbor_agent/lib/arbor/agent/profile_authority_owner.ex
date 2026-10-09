defmodule Arbor.Agent.ProfileAuthorityOwner do
  @moduledoc """
  Fixed synchronous owner of acknowledged Profile authority mutations and
  notice-only authoritative snapshots. Closed operations execute in this actor;
  no caller continuation, detached Task or delayed callback may write later.

  Lower notice-broker restart cannot expose a pre-write snapshot: new acquisition
  queues on this owner behind the acknowledged backend write. Owner restart also
  cannot resume a pre-enqueue write; enqueued operations remain serialized by the
  fixed BufferedStore backend owner. Ordinary Profile cache reads stay separate.
  """
  use GenServer
  @owner_table :arbor_agent_profile_authority_owner_directory
  @activation_failure_purpose :exact_activation_failure
  @activation_failure_resources [
    "arbor://security/identity/suspend/**",
    "arbor://security/revoke/**"
  ]
  @handoff_ttl_ms 30_000
  @handoff_purposes %{
    coding_task_executor: 0,
    coding_task_recovery: 0,
    coding_candidate_operator: 2
  }
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def store(profile), do: call({:store, profile})
  def delete(principal), do: call({:delete, principal})
  def migrate(profile), do: call({:migrate, profile})
  def mutate(observed, governed), do: call({:mutate, {observed, governed}})
  def notice_snapshot(principal), do: call({:notice_snapshot, principal})
  def store_signing_identity(_identity), do: {:error, :key_mutation_authority_required}

  def store_signing_identity(identity, actor_authority) do
    with {:ok, principal} <- identity_principal(identity),
         {:ok, proof} <- key_operation_proof(actor_authority, :store, principal) do
      call({:store_signing_identity, identity, actor_authority, proof})
    end
  end

  def delete_signing_key(_principal), do: {:error, :key_mutation_authority_required}

  def delete_signing_key(principal, actor_authority) when is_binary(principal) do
    with {:ok, proof} <- key_operation_proof(actor_authority, :delete, principal) do
      call({:delete_signing_key, principal, actor_authority, proof})
    end
  end

  def delete_signing_key(_principal, _actor_authority),
    do: {:error, :key_mutation_authority_required}

  def build_stored_identity_registration_proof(_identity),
    do: {:error, :key_mutation_authority_required}

  def build_stored_identity_registration_proof(identity, actor_authority) do
    with {:ok, principal} <- identity_principal(identity),
         {:ok, proof} <- key_operation_proof(actor_authority, :registration_proof, principal) do
      call({:build_stored_identity_registration_proof, identity, actor_authority, proof})
    end
  end

  @doc false
  def owner_process?, do: owner_pid() == self()

  @doc false
  def authorize_signing_authority_handoff(principal, purpose, claimant, context),
    do: call({:authorize_signing_authority_handoff, {principal, purpose, claimant, context}})

  @doc false
  def transfer_signing_authority_handoff(principal, purpose, claimant, context),
    do: call({:transfer_signing_authority_handoff, {principal, purpose, claimant, context}})

  def issue_signing_authority_bootstrap(principal, purpose),
    do: call({:claim_signing_authority_handoff, {principal, purpose}})

  @doc false
  def issue_runtime_admission_signing_authority_bootstrap(principal, purpose),
    do: call({:issue_runtime_admission_signing_authority_bootstrap, {principal, purpose}})

  if Mix.env() == :test do
    @doc false
    def issue_runtime_admission_signing_authority_bootstrap(principal, purpose, store_ref)
        when is_atom(store_ref) or is_pid(store_ref) or is_tuple(store_ref) do
      call(
        {:issue_runtime_admission_signing_authority_bootstrap, {principal, purpose, store_ref}}
      )
    end
  end

  @doc false
  def suspend_admitted_identity(principal, reason, store_ref)
      when is_binary(principal) and (is_atom(reason) or is_binary(reason)) and
             (is_atom(store_ref) or is_pid(store_ref)) do
    call({:suspend_admitted_identity, principal, reason, store_ref})
  end

  @doc false
  def revoke_admitted_capabilities(principal, store_ref)
      when is_binary(principal) and (is_atom(store_ref) or is_pid(store_ref)) do
    call({:revoke_admitted_capabilities, principal, store_ref})
  end

  @doc false
  def activation_failure_ready?, do: call(:activation_failure_ready?)

  @doc false
  def issue_supervised_action_cycle_bootstrap(principal),
    do: call({:issue_supervised_action_cycle_bootstrap, principal})

  defp call(message) do
    GenServer.call(owner_pid(), message, 30_000)
  rescue
    _ -> {:error, :authority_unavailable}
  catch
    :exit, _ -> {:error, :outcome_unknown}
  end

  @impl true
  def init(_opts) do
    Process.flag(:sensitive, true)

    with :ok <- claim_directory() do
      {:ok, %{handoffs: %{}}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({operation, value}, _from, state)
      when operation in [:store, :delete, :migrate, :mutate, :notice_snapshot] do
    {:reply, Arbor.Agent.ProfileStore.apply_owned_profile_operation(operation, value), state}
  end

  def handle_call(
        {:authorize_signing_authority_handoff, {principal, purpose, claimant, context}},
        {caller, _tag},
        state
      ) do
    state = prune_handoffs(state)

    case authorize_handoff(caller, principal, purpose, claimant, context, state) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:transfer_signing_authority_handoff, {principal, purpose, claimant, context}},
        {caller, _tag},
        state
      ) do
    state = prune_handoffs(state)

    case transfer_handoff(caller, principal, purpose, claimant, context, state) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:claim_signing_authority_handoff, {principal, purpose}},
        {caller, _tag},
        state
      ) do
    state = prune_handoffs(state)

    case consume_handoff(caller, principal, purpose, state) do
      {:ok, next_state} ->
        {:reply, issue_bootstrap(principal, purpose), next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:issue_runtime_admission_signing_authority_bootstrap, {principal, purpose}},
        {caller, _tag},
        state
      ) do
    {:reply, issue_runtime_admission_bootstrap(caller, principal, purpose), state}
  end

  if Mix.env() == :test do
    def handle_call(
          {:issue_runtime_admission_signing_authority_bootstrap, {principal, purpose, store_ref}},
          {caller, _tag},
          state
        ) do
      result =
        with true <- purpose in [:session, :heartbeat],
             true <- runtime_admission_worker?(caller, principal, store_ref) do
          issue_bootstrap(principal, purpose)
        else
          _ -> {:error, :signing_authority_handoff_unauthorized}
        end

      {:reply, result, state}
    end
  end

  def handle_call(
        {:suspend_admitted_identity, principal, reason, store_ref},
        {caller, _tag},
        state
      ) do
    result =
      with_activation_failure_authority(caller, principal, store_ref, fn authority ->
        Arbor.Security.suspend_identity(principal,
          reason: reason,
          actor_authority: authority
        )
      end)

    {:reply, result, state}
  end

  def handle_call(
        {:revoke_admitted_capabilities, principal, store_ref},
        {caller, _tag},
        state
      ) do
    result =
      with_activation_failure_authority(caller, principal, store_ref, fn authority ->
        case Arbor.Security.revoke_all(principal, actor_authority: authority) do
          {:ok, _count} -> :ok
          {:error, :not_found} -> :ok
          other -> other
        end
      end)

    {:reply, result, state}
  end

  def handle_call(:activation_failure_ready?, _from, state) do
    result =
      case open_activation_failure_authority() do
        {:ok, authority} ->
          _ = Arbor.Security.close_signing_authority(authority)
          :ok

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, result, state}
  end

  def handle_call({:issue_supervised_action_cycle_bootstrap, principal}, {caller, _tag}, state) do
    result =
      if action_cycle_consumer?(caller, principal) do
        issue_bootstrap(principal, :action_cycle)
      else
        {:error, :signing_authority_handoff_unauthorized}
      end

    {:reply, result, state}
  end

  def handle_call(
        {:store_signing_identity, identity, actor_authority, proof},
        {caller, _tag},
        state
      ) do
    result =
      with %{
             agent_id: agent_id,
             public_key: public_key,
             private_key: private_key,
             encryption_public_key: encryption_public_key,
             encryption_private_key: encryption_private_key
           }
           when is_binary(agent_id) and is_binary(public_key) and is_binary(private_key) and
                  is_binary(encryption_public_key) and is_binary(encryption_private_key) <-
             identity,
           {:ok, actor_id} <- verify_key_operation_proof(proof, :store, agent_id, caller),
           :ok <-
             Arbor.Security.validate_signing_authority_owner(
               actor_authority,
               caller,
               actor_id
             ),
           {^public_key, _expanded_private_key} <-
             :crypto.generate_key(:eddsa, :ed25519, private_key),
           {^encryption_public_key, _expanded_encryption_private_key} <-
             :crypto.generate_key(:ecdh, :x25519, encryption_private_key),
           ^agent_id <- Arbor.Contracts.Security.Identity.derive_agent_id(public_key),
           {:ok, ^public_key} <- Arbor.Security.lookup_public_key(agent_id) do
        Arbor.Security.store_signing_keypair(agent_id, private_key, encryption_private_key)
      else
        _ -> {:error, :key_mutation_unauthorized}
      end

    {:reply, result, state}
  end

  def handle_call(
        {:delete_signing_key, principal, actor_authority, proof},
        {caller, _tag},
        state
      ) do
    result =
      with {:ok, actor_id} <- verify_key_operation_proof(proof, :delete, principal, caller),
           :ok <-
             Arbor.Security.validate_signing_authority_owner(
               actor_authority,
               caller,
               actor_id
             ) do
        case Arbor.Security.lookup_public_key(principal) do
          {:error, :not_found} -> Arbor.Security.delete_signing_key(principal)
          _ -> {:error, :key_mutation_unauthorized}
        end
      end

    {:reply, result, state}
  end

  def handle_call(
        {:build_stored_identity_registration_proof, identity, actor_authority, proof},
        {caller, _tag},
        state
      ) do
    result =
      with {:ok, principal} <- identity_principal(identity),
           {:ok, actor_id} <-
             verify_key_operation_proof(proof, :registration_proof, principal, caller),
           :ok <-
             Arbor.Security.validate_signing_authority_owner(
               actor_authority,
               caller,
               actor_id
             ) do
        Arbor.Security.build_stored_identity_registration_proof(identity)
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    handoffs =
      state.handoffs
      |> Enum.reject(fn {_key, handoff} -> handoff.monitor == monitor end)
      |> Map.new()

    {:noreply, %{state | handoffs: handoffs}}
  end

  @impl true
  def format_status(status) when is_map(status),
    do:
      status
      |> Map.put(:state, :redacted)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :redacted)
      |> Map.put(:log, :redacted)

  defp claim_directory do
    table = :ets.new(@owner_table, [:named_table, :protected, :set, read_concurrency: true])
    true = :ets.insert(table, {:owner, self()})
    :ok
  rescue
    _ -> {:error, :authority_owner_directory_unavailable}
  end

  defp key_operation_proof(actor_authority, operation, principal) do
    with {:ok, _actor_id} <- Arbor.Security.signing_authority_principal(actor_authority),
         {:ok, %Arbor.Contracts.Security.SignedRequest{} = proof} <-
           Arbor.Security.sign_with_authority(
             actor_authority,
             key_operation_resource(operation, principal, self())
           ) do
      {:ok, proof}
    else
      _ -> {:error, :key_mutation_authority_required}
    end
  rescue
    _ -> {:error, :key_mutation_authority_required}
  catch
    _, _ -> {:error, :key_mutation_authority_required}
  end

  defp verify_key_operation_proof(proof, operation, principal, caller) do
    expected = key_operation_resource(operation, principal, caller)

    with %Arbor.Contracts.Security.SignedRequest{payload: ^expected} <- proof,
         {:ok, actor_id} when is_binary(actor_id) <- Arbor.Security.verify_request(proof) do
      {:ok, actor_id}
    else
      _ -> {:error, :key_mutation_unauthorized}
    end
  end

  defp key_operation_resource(operation, principal, caller) when is_pid(caller) do
    caller_binding =
      caller
      |> :erlang.term_to_binary()
      |> Base.url_encode64(padding: false)

    "arbor://agent/lifecycle/profile-key/#{operation}/#{principal}/caller/#{caller_binding}"
  end

  defp identity_principal(%{agent_id: principal}) when is_binary(principal) and principal != "",
    do: {:ok, principal}

  defp identity_principal(_identity), do: {:error, :key_mutation_unauthorized}

  defp authorize_handoff(caller, principal, purpose, claimant, context, state) do
    with true <- task_store_caller?(caller),
         true <- valid_handoff_binding?(principal, purpose, claimant, context),
         {:ok, transfers_left} <- Map.fetch(@handoff_purposes, purpose),
         key = {claimant, principal, purpose},
         false <- Map.has_key?(state.handoffs, key) do
      monitor = Process.monitor(claimant)

      handoff = %{
        context: context,
        expires_at: System.monotonic_time(:millisecond) + @handoff_ttl_ms,
        monitor: monitor,
        transfers_left: transfers_left
      }

      {:ok, put_in(state, [:handoffs, key], handoff)}
    else
      true -> {:error, :signing_authority_handoff_conflict}
      :error -> {:error, :invalid_signing_authority_handoff}
      _ -> {:error, :signing_authority_handoff_unauthorized}
    end
  end

  defp transfer_handoff(caller, principal, purpose, claimant, context, state) do
    source_key = {caller, principal, purpose}
    target_key = {claimant, principal, purpose}

    with true <- is_pid(claimant) and Process.alive?(claimant),
         {:ok, %{context: ^context, transfers_left: transfers_left} = handoff}
         when transfers_left > 0 <- Map.fetch(state.handoffs, source_key),
         false <- Map.has_key?(state.handoffs, target_key) do
      Process.demonitor(handoff.monitor, [:flush])
      monitor = Process.monitor(claimant)

      next_handoff = %{
        handoff
        | monitor: monitor,
          transfers_left: transfers_left - 1
      }

      next_state = %{
        state
        | handoffs:
            state.handoffs
            |> Map.delete(source_key)
            |> Map.put(target_key, next_handoff)
      }

      {:ok, next_state}
    else
      true -> {:error, :signing_authority_handoff_conflict}
      _ -> {:error, :signing_authority_handoff_unauthorized}
    end
  end

  defp consume_handoff(caller, principal, purpose, state) do
    key = {caller, principal, purpose}

    case Map.pop(state.handoffs, key) do
      {%{monitor: monitor}, remaining} ->
        Process.demonitor(monitor, [:flush])
        {:ok, %{state | handoffs: remaining}}

      {nil, _remaining} ->
        {:error, :signing_authority_handoff_required}
    end
  end

  defp prune_handoffs(state) do
    now = System.monotonic_time(:millisecond)

    {kept, expired} =
      Enum.split_with(state.handoffs, fn {{claimant, _principal, _purpose}, handoff} ->
        Process.alive?(claimant) and handoff.expires_at > now
      end)

    Enum.each(expired, fn {_key, handoff} ->
      Process.demonitor(handoff.monitor, [:flush])
    end)

    %{state | handoffs: Map.new(kept)}
  end

  defp valid_handoff_binding?(principal, purpose, claimant, context) do
    is_binary(principal) and principal != "" and Map.has_key?(@handoff_purposes, purpose) and
      is_pid(claimant) and Process.alive?(claimant) and is_map(context) and
      not is_struct(context) and map_size(context) > 0
  end

  defp issue_bootstrap(principal, purpose) do
    with {:ok, proof} <-
           Arbor.Security.build_stored_signing_authority_acquisition_proof(
             principal,
             purpose,
             self(),
             __MODULE__
           ) do
      Arbor.Security.issue_signing_authority_bootstrap(proof)
    end
  end

  defp task_store_caller?(caller) when is_pid(caller) do
    supervised_child_pid(Arbor.Agent.Orchestration.TaskStore) == caller
  end

  defp task_store_caller?(_caller), do: false

  defp with_activation_failure_authority(caller, principal, store_ref, operation) do
    if runtime_admission_worker?(caller, principal, store_ref) do
      case open_activation_failure_authority() do
        {:ok, authority} ->
          try do
            operation.(authority)
          after
            _ = Arbor.Security.close_signing_authority(authority)
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :signing_authority_handoff_unauthorized}
    end
  end

  defp open_activation_failure_authority do
    principal = Application.get_env(:arbor_agent, :activation_failure_principal_id)

    with true <- is_binary(principal) and principal != "",
         {:ok, capabilities} <- Arbor.Security.list_capabilities(principal),
         true <-
           Enum.all?(@activation_failure_resources, fn resource ->
             Enum.any?(capabilities, fn capability ->
               capability.resource_uri == resource and
                 Arbor.Contracts.Security.Capability.valid?(capability)
             end)
           end),
         {:ok, proof} <-
           Arbor.Security.build_stored_signing_authority_acquisition_proof(
             principal,
             @activation_failure_purpose,
             self(),
             __MODULE__
           ) do
      Arbor.Security.open_signing_authority(proof)
    else
      _ -> {:error, :activation_failure_authority_unavailable}
    end
  end

  defp issue_runtime_admission_bootstrap(caller, principal, purpose) do
    with true <- purpose in [:session, :heartbeat],
         true <- runtime_admission_worker?(caller, principal) do
      issue_bootstrap(principal, purpose)
    else
      _ -> {:error, :signing_authority_handoff_unauthorized}
    end
  end

  defp runtime_admission_worker?(caller, principal)
       when is_pid(caller) and is_binary(principal) do
    case supervised_child_pid(Arbor.Agent.Orchestration.TaskStore) do
      store when is_pid(store) ->
        runtime_admission_worker?(caller, principal, store)

      _ ->
        false
    end
  end

  defp runtime_admission_worker?(_caller, _principal), do: false

  defp runtime_admission_worker?(caller, principal, store)
       when is_pid(caller) and is_binary(principal) and (is_pid(store) or is_atom(store)) do
    GenServer.call(store, {:runtime_admission_worker_candidate, caller, principal}) == :ok
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp runtime_admission_worker?(_caller, _principal, _store), do: false

  defp action_cycle_consumer?(caller, principal)
       when is_pid(caller) and is_binary(principal) do
    with supervisor when is_pid(supervisor) <-
           supervised_child_pid(Arbor.Agent.ActionCycleSupervisor),
         true <-
           Enum.any?(DynamicSupervisor.which_children(supervisor), fn
             {_id, ^caller, _type, _modules} -> true
             _ -> false
           end),
         true <-
           Enum.any?(Registry.lookup(Arbor.Agent.ActionCycleRegistry, principal), fn
             {^caller, _value} -> true
             _ -> false
           end) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp action_cycle_consumer?(_caller, _principal), do: false

  defp supervised_child_pid(child_id) do
    with master when is_pid(master) <- :application_controller.get_master(:arbor_agent),
         {root, _module} when is_pid(root) <- :application_master.get_child(master),
         {^child_id, child, _type, _modules} when is_pid(child) <-
           Enum.find(Supervisor.which_children(root), fn
             {^child_id, _pid, _type, _modules} -> true
             _ -> false
           end) do
      child
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp owner_pid do
    case :ets.lookup(@owner_table, :owner) do
      [{:owner, pid}] when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: raise("authority owner unavailable")

      _ ->
        raise "authority owner unavailable"
    end
  end
end
