defmodule Arbor.Security.SigningKeyStore.Owner do
  @moduledoc false

  use GenServer

  alias Arbor.Security.OIDC.IdentityStore
  alias Arbor.Security.OIDC.Config, as: OIDCConfig
  alias Arbor.Security.OIDC.TokenVerifier
  alias Arbor.Security.PrivateState
  alias Arbor.Security.SigningKeyStore
  alias Arbor.Security.SupervisedOwner

  @name __MODULE__
  @directory :arbor_security_signing_key_store_owner_directory
  @role_custody_anchor {__MODULE__, :role_custody}
  @role_custody_schema :signing_key_owner_role_custody_v1
  # Roles whose key operations are bound to the first principal they name.
  @principal_bound_roles [:trust_grant_owner, :system_lifecycle_owner]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  def put(agent_id, private_key), do: call({:put, agent_id, private_key})

  def put_keypair(agent_id, signing_key, encryption_key),
    do: call({:put_keypair, agent_id, signing_key, encryption_key})

  def put_authority_bundle(agent_id, identity),
    do: call({:put_authority_bundle, agent_id, identity})

  def delete_authority_record(key), do: call({:delete_authority_record, key})

  def delete(agent_id), do: call({:delete, agent_id})
  def get(agent_id), do: call({:get, agent_id})
  def get_keypair(agent_id), do: call({:get_keypair, agent_id})
  def get_authority_bundle(agent_id), do: call({:get_authority_bundle, agent_id})

  @doc false
  def get_authority_bundle_from_supervisor(supervisor, agent_id),
    do: direct_call(supervisor, {:get_authority_bundle_from_supervisor, supervisor, agent_id})

  @doc false
  def get_keypair_from_supervisor(supervisor, agent_id),
    do: direct_call(supervisor, {:get_keypair_from_supervisor, supervisor, agent_id})

  @doc false
  def put_authority_bundle_from_supervisor(supervisor, agent_id, identity),
    do:
      direct_call(
        supervisor,
        {:put_authority_bundle_from_supervisor, supervisor, agent_id, identity}
      )

  @doc false
  def delete_authority_record_from_supervisor(supervisor, key),
    do: direct_call(supervisor, {:delete_authority_record_from_supervisor, supervisor, key})

  def load_public_identity(agent_id, opts), do: call({:load_public_identity, agent_id, opts})
  def build_registration_proof(identity), do: call({:build_registration_proof, identity})
  def migrate_legacy_locator(locator, opts), do: call({:migrate_legacy_locator, locator, opts})

  def build_named_acquisition_proof(principal_id, purpose, owner, registered_owner),
    do: call({:build_named_acquisition_proof, principal_id, purpose, owner, registered_owner})

  def load_or_create_oidc(id_token, provider_config),
    do: call({:load_or_create_oidc, id_token, provider_config})

  def load_or_create_local(claims), do: call({:load_or_create_local, claims})

  def build_oidc_acquisition_proof(id_token, provider_config, purpose, owner),
    do: call({:build_oidc_acquisition_proof, id_token, provider_config, purpose, owner})

  def build_oidc_registration_proof(identity, id_token, provider_config),
    do: call({:build_oidc_registration_proof, identity, id_token, provider_config})

  @doc false
  def owner_process? do
    match?({:ok, owner} when owner == self(), owner_pid())
  end

  @doc false
  def owner_process_from_supervisor?(supervisor) when is_pid(supervisor),
    do: SupervisedOwner.child_pid(supervisor, __MODULE__) == self()

  def owner_process_from_supervisor?(_supervisor), do: false

  @doc false
  def authorized_pid?(pid) when is_pid(pid), do: match?({:ok, ^pid}, owner_pid())
  def authorized_pid?(_pid), do: false

  if Mix.env() == :test do
    def put_fixture(agent_id, private_key), do: call({:put_fixture, agent_id, private_key})

    def put_keypair_fixture(agent_id, signing_key, encryption_key),
      do: call({:put_keypair_fixture, agent_id, signing_key, encryption_key})

    def delete_fixture(agent_id), do: call({:delete_fixture, agent_id})

    def load_public_identity_fixture(agent_id, opts),
      do: call({:load_public_identity_fixture, agent_id, opts})

    def load_or_create_oidc_fixture(claims), do: call({:load_or_create_oidc_fixture, claims})
  end

  @impl true
  def init(opts) do
    Process.flag(:sensitive, true)

    with {:ok, supervisor_pid} <- startup_supervisor_pid(),
         {:ok, role_specs} <- fetch_pinned_role_specs(opts),
         :ok <- claim_directory() do
      {:ok,
       %{
         security_supervisor_pid: supervisor_pid,
         role_custody:
           PrivateState.new(
             @role_custody_anchor,
             @role_custody_schema,
             %{bindings: %{}, role_principals: %{}, role_specs: role_specs}
           ),
         authenticated_calls: Arbor.Common.new_authenticated_call_custody()
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp fetch_pinned_role_specs(opts) when is_list(opts) do
    case Keyword.fetch(opts, :role_specs) do
      {:ok, role_specs} when is_map(role_specs) and map_size(role_specs) > 0 ->
        {:ok, role_specs}

      _ ->
        {:error, :invalid_signing_key_owner_roles}
    end
  end

  defp fetch_pinned_role_specs(_opts), do: {:error, :invalid_signing_key_owner_roles}

  defp handle_authenticated_call({:put, agent_id, private_key}, caller, state) do
    case admit_key_owner(caller, agent_id, state) do
      {:ok, state} ->
        {:reply, SigningKeyStore.put_from_owner(agent_id, private_key), state}

      {:error, _reason} ->
        {:reply, {:error, :key_mutation_unauthorized}, state}
    end
  end

  defp handle_authenticated_call(
         {:put_keypair, agent_id, signing_key, encryption_key},
         caller,
         state
       ) do
    case admit_key_owner(caller, agent_id, state) do
      {:ok, state} ->
        {:reply, SigningKeyStore.put_keypair_from_owner(agent_id, signing_key, encryption_key),
         state}

      {:error, _reason} ->
        {:reply, {:error, :key_mutation_unauthorized}, state}
    end
  end

  defp handle_authenticated_call({:put_authority_bundle, agent_id, identity}, caller, state) do
    case admit_system_authority(caller, state) do
      {:ok, state} ->
        {:reply, SigningKeyStore.put_authority_bundle_from_owner(agent_id, identity), state}

      {:error, _reason} ->
        {:reply, {:error, :key_mutation_unauthorized}, state}
    end
  end

  defp handle_authenticated_call({:delete_authority_record, key}, caller, state) do
    case admit_system_authority(caller, state) do
      {:ok, state} ->
        {:reply, SigningKeyStore.delete_authority_record_from_owner(key), state}

      {:error, _reason} ->
        {:reply, {:error, :key_mutation_unauthorized}, state}
    end
  end

  defp handle_authenticated_call(
         {:get_authority_bundle_from_supervisor, supervisor, agent_id},
         caller,
         state
       ) do
    case admit_startup_system_authority(caller, supervisor, state) do
      {:ok, state} ->
        {:reply, SigningKeyStore.get_authority_bundle_from_owner(agent_id, supervisor), state}

      {:error, _reason} ->
        {:reply, {:error, :unauthorized}, state}
    end
  end

  defp handle_authenticated_call(
         {:get_keypair_from_supervisor, supervisor, agent_id},
         caller,
         state
       ) do
    case admit_startup_system_authority(caller, supervisor, state) do
      {:ok, state} ->
        {:reply, SigningKeyStore.get_keypair_from_owner(agent_id, supervisor), state}

      {:error, _reason} ->
        {:reply, {:error, :unauthorized}, state}
    end
  end

  defp handle_authenticated_call(
         {:put_authority_bundle_from_supervisor, supervisor, agent_id, identity},
         caller,
         state
       ) do
    case admit_startup_system_authority(caller, supervisor, state) do
      {:ok, state} ->
        {:reply, SigningKeyStore.put_authority_bundle_from_owner(agent_id, identity, supervisor),
         state}

      {:error, _reason} ->
        {:reply, {:error, :key_mutation_unauthorized}, state}
    end
  end

  defp handle_authenticated_call(
         {:delete_authority_record_from_supervisor, supervisor, key},
         caller,
         state
       ) do
    case admit_startup_system_authority(caller, supervisor, state) do
      {:ok, state} ->
        {:reply, SigningKeyStore.delete_authority_record_from_owner(key, supervisor), state}

      {:error, _reason} ->
        {:reply, {:error, :key_mutation_unauthorized}, state}
    end
  end

  defp handle_authenticated_call({:delete, agent_id}, caller, state) do
    case admit_key_owner(caller, agent_id, state) do
      {:ok, state} ->
        {:reply, SigningKeyStore.delete_from_owner(agent_id), state}

      {:error, _reason} ->
        {:reply, {:error, :key_mutation_unauthorized}, state}
    end
  end

  defp handle_authenticated_call({operation, agent_id}, caller, state)
       when operation in [:get, :get_keypair, :get_authority_bundle] do
    case admit_raw_reader(caller, state) do
      {:ok, state} ->
        reply =
          case operation do
            :get -> SigningKeyStore.get_from_owner(agent_id)
            :get_keypair -> SigningKeyStore.get_keypair_from_owner(agent_id)
            :get_authority_bundle -> SigningKeyStore.get_authority_bundle_from_owner(agent_id)
          end

        {:reply, reply, state}

      {:error, _reason} ->
        {:reply, {:error, :unauthorized}, state}
    end
  end

  defp handle_authenticated_call({:load_public_identity, agent_id, opts}, caller, state) do
    case admit_stored_identity_owner(caller, agent_id, state) do
      {:ok, state} ->
        {:reply, SigningKeyStore.load_public_identity_from_owner(agent_id, opts), state}

      {:error, _reason} ->
        {:reply, {:error, :unauthorized_key_owner}, state}
    end
  end

  defp handle_authenticated_call({:build_registration_proof, identity}, caller, state) do
    case admit_registration_proof_owner(caller, identity, state) do
      {:ok, state} ->
        {:reply, SigningKeyStore.build_registration_proof_from_owner(identity), state}

      {:error, _reason} ->
        {:reply, {:error, :unauthorized_key_owner}, state}
    end
  end

  defp handle_authenticated_call({:migrate_legacy_locator, locator, opts}, caller, state) do
    case admit_scheduler_owner(caller, state) do
      {:ok, state} ->
        {:reply, SigningKeyStore.migrate_legacy_locator_from_owner(locator, opts), state}

      {:error, _reason} ->
        {:reply, {:error, :unauthorized_key_owner}, state}
    end
  end

  defp handle_authenticated_call(
         {:build_named_acquisition_proof, principal_id, purpose, owner, registered_owner},
         caller,
         state
       ) do
    role = role_for_registered_owner(state, registered_owner)

    authorization =
      if is_nil(role) or not purpose_allowed?(state, role, purpose),
        do: {:error, :unauthorized_key_owner},
        else: admit_role_principal(state, role, caller, principal_id)

    case authorization do
      {:ok, state} when caller == owner ->
        {:reply,
         SigningKeyStore.build_named_acquisition_proof_from_owner(
           principal_id,
           purpose,
           owner
         ), state}

      _ ->
        {:reply, {:error, :unauthorized_key_owner}, state}
    end
  end

  defp handle_authenticated_call(
         {:load_or_create_oidc, id_token, provider_config},
         _caller,
         state
       ) do
    reply =
      with {:ok, claims} <- TokenVerifier.verify(id_token, provider_config) do
        IdentityStore.load_or_create_verified(claims)
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_call({:load_or_create_local, claims}, _caller, state) do
    reply =
      with :ok <- admit_local_human_claims(claims) do
        IdentityStore.load_or_create_verified(claims)
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_call(
         {:build_oidc_registration_proof, identity, id_token, provider_config},
         _caller,
         state
       ) do
    reply =
      SigningKeyStore.build_oidc_registration_proof_from_owner(
        identity,
        id_token,
        provider_config
      )

    {:reply, reply, state}
  end

  defp handle_authenticated_call(
         {:build_oidc_acquisition_proof, id_token, provider_config, purpose, owner},
         caller,
         state
       ) do
    reply =
      if caller == owner do
        SigningKeyStore.build_oidc_acquisition_proof_from_owner(
          id_token,
          provider_config,
          purpose,
          owner
        )
      else
        {:error, :unauthorized_key_owner}
      end

    {:reply, reply, state}
  end

  if Mix.env() == :test do
    defp handle_authenticated_call({:put_fixture, agent_id, private_key}, _caller, state),
      do: {:reply, SigningKeyStore.put_from_owner(agent_id, private_key), state}

    defp handle_authenticated_call(
           {:put_keypair_fixture, agent_id, signing_key, encryption_key},
           _caller,
           state
         ),
         do:
           {:reply, SigningKeyStore.put_keypair_from_owner(agent_id, signing_key, encryption_key),
            state}

    defp handle_authenticated_call({:delete_fixture, agent_id}, _caller, state),
      do: {:reply, SigningKeyStore.delete_from_owner(agent_id), state}

    defp handle_authenticated_call(
           {:load_public_identity_fixture, agent_id, opts},
           _caller,
           state
         ),
         do: {:reply, SigningKeyStore.load_public_identity_from_owner(agent_id, opts), state}

    defp handle_authenticated_call({:load_or_create_oidc_fixture, claims}, _caller, state),
      do: {:reply, IdentityStore.load_or_create_verified(claims), state}
  end

  defp handle_authenticated_call(_request, _caller, state),
    do: {:reply, {:error, :key_mutation_unauthorized}, state}

  @impl true
  def handle_call(_request, _from, state),
    do: {:reply, {:error, :key_mutation_unauthorized}, state}

  @impl true
  def handle_info(message, state) do
    case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
      {:authenticated, caller, request, reply_to} ->
        {:reply, reply, state} = handle_authenticated_call(request, caller, state)
        :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
        {:noreply, state}

      result when result in [:pending, :expired, :rejected] ->
        {:noreply, state}

      :unrecognized ->
        {:noreply, state}
    end
  end

  @impl true
  def format_status(status) when is_map(status), do: Map.put(status, :state, :redacted)

  defp call(request) do
    with {:ok, owner} <- owner_pid() do
      Arbor.Common.authenticated_call(owner, request, 30_000)
    end
  rescue
    _ -> {:error, :key_store_unavailable}
  catch
    :exit, _ -> {:error, :key_store_unavailable}
  end

  defp admit_key_owner(caller, principal_id, state) do
    case admit_role(state, :profile_owner, caller) do
      {:ok, state} ->
        {:ok, state}

      {:error, _reason} ->
        case admit_role(state, :scheduler_owner, caller) do
          {:ok, state} ->
            {:ok, state}

          {:error, _reason} ->
            admit_principal_bound_owner(state, caller, principal_id)
        end
    end
  end

  defp admit_registration_proof_owner(caller, identity, state) do
    case admit_role(state, :profile_owner, caller) do
      {:ok, state} ->
        {:ok, state}

      {:error, _reason} ->
        case admit_role(state, :scheduler_owner, caller) do
          {:ok, state} ->
            {:ok, state}

          {:error, _reason} ->
            admit_principal_bound_owner(state, caller, Map.get(identity, :agent_id))
        end
    end
  end

  # Owners bound to exactly one principal (their own): the first key operation
  # binds it, and every later key operation must name the same principal.
  defp admit_principal_bound_owner(state, caller, principal_id) do
    case admit_role_principal(state, :trust_grant_owner, caller, principal_id) do
      {:ok, state} ->
        {:ok, state}

      {:error, _reason} ->
        admit_role_principal(state, :system_lifecycle_owner, caller, principal_id)
    end
  end

  defp admit_scheduler_owner(caller, state), do: admit_role(state, :scheduler_owner, caller)

  defp admit_stored_identity_owner(caller, principal_id, state) do
    case admit_scheduler_owner(caller, state) do
      {:ok, state} ->
        {:ok, state}

      {:error, _reason} ->
        case admit_role_principal(state, :trust_grant_owner, caller, principal_id) do
          {:ok, state} ->
            {:ok, state}

          # Public-key derivation only. The system lifecycle owner scans named
          # candidates at restart, so this read must not bind its principal;
          # key-material operations (store, proofs) still do.
          {:error, _reason} ->
            admit_role(state, :system_lifecycle_owner, caller)
        end
    end
  end

  defp admit_system_authority(caller, state),
    do: admit_role(state, :system_authority, caller)

  defp admit_raw_reader(caller, state) do
    case admit_role(state, :system_authority, caller) do
      {:ok, state} ->
        {:ok, state}

      {:error, _reason} ->
        case admit_role(state, :signing_broker, caller) do
          {:ok, state} -> {:ok, state}
          {:error, _reason} -> admit_role(state, :channel_broker, caller)
        end
    end
  end

  defp admit_role(state, role, caller) do
    with {:ok, custody} <- role_custody(state) do
      case Map.get(custody.bindings, role) do
        ^caller ->
          {:ok, state}

        bound when is_pid(bound) ->
          if Process.alive?(bound),
            do: {:error, :unauthorized_key_owner},
            else: bind_role(state, custody, role, caller)

        nil ->
          bind_role(state, custody, role, caller)

        _invalid ->
          {:error, :unauthorized_key_owner}
      end
    else
      _ -> {:error, :unauthorized_key_owner}
    end
  end

  defp admit_startup_system_authority(
         caller,
         supervisor,
         %{security_supervisor_pid: supervisor} = state
       )
       when is_pid(caller) and is_pid(supervisor) do
    with {:ok, custody} <- role_custody(state),
         {:ok, spec} <- Map.fetch(custody.role_specs, :system_authority),
         true <- registered_name(caller) == spec.registered_name,
         true <- supervised_child_at_path(supervisor, spec.path) == caller do
      case Map.get(custody.bindings, :system_authority) do
        ^caller ->
          {:ok, state}

        nil ->
          bind_startup_role(state, custody, caller)

        bound when is_pid(bound) ->
          if Process.alive?(bound),
            do: {:error, :unauthorized_key_owner},
            else: bind_startup_role(state, custody, caller)
      end
    else
      _other -> {:error, :unauthorized_key_owner}
    end
  end

  defp admit_startup_system_authority(_caller, _supervisor, _state),
    do: {:error, :unauthorized_key_owner}

  defp bind_startup_role(state, custody, caller) do
    next = put_in(custody, [:bindings, :system_authority], caller)

    case put_role_custody(state, next) do
      :ok -> {:ok, state}
      {:error, _reason} -> {:error, :unauthorized_key_owner}
    end
  end

  defp admit_role_principal(state, role, caller, principal_id) do
    with {:ok, state} <- admit_role(state, role, caller) do
      bind_role_principal(state, role, principal_id)
    end
  end

  defp bind_role_principal(state, role, principal_id)
       when role in @principal_bound_roles and is_binary(principal_id) do
    with {:ok, custody} <- role_custody(state) do
      case Map.get(custody.role_principals, role) do
        nil ->
          next = put_in(custody, [:role_principals, role], principal_id)

          case put_role_custody(state, next) do
            :ok -> {:ok, state}
            {:error, _reason} -> {:error, :unauthorized_key_owner}
          end

        ^principal_id ->
          {:ok, state}

        _other ->
          {:error, :unauthorized_key_owner}
      end
    else
      _ -> {:error, :unauthorized_key_owner}
    end
  end

  defp bind_role_principal(_state, role, _principal_id) when role in @principal_bound_roles,
    do: {:error, :unauthorized_key_owner}

  defp bind_role_principal(state, _role, _principal_id), do: {:ok, state}

  defp bind_role(state, custody, role, caller) do
    if legitimate_role_candidate?(custody, role, caller) do
      next = put_in(custody, [:bindings, role], caller)

      case put_role_custody(state, next) do
        :ok -> {:ok, state}
        {:error, _reason} -> {:error, :unauthorized_key_owner}
      end
    else
      {:error, :unauthorized_key_owner}
    end
  end

  defp legitimate_role_candidate?(custody, role, caller) do
    case Map.fetch(custody.role_specs, role) do
      {:ok,
       %{
         application: application,
         path: path,
         registered_name: registered_name
       }} ->
        registered_name(caller) == registered_name and
          SupervisedOwner.authorized?(caller, application, path)

      :error ->
        false
    end
  end

  defp role_for_registered_owner(state, registered_owner) do
    with {:ok, custody} <- role_custody(state) do
      Enum.find_value(custody.role_specs, fn {role, spec} ->
        if spec.registered_name == registered_owner, do: role
      end)
    else
      _ -> nil
    end
  end

  defp purpose_allowed?(state, role, purpose) do
    with {:ok, custody} <- role_custody(state) do
      case Map.fetch(custody.role_specs, role) do
        {:ok, %{purposes: purposes}} -> purpose in purposes
        :error -> false
      end
    else
      _ -> false
    end
  end

  defp role_custody(%{role_custody: custody}) do
    PrivateState.fetch(
      custody,
      @role_custody_anchor,
      @role_custody_schema,
      &valid_role_custody?/1
    )
  end

  defp role_custody(_state), do: {:error, :invalid_private_state}

  defp put_role_custody(%{role_custody: custody}, value) do
    PrivateState.replace(
      custody,
      @role_custody_anchor,
      @role_custody_schema,
      value,
      &valid_role_custody?/1
    )
  end

  defp put_role_custody(_state, _value), do: {:error, :invalid_private_state}

  defp valid_role_custody?(
         %{
           bindings: bindings,
           role_principals: role_principals,
           role_specs: role_specs
         } = custody
       ) do
    Map.keys(custody) |> Enum.sort() == [:bindings, :role_principals, :role_specs] and
      is_map(bindings) and
      Enum.all?(bindings, fn {role, pid} -> Map.has_key?(role_specs, role) and is_pid(pid) end) and
      is_map(role_principals) and
      Enum.all?(role_principals, fn
        {role, principal_id} when role in @principal_bound_roles -> is_binary(principal_id)
        _other -> false
      end) and valid_role_specs?(role_specs)
  end

  defp valid_role_custody?(_custody), do: false

  defp valid_role_specs?(role_specs) when is_map(role_specs) and map_size(role_specs) > 0 do
    Enum.all?(role_specs, fn
      {role,
       %{
         application: application,
         path: path,
         registered_name: registered_name,
         purposes: purposes
       }} ->
        is_atom(role) and is_atom(application) and not is_nil(application) and is_list(path) and
          path != [] and Enum.all?(path, &(is_atom(&1) and not is_nil(&1))) and
          is_atom(registered_name) and not is_nil(registered_name) and is_list(purposes) and
          Enum.all?(purposes, &(is_atom(&1) and not is_nil(&1)))

      _invalid ->
        false
    end)
  end

  defp valid_role_specs?(_role_specs), do: false

  defp admit_local_human_claims(claims) when is_map(claims) do
    issuer = Map.get(claims, :iss) || Map.get(claims, "iss")
    subject = Map.get(claims, :sub) || Map.get(claims, "sub")

    cond do
      Application.get_env(:arbor_security, :allow_local_human_identity, false) != true ->
        {:error, :local_human_identity_disabled}

      OIDCConfig.enabled?() ->
        {:error, :oidc_configured}

      issuer != "arbor://local" ->
        {:error, :invalid_local_human_claims}

      not is_binary(subject) or byte_size(subject) not in 1..512 ->
        {:error, :invalid_local_human_claims}

      not String.valid?(subject) or String.contains?(subject, <<0>>) ->
        {:error, :invalid_local_human_claims}

      true ->
        :ok
    end
  end

  defp admit_local_human_claims(_claims), do: {:error, :invalid_local_human_claims}

  defp registered_name(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) -> name
      _ -> nil
    end
  end

  defp supervised_child_at_path(supervisor, child_path) do
    Enum.reduce_while(child_path, supervisor, fn child_id, parent ->
      case SupervisedOwner.child_pid(parent, child_id) do
        child when is_pid(child) -> {:cont, child}
        _other -> {:halt, nil}
      end
    end)
  end

  defp direct_call(supervisor, request) when is_pid(supervisor) do
    case SupervisedOwner.child_pid(supervisor, __MODULE__) do
      owner when is_pid(owner) -> Arbor.Common.authenticated_call(owner, request, 30_000)
      nil -> {:error, :key_store_unavailable}
    end
  rescue
    _ -> {:error, :key_store_unavailable}
  catch
    :exit, _ -> {:error, :key_store_unavailable}
  end

  defp direct_call(_supervisor, _request), do: {:error, :key_store_unavailable}

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

  defp claim_directory do
    table = :ets.new(@directory, [:named_table, :protected, :set, read_concurrency: true])
    true = :ets.insert(table, {:owner, self()})
    :ok
  rescue
    _ -> {:error, :signing_key_owner_directory_unavailable}
  end

  defp owner_pid do
    case SupervisedOwner.protected_directory_owner(
           @directory,
           :owner,
           :arbor_security,
           [__MODULE__]
         ) do
      owner when is_pid(owner) -> {:ok, owner}
      nil -> {:error, :key_store_unavailable}
    end
  end
end
