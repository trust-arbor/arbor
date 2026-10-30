defmodule Arbor.Security.TestBootstrapSupervisorOwnershipSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.SigningAuthorityBroker
  alias Arbor.Security.SystemAuthority
  alias Arbor.Security.TestBootstrap

  @supervisor Arbor.Security.Supervisor
  @capability_store :arbor_security_capabilities
  @signing_store :arbor_security_signing_keys

  setup do
    Process.flag(:trap_exit, true)
    on_exit(&TestBootstrap.restore_supervised_tree!/0)
    :ok
  end

  test "security regression: rogue signing-store pid cannot make start! succeed" do
    supervisor = Process.whereis(@supervisor)
    assert is_pid(supervisor)
    expected = Enum.reverse(TestBootstrap.canonical_start_ids())

    :ok = Supervisor.terminate_child(@supervisor, @signing_store)
    :ok = Supervisor.delete_child(@supervisor, @signing_store)

    {:ok, rogue} =
      AuthorityStore.start_link(
        name: @signing_store,
        backend: nil,
        namespace: "signing_keys",
        hydration_limit: 100
      )

    Process.unlink(rogue)
    assert Process.whereis(@signing_store) == rogue

    assert :ok = TestBootstrap.start!()
    refute Process.whereis(@signing_store) == rogue
    refute Process.alive?(rogue)

    replacement = Process.whereis(@supervisor)
    assert is_pid(replacement)
    refute replacement == supervisor
    assert observed_child_ids() == expected
    owned = supervisor_child_pid(@signing_store)
    assert is_pid(owned)
    assert Process.whereis(@signing_store) == owned
  end

  test "security regression: start! owns every canonical id by supervisor pid equality" do
    assert :ok = TestBootstrap.start!()
    canonical_ids = TestBootstrap.canonical_start_ids()

    # Assert the dependency order, not offsets from an evolving list's end.
    # Journal loss must restart its consumers; receipt loss must retire logins.
    dependency_order = [
      Arbor.Security.AuditJournalOwner,
      CapabilityStore,
      Arbor.Security.Reflex.Registry,
      Arbor.Security.DeliveryReceiptBroker,
      Arbor.Security.TerminalLogin
    ]

    assert Enum.filter(canonical_ids, &(&1 in dependency_order)) == dependency_order
    assert observed_child_ids() == Enum.reverse(canonical_ids)

    Enum.each(canonical_ids, fn id ->
      owned = supervisor_child_pid(id)
      assert is_pid(owned), "#{inspect(id)} is not a live supervisor child"
      assert Process.whereis(id) == owned
    end)

    agent_id = SystemAuthority.agent_id()
    public_key = SystemAuthority.public_key()

    assert {:ok, ^public_key} = Registry.lookup(agent_id)
    assert %{active_capabilities: active_capabilities} = CapabilityStore.stats()
    assert is_integer(active_capabilities)
    assert {:ok, %{"serving" => true}} = Arbor.Security.audit_journal_status()
  end

  test "security regression: direct SystemAuthority startup cannot deadlock or trust a squatted Registry name" do
    real_registry = Process.whereis(Registry)
    assert is_pid(real_registry)
    assert Process.unregister(Registry)

    test_pid = self()

    squatter =
      spawn(fn ->
        true = Process.register(self(), Registry)
        send(test_pid, {:identity_registry_squatter_ready, self()})
        registry_squatter_loop(test_pid)
      end)

    assert_receive {:identity_registry_squatter_ready, ^squatter}
    assert Process.whereis(Registry) == squatter

    try do
      assert :ok = Supervisor.terminate_child(@supervisor, SystemAuthority)
      assert :ok = Supervisor.delete_child(@supervisor, SystemAuthority)

      start_task =
        Task.async(fn ->
          Supervisor.start_child(@supervisor, {SystemAuthority, []})
        end)

      start_result =
        case Task.yield(start_task, 2_000) do
          {:ok, result} ->
            result

          nil ->
            Task.shutdown(start_task, :brutal_kill)
            flunk("SystemAuthority startup blocked its own supervisor")
        end

      assert {:ok, authority_pid} = start_result
      assert Process.whereis(SystemAuthority) == authority_pid

      agent_id = SystemAuthority.agent_id()
      assert {:ok, public_key} = Registry.lookup(agent_id)
      assert public_key == SystemAuthority.public_key()

      # Startup-token lookup and registration must follow Registry's
      # supervisor-owned directory pid. The process holding only the registered
      # name must receive neither request nor token.
      refute_received {:identity_registry_squatter_called, _message}
    after
      if Process.whereis(Registry) == squatter do
        Process.unregister(Registry)
      end

      if Process.alive?(squatter), do: Process.exit(squatter, :kill)
      if Process.alive?(real_registry), do: Process.register(real_registry, Registry)

      case Supervisor.terminate_child(@supervisor, SystemAuthority) do
        :ok -> :ok
        {:error, :not_found} -> :ok
      end

      case Supervisor.delete_child(@supervisor, SystemAuthority) do
        :ok -> :ok
        {:error, :not_found} -> :ok
      end

      assert :ok = TestBootstrap.restore_supervised_tree!()
      assert %{authority_count: 0} = SigningAuthorityBroker.debug_state()
    end
  end

  test "security regression: deleted-child recovery preserves reverse rest_for_one listing order" do
    assert :ok = TestBootstrap.start!()
    expected = Enum.reverse(TestBootstrap.canonical_start_ids())
    assert observed_child_ids() == expected

    :ok = Supervisor.terminate_child(@supervisor, @signing_store)
    :ok = Supervisor.delete_child(@supervisor, @signing_store)

    assert :ok = TestBootstrap.restore_supervised_tree!()
    assert observed_child_ids() == expected
    # Append-at-end would list the restored store first (OTP reverse listing).
    refute hd(observed_child_ids()) == @signing_store
  end

  test "security regression: terminated journal owner is restored under supervisor ownership" do
    supervisor = Process.whereis(@supervisor)
    assert is_pid(supervisor)
    owner = Arbor.Security.AuditJournalOwner

    assert :ok = Supervisor.terminate_child(@supervisor, owner)
    assert :ok = TestBootstrap.start!()
    assert Process.whereis(@supervisor) == supervisor
    owned = supervisor_child_pid(owner)
    assert is_pid(owned)
    assert Process.whereis(owner) == owned
  end

  test "security regression: terminated-only restore preserves supervisor pid" do
    supervisor = Process.whereis(@supervisor)
    assert is_pid(supervisor)

    for _ <- 1..5 do
      assert :ok = Supervisor.terminate_child(@supervisor, CapabilityStore)
      assert :ok = TestBootstrap.start!()
      assert Process.whereis(@supervisor) == supervisor
      assert Process.whereis(CapabilityStore) == supervisor_child_pid(CapabilityStore)
    end
  end

  test "security regression: foreign occupancy rebuilds the supervisor and restores ownership order" do
    supervisor = Process.whereis(@supervisor)
    assert is_pid(supervisor)
    expected = Enum.reverse(TestBootstrap.canonical_start_ids())

    assert :ok = Supervisor.terminate_child(@supervisor, CapabilityStore)
    assert :ok = Supervisor.terminate_child(@supervisor, @capability_store)

    {:ok, foreign_store} =
      AuthorityStore.start_link(
        name: @capability_store,
        backend: nil,
        namespace: "capabilities",
        hydration_limit: 100
      )

    {:ok, foreign_caps} = CapabilityStore.start_link([])
    Process.unlink(foreign_store)
    Process.unlink(foreign_caps)

    assert Process.whereis(@capability_store) == foreign_store
    assert Process.whereis(CapabilityStore) == foreign_caps

    assert :ok = TestBootstrap.restore_supervised_tree!()

    replacement = Process.whereis(@supervisor)
    assert is_pid(replacement)
    refute replacement == supervisor
    assert observed_child_ids() == expected
    assert Process.whereis(CapabilityStore) == supervisor_child_pid(CapabilityStore)
    assert Process.whereis(@capability_store) == supervisor_child_pid(@capability_store)
    refute Process.whereis(@capability_store) == foreign_store
    refute Process.whereis(CapabilityStore) == foreign_caps
  end

  defp observed_child_ids do
    @supervisor
    |> Supervisor.which_children()
    |> Enum.map(&elem(&1, 0))
  end

  defp supervisor_child_pid(id) do
    @supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^id, pid, _type, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
  end

  defp registry_squatter_loop(test_pid) do
    receive do
      message ->
        send(test_pid, {:identity_registry_squatter_called, message})
        registry_squatter_loop(test_pid)
    end
  end
end
