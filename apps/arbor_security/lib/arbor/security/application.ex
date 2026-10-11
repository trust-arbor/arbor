defmodule Arbor.Security.Application do
  @moduledoc false

  use Application

  alias Arbor.Security.ProviderGate

  require Logger

  @compile_env Mix.env()
  @provider_gate Arbor.Security.ProviderGate
  @supervisor Arbor.Security.Supervisor
  @partial_shutdown_timeout 5_000
  @authority_store_names [
    :arbor_security_capabilities,
    :arbor_security_identities,
    :arbor_security_signing_keys,
    :arbor_security_issuers
  ]

  @impl true
  def start(_type, _args) do
    # Application owns the claim table for the VM lifetime. Creating it in a
    # freeze caller lets that process's exit drop the table and reopen insert_new.
    # A pre-existing named table owned by anyone else is squatting: fail closed
    # before freeze or supervision so startup cannot continue with a mutable
    # foreign claim table.
    with :ok <- Arbor.Security.SessionToken.configuration_status(),
         :ok <- Arbor.Security.Config.ensure_enforcement_toggle_claim_table(),
         :ok <- Arbor.Security.Config.ensure_authority_root_claim_table() do
      start_supervised_children()
    end
  end

  defp start_supervised_children do
    Arbor.Security.Config.maybe_freeze_enforcement_toggles(@compile_env)

    signing_authority_owner_token = make_ref()
    system_authority_registration_token = make_ref()

    with {:ok, snapshot} <- Arbor.Security.Config.startup_store_snapshot(:application),
         {:ok, profile} <- admit_profile(snapshot.start_profile),
         {:ok, signing_key_owner_roles} <- Arbor.Security.Config.signing_key_owner_roles(),
         {:ok, default_startup_timeout} <- Arbor.Security.Config.startup_timeout_ms(),
         {:ok, capability_startup_timeout} <-
           Arbor.Security.Config.startup_timeout_ms(snapshot.capabilities_hydration_limit) do
      children =
        children_from_snapshot(
          snapshot,
          signing_authority_owner_token,
          system_authority_registration_token,
          signing_key_owner_roles
        )

      start_security_supervisor(
        profile,
        children,
        system_authority_registration_token,
        signing_authority_owner_token,
        %{
          default: default_startup_timeout,
          capabilities: capability_startup_timeout
        }
      )
    end
  end

  defp admit_profile(profile) when profile in [:full, :activation_only], do: {:ok, profile}
  defp admit_profile(other), do: {:error, {:invalid_start_profile, other}}

  defp start_security_supervisor(
         _profile,
         [],
         _system_authority_registration_token,
         _signing_authority_owner_token,
         _startup_timeouts
       ) do
    Supervisor.start_link([], strategy: :rest_for_one, name: @supervisor)
  end

  defp start_security_supervisor(
         :full,
         children,
         system_authority_registration_token,
         signing_authority_owner_token,
         startup_timeouts
       ) do
    {foundation, downstream} = split_at_system_authority(children)

    [ProviderGate.child_spec([]) | foundation]
    |> Arbor.KernelRuntime.start_provider_gate_supervisor(@supervisor, @provider_gate)
    |> finish_security_startup(
      :full,
      downstream,
      system_authority_registration_token,
      signing_authority_owner_token,
      startup_timeouts
    )
  end

  defp start_security_supervisor(
         _profile,
         children,
         system_authority_registration_token,
         signing_authority_owner_token,
         startup_timeouts
       ) do
    {foundation, downstream} = split_at_system_authority(children)

    foundation
    |> Supervisor.start_link(strategy: :rest_for_one, name: @supervisor)
    |> finish_security_startup(
      :activation_only,
      downstream,
      system_authority_registration_token,
      signing_authority_owner_token,
      startup_timeouts
    )
  end

  defp split_at_system_authority(children) do
    {before_authority, from_authority} =
      Enum.split_while(children, &(child_id(&1) != Arbor.Security.SystemAuthority))

    case from_authority do
      [authority | downstream] -> {before_authority ++ [authority], downstream}
      [] -> {children, []}
    end
  end

  defp child_id(child), do: child |> Supervisor.child_spec([]) |> Map.fetch!(:id)

  defp finish_security_startup(
         {:ok, supervisor} = started,
         profile,
         downstream,
         system_authority_registration_token,
         signing_authority_owner_token,
         startup_timeouts
       ) do
    with :ok <- hydrate_authority_stores(supervisor, profile, startup_timeouts),
         :ok <-
           Arbor.Security.Identity.Registry.complete_startup(
             supervisor,
             system_authority_registration_token,
             startup_timeouts.default
           ),
         :ok <-
           Arbor.Security.IssuerRegistry.complete_startup(
             supervisor,
             startup_timeouts.default
           ),
         :ok <-
           Arbor.Security.SystemAuthority.complete_startup(
             supervisor,
             system_authority_registration_token,
             startup_timeouts.default
           ),
         :ok <-
           start_downstream_children(
             supervisor,
             downstream,
             signing_authority_owner_token,
             startup_timeouts.default
           ) do
      started
    else
      {:error, reason} ->
        startup_error =
          case reason do
            {:downstream_child_start_failed, _child, _failure} -> reason
            {:downstream_child_readiness_failed, _child, _failure} -> reason
            _ -> {:security_readiness_failed, reason}
          end

        case stop_partial_supervisor(supervisor) do
          :ok -> {:error, startup_error}
          {:error, cleanup_reason} -> {:error, {startup_error, cleanup_reason}}
        end
    end
  end

  defp finish_security_startup(
         {:error, _reason} = error,
         _profile,
         _downstream,
         _system_authority_registration_token,
         _signing_authority_owner_token,
         _startup_timeouts
       ),
       do: error

  defp hydrate_authority_stores(_supervisor, :activation_only, _startup_timeouts), do: :ok

  defp hydrate_authority_stores(supervisor, :full, startup_timeouts) do
    Enum.reduce_while(@authority_store_names, :ok, fn name, :ok ->
      timeout =
        if name == :arbor_security_capabilities,
          do: startup_timeouts.capabilities,
          else: startup_timeouts.default

      case Arbor.Security.AuthorityStore.complete_startup(
             supervisor,
             name,
             timeout
           ) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt,
           {:error, {:authority_store_startup_failed, name, actionable_startup_failure(reason)}}}
      end
    end)
  end

  # Stores written before authenticated authority records (2026-10-07) are
  # refused and no offline migration tool exists yet. A bare
  # :offline_migration_required atom left operators hunting for the store, so
  # name the directory and the only recovery available today.
  @doc false
  def actionable_startup_failure({:authority_store_hydration_failed, :offline_migration_required}) do
    root =
      case Arbor.Security.Config.authority_root() do
        {:ok, root} -> root
        {:error, _reason} -> "the configured authority root"
      end

    action =
      "#{root} holds authority records from before authenticated records " <>
        "(2026-10-07) and no migration tool exists yet. Stop Arbor, move the " <>
        "directory aside as a backup (for example: mv #{root} " <>
        "~/.arbor/backups/security-$(date +%Y%m%d)), and start again to begin " <>
        "with a fresh store. Identities, capabilities and grants in the old " <>
        "store are not carried over."

    Logger.error("[Arbor.Security] Authority store needs offline migration: " <> action)

    {:authority_store_hydration_failed, :offline_migration_required,
     %{authority_root: root, action: action}}
  end

  def actionable_startup_failure(reason), do: reason

  defp start_downstream_children(
         supervisor,
         children,
         signing_authority_owner_token,
         startup_timeout
       ) do
    Enum.reduce_while(children, :ok, fn child, :ok ->
      spec = Supervisor.child_spec(child, [])

      case Supervisor.start_child(supervisor, spec) do
        {:ok, _pid} ->
          continue_after_child_readiness(
            supervisor,
            spec,
            signing_authority_owner_token,
            startup_timeout
          )

        {:ok, _pid, _info} ->
          continue_after_child_readiness(
            supervisor,
            spec,
            signing_authority_owner_token,
            startup_timeout
          )

        {:error, reason} ->
          {:halt, {:error, {:downstream_child_start_failed, spec.id, reason}}}
      end
    end)
  end

  defp continue_after_child_readiness(
         supervisor,
         spec,
         signing_authority_owner_token,
         startup_timeout
       ) do
    case complete_downstream_child_startup(
           supervisor,
           spec.id,
           signing_authority_owner_token,
           startup_timeout
         ) do
      :ok ->
        {:cont, :ok}

      {:error, reason} ->
        {:halt, {:error, {:downstream_child_readiness_failed, spec.id, reason}}}
    end
  end

  defp complete_downstream_child_startup(
         supervisor,
         Arbor.Security.SigningAuthorityBroker,
         signing_authority_owner_token,
         startup_timeout
       ) do
    Arbor.Security.SigningAuthorityBroker.complete_startup(
      supervisor,
      signing_authority_owner_token,
      startup_timeout
    )
  end

  defp complete_downstream_child_startup(
         supervisor,
         Arbor.Security.CapabilityStore,
         _signing_authority_owner_token,
         startup_timeout
       ) do
    Arbor.Security.CapabilityStore.complete_startup(
      supervisor,
      startup_timeout
    )
  end

  defp complete_downstream_child_startup(
         _supervisor,
         _child,
         _signing_authority_owner_token,
         _startup_timeout
       ),
       do: :ok

  defp stop_partial_supervisor(supervisor) do
    children = partial_supervisor_children(supervisor)

    monitored =
      [supervisor | children]
      |> Enum.uniq()
      |> Map.new(&{&1, Process.monitor(&1)})

    Process.unlink(supervisor)

    _ =
      try do
        Supervisor.stop(supervisor, :shutdown, @partial_shutdown_timeout)
      catch
        :exit, _reason -> :shutdown_incomplete
      end

    Enum.each(Map.keys(monitored), fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    await_processes_down(monitored, @partial_shutdown_timeout)
  end

  defp partial_supervisor_children(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.flat_map(fn
      {_id, pid, _type, _modules} when is_pid(pid) -> [pid]
      _child -> []
    end)
  rescue
    _ -> []
  catch
    :exit, _reason -> []
  end

  defp await_processes_down(monitored, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_processes_down_until(monitored, deadline)
  end

  defp await_processes_down_until(monitored, _deadline) when map_size(monitored) == 0, do: :ok

  defp await_processes_down_until(monitored, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, reference, :process, pid, _reason} ->
        case Map.get(monitored, pid) do
          ^reference -> await_processes_down_until(Map.delete(monitored, pid), deadline)
          _other -> await_processes_down_until(monitored, deadline)
        end
    after
      remaining -> {:error, {:partial_supervisor_shutdown_timeout, Map.keys(monitored)}}
    end
  end

  defp children_from_snapshot(
         %{start_children: false},
         _signing_authority_owner_token,
         _system_authority_registration_token,
         _signing_key_owner_roles
       ),
       do: []

  defp children_from_snapshot(
         %{start_children: nil},
         _signing_authority_owner_token,
         _system_authority_registration_token,
         _signing_key_owner_roles
       ),
       do: []

  defp children_from_snapshot(
         snapshot,
         signing_authority_owner_token,
         system_authority_registration_token,
         signing_key_owner_roles
       ) do
    children_for_profile(
      snapshot,
      signing_authority_owner_token,
      system_authority_registration_token,
      signing_key_owner_roles
    )
  end

  defp children_for_profile(
         %{start_profile: :activation_only} = snapshot,
         signing_authority_owner_token,
         system_authority_registration_token,
         signing_key_owner_roles
       ) do
    core_security_children(
      snapshot,
      signing_authority_owner_token,
      system_authority_registration_token,
      signing_key_owner_roles
    )
  end

  defp children_for_profile(
         snapshot,
         signing_authority_owner_token,
         system_authority_registration_token,
         signing_key_owner_roles
       ) do
    security_store_children(snapshot) ++
      core_security_children(
        snapshot,
        signing_authority_owner_token,
        system_authority_registration_token,
        signing_key_owner_roles
      )
  end

  defp security_store_children(snapshot) do
    store_tokens =
      Map.new(
        [
          :arbor_security_capabilities,
          :arbor_security_identities,
          :arbor_security_signing_keys,
          :arbor_security_issuers
        ],
        &{&1, make_ref()}
      )

    [
      {Arbor.Security.MasterKeyAccessOwner, store_tokens: store_tokens},
      authority_store_child(
        snapshot,
        :arbor_security_capabilities,
        "capabilities",
        hydration_limit: snapshot.capabilities_hydration_limit,
        mutation_owners: [Arbor.Security.CapabilityStore],
        backend_opts: [
          record_authentication_token: store_tokens.arbor_security_capabilities
        ]
      ),
      authority_store_child(snapshot, :arbor_security_identities, "identities",
        mutation_owners: [Arbor.Security.Identity.Registry],
        backend_opts: [record_authentication_token: store_tokens.arbor_security_identities]
      ),
      authority_store_child(snapshot, :arbor_security_signing_keys, "signing_keys",
        mutation_owners: [
          Arbor.Security.SigningKeyStore.Owner
        ],
        backend_opts: [record_authentication_token: store_tokens.arbor_security_signing_keys]
      ),
      authority_store_child(snapshot, :arbor_security_issuers, "issuers",
        mutation_owners: [Arbor.Security.IssuerRegistry],
        backend_opts: [record_authentication_token: store_tokens.arbor_security_issuers]
      )
    ]
  end

  defp authority_store_child(snapshot, name, namespace, extra) do
    store_opts =
      Arbor.Security.Config.authority_store_start_opts(name, namespace, snapshot, extra)
      |> Keyword.put(:defer_hydration, true)

    Supervisor.child_spec({Arbor.Security.AuthorityStore, store_opts}, id: name)
  end

  defp core_security_children(
         snapshot,
         signing_authority_owner_token,
         system_authority_registration_token,
         signing_key_owner_roles
       ) do
    [
      {Arbor.Security.SigningKeyStore.Owner, role_specs: signing_key_owner_roles},
      {Arbor.Security.OIDC.TokenCacheOwner, []},
      {Arbor.Security.Identity.Registry,
       system_authority_registration_token: system_authority_registration_token,
       defer_initialization: true,
       registration_role_specs:
         Map.take(
           signing_key_owner_roles,
           Arbor.Security.Config.identity_registration_roles()
         )},
      {Arbor.Security.IssuerRegistry, defer_initialization: true},
      {Arbor.Security.Identity.NonceCache, []},
      # Session ids are live server state. Registry loss invalidates every
      # outstanding bearer token rather than silently resurrecting it.
      {Arbor.Security.SessionRegistry, []},
      # Classifies connected nodes for the signed-request replay gate. Before
      # NonceCache's consumers so the gate reads a live table; absent, every
      # peer counts as a replay peer (fail closed).
      {Arbor.Security.Identity.ReplayPeers, Arbor.Security.Config.replay_peers_start_opts()},
      {Arbor.Security.SystemAuthority,
       system_authority_registration_token: system_authority_registration_token,
       defer_initialization: true},
      # The StateOwner/Broker pair is ordered for rest_for_one recovery. The
      # owner precedes the broker so owner loss restarts both and no broker can
      # retain stale owner authority; broker-only loss restarts only the broker
      # and preserves owner-held metadata. Their shared opaque startup token
      # binds the pair. The key/identity stores and registries above must
      # already be live before either child starts.
      {Arbor.Security.SigningAuthorityStateOwner, broker_token: signing_authority_owner_token},
      {Arbor.Security.SigningAuthorityBroker,
       state_owner_token: signing_authority_owner_token, defer_initialization: true},
      # Narrow caller-bound signing/encryption authority for internal channels.
      # It starts after the signing broker and never exports decrypted keys.
      {Arbor.Security.ChannelAuthorityBroker, []},
      {Arbor.Security.Constraint.RateLimiter, []},
      {Arbor.Security.AuditJournalOwner,
       Arbor.Security.Config.audit_journal_start_opts(snapshot)},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.InvocationReceiptBroker, []},
      {Arbor.Security.Reflex.Registry, []},
      {Arbor.Security.UriRegistry, []},
      # Ephemeral one-use delivery receipts and terminal login credentials.
      # Receipt loss also retires dependent terminal sessions fail-closed.
      {Arbor.Security.DeliveryReceiptBroker, []},
      {Arbor.Security.ApprovalReceiptBroker, []},
      {Arbor.Security.NativeNoticeBroker, []},
      {Arbor.Security.OIDC.JwksCache, []},
      {Arbor.Security.TerminalLogin, []}
    ]
  end
end
