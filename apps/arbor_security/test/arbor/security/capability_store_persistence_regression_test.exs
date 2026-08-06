defmodule Arbor.Security.CapabilityStorePersistenceRegressionTest.DeleteFailingJSONFile do
  @behaviour Arbor.Contracts.Persistence.Store

  alias Arbor.Security.Store.JSONFile

  @delete_failures_key {__MODULE__, :delete_failures}
  @put_failures_key {__MODULE__, :put_failures}

  def fail_deletes(count) when is_integer(count) and count >= 0 do
    :persistent_term.put(@delete_failures_key, count)
  end

  def fail_puts(count) when is_integer(count) and count >= 0 do
    :persistent_term.put(@put_failures_key, count)
  end

  def clear do
    :persistent_term.erase(@delete_failures_key)
    :persistent_term.erase(@put_failures_key)
  end

  @impl true
  def put(key, record, opts \\ []) do
    case :persistent_term.get(@put_failures_key, 0) do
      count when count > 0 ->
        :persistent_term.put(@put_failures_key, count - 1)
        {:error, :injected_put_failure}

      _ ->
        JSONFile.put(key, record, opts)
    end
  end

  @impl true
  def get(key, opts \\ []), do: JSONFile.get(key, opts)

  @impl true
  def delete(key, opts \\ []) do
    case :persistent_term.get(@delete_failures_key, 0) do
      count when count > 0 ->
        :persistent_term.put(@delete_failures_key, count - 1)
        {:error, :injected_delete_failure}

      _ ->
        JSONFile.delete(key, opts)
    end
  end

  @impl true
  def list(opts \\ []), do: JSONFile.list(opts)

  @impl true
  def exists?(key, opts \\ []), do: JSONFile.exists?(key, opts)
end

