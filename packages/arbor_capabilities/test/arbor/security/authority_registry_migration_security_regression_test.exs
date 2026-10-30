defmodule Arbor.Security.AuthorityRegistryMigrationSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Common.SafePath
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.Config
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.IssuerRegistry
  alias Arbor.Security.Store.JSONFile
  alias Arbor.Security.TestBootstrap

  defmodule ControlledBackend do
    @moduledoc false

    def put(key, value, opts), do: dispatch(:put, [key, value, opts], opts)
    def get(key, opts), do: dispatch(:get, [key, opts], opts)
    def delete(key, opts), do: dispatch(:delete, [key, opts], opts)
    def list(opts), do: dispatch(:list, [opts], opts)

    def bounded_list(limit, opts),
      do: dispatch(:bounded_list, [limit, opts], opts)

    def compare_and_swap(key, expected, replacement, opts),
      do: dispatch(:compare_and_swap, [key, expected, replacement, opts], opts)

    def compare_and_delete(key, expected, opts),
      do: dispatch(:compare_and_delete, [key, expected, opts], opts)

    def durability_class(_opts), do: :node_restart

    defp dispatch(operation, args, opts) do
      control = Keyword.fetch!(opts, :control)

      if Agent.get(control, &MapSet.member?(&1, operation)) do
        {:error, :forced_backend_failure}
      else
        apply(JSONFile, operation, args)
      end
    end
  end

  setup do
    base_dir = unique_authority_root!()

    on_exit(fn ->
      try do
        stop_packet_processes()
        restore_default_topology()
      after
        File.rm_rf!(base_dir)
      end
    end)

    {:ok, control} = Agent.start_link(fn -> MapSet.new() end)
    {:ok, signing_key_owner_roles} = Config.signing_key_owner_roles()

    {:ok,
     base_dir: base_dir,
     control: control,
     registration_token: make_ref(),
     registration_role_specs:
       Map.take(signing_key_owner_roles, Config.identity_registration_roles())}
  end

  test "security regression: identity write delete and status failures leave hot authority unchanged",
       context do
    start_topology(context)

    {:ok, existing} = Identity.generate(name: "existing")
    assert :ok = Registry.register_fixture(existing)

    fail_operations(context.control, [:compare_and_swap, :compare_and_delete])

    {:ok, rejected} = Identity.generate(name: "rejected")
    assert {:error, :identity_store_outcome_unknown} = Registry.register_fixture(rejected)
    refute Registry.registered?(rejected.agent_id)

    assert {:error, :identity_store_outcome_unknown} =
             Registry.suspend_fixture(existing.agent_id, "fixture")

    assert {:ok, :active} = Registry.identity_status(existing.agent_id)

    stats_before = Registry.stats()

    assert {:error, :identity_store_outcome_unknown} =
             Registry.deregister_fixture(existing.agent_id)

    assert {:ok, existing.public_key} == Registry.lookup(existing.agent_id)
    assert Registry.stats() == stats_before
  end

  test "security regression: a malformed later hydration entry rejects the entire identity inventory",
       context do
    stop_packet_processes()

    {:ok, valid} = Identity.generate(name: "valid-prefix")
    valid_record = Record.new(valid.agent_id, identity_payload(valid))

    assert :ok =
             ControlledBackend.put(
               valid.agent_id,
               valid_record,
               backend_opts(context, "identities")
             )

    malformed_key = "zzzz-malformed-later"

    malformed_record =
      Record.new(malformed_key, %{
        "agent_id" => malformed_key,
        "public_key" => "not-a-public-key"
      })

    assert :ok =
             ControlledBackend.put(
               malformed_key,
               malformed_record,
               backend_opts(context, "identities")
             )

    start_authority(:arbor_security_identities, "identities", context)

    pid = start_registry_child!(context, restart: :temporary, complete_startup?: false)
    monitor = Process.monitor(pid)

    assert {:error, :registration_unavailable} =
             Registry.complete_startup(security_supervisor_pid!(), context.registration_token)

    assert_receive {:DOWN, ^monitor, :process, ^pid, {:identity_authority, :malformed_inventory}},
                   1_000

    refute Process.alive?(pid)
    refute Process.whereis(Registry)
  end

  test "activation-only identity registry is explicitly hot-only while issuers stay unavailable",
       context do
    start_topology(context, identity_store?: false, issuer_store?: false)

    {:ok, identity} = Identity.generate(name: "activation-only")
    assert :ok = Registry.register_fixture(identity)
    assert {:ok, :active} = Registry.identity_status(identity.agent_id)
    assert :ok = Registry.suspend_fixture(identity.agent_id, "fixture")
    assert {:ok, :suspended} = Registry.identity_status(identity.agent_id)
    assert :ok = Registry.resume_fixture(identity.agent_id)
    assert :ok = Registry.deregister_fixture(identity.agent_id)

    envelope = envelope_for(identity.agent_id)

    assert {:error, :store_unavailable} =
             IssuerRegistry.register_fixture(identity.agent_id, [envelope])
  end

  test "identity authority round-trips across restart and remote sync reloads the committed record",
       context do
    start_topology(context)

    {:ok, identity} = Identity.generate(name: "restart-and-sync")
    assert :ok = Registry.register_fixture(identity)

    restart_registry(context)
    assert {:ok, identity.public_key} == Registry.lookup(identity.agent_id)

    assert {:ok, current} =
             AuthorityStore.authoritative_get(identity.agent_id,
               name: :arbor_security_identities
             )

    status_changed_at = DateTime.utc_now()

    replacement =
      Record.new(identity.agent_id, %{
        current.data
        | "status" => "suspended",
          "status_changed_at" => DateTime.to_iso8601(status_changed_at),
          "status_reason" => "remote"
      })

    assert {:ok, stored} =
             ControlledBackend.compare_and_swap(
               identity.agent_id,
               {:value, current},
               replacement,
               backend_opts(context, "identities")
             )

    remote_entry = %{
      public_key: identity.public_key,
      encryption_public_key: identity.encryption_public_key,
      name: identity.name,
      key_version: identity.key_version,
      created_at: identity.created_at,
      metadata: identity.metadata,
      status: :suspended,
      status_changed_at: status_changed_at,
      status_reason: "remote"
    }

    assert :ok =
             Registry.reconcile_remote_authority_result_fixture(
               :identity_suspended,
               identity.agent_id,
               {:ok, stored, remote_entry}
             )

    assert {:ok, :suspended} = Registry.identity_status(identity.agent_id)
  end

  test "security regression: issuer unavailability is not absence and failed writes never succeed",
       context do
    start_topology(context)

    {:ok, identity} = Identity.generate(name: "issuer-failure")
    assert :ok = Registry.register_fixture(identity)
    envelope = envelope_for(identity.agent_id)

    fail_operations(context.control, [:get])

    assert {:error, :store_unavailable} =
             IssuerRegistry.register_fixture(identity.agent_id, [envelope])

    fail_operations(context.control, [])
    assert {:error, :not_found} = IssuerRegistry.lookup(identity.agent_id)

    fail_operations(context.control, [:compare_and_swap])

    assert {:error, :outcome_unknown} =
             IssuerRegistry.register_fixture(identity.agent_id, [envelope])

    fail_operations(context.control, [])
    assert {:error, :not_found} = IssuerRegistry.lookup(identity.agent_id)
  end

  test "issuer authority round-trips and read failures close lookup and verification", context do
    start_topology(context)

    {:ok, identity} = Identity.generate(name: "issuer-round-trip")
    assert :ok = Registry.register_fixture(identity)
    envelope = envelope_for(identity.agent_id)
    assert :ok = IssuerRegistry.register_fixture(identity.agent_id, [envelope])

    restart_issuer_registry(context)
    assert {:ok, %{public_key: public_key}} = IssuerRegistry.lookup(identity.agent_id)
    assert public_key == identity.public_key

    fail_operations(context.control, [:get])
    assert {:error, :store_unavailable} = IssuerRegistry.lookup(identity.agent_id)

    assert {:error, :store_unavailable} =
             IssuerRegistry.verify_envelope(identity.agent_id, envelope)

    assert [] = IssuerRegistry.list()
  end

  defp start_topology(context, opts \\ []) do
    stop_packet_processes()

    if Keyword.get(opts, :identity_store?, true) do
      start_authority(:arbor_security_identities, "identities", context)
    end

    if Keyword.get(opts, :issuer_store?, true) do
      start_authority(:arbor_security_issuers, "issuers", context)
    end

    start_registry_child!(context)
    start_issuer_registry_child!()
  end

  defp start_authority(name, namespace, context) do
    spec =
      Supervisor.child_spec(
        {AuthorityStore,
         name: name,
         namespace: namespace,
         backend: ControlledBackend,
         backend_opts: backend_opts(context, namespace),
         mutation_owners: authority_mutation_owners(name),
         defer_hydration: true},
        id: name
      )

    pid = start_child!(spec, name)
    :ok = AuthorityStore.complete_startup(security_supervisor_pid!(), name)
    pid
  end

  defp restore_default_topology do
    TestBootstrap.restore_supervised_tree!()
  end

  defp start_child!(spec, id) do
    case Supervisor.start_child(security_supervisor_pid!(), spec) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        pid

      {:error, :already_present} ->
        :ok = Supervisor.delete_child(security_supervisor_pid!(), id)
        {:ok, pid} = Supervisor.start_child(security_supervisor_pid!(), spec)
        pid
    end
  end

  defp stop_packet_processes do
    case Process.whereis(Arbor.Security.Supervisor) do
      supervisor when is_pid(supervisor) ->
        for id <- [IssuerRegistry, Registry, :arbor_security_issuers, :arbor_security_identities] do
          case Supervisor.terminate_child(supervisor, id) do
            :ok -> Supervisor.delete_child(supervisor, id)
            {:error, :not_found} -> :ok
          end
        end

      nil ->
        :ok
    end
  end

  defp restart_registry(context) do
    :ok = Supervisor.terminate_child(security_supervisor_pid!(), Registry)
    :ok = Supervisor.delete_child(security_supervisor_pid!(), Registry)
    start_registry_child!(context)
  end

  defp restart_issuer_registry(_context) do
    :ok = Supervisor.terminate_child(security_supervisor_pid!(), IssuerRegistry)
    :ok = Supervisor.delete_child(security_supervisor_pid!(), IssuerRegistry)
    start_issuer_registry_child!()
  end

  defp start_registry_child!(context, opts \\ []) do
    registry_opts = [
      system_authority_registration_token: context.registration_token,
      registration_role_specs: context.registration_role_specs,
      defer_initialization: true
    ]

    spec =
      Supervisor.child_spec({Registry, registry_opts},
        id: Registry,
        restart: Keyword.get(opts, :restart, :permanent)
      )

    pid = start_child!(spec, Registry)

    if Keyword.get(opts, :complete_startup?, true) do
      :ok = Registry.complete_startup(security_supervisor_pid!(), context.registration_token)
    end

    pid
  end

  defp start_issuer_registry_child! do
    spec = Supervisor.child_spec({IssuerRegistry, defer_initialization: true}, id: IssuerRegistry)
    pid = start_child!(spec, IssuerRegistry)
    :ok = IssuerRegistry.complete_startup(security_supervisor_pid!())
    pid
  end

  defp security_supervisor_pid! do
    case Process.whereis(Arbor.Security.Supervisor) do
      pid when is_pid(pid) -> pid
      nil -> raise "Security.Supervisor is unavailable"
    end
  end

  defp unique_authority_root! do
    {:ok, canonical_tmp} = SafePath.resolve_real(System.tmp_dir!())
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    base_dir = Path.join(canonical_tmp, "arbor-authority-registry-#{suffix}")
    :ok = File.mkdir!(base_dir)
    base_dir
  end

  defp fail_operations(control, operations) do
    Agent.update(control, fn _current -> MapSet.new(operations) end)
  end

  defp backend_opts(context, namespace) do
    [base_dir: context.base_dir, name: namespace, control: context.control]
  end

  defp authority_mutation_owners(:arbor_security_identities), do: [Registry]
  defp authority_mutation_owners(:arbor_security_issuers), do: [IssuerRegistry]

  defp identity_payload(identity) do
    %{
      "agent_id" => identity.agent_id,
      "public_key" => Base.encode16(identity.public_key, case: :lower),
      "encryption_public_key" => Base.encode16(identity.encryption_public_key, case: :lower),
      "name" => identity.name,
      "key_version" => identity.key_version,
      "created_at" => DateTime.to_iso8601(identity.created_at),
      "metadata" => identity.metadata,
      "status" => "active",
      "status_changed_at" => nil,
      "status_reason" => nil
    }
  end

  defp envelope_for(issuer_id) do
    {:ok, envelope} =
      Capability.new(
        resource_uri: "arbor://fs/read/packet-3a/**",
        principal_id: issuer_id
      )

    envelope
  end
end
