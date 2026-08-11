defmodule Arbor.Security.CapabilityStoreRestoreTest do
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
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Persistence.BufferedStore
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.CapabilityStore.Serializer
  alias Arbor.Security.Config
  alias Arbor.Security.Store.JSONFile
  alias Arbor.Security.TestBootstrap

  setup do
    Process.flag(:trap_exit, true)
    on_exit(&restore_security_children/0)
    :ok
  end

  test "restores latest granted_at winner for exact principal/resource pair" do
    dir = unique_dir("restore-latest")
    older = build_cap("cap_old", "agent_restore_latest", "arbor://fs/read/restore-latest", -120)
    newer = build_cap("cap_new", "agent_restore_latest", "arbor://fs/read/restore-latest", -60)

    seed_caps!(dir, [older, newer])
    start_isolated_stack!(dir)

    assert {:ok, restored} = CapabilityStore.get("cap_new")
    assert restored.id == "cap_new"
    assert {:error, :not_found} = CapabilityStore.get("cap_old")

    assert_durable_ids!(dir, ["cap_old", "cap_new"])
  end

  test "uses capability id as deterministic granted_at tie-breaker" do
    dir = unique_dir("restore-tie")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    a =
      build_cap("cap_tie_a", "agent_restore_tie", "arbor://fs/read/restore-tie", 0,
        granted_at: now
      )

    b =
      build_cap("cap_tie_b", "agent_restore_tie", "arbor://fs/read/restore-tie", 0,
        granted_at: now
      )

    seed_caps!(dir, [a, b])
    start_isolated_stack!(dir)

    # id DESC: "cap_tie_b" > "cap_tie_a"
    assert {:ok, %{id: "cap_tie_b"}} = CapabilityStore.get("cap_tie_b")
    assert {:error, :not_found} = CapabilityStore.get("cap_tie_a")
    assert_durable_ids!(dir, ["cap_tie_a", "cap_tie_b"])
  end

  test "expired latest does not revive an older grant; durable unchanged" do
    dir = unique_dir("restore-expired")

    older =
      build_cap("cap_alive", "agent_restore_expired", "arbor://fs/read/restore-expired", -300)

    latest_expired =
      build_cap("cap_expired", "agent_restore_expired", "arbor://fs/read/restore-expired", -30,
        expires_at: DateTime.add(DateTime.utc_now(), -10, :second)
      )

    seed_caps!(dir, [older, latest_expired])
    start_isolated_stack!(dir)

    assert {:error, :not_found} = CapabilityStore.get("cap_alive")
    assert {:error, :not_found} = CapabilityStore.get("cap_expired")
    assert_durable_ids!(dir, ["cap_alive", "cap_expired"])

    stats = CapabilityStore.stats()
    assert stats.restore_expired >= 1
    assert stats.restore_active == 0
  end

  test "restored global quota violation fails closed without registering" do
    dir = unique_dir("restore-global-quota")
    original = Application.get_env(:arbor_security, :max_global_capabilities)

    on_exit(fn ->
      restore_env(:max_global_capabilities, original)
    end)

    Application.put_env(:arbor_security, :max_global_capabilities, 1)

    caps =
      for i <- 1..2 do
        build_cap(
          "cap_gq_#{i}",
          "agent_restore_gq_#{i}",
          "arbor://fs/read/restore-gq-#{i}",
          -60
        )
      end

    seed_caps!(dir, caps)
    release_capability_stack_for_isolation!()

    {:ok, _} =
      BufferedStore.start_link(
        name: @capability_store,
        backend: JSONFile,
        backend_opts: [base_dir: dir],
        write_mode: :sync,
        ack_mode: :backend,
        collection: "capabilities",
        # Hydration must succeed so restore can fail on quota, not inventory.
        hydration_limit: 100
      )

    assert {:error, {:capability_restore_failed, :restored_global_quota_exceeded}} =
             CapabilityStore.start_link([])

    assert Process.whereis(CapabilityStore) == nil
    assert_durable_ids!(dir, Enum.map(caps, & &1.id))
  end

  test "restored per-principal quota violation fails closed without registering" do
    dir = unique_dir("restore-per-quota")
    original = Application.get_env(:arbor_security, :max_capabilities_per_agent)

    on_exit(fn ->
      restore_env(:max_capabilities_per_agent, original)
    end)

    Application.put_env(:arbor_security, :max_capabilities_per_agent, 1)

    caps =
      for i <- 1..2 do
        build_cap(
          "cap_pq_#{i}",
          "agent_restore_pq",
          "arbor://fs/read/restore-pq-#{i}",
          -60
        )
      end

    seed_caps!(dir, caps)
    release_capability_stack_for_isolation!()

    {:ok, _} =
      BufferedStore.start_link(
        name: @capability_store,
        backend: JSONFile,
        backend_opts: [base_dir: dir],
        write_mode: :sync,
        ack_mode: :backend,
        collection: "capabilities",
        hydration_limit: Config.max_global_capabilities()
      )

    assert {:error, {:capability_restore_failed, :restored_per_principal_quota_exceeded}} =
             CapabilityStore.start_link([])

    assert Process.whereis(CapabilityStore) == nil
    assert_durable_ids!(dir, Enum.map(caps, & &1.id))
  end

  test "restored delegation-depth quota violation fails closed without registering" do
    dir = unique_dir("restore-depth-quota")
    original = Application.get_env(:arbor_security, :max_delegation_depth)

    on_exit(fn ->
      restore_env(:max_delegation_depth, original)
    end)

    Application.put_env(:arbor_security, :max_delegation_depth, 1)

    cap =
      build_cap(
        "cap_depth_quota",
        "agent_restore_depth_quota",
        "arbor://fs/read/restore-depth-quota",
        -60,
        delegation_depth: 2
      )

    seed_caps!(dir, [cap])
    release_capability_stack_for_isolation!()

    {:ok, _} =
      BufferedStore.start_link(
        name: @capability_store,
        backend: JSONFile,
        backend_opts: [base_dir: dir],
        write_mode: :sync,
        ack_mode: :backend,
        collection: "capabilities",
        hydration_limit: Config.max_global_capabilities()
      )

    assert {:error, {:capability_restore_failed, :restored_delegation_depth_exceeded}} =
             CapabilityStore.start_link([])

    assert Process.whereis(CapabilityStore) == nil
    assert_durable_ids!(dir, [cap.id])
  end

  test "restart selects deterministic authorizing capability among multiple matches" do
    dir = unique_dir("restore-find-order")
    principal = "agent_restore_find_order"
    target = "arbor://fs/read/project/docs"

    older =
      build_cap("cap_broad_old", principal, "arbor://fs/read/**", -120,
        constraints: %{"mode" => "older_constraints"}
      )

    newer =
      build_cap("cap_broad_new", principal, "arbor://fs/**", -30,
        constraints: %{"mode" => "newer_constraints"}
      )

    # Seed in reverse recency so durable iteration order is not already newest-first.
    seed_caps!(dir, [older, newer])
    start_isolated_stack!(dir)

    assert {:ok, selected_before} = CapabilityStore.find_authorizing(principal, target)
    assert selected_before.id == "cap_broad_new"
    assert selected_before.constraints["mode"] == "newer_constraints"

    # Full BufferedStore + CapabilityStore recreate (no residual ETS).
    # release_capability_stack_for_isolation!/0 stops test-owned instances when
    # supervisor children are already terminated.
    start_isolated_stack!(dir)

    assert {:ok, selected_after} = CapabilityStore.find_authorizing(principal, target)
    assert selected_after.id == "cap_broad_new"
    assert selected_after.constraints["mode"] == "newer_constraints"

    # Principal index itself is recency-desc (matches live prepend semantics).
    state = :sys.get_state(CapabilityStore)
    assert ["cap_broad_new", "cap_broad_old"] = Map.fetch!(state.by_principal, principal)

    assert_durable_ids!(dir, ["cap_broad_old", "cap_broad_new"])
  end

  test "malformed granted_at fails closed without registering" do
    dir = unique_dir("restore-malformed")
    File.mkdir_p!(Path.expand(Path.join(dir, "capabilities"), File.cwd!()))

    path =
      Path.expand(Path.join([dir, "capabilities", "cap_bad.json"]), File.cwd!())

    File.write!(
      path,
      Jason.encode!(%{
        "data" => %{
          "id" => "cap_bad",
          "principal_id" => "agent_restore_bad",
          "resource_uri" => "arbor://fs/read/restore-bad",
          "granted_at" => "not-a-datetime",
          "delegation_depth" => 0,
          "constraints" => %{},
          "metadata" => %{},
          "delegation_chain" => []
        },
        "metadata" => %{}
      })
    )

    release_capability_stack_for_isolation!()

    {:ok, _} =
      BufferedStore.start_link(
        name: @capability_store,
        backend: JSONFile,
        backend_opts: [base_dir: dir],
        write_mode: :sync,
        ack_mode: :backend,
        collection: "capabilities",
        hydration_limit: Config.max_global_capabilities()
      )

    assert {:error, {:capability_restore_failed, :invalid_capability_record}} =
             CapabilityStore.start_link([])

    assert Process.whereis(CapabilityStore) == nil
  end

  test "malformed not_before fails closed without dropping future-use restriction or durable data" do
    dir = unique_dir("restore-malformed-not-before")
    File.mkdir_p!(Path.expand(Path.join(dir, "capabilities"), File.cwd!()))

    path =
      Path.expand(Path.join([dir, "capabilities", "cap_nb_bad.json"]), File.cwd!())

    durable =
      %{
        "data" => %{
          "id" => "cap_nb_bad",
          "principal_id" => "agent_restore_nb_bad",
          "resource_uri" => "arbor://fs/read/restore-nb-bad",
          "granted_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "not_before" => "not-a-datetime",
          "delegation_depth" => 0,
          "constraints" => %{},
          "metadata" => %{},
          "delegation_chain" => []
        },
        "metadata" => %{}
      }

    File.write!(path, Jason.encode!(durable))
    before_bytes = File.read!(path)

    release_capability_stack_for_isolation!()

    {:ok, _} =
      BufferedStore.start_link(
        name: @capability_store,
        backend: JSONFile,
        backend_opts: [base_dir: dir],
        write_mode: :sync,
        ack_mode: :backend,
        collection: "capabilities",
        hydration_limit: Config.max_global_capabilities()
      )

    # Serializer would map malformed not_before to nil; restore must fail-stop
    # instead of admitting an unsigned cap with the restriction removed.
    assert {:error, {:capability_restore_failed, :invalid_capability_record}} =
             CapabilityStore.start_link([])

    assert Process.whereis(CapabilityStore) == nil
    assert_migrated_durable_payload!(dir, "cap_nb_bad", before_bytes)
    assert_durable_ids!(dir, ["cap_nb_bad"])
  end

  test "security regression: malformed issuer_signature fails closed without dropping signature" do
    dir = unique_dir("restore-malformed-sig")
    File.mkdir_p!(Path.expand(Path.join(dir, "capabilities"), File.cwd!()))
    path = Path.expand(Path.join([dir, "capabilities", "cap_sig_bad.json"]), File.cwd!())

    # Non-nil non-hex signature would be lossily decoded to nil by Serializer.
    durable = %{
      "data" => %{
        "id" => "cap_sig_bad",
        "principal_id" => "agent_restore_sig_bad",
        "resource_uri" => "arbor://fs/read/restore-sig-bad",
        "granted_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "delegation_depth" => 0,
        "issuer_signature" => "not-valid-hex!!",
        "constraints" => %{},
        "metadata" => %{},
        "delegation_chain" => []
      },
      "metadata" => %{}
    }

    File.write!(path, Jason.encode!(durable))
    before_bytes = File.read!(path)

    release_capability_stack_for_isolation!()

    {:ok, _} =
      BufferedStore.start_link(
        name: @capability_store,
        backend: JSONFile,
        backend_opts: [base_dir: dir],
        write_mode: :sync,
        ack_mode: :backend,
        collection: "capabilities",
        hydration_limit: Config.max_global_capabilities()
      )

    assert {:error, {:capability_restore_failed, :invalid_capability_record}} =
             CapabilityStore.start_link([])

    assert Process.whereis(CapabilityStore) == nil
    assert_migrated_durable_payload!(dir, "cap_sig_bad", before_bytes)
    assert_durable_ids!(dir, ["cap_sig_bad"])
  end

  test "security regression: malformed delegation_chain fails closed without emptying chain" do
    dir = unique_dir("restore-malformed-chain")
    File.mkdir_p!(Path.expand(Path.join(dir, "capabilities"), File.cwd!()))
    path = Path.expand(Path.join([dir, "capabilities", "cap_chain_bad.json"]), File.cwd!())

    # Non-list chain would be lossily coerced to [] by Serializer, stripping
    # delegation history and changing authorization shape after restart.
    durable = %{
      "data" => %{
        "id" => "cap_chain_bad",
        "principal_id" => "agent_restore_chain_bad",
        "resource_uri" => "arbor://fs/read/restore-chain-bad",
        "granted_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "delegation_depth" => 1,
        "parent_capability_id" => "cap_parent",
        "delegation_chain" => "not-a-list",
        "constraints" => %{},
        "metadata" => %{}
      },
      "metadata" => %{}
    }

    File.write!(path, Jason.encode!(durable))
    before_bytes = File.read!(path)

    release_capability_stack_for_isolation!()

    {:ok, _} =
      BufferedStore.start_link(
        name: @capability_store,
        backend: JSONFile,
        backend_opts: [base_dir: dir],
        write_mode: :sync,
        ack_mode: :backend,
        collection: "capabilities",
        hydration_limit: Config.max_global_capabilities()
      )

    assert {:error, {:capability_restore_failed, :invalid_capability_record}} =
             CapabilityStore.start_link([])

    assert Process.whereis(CapabilityStore) == nil
    assert_migrated_durable_payload!(dir, "cap_chain_bad", before_bytes)
    assert_durable_ids!(dir, ["cap_chain_bad"])
  end

  test "security regression: non-map constraints fail closed (Serializer would error/lossy default)" do
    dir = unique_dir("restore-malformed-constraints")
    File.mkdir_p!(Path.expand(Path.join(dir, "capabilities"), File.cwd!()))
    path = Path.expand(Path.join([dir, "capabilities", "cap_constraints_bad.json"]), File.cwd!())

    durable = %{
      "data" => %{
        "id" => "cap_constraints_bad",
        "principal_id" => "agent_restore_constraints_bad",
        "resource_uri" => "arbor://fs/read/restore-constraints-bad",
        "granted_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "delegation_depth" => 0,
        "constraints" => "not-a-map",
        "metadata" => %{},
        "delegation_chain" => []
      },
      "metadata" => %{}
    }

    File.write!(path, Jason.encode!(durable))
    before_bytes = File.read!(path)

    release_capability_stack_for_isolation!()

    {:ok, _} =
      BufferedStore.start_link(
        name: @capability_store,
        backend: JSONFile,
        backend_opts: [base_dir: dir],
        write_mode: :sync,
        ack_mode: :backend,
        collection: "capabilities",
        hydration_limit: Config.max_global_capabilities()
      )

    assert {:error, {:capability_restore_failed, :invalid_capability_record}} =
             CapabilityStore.start_link([])

    assert Process.whereis(CapabilityStore) == nil
    assert_migrated_durable_payload!(dir, "cap_constraints_bad", before_bytes)
    assert_durable_ids!(dir, ["cap_constraints_bad"])
  end

  test "security regression: malformed max_uses fails closed instead of resetting its limit" do
    dir = unique_dir("restore-malformed-max-uses")

    cap =
      build_cap(
        "cap_max_uses_bad",
        "agent_restore_max_uses_bad",
        "arbor://fs/read/restore-max-uses-bad",
        -60
      )

    data = cap |> Serializer.serialize() |> Map.put("max_uses", "3")

    assert :ok =
             JSONFile.put(
               cap.id,
               Record.new(cap.id, data),
               name: "capabilities",
               base_dir: dir
             )

    release_capability_stack_for_isolation!()

    {:ok, _} =
      BufferedStore.start_link(
        name: @capability_store,
        backend: JSONFile,
        backend_opts: [base_dir: dir],
        write_mode: :sync,
        ack_mode: :backend,
        collection: "capabilities",
        hydration_limit: Config.max_global_capabilities()
      )

    assert {:error, {:capability_restore_failed, :invalid_capability_record}} =
             CapabilityStore.start_link([])

    assert Process.whereis(CapabilityStore) == nil
    assert_durable_ids!(dir, [cap.id])
  end

  test "security regression: parent without chain fails closed (incoherent delegation)" do
    dir = unique_dir("restore-incoherent-chain")
    File.mkdir_p!(Path.expand(Path.join(dir, "capabilities"), File.cwd!()))
    path = Path.expand(Path.join([dir, "capabilities", "cap_incoherent.json"]), File.cwd!())

    durable = %{
      "data" => %{
        "id" => "cap_incoherent",
        "principal_id" => "agent_restore_incoherent",
        "resource_uri" => "arbor://fs/read/restore-incoherent",
        "granted_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "delegation_depth" => 1,
        "parent_capability_id" => "cap_parent",
        "delegation_chain" => [],
        "constraints" => %{},
        "metadata" => %{}
      },
      "metadata" => %{}
    }

    File.write!(path, Jason.encode!(durable))
    before_bytes = File.read!(path)

    release_capability_stack_for_isolation!()

    {:ok, _} =
      BufferedStore.start_link(
        name: @capability_store,
        backend: JSONFile,
        backend_opts: [base_dir: dir],
        write_mode: :sync,
        ack_mode: :backend,
        collection: "capabilities",
        hydration_limit: Config.max_global_capabilities()
      )

    assert {:error, {:capability_restore_failed, :invalid_capability_record}} =
             CapabilityStore.start_link([])

    assert Process.whereis(CapabilityStore) == nil
    assert_migrated_durable_payload!(dir, "cap_incoherent", before_bytes)
  end

  test "failed hydration prevents CapabilityStore startup and grants" do
    dir = unique_dir("restore-hydration-fail")

    caps =
      for i <- 1..10_001 do
        build_cap(
          "cap_hf_#{i}",
          "agent_restore_hf_#{i}",
          "arbor://fs/read/restore-hf-#{i}",
          -60
        )
      end

    seed_caps!(dir, caps)
    release_capability_stack_for_isolation!()

    # Default hydration_limit 10_000 overflows.
    {:ok, _} =
      BufferedStore.start_link(
        name: @capability_store,
        backend: JSONFile,
        backend_opts: [base_dir: dir],
        write_mode: :sync,
        ack_mode: :backend,
        collection: "capabilities"
      )

    assert {:ok, %{status: :failed, reason: :inventory_limit_exceeded}} =
             BufferedStore.hydration_status(name: @capability_store)

    assert {:error, {:capability_restore_failed, :inventory_limit_exceeded}} =
             CapabilityStore.start_link([])

    # Availability probes only check whereis — process must not remain registered.
    assert Process.whereis(CapabilityStore) == nil

    assert catch_exit(
             CapabilityStore.put(
               build_cap(
                 "cap_after_fail",
                 "agent_after_fail",
                 "arbor://fs/read/after-fail",
                 0
               )
             )
           )
  end

  test "test bootstrap restarts an already-present terminated security child" do
    assert :ok = Supervisor.terminate_child(@security_supervisor, CapabilityStore)
    assert Process.whereis(CapabilityStore) == nil

    assert :ok = TestBootstrap.start!()
    assert is_pid(Process.whereis(CapabilityStore))
  end

  defp build_cap(id, principal, resource, granted_offset_seconds, opts \\ []) do
    granted_at =
      Keyword.get(
        opts,
        :granted_at,
        DateTime.add(DateTime.utc_now(), granted_offset_seconds, :second)
      )

    expires_at = Keyword.get(opts, :expires_at)
    constraints = Keyword.get(opts, :constraints, %{})
    delegation_depth = Keyword.get(opts, :delegation_depth, 0)

    {:ok, cap} =
      Capability.new(
        id: id,
        principal_id: principal,
        resource_uri: resource,
        granted_at: granted_at,
        expires_at: expires_at,
        constraints: constraints,
        delegation_depth: delegation_depth
      )

    cap
  end

  defp seed_caps!(dir, caps) do
    File.mkdir_p!(Path.expand(dir, File.cwd!()))

    Enum.each(caps, fn cap ->
      record = Record.new(cap.id, Serializer.serialize(cap))
      assert :ok = JSONFile.put(cap.id, record, name: "capabilities", base_dir: dir)
    end)
  end

  defp start_isolated_stack!(dir) do
    release_capability_stack_for_isolation!()

    {:ok, _} =
      BufferedStore.start_link(
        name: @capability_store,
        backend: JSONFile,
        backend_opts: [base_dir: dir],
        write_mode: :sync,
        ack_mode: :backend,
        collection: "capabilities",
        hydration_limit: Config.max_global_capabilities()
      )

    assert {:ok, _pid} = CapabilityStore.start_link([])
  end

  # Initial detach must use Supervisor.terminate_child so permanent children
  # cannot race-restart under the registered names. Only after detach (or when
  # the names are held by prior test-owned start_link processes) may we stop by name.
  defp release_capability_stack_for_isolation! do
    case Supervisor.terminate_child(@security_supervisor, CapabilityStore) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> raise "failed to detach CapabilityStore: #{inspect(reason)}"
    end

    stop_named_process(CapabilityStore)

    case Supervisor.terminate_child(@security_supervisor, @capability_store) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> raise "failed to detach #{@capability_store}: #{inspect(reason)}"
    end

    stop_named_process(@capability_store)

    :ok
  end

  defp assert_durable_ids!(dir, expected_ids) do
    assert {:ok, keys} = JSONFile.list(name: "capabilities", base_dir: dir)
    assert Enum.sort(keys) == Enum.sort(expected_ids)
  end

  defp assert_migrated_durable_payload!(dir, key, legacy_bytes) do
    legacy = Jason.decode!(legacy_bytes)
    legacy_path = Path.expand(Path.join([dir, "capabilities", key <> ".json"]), File.cwd!())

    refute File.exists?(legacy_path)

    assert {:ok, %Record{} = record} =
             JSONFile.get(key, name: "capabilities", base_dir: dir)

    assert record.id == key
    assert record.key == key
    assert record.data == legacy["data"]
    assert record.metadata == Map.get(legacy, "metadata", %{})
    assert record.generation == 1
    assert record.revision == 1
    assert is_nil(record.inserted_at)
    assert %DateTime{} = record.updated_at
  end

  defp unique_dir(label) do
    rel = Path.join("var", "capability-store-#{label}-#{:erlang.unique_integer([:positive])}")
    abs = Path.expand(rel, File.cwd!())
    File.mkdir_p!(abs)
    on_exit(fn -> File.rm_rf!(abs) end)
    rel
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_security, key, value)

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
      {:error, :running} -> :ok
      {:error, {:already_started, _pid}} -> :ok
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
      raise "security children left dead after this module: #{inspect(dead)}"
    end
  end

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
end
