defmodule Arbor.Scheduler.Identity do
  @moduledoc """
  Per-machine cryptographic identity for the scheduler.

  The scheduler owns a reload-stable `Arbor.Contracts.Security.SigningAuthority`
  for the lifetime of this GenServer. Private key material is used only during
  startup to prove possession and open that authority; the GenServer state
  retains only the principal id and opaque authority reference.

  The authority key is indexed by the same derived `agent_id` used by the
  identity registry and the authority proof. The scheduler display name is the
  normal durable locator. `system_scheduler` is read only as a fallback for
  legacy installations and is never created for a fresh identity.
  """

  use GenServer

  require Logger

  alias Arbor.Security
  alias Arbor.Trust

  @identity_name "scheduler"
  @legacy_signing_locator "system_scheduler"
  @blanket_capability "arbor://orchestrator/execute/**"
  @required_capabilities [
    @blanket_capability,
    "arbor://security/identity/register",
    "arbor://security/grant/**",
    "arbor://security/revoke/**",
    "arbor://security/identity/deregister/**"
  ]
  @trust_rule_prefix "arbor://orchestrator/execute"
  @test_env Mix.env() == :test
  @custody_table Arbor.Scheduler.Identity.Custody
  @custody_tag :arbor_scheduler_identity_custody_v1

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the stable scheduler principal id, or `nil` when not running."
  @spec agent_id() :: String.t() | nil
  def agent_id do
    case GenServer.call(__MODULE__, :get_agent_id, 5_000) do
      {:ok, id} -> id
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  @doc false
  @spec await_ready(timeout()) :: :ok | {:error, term()}
  def await_ready(timeout \\ 30_000) do
    GenServer.call(__MODULE__, :await_ready, timeout)
  catch
    :exit, {reason, {GenServer, :call, _args}} -> {:error, reason}
    :exit, reason -> {:error, reason}
  end

  @doc false
  def required_capability_uris, do: @required_capabilities

  @doc false
  def register_run_identity(identity, token),
    do: protected_call({:register_run_identity, identity, token})

  @doc false
  def grant_run_capability(opts, token),
    do: protected_call({:grant_run_capability, opts, token})

  @doc false
  def revoke_run_capability(capability_id, token),
    do: protected_call({:revoke_run_capability, capability_id, token})

  @doc false
  def deregister_run_identity(agent_id, token),
    do: protected_call({:deregister_run_identity, agent_id, token})

  @doc false
  def reap_capability(capability_id, token),
    do: protected_call({:reap_capability, capability_id, token})

  @doc false
  def reap_identity(agent_id, token),
    do: protected_call({:reap_identity, agent_id, token})

  @impl true
  def init(opts) do
    Process.flag(:sensitive, true)
    @custody_table = :ets.new(@custody_table, [:named_table, :set, :private])
    true = :ets.insert(@custody_table, {@custody_tag, :bootstrap, opts})

    {:ok,
     %{
       phase: :pending,
       authenticated_calls: Arbor.Common.new_authenticated_call_custody()
     }, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, pending_state) do
    # SigningKeyStore admits this process by exact RuntimeSupervisor child
    # membership. Running bootstrap in init would ask that supervisor for its
    # children while it was still blocked waiting for this init to acknowledge.
    # A continuation runs only after the child has been recorded; ordinary
    # calls remain queued until this callback establishes the ready state.

    case read_bootstrap_custody() do
      {:error, reason} ->
        {:stop, reason, pending_state}

      {:ok, opts} ->
        security = Keyword.get(opts, :security_facade, Security)
        trust = Keyword.get(opts, :trust_facade, Trust)

        with {:ok, mutation_token} <- scheduler_mutation_token(opts) do
          case load_or_create_identity(security) do
            {:ok, identity, status, _identity_effects} ->
              case provision_runtime_authority(identity, security, trust) do
                {:ok, authority} ->
                  Logger.info("[Scheduler.Identity] #{status} keypair for #{identity.agent_id}")
                  :ok = put_ready_custody(authority, security, mutation_token)

                  {:noreply,
                   %{
                     phase: :ready,
                     agent_id: identity.agent_id,
                     authenticated_calls: pending_state.authenticated_calls
                   }}

                {:error, reason} ->
                  Logger.error("[Scheduler.Identity] init failed: #{inspect(reason)}")
                  {:stop, reason, pending_state}
              end

            {:error, reason} ->
              Logger.error("[Scheduler.Identity] init failed: #{inspect(reason)}")
              {:stop, reason, pending_state}
          end
        else
          {:error, reason} -> {:stop, reason, pending_state}
        end
    end
  end

  @impl true
  def handle_call(:get_signing_authority, _from, state) do
    {:reply, {:error, :scheduler_authority_not_exported}, state}
  end

  def handle_call(:await_ready, _from, state), do: {:reply, :ok, state}

  def handle_call(:get_agent_id, _from, state) do
    {:reply, {:ok, state.agent_id}, state}
  end

  # A raw `$gen_call` `from` tuple is attacker-controlled message data. Only
  # read-only readiness/identity observations use GenServer.call; mutations are
  # admitted through AuthenticatedCall and exact supervision provenance.
  def handle_call(_request, _from, state) do
    {:reply, {:error, :scheduler_mutation_unauthorized}, state}
  end

  @impl true
  def format_status(status) when is_map(status) do
    status
    |> Map.put(:message, :redacted)
    |> Map.put(:state, %{identity: :private_custody})
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, :redacted)
  end

  @impl true
  def handle_cast(_request, state), do: {:noreply, state}

  @impl true
  def handle_info(message, state) do
    case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
      {:authenticated, caller, request, reply_to} ->
        {reply, state} = dispatch_authenticated(request, caller, state)
        :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
        {:noreply, state}

      result when result in [:pending, :expired, :rejected, :unrecognized] ->
        {:noreply, state}
    end
  end

  defp handle_authenticated_call({:register_run_identity, identity, token}, caller, state) do
    with {:ok, custody} <- authorize_scheduler_mutation(token, caller, :mutation_owner),
         result <- custody.security.register_identity(identity, custody.authority) do
      {result, state}
    else
      _ -> {{:error, :scheduler_mutation_unauthorized}, state}
    end
  end

  defp handle_authenticated_call({:grant_run_capability, opts, token}, caller, state) do
    with {:ok, custody} <- authorize_scheduler_mutation(token, caller, :mutation_owner),
         true <- is_list(opts) and Keyword.keyword?(opts),
         result <-
           custody.security.grant(Keyword.put(opts, :actor_authority, custody.authority)) do
      {result, state}
    else
      _ -> {{:error, :scheduler_mutation_unauthorized}, state}
    end
  end

  defp handle_authenticated_call({:revoke_run_capability, capability_id, token}, caller, state) do
    with {:ok, custody} <- authorize_scheduler_mutation(token, caller, :mutation_owner),
         result <-
           custody.security.revoke(
             capability_id,
             actor_authority: custody.authority
           ) do
      {result, state}
    else
      _ -> {{:error, :scheduler_mutation_unauthorized}, state}
    end
  end

  defp handle_authenticated_call({:deregister_run_identity, agent_id, token}, caller, state) do
    with {:ok, custody} <- authorize_scheduler_mutation(token, caller, :mutation_owner),
         result <-
           custody.security.deregister_identity(
             agent_id,
             actor_authority: custody.authority
           ) do
      {result, state}
    else
      _ -> {{:error, :scheduler_mutation_unauthorized}, state}
    end
  end

  defp handle_authenticated_call({operation, target, token}, caller, state)
       when operation in [:reap_capability, :reap_identity] do
    with role when role in [:reconciler, :reaper] <- scheduler_reaper_role(caller),
         {:ok, custody} <- authorize_scheduler_mutation(token, caller, role) do
      result =
        case operation do
          :reap_capability ->
            custody.security.revoke(
              target,
              actor_authority: custody.authority
            )

          :reap_identity ->
            custody.security.deregister_identity(
              target,
              actor_authority: custody.authority
            )
        end

      {result, state}
    else
      _ -> {{:error, :scheduler_mutation_unauthorized}, state}
    end
  end

  defp handle_authenticated_call(_request, _caller, state),
    do: {{:error, :scheduler_mutation_unauthorized}, state}

  defp dispatch_authenticated(request, caller, state),
    do: handle_authenticated_call(request, caller, state)

  @impl true
  def terminate(_reason, _state) do
    case read_ready_custody() do
      {:ok, %{authority: authority, security: security}} ->
        _ = security.close_signing_authority(authority)

      _error ->
        :ok
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp load_or_create_identity(security) do
    case find_named_identity(security) do
      {:ok, identity} ->
        {:ok, identity, :loaded, no_identity_effects()}

      :not_found ->
        load_from_legacy_locator(security)

      {:error, _} = error ->
        error
    end
  end

  defp find_named_identity(security) do
    case security.lookup_identity_ids_by_display_name(@identity_name) do
      {:ok, agent_ids} -> find_valid_named_identity(agent_ids, security)
      {:error, :not_found} -> :not_found
      {:error, reason} -> {:error, {:identity_lookup_failed, reason}}
    end
  rescue
    exception -> {:error, {:identity_lookup_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:identity_lookup_exit, reason}}
  end

  defp find_valid_named_identity(agent_ids, security) do
    result =
      Enum.find_value(agent_ids, fn agent_id ->
        with {:ok, %{agent_id: ^agent_id} = identity} <-
               security.signing_key_public_identity(agent_id, name: @identity_name) do
          expected_public_key = identity.public_key

          case security.lookup_public_key(agent_id) do
            {:ok, ^expected_public_key} -> {:ok, identity}
            _ -> nil
          end
        else
          _ -> nil
        end
      end)

    result || {:error, :named_scheduler_key_unavailable}
  end

  defp load_from_legacy_locator(security) do
    case security.migrate_legacy_signing_key_locator(@legacy_signing_locator,
           name: @identity_name
         ) do
      {:ok, identity, status} -> load_legacy_identity(identity, status, security)
      {:error, :no_signing_key} -> create_new(security)
      {:error, reason} -> {:error, {:legacy_locator_read_failed, reason}}
    end
  rescue
    exception -> {:error, {:legacy_locator_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:legacy_locator_exit, reason}}
  end

  defp load_legacy_identity(identity, migration_status, security) do
    case ensure_principal_key(identity, security) do
      {:ok, principal_key_created?} ->
        case ensure_registered(identity, security) do
          {:ok, identity_created?} ->
            {:ok, identity, :loaded,
             %{
               principal_key_created?: principal_key_created? or migration_status == :created,
               identity_created?: identity_created?
             }}

          {:error, _} = error ->
            if principal_key_created?, do: safe_delete_key(identity.agent_id, security)
            error
        end

      {:error, _} = error ->
        error
    end
  end

  defp ensure_principal_key(identity, security) do
    case security.signing_key_status(identity.agent_id) do
      {:ok, :available} ->
        case security.signing_key_public_identity(identity.agent_id) do
          {:ok, %{public_key: public_key}} when public_key == identity.public_key -> {:ok, false}
          _ -> {:error, :principal_signing_key_mismatch}
        end

      {:error, :no_signing_key} ->
        case security.store_signing_key(identity.agent_id, identity.private_key) do
          :ok -> {:ok, true}
          {:error, reason} -> {:error, {:principal_key_store_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:principal_key_read_failed, reason}}
    end
  end

  defp ensure_registered(identity, security) do
    case security.lookup_public_key(identity.agent_id) do
      {:ok, public_key} when public_key == identity.public_key ->
        {:ok, false}

      {:ok, _other_public_key} ->
        {:error, :registered_public_key_mismatch}

      {:error, :not_found} ->
        with {:ok, possession_proof} <-
               security.build_stored_identity_registration_proof(identity),
             :ok <- security.register_scheduler_identity(identity, possession_proof) do
          {:ok, true}
        else
          {:error, {:already_registered, _}} -> ensure_registered(identity, security)
          {:error, reason} -> {:error, {:identity_registration_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:identity_lookup_failed, reason}}
    end
  end

  defp create_new(security) do
    with {:ok, identity} <- security.generate_identity(name: @identity_name),
         :ok <- ensure_fresh_principal_available(identity, security),
         :ok <- security.store_signing_key(identity.agent_id, identity.private_key) do
      case safe_register_fresh_identity(identity, security) do
        :ok ->
          {:ok, identity, :generated, %{principal_key_created?: true, identity_created?: true}}

        {:error, reason} ->
          _ = security.delete_signing_key(identity.agent_id)
          {:error, {:identity_registration_failed, reason}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, {:identity_creation_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:identity_creation_exit, reason}}
  end

  defp safe_register_fresh_identity(identity, security) do
    with {:ok, possession_proof} <-
           security.build_stored_identity_registration_proof(identity) do
      security.register_scheduler_identity(identity, possession_proof)
    end
  rescue
    exception -> {:error, {:registration_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:registration_exit, reason}}
  end

  defp ensure_fresh_principal_available(identity, security) do
    with {:error, :no_signing_key} <- security.signing_key_status(identity.agent_id),
         {:error, :not_found} <- security.lookup_public_key(identity.agent_id) do
      :ok
    else
      {:ok, _} -> {:error, :fresh_principal_collision}
      {:error, reason} -> {:error, {:fresh_principal_preflight_failed, reason}}
    end
  end

  defp provision_runtime_authority(identity, security, trust) do
    case ensure_capability(identity.agent_id, security) do
      {:ok, :existing} ->
        case ensure_trust_profile(identity.agent_id, trust) do
          {:ok, trust_effect} ->
            case open_authority(identity, security) do
              {:ok, authority} ->
                {:ok, authority}

              {:error, reason} ->
                rollback_trust(trust_effect, identity.agent_id, trust)
                {:error, {:signing_authority_open_failed, reason}}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_capability(agent_id, security) do
    case security.list_capabilities(agent_id) do
      {:ok, capabilities} ->
        case Enum.find(@required_capabilities, fn resource ->
               not Enum.any?(capabilities, &(&1.resource_uri == resource))
             end) do
          nil ->
            {:ok, :existing}

          missing ->
            {:error,
             {:capability_provision_failed, {:scheduler_capability_not_provisioned, missing}}}
        end

      {:error, reason} ->
        {:error, {:capability_lookup_failed, reason}}
    end
  rescue
    exception -> {:error, {:capability_provision_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:capability_provision_exit, reason}}
  end

  defp ensure_trust_profile(agent_id, trust) do
    case trust.get_trust_profile(agent_id) do
      {:ok, profile} ->
        desired_rules = Map.put(profile.rules || %{}, @trust_rule_prefix, :allow)

        if desired_rules == profile.rules do
          {:ok, :existing}
        else
          case trust.ensure_trust_profile(agent_id,
                 baseline: profile.baseline,
                 rules: desired_rules
               ) do
            {:ok, _profile} -> {:ok, {:updated, profile}}
            {:error, reason} -> {:error, {:trust_profile_provision_failed, reason}}
          end
        end

      {:error, :not_found} ->
        case trust.ensure_trust_profile(agent_id,
               baseline: :ask,
               rules: %{@trust_rule_prefix => :allow}
             ) do
          {:ok, _profile} -> {:ok, :created}
          {:error, reason} -> {:error, {:trust_profile_provision_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:trust_profile_lookup_failed, reason}}
    end
  rescue
    exception -> {:error, {:trust_profile_provision_exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:trust_profile_provision_exit, reason}}
  end

  defp open_authority(identity, security) do
    proof_result =
      if is_binary(identity.private_key) do
        security.build_signing_authority_acquisition_proof(
          identity.agent_id,
          identity.private_key,
          purpose: :scheduler,
          owner: self()
        )
      else
        security.build_stored_signing_authority_acquisition_proof(
          identity.agent_id,
          :scheduler,
          self(),
          __MODULE__
        )
      end

    with {:ok, proof} <- proof_result do
      security.open_signing_authority(proof)
    end
  end

  defp rollback_trust(:existing, _agent_id, _trust), do: :ok

  defp rollback_trust(:created, agent_id, trust) do
    _ = trust.delete_trust_profile(agent_id)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp rollback_trust({:updated, profile}, agent_id, trust) do
    _ =
      trust.ensure_trust_profile(agent_id,
        baseline: profile.baseline,
        rules: profile.rules || %{}
      )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_delete_key(agent_id, security) do
    _ = security.delete_signing_key(agent_id)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp no_identity_effects do
    %{principal_key_created?: false, identity_created?: false}
  end

  defp scheduler_mutation_token(opts) do
    case Keyword.get(opts, :scheduler_mutation_token) do
      token when is_reference(token) ->
        {:ok, token}

      nil ->
        if @test_env,
          do: test_scheduler_mutation_token(),
          else: {:error, :scheduler_mutation_token_required}

      _ ->
        {:error, :scheduler_mutation_token_required}
    end
  end

  defp test_scheduler_mutation_token do
    case Application.get_env(:arbor_scheduler, :test_scheduler_mutation_token) do
      token when is_reference(token) -> {:ok, token}
      _ -> {:error, :scheduler_mutation_token_required}
    end
  end

  defp authorize_scheduler_mutation(supplied, caller, role)
       when is_reference(supplied) and is_pid(caller) and
              role in [:mutation_owner, :reconciler, :reaper] do
    with {:ok, %{mutation_token: expected} = custody} <- read_ready_custody(),
         true <- supplied == expected,
         true <- legitimate_scheduler_role?(caller, role) do
      {:ok, custody}
    else
      _other -> {:error, :scheduler_mutation_unauthorized}
    end
  end

  defp authorize_scheduler_mutation(_supplied, _caller, _role),
    do: {:error, :scheduler_mutation_unauthorized}

  defp put_ready_custody(authority, security, mutation_token) do
    if valid_custody_owner?() and is_reference(mutation_token) do
      true =
        :ets.insert(
          @custody_table,
          {@custody_tag, :ready, authority, security, mutation_token}
        )

      :ok
    else
      {:error, :scheduler_identity_custody_invalid}
    end
  rescue
    ArgumentError -> {:error, :scheduler_identity_custody_invalid}
  end

  defp read_bootstrap_custody do
    if valid_custody_owner?() and :ets.info(@custody_table, :size) == 1 do
      case :ets.lookup(@custody_table, @custody_tag) do
        [{@custody_tag, :bootstrap, opts}] when is_list(opts) -> {:ok, opts}
        _other -> {:error, :scheduler_identity_custody_invalid}
      end
    else
      {:error, :scheduler_identity_custody_invalid}
    end
  rescue
    ArgumentError -> {:error, :scheduler_identity_custody_invalid}
  end

  defp read_ready_custody do
    if valid_custody_owner?() and :ets.info(@custody_table, :size) == 1 do
      case :ets.lookup(@custody_table, @custody_tag) do
        [
          {@custody_tag, :ready, %Arbor.Contracts.Security.SigningAuthority{} = authority,
           security, mutation_token}
        ]
        when is_atom(security) and is_reference(mutation_token) ->
          {:ok, %{authority: authority, security: security, mutation_token: mutation_token}}

        _other ->
          {:error, :scheduler_identity_custody_invalid}
      end
    else
      {:error, :scheduler_identity_custody_invalid}
    end
  rescue
    ArgumentError -> {:error, :scheduler_identity_custody_invalid}
  end

  defp valid_custody_owner? do
    :ets.info(@custody_table, :owner) == self() and
      :ets.info(@custody_table, :protection) == :private and
      :ets.info(@custody_table, :type) == :set and
      :ets.info(@custody_table, :named_table) == true
  rescue
    ArgumentError -> false
  end

  defp legitimate_scheduler_role?(caller, role) do
    {path, registered_name} = scheduler_role_path(role)

    case Arbor.Common.supervised_registered_child_pid(
           :arbor_scheduler,
           path,
           registered_name
         ) do
      {:ok, ^caller} -> true
      _error -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp scheduler_reaper_role(caller) do
    cond do
      legitimate_scheduler_role?(caller, :reconciler) -> :reconciler
      legitimate_scheduler_role?(caller, :reaper) -> :reaper
      true -> :unknown
    end
  end

  defp scheduler_role_path(:mutation_owner) do
    {
      [
        Arbor.Scheduler.RuntimeSupervisor,
        Arbor.Scheduler.RunLeaseSupervisor,
        Arbor.Scheduler.RunLease.StateOwner
      ],
      Arbor.Scheduler.RunLease.StateOwner
    }
  end

  defp scheduler_role_path(:reconciler) do
    {
      [
        Arbor.Scheduler.RuntimeSupervisor,
        Arbor.Scheduler.RunLeaseSupervisor,
        Arbor.Scheduler.RunLease.Reconciler
      ],
      Arbor.Scheduler.RunLease.Reconciler
    }
  end

  defp scheduler_role_path(:reaper) do
    {
      [Arbor.Scheduler.RuntimeSupervisor, Arbor.Scheduler.RunIdentityReaper],
      Arbor.Scheduler.RunIdentityReaper
    }
  end

  defp protected_call(request) do
    with {:ok, pid} <-
           Arbor.Common.supervised_registered_child_pid(
             :arbor_scheduler,
             [Arbor.Scheduler.RuntimeSupervisor, __MODULE__],
             __MODULE__
           ) do
      Arbor.Common.authenticated_call(pid, request, 30_000)
    else
      _error -> {:error, :scheduler_identity_unavailable}
    end
  rescue
    _exception -> {:error, :scheduler_identity_unavailable}
  catch
    :exit, _reason -> {:error, :scheduler_identity_unavailable}
  end
end