defmodule Arbor.Security.CapabilityStorePersistenceRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @security_supervisor Arbor.Security.Supervisor
  @capability_store :arbor_security_capabilities

  @security_children [
    :arbor_security_capabilities,
    :arbor_security_identities,
    :arbor_security_signing_keys,
    :arbor_security_issuers,
    Arbor.Security.Identity.Registry,
    Arbor.Security.IssuerRegistry,
    Arbor.Security.Identity.NonceCache,
    Arbor.Security.SystemAuthority,
    Arbor.Security.SigningAuthorityStateOwner,
    Arbor.Security.SigningAuthorityBroker,
    Arbor.Security.Constraint.RateLimiter,
    Arbor.Security.CapabilityStore,
    Arbor.Security.Reflex.Registry,
    Arbor.Security.DeliveryReceiptBroker
  ]

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence.BufferedStore
  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Store.JSONFile
  alias Arbor.Security.CapabilityStorePersistenceRegressionTest.DeleteFailingJSONFile

  test "security regression: replacement removes the superseded JSON record" do
    principal_id = "agent_capability_store_persistence_regression"
    resource_uri = "arbor://fs/read/capability-store-persistence-regression"

    backend_dir = Path.join("var", "capability-store-regression-#{unique_integer()}")
    tmp_dir = Path.expand(backend_dir, File.cwd!())

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    configure_isolated_json_store(backend_dir)

    assert {:ok, original} = Security.grant(principal: principal_id, resource: resource_uri)

    assert {:ok, 1} = CapabilityStore.increment_usage(original.id)

    assert {:ok, :authorized} =
             Security.authorize(principal_id, resource_uri, nil, verify_identity: false)

    assert {:ok, %Record{}} =
             BufferedStore.authoritative_get(original.id, name: @capability_store)

    assert {:ok, replacement} = Security.grant(principal: principal_id, resource: resource_uri)
    assert original.id != replacement.id

    state = :sys.get_state(CapabilityStore)
    assert replacement.id in Map.get(state.by_issuer, replacement.issuer_id, [])
    refute original.id in Map.get(state.by_issuer, original.issuer_id, [])
    refute Map.has_key?(state.by_usage, original.id)

    assert {:ok, listed} = Security.list_capabilities(principal_id)
    assert [%{id: replacement_id}] = listed
    assert replacement_id == replacement.id

    assert {:ok, :authorized} =
             Security.authorize(principal_id, resource_uri, nil, verify_identity: false)

    assert {:error, :not_found} =
             BufferedStore.authoritative_get(original.id, name: @capability_store)

    assert {:ok, %Record{}} =
             BufferedStore.authoritative_get(replacement.id, name: @capability_store)

    restart_capability_store()

    assert {:ok, [%{id: ^replacement_id}]} = Security.list_capabilities(principal_id)

    assert {:ok, :authorized} =
             Security.authorize(principal_id, resource_uri, nil, verify_identity: false)

    assert {:error, :not_found} =
             BufferedStore.authoritative_get(original.id, name: @capability_store)

    assert {:ok, %Record{}} =
             BufferedStore.authoritative_get(replacement.id, name: @capability_store)
  end

  test "security regression: failed replacement compensates durable state" do
    principal_id = "agent_capability_store_compensation_regression"
    resource_uri = "arbor://fs/read/capability-store-compensation-regression"
    backend_dir = Path.join("var", "capability-store-compensation-#{unique_integer()}")
    tmp_dir = Path.expand(backend_dir, File.cwd!())

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    on_exit(&DeleteFailingJSONFile.clear/0)

    configure_isolated_json_store(backend_dir, DeleteFailingJSONFile)

    assert {:ok, original} = Security.grant(principal: principal_id, resource: resource_uri)
    original_id = original.id

    DeleteFailingJSONFile.fail_deletes(1)

    assert {:error, {:capability_replacement_failed, :outcome_unknown}} =
             Security.grant(principal: principal_id, resource: resource_uri)

    assert {:ok, [%{id: ^original_id}]} = Security.list_capabilities(principal_id)

    assert {:ok, [^original_id]} =
             BufferedStore.authoritative_list(name: @capability_store)
  end

  test "security regression: same-id replacement compensation retains restored record" do
    principal_id = "agent_capability_store_same_id_regression"
    resource_uri = "arbor://fs/read/capability-store-same-id-regression"
    backend_dir = Path.join("var", "capability-store-same-id-#{unique_integer()}")
    tmp_dir = Path.expand(backend_dir, File.cwd!())

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    on_exit(&DeleteFailingJSONFile.clear/0)

    configure_isolated_json_store(backend_dir, DeleteFailingJSONFile)

    assert {:ok, original} = Security.grant(principal: principal_id, resource: resource_uri)
    original_id = original.id
    DeleteFailingJSONFile.fail_puts(1)

    assert {:error, {:capability_replacement_failed, :outcome_unknown}} =
             CapabilityStore.put(original)

    assert {:ok, [%{id: ^original_id}]} = Security.list_capabilities(principal_id)

    assert {:ok, %Record{}} =
             BufferedStore.authoritative_get(original_id, name: @capability_store)
  end

  test "security regression: unknown replacement compensation never reports success" do
    principal_id = "agent_capability_store_unknown_outcome_regression"
    resource_uri = "arbor://fs/read/capability-store-unknown-outcome-regression"
    backend_dir = Path.join("var", "capability-store-unknown-#{unique_integer()}")
    tmp_dir = Path.expand(backend_dir, File.cwd!())

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    on_exit(&DeleteFailingJSONFile.clear/0)

    configure_isolated_json_store(backend_dir, DeleteFailingJSONFile)

    assert {:ok, original} = Security.grant(principal: principal_id, resource: resource_uri)
    original_id = original.id

    DeleteFailingJSONFile.fail_deletes(2)

    result = Security.grant(principal: principal_id, resource: resource_uri)
    assert {:error, {:capability_replacement_outcome_unknown, details}} = result
    assert details.original == :outcome_unknown

    assert {:ok, persisted_ids} = BufferedStore.authoritative_list(name: @capability_store)
    assert original_id in persisted_ids
    assert length(persisted_ids) == 2
  end

  test "security regression: remote replacement revocation removes durable projection" do
    principal_id = "agent_capability_store_remote_revoke_regression"
    resource_uri = "arbor://fs/read/capability-store-remote-revoke-regression"
    backend_dir = Path.join("var", "capability-store-remote-revoke-#{unique_integer()}")
    tmp_dir = Path.expand(backend_dir, File.cwd!())

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    configure_isolated_json_store(backend_dir)

    assert {:ok, original} = Security.grant(principal: principal_id, resource: resource_uri)

    assert {:ok, :authorized} =
             Security.authorize(principal_id, resource_uri, nil, verify_identity: false)

    send(
      CapabilityStore,
      {:signal_received,
       %{
         type: :capability_revoked,
         data: %{
           capability_ids: [original.id],
           principal_id: principal_id,
           origin_node: "remote-capability-store-test@localhost"
         }
       }}
    )

    :sys.get_state(CapabilityStore)

    assert {:ok, []} = Security.list_capabilities(principal_id)

    assert {:error, :unauthorized} =
             Security.authorize(principal_id, resource_uri, nil, verify_identity: false)

    assert {:error, :not_found} =
             BufferedStore.authoritative_get(original.id, name: @capability_store)

    restart_capability_store()

    assert {:ok, []} = Security.list_capabilities(principal_id)

    assert {:error, :not_found} =
             BufferedStore.authoritative_get(original.id, name: @capability_store)
  end

  defp configure_isolated_json_store(tmp_dir, backend \\ JSONFile) do
    on_exit(&restore_security_children/0)

    :ok = Supervisor.terminate_child(@security_supervisor, CapabilityStore)
    :ok = Supervisor.terminate_child(@security_supervisor, @capability_store)

    {:ok, _pid} =
      BufferedStore.start_link(
        name: @capability_store,
        backend: backend,
        backend_opts: [base_dir: tmp_dir],
        write_mode: :sync,
        ack_mode: :backend,
        collection: "capabilities"
      )

    {:ok, _pid} = CapabilityStore.start_link([])
  end

  defp restart_capability_store do
    stop_named_process(CapabilityStore)
    {:ok, _pid} = CapabilityStore.start_link([])
  end

  defp restore_security_children do
    stop_named_process(CapabilityStore)
    stop_named_process(@capability_store)

    Enum.each(@security_children, fn child_id ->
      case Supervisor.which_children(@security_supervisor) do
        children when is_list(children) ->
          if Enum.any?(children, fn {id, pid, _type, _modules} ->
               id == child_id and is_nil(pid)
             end) do
            {:ok, _pid} = Supervisor.restart_child(@security_supervisor, child_id)
          end

        _ ->
          :ok
      end
    end)
  end

  defp stop_named_process(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp unique_integer, do: :erlang.unique_integer([:positive])
end
