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

  # This module terminates children on the SHARED Arbor.Security.Supervisor to
  # occupy their registered names (production resolves the store by name, so
  # intercepting requires taking the name). Restoring them afterwards is
  # therefore load-bearing for every test that runs after this module.
  #
  # It previously guarded the restart on `is_nil(pid)` from which_children/1.
  # Supervisor.which_children/1 reports a TERMINATED child as `:undefined`, not
  # `nil`, so that predicate was never true and the function restarted nothing —
  # a silent no-op. Every security test scheduled after this module then failed
  # with `no process`, and because ExUnit shuffles module order by seed, the
  # suite ranged from 0 to 290 failures run to run on the same commit.
  #
  # restart_child/2 already reports {:error, :running} when a child is up, so
  # the correct shape is to call it unconditionally and treat "already running"
  # as success — no inspection, no predicate to get wrong. The final assertion
  # exists so that if restoration ever breaks again it fails HERE, loudly, in
  # the module that caused it, rather than as a cascade of unrelated failures.
  defp restore_security_children do
    stop_named_process(CapabilityStore)
    stop_named_process(@capability_store)

    Enum.each(@security_children, &restart_security_child!/1)
    assert_security_children_alive!()
  end

  defp restart_security_child!(child_id) do
    case Supervisor.restart_child(@security_supervisor, child_id) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      # Already running, or never terminated in the first place.
      {:error, :running} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      # Not a child of this supervisor in this test profile.
      {:error, :not_found} -> :ok
      {:error, reason} -> raise "failed to restore #{inspect(child_id)}: #{inspect(reason)}"
    end
  end

  defp assert_security_children_alive! do
    dead =
      Enum.filter(@security_children, fn child_id ->
        case Process.whereis(child_id) do
          nil -> child_id not in optional_children()
          pid -> not Process.alive?(pid)
        end
      end)

    if dead != [] do
      raise """
      security children left dead after this module: #{inspect(dead)}

      Every subsequent test that touches them will fail with `no process`, and
      the failure will look like it belongs to whichever module ExUnit happened
      to schedule next. Fix the restore path here.
      """
    end
  end

  # Children that may legitimately be absent depending on the test profile.
  defp optional_children do
    [
      :arbor_security_issuers,
      Arbor.Security.IssuerRegistry,
      Arbor.Security.SigningAuthorityStateOwner,
      Arbor.Security.SigningAuthorityBroker,
      Arbor.Security.DeliveryReceiptBroker
    ]
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
