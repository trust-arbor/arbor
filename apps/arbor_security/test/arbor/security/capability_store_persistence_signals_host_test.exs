defmodule Arbor.Security.CapabilityStorePersistenceSignalsHostTest do
  use ExUnit.Case, async: false

  @security_supervisor Arbor.Security.Supervisor
  @capability_store :arbor_security_capabilities

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Config
  alias Arbor.Security.Store.JSONFile
  alias Arbor.Security.TestBootstrap
  alias Arbor.Common.SafePath
  alias Arbor.Signals

  @tag :fast
  test "security regression: remote replacement revocation removes durable projection" do
    principal_id = "agent_capability_store_remote_revoke_regression"
    resource_uri = "arbor://fs/read/capability-store-remote-revoke-regression"
    backend_dir = unique_tmp_dir("capability-store-remote-revoke")

    previous_distributed_signals =
      Application.get_env(:arbor_capabilities, :distributed_signals)

    Application.put_env(:arbor_capabilities, :distributed_signals, true)
    ensure_signals_children!()

    configure_isolated_json_store(backend_dir)

    # Register after the store cleanup so the canonical CapabilityStore is
    # restored with the suite's original distributed-signals configuration.
    on_exit(fn ->
      restore_security_env(:distributed_signals, previous_distributed_signals)
    end)

    assert {:ok, original} =
             Security.grant_fixture(principal: principal_id, resource: resource_uri)

    assert {:ok, :authorized} =
             Security.authorize(principal_id, resource_uri, nil, verify_identity: false)

    signal =
      Signals.build_signal_fixture(:security, :capability_revoked, %{
        capability_ids: [original.id],
        principal_id: principal_id,
        origin_node: :remote_capability_store_test@localhost
      })

    assert :ok =
             Signals.receive_relay_batch_fixture(
               [signal],
               :remote_capability_store_test@localhost
             )

    assert eventually(fn -> Security.list_capabilities(principal_id) == {:ok, []} end)

    assert {:ok, []} = Security.list_capabilities(principal_id)

    assert {:error, :unauthorized} =
             Security.authorize(principal_id, resource_uri, nil, verify_identity: false)

    assert {:error, :not_found} =
             AuthorityStore.authoritative_get(original.id, name: @capability_store)

    restart_capability_store()

    assert {:ok, []} = Security.list_capabilities(principal_id)

    assert {:error, :not_found} =
             AuthorityStore.authoritative_get(original.id, name: @capability_store)
  end

  # P3 public admission proof on the default durable JSONFile backend.
  # Store-layer causal ABA evidence: JSONFileDurableCasTest (P2) and pre-P2
  # baseline 4582ec8de9acb2280109b76c6d797d8872240a2d. This test adds the
  # public facade + AuthorityStore + CapabilityStore dual-restart path.

  defp configure_isolated_json_store(tmp_dir, backend \\ JSONFile) do
    on_exit(&restore_security_children/0)

    remove_security_child!(CapabilityStore)
    remove_security_child!(@capability_store)
    start_capability_authority_store!(tmp_dir, backend)
    start_capability_store!()
  end

  defp restart_capability_store do
    remove_security_child!(CapabilityStore)
    start_capability_store!()
  end

  # Full recreate of both test-owned processes so residual ETS cannot pass a
  # durability assertion. Same isolated JSON directory is re-attached.

  defp start_capability_authority_store!(backend_dir, backend \\ JSONFile) do
    spec =
      Supervisor.child_spec(
        {AuthorityStore,
         name: @capability_store,
         backend: backend,
         backend_opts: [base_dir: absolute_test_root(backend_dir)],
         namespace: "capabilities",
         hydration_limit: Config.max_global_capabilities(),
         mutation_owners: [CapabilityStore],
         defer_hydration: true},
        id: @capability_store
      )

    {:ok, pid} = Supervisor.start_child(@security_supervisor, spec)
    {:ok, timeout} = Config.startup_timeout_ms(Config.max_global_capabilities())

    :ok =
      AuthorityStore.complete_startup(
        security_supervisor_pid!(),
        @capability_store,
        timeout
      )

    pid
  end

  defp start_capability_store! do
    {:ok, pid} = Supervisor.start_child(@security_supervisor, {CapabilityStore, []})
    :ok = CapabilityStore.complete_startup(security_supervisor_pid!())
    pid
  end

  defp absolute_test_root(dir) when is_binary(dir) do
    if Path.type(dir) == :absolute, do: dir, else: Path.expand(dir)
  end

  defp unique_tmp_dir(label) do
    {:ok, canonical_tmp} = SafePath.resolve_real(System.tmp_dir!())
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    dir = Path.join(canonical_tmp, "#{label}-#{suffix}")
    :ok = File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Isolation tests occupy supervisor-owned names. Restore through TestBootstrap
  # so success requires supervisor pid equality, not name occupancy.
  defp restore_security_children do
    try do
      remove_security_child!(CapabilityStore)
      remove_security_child!(@capability_store)
    after
      TestBootstrap.restore_supervised_tree!()
    end
  end

  defp remove_security_child!(id) do
    supervisor = security_supervisor_pid!()

    case Supervisor.terminate_child(supervisor, id) do
      :ok ->
        :ok = Supervisor.delete_child(supervisor, id)

      {:error, :not_found} ->
        :ok
    end

    case Process.whereis(id) do
      pid when is_pid(pid) -> GenServer.stop(pid)
      nil -> :ok
    end
  end

  defp security_supervisor_pid! do
    case Process.whereis(@security_supervisor) do
      pid when is_pid(pid) -> pid
      nil -> raise "Security.Supervisor is unavailable"
    end
  end

  defp ensure_signals_children! do
    :ok = Signals.restore_runtime_fixture()
    on_exit(fn -> :ok = Signals.restore_runtime_fixture() end)
    :ok
  end

  defp restore_security_env(key, nil), do: Application.delete_env(:arbor_capabilities, key)

  defp restore_security_env(key, value),
    do: Application.put_env(:arbor_capabilities, key, value)

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when is_function(fun, 0) and attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
