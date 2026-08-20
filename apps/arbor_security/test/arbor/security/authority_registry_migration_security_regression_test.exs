defmodule Arbor.Security.AuthorityRegistryMigrationSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.IssuerRegistry
  alias Arbor.Security.Store.JSONFile
  alias Arbor.Security.SystemAuthority
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
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "arbor-authority-registry-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(base_dir)
    {:ok, control} = Agent.start_link(fn -> MapSet.new() end)

    on_exit(fn ->
      stop_packet_processes()
      restore_default_topology()
      File.rm_rf!(base_dir)
    end)

    {:ok, base_dir: base_dir, control: control}
  end

  test "security regression: identity write delete and status failures leave hot authority unchanged",
       context do
    start_topology(context)

    {:ok, existing} = Identity.generate(name: "existing")
    assert :ok = Registry.register(existing)

    fail_operations(context.control, [:compare_and_swap, :compare_and_delete])

    {:ok, rejected} = Identity.generate(name: "rejected")
    assert {:error, :identity_store_outcome_unknown} = Registry.register(rejected)
    refute Registry.registered?(rejected.agent_id)

    assert {:error, :identity_store_outcome_unknown} = Registry.suspend(existing.agent_id)
    assert {:ok, :active} = Registry.identity_status(existing.agent_id)

    stats_before = Registry.stats()
    assert {:error, :identity_store_outcome_unknown} = Registry.deregister(existing.agent_id)
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

    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:identity_authority, :malformed_inventory}} = Registry.start_link()
      refute Process.whereis(Registry)
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  test "activation-only identity registry is explicitly hot-only while issuers stay unavailable",
       context do
    start_topology(context, identity_store?: false, issuer_store?: false)

    {:ok, identity} = Identity.generate(name: "activation-only")
    assert :ok = Registry.register(identity)
    assert {:ok, :active} = Registry.identity_status(identity.agent_id)
    assert :ok = Registry.suspend(identity.agent_id)
    assert {:ok, :suspended} = Registry.identity_status(identity.agent_id)
    assert :ok = Registry.resume(identity.agent_id)
    assert :ok = Registry.deregister(identity.agent_id)

    envelope = envelope_for(identity.agent_id)
    assert {:error, :store_unavailable} = IssuerRegistry.register(identity.agent_id, [envelope])
  end

  test "identity authority round-trips across restart and remote sync reloads the committed record",
       context do
    start_topology(context)

    {:ok, identity} = Identity.generate(name: "restart-and-sync")
    assert :ok = Registry.register(identity)

    restart_registry()
    assert {:ok, identity.public_key} == Registry.lookup(identity.agent_id)

    assert {:ok, current} =
             AuthorityStore.authoritative_get(identity.agent_id,
               name: :arbor_security_identities
             )

    replacement =
      Record.new(identity.agent_id, %{
        current.data
        | "status" => "suspended",
          "status_changed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "status_reason" => "remote"
      })

    assert {:ok, _stored} =
             AuthorityStore.acknowledged_compare_and_swap(
               identity.agent_id,
               {:value, current},
               replacement,
               name: :arbor_security_identities
             )

    send(Registry, {
      :signal_received,
      %{
        type: :identity_suspended,
        data: %{agent_id: identity.agent_id, origin_node: :remote@packet_3a}
      }
    })

    _ = :sys.get_state(Registry)
    assert {:ok, :suspended} = Registry.identity_status(identity.agent_id)
  end

  test "security regression: issuer unavailability is not absence and failed writes never succeed",
       context do
    start_topology(context)

    {:ok, identity} = Identity.generate(name: "issuer-failure")
    assert :ok = Registry.register(identity)
    envelope = envelope_for(identity.agent_id)

    fail_operations(context.control, [:get])
    assert {:error, :store_unavailable} = IssuerRegistry.register(identity.agent_id, [envelope])

    fail_operations(context.control, [])
    assert {:error, :not_found} = IssuerRegistry.lookup(identity.agent_id)

    fail_operations(context.control, [:compare_and_swap])
    assert {:error, :outcome_unknown} = IssuerRegistry.register(identity.agent_id, [envelope])

    fail_operations(context.control, [])
    assert {:error, :not_found} = IssuerRegistry.lookup(identity.agent_id)
  end

  test "issuer authority round-trips and read failures close lookup and verification", context do
    start_topology(context)

    {:ok, identity} = Identity.generate(name: "issuer-round-trip")
    assert :ok = Registry.register(identity)
    envelope = envelope_for(identity.agent_id)
    assert :ok = IssuerRegistry.register(identity.agent_id, [envelope])

    restart_issuer_registry()
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

    start_child!({Registry, []}, Registry)
    start_child!({IssuerRegistry, []}, IssuerRegistry)
  end

  defp start_authority(name, namespace, context) do
    spec =
      Supervisor.child_spec(
        {AuthorityStore,
         name: name,
         namespace: namespace,
         backend: ControlledBackend,
         backend_opts: backend_opts(context, namespace)},
        id: name
      )

    start_child!(spec, name)
  end

  defp restore_default_topology do
    TestBootstrap.restore_supervised_tree!()
  end

  defp start_child!(spec, id) do
    case Supervisor.start_child(Arbor.Security.Supervisor, spec) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, :already_present} ->
        :ok = Supervisor.delete_child(Arbor.Security.Supervisor, id)
        {:ok, _pid} = Supervisor.start_child(Arbor.Security.Supervisor, spec)
        :ok
    end
  end

  defp stop_packet_processes do
    for id <- [IssuerRegistry, Registry, :arbor_security_issuers, :arbor_security_identities] do
      case Supervisor.terminate_child(Arbor.Security.Supervisor, id) do
        :ok -> Supervisor.delete_child(Arbor.Security.Supervisor, id)
        {:error, :not_found} -> :ok
      end
    end
  end

  defp restart_registry do
    :ok = Supervisor.terminate_child(Arbor.Security.Supervisor, Registry)
    :ok = Supervisor.delete_child(Arbor.Security.Supervisor, Registry)
    start_child!({Registry, []}, Registry)
  end

  defp restart_issuer_registry do
    :ok = Supervisor.terminate_child(Arbor.Security.Supervisor, IssuerRegistry)
    :ok = Supervisor.delete_child(Arbor.Security.Supervisor, IssuerRegistry)
    start_child!({IssuerRegistry, []}, IssuerRegistry)
  end

  defp fail_operations(control, operations) do
    Agent.update(control, fn _current -> MapSet.new(operations) end)
  end

  defp backend_opts(context, namespace) do
    [base_dir: context.base_dir, name: namespace, control: context.control]
  end

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
