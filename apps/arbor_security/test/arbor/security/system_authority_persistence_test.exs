defmodule Arbor.Security.SystemAuthorityPersistenceTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Identifiers
  alias Arbor.Security
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.Crypto
  alias Arbor.Security.SigningKeyStore
  alias Arbor.Security.SystemAuthority
  alias Arbor.Security.TestBootstrap

  @moduletag :fast
  @store_name :arbor_security_signing_keys
  @authority_signing_id "system_authority"
  @authority_metadata_key "system_authority_metadata_v2"

  defmodule ControlledBackend do
    @behaviour Arbor.Contracts.Persistence.Store

    @impl true
    def put(key, record, opts) do
      case mode(opts, :put_mode) do
        :ok -> store(opts, key, record)
        :known_failure -> {:error, :key_mismatch}
        :reject -> {:error, :backend_rejected}
        :commit_then_error -> store(opts, key, record) && {:error, :reply_lost}
      end
    end

    @impl true
    def get(key, opts) do
      case :ets.lookup(opts[:table], {:record, key}) do
        [{{:record, ^key}, record}] -> {:ok, record}
        [] -> {:error, :not_found}
      end
    end

    @impl true
    def delete(key, opts) do
      case mode(opts, :delete_mode) do
        :ok -> delete_record(opts, key)
        :reject -> {:error, :backend_rejected}
        :commit_then_error -> delete_record(opts, key) && {:error, :reply_lost}
      end
    end

    @impl true
    def list(opts) do
      keys =
        opts[:table]
        |> :ets.tab2list()
        |> Enum.flat_map(fn
          {{:record, key}, _record} when is_binary(key) -> [key]
          _other -> []
        end)

      {:ok, keys}
    end

    @impl true
    def durability_class(_opts), do: :node_restart

    defp mode(opts, key) do
      case :ets.lookup(opts[:table], key) do
        [{^key, value}] -> value
        [] -> :ok
      end
    end

    defp store(opts, key, record) do
      true = :ets.insert(opts[:table], {{:record, key}, record})
      :ok
    end

    defp delete_record(opts, key) do
      true = :ets.delete(opts[:table], {:record, key})
      :ok
    end
  end

  setup do
    table = :ets.new(:system_authority_persistence, [:set, :public])
    replace_signing_store!(table)

    fixture_root =
      Path.join(
        System.tmp_dir!(),
        "arbor_authority_v3_#{System.unique_integer([:positive])}"
      )

    master_key_path = Path.join(fixture_root, "master.key")
    previous_master_key_path = Application.get_env(:arbor_security, :master_key_path)
    previous_mode = Application.get_env(:arbor_security, :system_authority_mode)
    Application.put_env(:arbor_security, :master_key_path, master_key_path)

    on_exit(fn ->
      restore_env(:system_authority_mode, previous_mode)
      restore_env(:master_key_path, previous_master_key_path)
      stop_signing_store!()
      TestBootstrap.restore_supervised_tree!()
      remove_fixture!(fixture_root)
    end)

    {:ok, identity} = Identity.generate(name: "v3_test_authority")
    %{identity: identity, table: table}
  end

  test "security regression: acknowledged signing-key mutations never report ambiguous success",
       %{table: table} do
    {_public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    set_mode(table, :put_mode, :known_failure)

    assert {:error, :invalid_store_record} =
             SigningKeyStore.put("agent_failed_write", private_key)

    assert {:error, :not_found} =
             AuthorityStore.authoritative_get("agent_failed_write", name: @store_name)

    assert {:error, :invalid_store_record} =
             SigningKeyStore.put_keypair(
               "agent_failed_keypair_write",
               private_key,
               :crypto.strong_rand_bytes(32)
             )

    assert {:error, :not_found} =
             AuthorityStore.authoritative_get("agent_failed_keypair_write", name: @store_name)

    set_mode(table, :put_mode, :ok)
    assert :ok = SigningKeyStore.put("agent_failed_delete", private_key)

    set_mode(table, :delete_mode, :reject)
    assert {:error, :outcome_unknown} = SigningKeyStore.delete("agent_failed_delete")

    assert {:ok, %Record{}} =
             AuthorityStore.authoritative_get("agent_failed_delete", name: @store_name)
  end

  test "security regression: v3 authority bundle is one ciphertext-only record and survives store restart",
       %{identity: identity, table: table} do
    assert :ok = SystemAuthority.persist_keypair(identity)
    assert {:ok, [@authority_signing_id]} = AuthorityStore.authoritative_list(name: @store_name)

    assert {:ok, %Record{data: data}} =
             AuthorityStore.authoritative_get(@authority_signing_id, name: @store_name)

    assert %{
             "v" => 3,
             "format" => "authority_bundle",
             "ct" => ciphertext,
             "iv" => iv,
             "tag" => tag,
             "public" => public
           } = data

    assert is_binary(ciphertext) and is_binary(iv) and is_binary(tag)
    assert public["agent_id"] == identity.agent_id
    refute Map.has_key?(data, "private_key")
    refute Map.has_key?(data, "encryption_private_key")
    refute contains_private_material?(data, identity.private_key)
    refute contains_private_material?(data, identity.encryption_private_key)

    restart_signing_store!(table)

    assert {:ok, loaded} = SystemAuthority.load_persisted_keypair()
    assert loaded.agent_id == identity.agent_id
    assert loaded.private_key == identity.private_key
    assert loaded.encryption_private_key == identity.encryption_private_key

    assert {:ok, _stale_metadata} = put_legacy_metadata(identity)
    assert {:ok, preferred} = SystemAuthority.load_persisted_keypair()
    assert preferred.agent_id == identity.agent_id
  end

  test "security regression: valid legacy v2 split records migrate only after full validation",
       %{identity: identity} do
    put_legacy_split!(identity, identity)

    assert {:ok, loaded} = SystemAuthority.load_persisted_keypair()
    assert loaded.agent_id == identity.agent_id

    assert {:ok, %Record{data: %{"v" => 3, "format" => "authority_bundle"}}} =
             AuthorityStore.authoritative_get(@authority_signing_id, name: @store_name)

    assert {:error, :not_found} =
             AuthorityStore.authoritative_get(@authority_metadata_key, name: @store_name)
  end

  test "security regression: a split-write mismatch is never admitted or migrated",
       %{identity: private_identity} do
    {:ok, public_identity} = Identity.generate(name: "mismatched_public_half")
    put_legacy_split!(private_identity, public_identity)

    assert {:error, :invalid_persisted_authority} =
             SystemAuthority.load_persisted_keypair()

    assert {:ok, %Record{data: %{"v" => 2, "format" => "keypair"}}} =
             AuthorityStore.authoritative_get(@authority_signing_id, name: @store_name)
  end

  test "security regression: legacy missing halves and malformed v3 bundles fail closed",
       %{identity: identity} do
    assert {:ok, _stored} = put_legacy_metadata(identity)

    assert {:error, :metadata_without_keypair} =
             SystemAuthority.load_persisted_keypair()

    clear_authority_records!()
    assert :ok = put_legacy_private(identity)

    assert {:error, :keypair_without_metadata} =
             SystemAuthority.load_persisted_keypair()

    clear_authority_records!()

    malformed =
      Record.new(@authority_signing_id, %{
        "v" => 3,
        "format" => "authority_bundle",
        "ct" => "not-base64",
        "iv" => "not-base64",
        "tag" => "not-base64",
        "public" => %{}
      })

    assert {:ok, _stored} =
             AuthorityStore.acknowledged_put(@authority_signing_id, malformed, name: @store_name)

    assert {:error, :invalid_authority_bundle} =
             SystemAuthority.load_persisted_keypair()

    clear_authority_records!()
    assert :ok = SystemAuthority.persist_keypair(identity)

    assert {:ok, %Record{data: valid_data} = valid_record} =
             AuthorityStore.authoritative_get(@authority_signing_id, name: @store_name)

    plaintext_smuggling = %{
      valid_record
      | data: Map.put(valid_data, "private_key", Base.encode64(identity.private_key))
    }

    assert {:ok, _stored} =
             AuthorityStore.acknowledged_put(@authority_signing_id, plaintext_smuggling,
               name: @store_name
             )

    assert {:error, :invalid_authority_bundle} =
             SystemAuthority.load_persisted_keypair()

    clear_authority_records!()
    assert :ok = put_legacy_private(identity)

    malformed_metadata =
      Record.new(@authority_metadata_key, %{
        "v" => 2,
        "agent_id" => identity.agent_id,
        "public_key" => "not-base64",
        "encryption_public_key" => "not-base64",
        "name" => identity.name,
        "created_at" => "not-a-date"
      })

    assert {:ok, _stored} =
             AuthorityStore.acknowledged_put(@authority_metadata_key, malformed_metadata,
               name: @store_name
             )

    assert {:error, :invalid_persisted_authority} =
             SystemAuthority.load_persisted_keypair()
  end

  test "security regression: pre-v2 plaintext authority records remain cleanup-only" do
    plaintext =
      Record.new("system_authority_keypair", %{
        "private_key" => Base.encode64(:crypto.strong_rand_bytes(64))
      })

    assert {:ok, _stored} =
             AuthorityStore.acknowledged_put("system_authority_keypair", plaintext,
               name: @store_name
             )

    assert :ok = SystemAuthority.cleanup_legacy_plaintext_record()

    assert {:error, :not_found} =
             AuthorityStore.authoritative_get("system_authority_keypair", name: @store_name)
  end

  test "security regression: persistent rotation preserves the live root and converges unknown outcomes",
       %{identity: identity, table: table} do
    assert :ok = SystemAuthority.persist_keypair(identity)
    previous_mode = Application.get_env(:arbor_security, :system_authority_mode)
    Application.put_env(:arbor_security, :system_authority_mode, :persistent)
    restart_system_authority!()

    on_exit(fn ->
      restore_env(:system_authority_mode, previous_mode)
      restart_system_authority!()
    end)

    assert SystemAuthority.agent_id() == identity.agent_id

    set_mode(table, :put_mode, :known_failure)

    assert {:error, {:rotation_failed, :invalid_store_record}} = SystemAuthority.rotate()
    assert SystemAuthority.agent_id() == identity.agent_id

    set_mode(table, :put_mode, :reject)
    old_pid = Process.whereis(SystemAuthority)
    monitor = Process.monitor(old_pid)

    assert {:error, {:rotation_failed, :outcome_unknown}} = SystemAuthority.rotate()

    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :authority_rotation_outcome_unknown},
                   2_000

    new_pid = wait_for_new_process(SystemAuthority, old_pid)
    assert is_pid(new_pid)
    assert SystemAuthority.agent_id() == identity.agent_id

    set_mode(table, :put_mode, :commit_then_error)
    converging_pid = Process.whereis(SystemAuthority)
    converging_monitor = Process.monitor(converging_pid)

    assert {:error, {:rotation_failed, :outcome_unknown}} = SystemAuthority.rotate()

    assert_receive {:DOWN, ^converging_monitor, :process, ^converging_pid,
                    :authority_rotation_outcome_unknown},
                   2_000

    assert is_pid(wait_for_new_process(SystemAuthority, converging_pid))
    assert {:ok, committed_identity} = SigningKeyStore.get_authority_bundle(@authority_signing_id)
    assert committed_identity.agent_id != identity.agent_id
    assert SystemAuthority.agent_id() == committed_identity.agent_id
  end

  test "security regression: private memory root stamps survive restart and reject offline rewrites" do
    Application.put_env(:arbor_security, :system_authority_mode, :persistent)
    restart_system_authority!()
    {admission, descriptor, agent, _human} = private_memory_fixture!()

    assert {:ok, stamp} = Security.attest_private_memory_record(admission, descriptor)
    assert {:ok, ^stamp} = Security.attest_private_memory_record(admission, descriptor)
    assert :ok = Security.verify_private_memory_record(descriptor, stamp)

    for {key, value} <- descriptor do
      replacement =
        case value do
          value when is_binary(value) ->
            if key in ["body_digest", "vector_digest"],
              do: String.duplicate("b", 64),
              else: value <> "_changed"

          value when is_integer(value) ->
            value + 1

          false ->
            true
        end

      assert {:error, :invalid_memory_record} =
               Security.verify_private_memory_record(Map.put(descriptor, key, replacement), stamp)
    end

    payload =
      "arbor.private-memory-record.v1\0" <> agent.agent_id <> "\0" <> stamp["descriptor_digest"]

    forged = %{
      stamp
      | "issuer_id" => agent.agent_id,
        "signature" => Base.encode64(Crypto.sign(payload, agent.private_key))
    }

    assert {:error, :invalid_memory_record} =
             Security.verify_private_memory_record(descriptor, forged)

    assert {:error, :invalid_memory_record} =
             Security.attest_private_memory_record(
               admission,
               Map.put(descriptor, "human_id", "human_forged")
             )

    restart_system_authority!()
    assert :ok = Security.verify_private_memory_record(descriptor, stamp)
    assert :ok = Security.close_private_memory_admission(admission)

    assert {:error, :invalid_memory_admission} =
             Security.attest_private_memory_record(admission, descriptor)

    assert :ok = Security.verify_private_memory_record(descriptor, stamp)

    assert {:ok, _} = SystemAuthority.rotate()

    assert {:error, :invalid_memory_record} =
             Security.verify_private_memory_record(descriptor, stamp)
  end

  test "security regression: ephemeral and volatile roots refuse private stamps without changing ordinary signing" do
    Application.put_env(:arbor_security, :system_authority_mode, :ephemeral)
    restart_system_authority!()
    {admission, descriptor, _agent, _human} = private_memory_fixture!()

    assert {:error, :memory_attestation_unavailable} =
             Security.attest_private_memory_record(admission, descriptor)

    assert :ok = Security.close_private_memory_admission(admission)

    stop_signing_store!()

    {:ok, store} =
      AuthorityStore.start_link(name: @store_name, backend: nil, namespace: "signing_keys")

    Process.unlink(store)
    Application.put_env(:arbor_security, :system_authority_mode, :persistent)
    restart_system_authority!()
    {admission, descriptor, _agent, _human} = private_memory_fixture!()

    assert {:error, :memory_attestation_unavailable} =
             Security.attest_private_memory_record(admission, descriptor)

    assert :ok = Security.close_private_memory_admission(admission)
  end

  test "security regression: direct root attestation rechecks current memory capability" do
    Application.put_env(:arbor_security, :system_authority_mode, :persistent)
    restart_system_authority!()
    {admission, descriptor, agent, _human} = private_memory_fixture!()
    assert {:ok, _stamp} = SystemAuthority.attest_private_memory_record(admission, descriptor)
    assert {:ok, caps} = Security.list_capabilities(agent.agent_id)
    Enum.each(caps, &Security.revoke(&1.id))

    assert {:error, :invalid_memory_admission} =
             SystemAuthority.attest_private_memory_record(admission, descriptor)

    assert {:error, :invalid_memory_admission} =
             GenServer.call(
               SystemAuthority,
               {:attest_private_memory_record, admission, descriptor}
             )

    assert :ok = Security.close_private_memory_admission(admission)
  end

  test "security regression: root remains responsive during authorization and deadline retires worker" do
    Application.put_env(:arbor_security, :system_authority_mode, :persistent)
    restart_system_authority!()
    {admission, descriptor, _agent, _human} = private_memory_fixture!()
    previous = Application.fetch_env(:arbor_security, :private_memory_attestation_timeout_ms)
    Application.put_env(:arbor_security, :private_memory_attestation_timeout_ms, 500)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:arbor_security, :private_memory_attestation_timeout_ms, value)

        :error ->
          Application.delete_env(:arbor_security, :private_memory_attestation_timeout_ms)
      end
    end)

    registry = Process.whereis(Arbor.Security.Identity.Registry)
    parent = self()

    observer =
      spawn(fn ->
        {reference, job} = await_memory_job!()
        send(parent, {:memory_job, reference, job.worker, SystemAuthority.agent_id()})
      end)

    on_exit(fn -> if Process.alive?(observer), do: Process.exit(observer, :kill) end)
    :sys.suspend(registry)

    try do
      assert {:error, :memory_attestation_unavailable} =
               Security.attest_private_memory_record(admission, descriptor)

      assert_receive {:memory_job, reference, worker, authority_id}, 2_000
      assert is_binary(authority_id)
      refute Process.alive?(worker)
      send(SystemAuthority, {:private_memory_authorized, reference, worker, :ok})
      assert :sys.get_state(SystemAuthority).memory_attestations == %{}
      refute inspect(:sys.get_status(SystemAuthority)) =~ descriptor["human_id"]
    after
      :sys.resume(registry)
    end

    Application.put_env(:arbor_security, :private_memory_attestation_timeout_ms, 5_000)
    assert {:ok, _stamp} = Security.attest_private_memory_record(admission, descriptor)
    assert :ok = Security.close_private_memory_admission(admission)
  end

  test "security regression: caller death and root death retire pending attestation workers" do
    Application.put_env(:arbor_security, :system_authority_mode, :persistent)
    restart_system_authority!()
    {initial, descriptor, agent, human} = private_memory_fixture!()
    assert :ok = Security.close_private_memory_admission(initial)
    resource = "arbor://chat/agent/" <> agent.agent_id
    parent = self()

    for victim <- [:caller, :root] do
      assert {:ok, signed} = SignedRequest.sign(resource, human.agent_id, human.private_key)

      assert {:ok, receipt} =
               Security.authorize_and_issue_delivery_receipt(human.agent_id, resource, :chat,
                 signed_request: signed,
                 expected_resource: resource
               )

      caller =
        spawn(fn ->
          {:ok, admission} =
            Security.exchange_private_memory_receipt(receipt, agent.agent_id, human.agent_id, %{
              session_id: descriptor["session_id"],
              turn_id: descriptor["turn_id"]
            })

          :ok = Security.activate_private_memory_admission(admission, descriptor["engagement_id"])
          send(parent, {:caller_ready, self()})

          receive do
            :attest -> :ok
          end

          result = Security.attest_private_memory_record(admission, descriptor)
          send(parent, {:caller_result, result})
        end)

      assert_receive {:caller_ready, ^caller}, 5_000
      registry = Process.whereis(Arbor.Security.Identity.Registry)
      root = Process.whereis(SystemAuthority)
      :sys.suspend(registry)

      try do
        send(caller, :attest)
        {_reference, job} = await_memory_job!()
        monitor = Process.monitor(job.worker)
        Process.exit(if(victim == :caller, do: caller, else: root), :kill)
        assert_receive {:DOWN, ^monitor, :process, _worker, _reason}, 2_000
        refute_receive {:caller_result, {:ok, _stamp}}, 20
      after
        :sys.resume(registry)
        if Process.alive?(caller), do: Process.exit(caller, :kill)
      end

      if victim == :root do
        assert is_pid(wait_for_new_process(SystemAuthority, root))
        assert is_binary(SystemAuthority.agent_id())
        assert Map.get(:sys.get_state(SystemAuthority), :memory_attestations, %{}) == %{}

        # Root registration precedes rest_for_one recovery of the capability
        # store and receipt broker. Wait for the supervising callback to finish
        # before the test owner exits and fixture cleanup revokes its grants.
        children = Supervisor.which_children(Arbor.Security.Supervisor)

        for child <- [Arbor.Security.CapabilityStore, Arbor.Security.DeliveryReceiptBroker] do
          assert {^child, pid, :worker, _modules} = List.keyfind(children, child, 0)
          assert is_pid(pid) and Process.alive?(pid)
          assert Process.whereis(child) == pid
        end

        assert {:ok, _capabilities} = Security.list_capabilities(agent.agent_id)
      end
    end
  end

  defp await_memory_job!(attempts \\ 200)
  defp await_memory_job!(0), do: flunk("private memory authorization worker did not start")

  defp await_memory_job!(attempts) do
    case Map.to_list(Map.get(:sys.get_state(SystemAuthority), :memory_attestations, %{})) do
      [job] ->
        job

      [] ->
        Process.sleep(5)
        await_memory_job!(attempts - 1)
    end
  end

  defp private_memory_fixture! do
    settings = [
      identity_verification: true,
      policy_enforcer_enabled: false,
      approval_guard_enabled: false,
      reflex_checking_enabled: false,
      uri_registry_enforcement: false
    ]

    previous =
      for {key, value} <- settings do
        old = Application.fetch_env(:arbor_security, key)
        Application.put_env(:arbor_security, key, value)
        {key, old}
      end

    human =
      Arbor.Security.OIDCTestHelper.issue_identity(
        subject: Identifiers.generate_id("memory_root_")
      )

    assert :ok = Security.register_oidc_identity(human.identity, human.id_token, human.provider)
    assert {:ok, agent} = Identity.generate(name: "private-memory-root-test")
    assert :ok = Security.register_identity(Identity.public_only(agent))
    resource = "arbor://chat/agent/" <> agent.agent_id

    caps =
      for {principal, uri} <- [
            {human.identity.agent_id, resource},
            {agent.agent_id, "arbor://memory/write/" <> agent.agent_id}
          ] do
        assert {:ok, cap} = Security.grant(principal: principal, resource: uri)
        cap
      end

    on_exit(fn ->
      Enum.each(caps, &Security.revoke(&1.id))
      human.cleanup.()
      Security.deregister_identity(human.identity.agent_id)
      Security.deregister_identity(agent.agent_id)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_security, key, value)
        {key, :error} -> Application.delete_env(:arbor_security, key)
      end)
    end)

    assert {:ok, signed} =
             SignedRequest.sign(resource, human.identity.agent_id, human.identity.private_key)

    assert {:ok, receipt} =
             Security.authorize_and_issue_delivery_receipt(
               human.identity.agent_id,
               resource,
               :chat,
               signed_request: signed,
               expected_resource: resource
             )

    context = %{
      session_id: Identifiers.generate_id("session_"),
      turn_id: Identifiers.generate_id("turn_")
    }

    assert {:ok, admission} =
             Security.exchange_private_memory_receipt(
               receipt,
               agent.agent_id,
               human.identity.agent_id,
               context
             )

    assert :ok = Security.activate_private_memory_admission(admission, "engagement_private")

    descriptor = %{
      "agent_id" => agent.agent_id,
      "human_id" => human.identity.agent_id,
      "engagement_id" => "engagement_private",
      "session_id" => context.session_id,
      "turn_id" => context.turn_id,
      "id" => "private_memory_record",
      "source_namespace" => "private_memory_namespace",
      "source_key" => "private_memory_key",
      "body_digest" => String.duplicate("a", 64),
      "vector_digest" => String.duplicate("c", 64),
      "model_id" => "test-model",
      "dimensions" => 3,
      "encoding" => "ieee754_float32_be_v1",
      "category" => "conversation",
      "generation" => 1,
      "revision" => 1,
      "tombstone" => false
    }

    {admission, descriptor, agent, human.identity}
  end

  test "private transcript source uses a distinct persisted-root purpose and later indexing retains original scope" do
    Application.put_env(:arbor_security, :system_authority_mode, :persistent)
    restart_system_authority!()
    {admission, record, agent, human} = private_memory_fixture!()
    {source, record} = source_descriptors(record)
    assert {:ok, stamp} = Security.attest_private_memory_source(admission, source)
    assert {:ok, ^stamp} = Security.attest_private_memory_source(admission, source)
    assert :ok = Security.verify_private_memory_source(source, stamp)
    assert {:error, _} = Security.verify_private_memory_record(record, stamp)
    assert :ok = Security.close_private_memory_admission(admission)
    restart_system_authority!()
    assert :ok = Security.verify_private_memory_source(source, stamp)

    fresh = source_admission!(agent, human)
    assert {:error, _} = Security.attest_private_memory_source(fresh, source)
    assert {:error, _} = Security.attest_private_memory_record(fresh, record)

    assert {:ok, record_stamp} =
             Security.attest_private_memory_record_from_source(fresh, record, source, stamp)

    assert :ok = Security.verify_private_memory_record(record, record_stamp)
    assert {:error, _} = Security.verify_private_memory_source(source, record_stamp)
    assert :ok = Security.close_private_memory_admission(fresh)
  end

  test "direct root source APIs require exact caller, content binding and current capability checks" do
    Application.put_env(:arbor_security, :system_authority_mode, :persistent)
    restart_system_authority!()
    {admission, record, agent, _human} = private_memory_fixture!()
    {source, record} = source_descriptors(record)
    assert {:ok, stamp} = Security.attest_private_memory_source(admission, source)

    copied = Task.async(fn -> SystemAuthority.attest_private_memory_source(admission, source) end)
    assert {:error, _} = Task.await(copied)

    assert {:error, _} =
             SystemAuthority.attest_private_memory_source(
               admission,
               Map.put(source, "human_id", "human_forged")
             )

    for changed <- [
          Map.put(record, "body_digest", String.duplicate("b", 64)),
          Map.put(record, "engagement_id", "engagement_forged")
        ] do
      assert {:error, _} =
               SystemAuthority.attest_private_memory_record_from_source(
                 admission,
                 changed,
                 source,
                 stamp
               )
    end

    assert {:error, _} =
             SystemAuthority.attest_private_memory_record_from_source(
               admission,
               record,
               source,
               Map.put(stamp, "signature", Base.encode64(<<0::512>>))
             )

    assert {:ok, _} =
             SystemAuthority.attest_private_memory_record_from_source(
               admission,
               record,
               source,
               stamp
             )

    assert {:ok, caps} = Arbor.Security.CapabilityStore.list_for_principal(agent.agent_id)

    for cap <- caps,
        cap.resource_uri == "arbor://memory/write/" <> agent.agent_id do
      assert :ok = Security.revoke(cap.id)
    end

    assert {:error, _} = SystemAuthority.attest_private_memory_source(admission, source)

    assert {:error, _} =
             SystemAuthority.attest_private_memory_record_from_source(
               admission,
               record,
               source,
               stamp
             )

    # Historical verification remains valid; it grants no current admission.
    assert :ok = Security.verify_private_memory_source(source, stamp)
  end

  defp source_descriptors(record) do
    alias Arbor.Contracts.Persistence.VectorRecord
    scope = Map.take(record, ~w(agent_id human_id engagement_id session_id turn_id))
    source_id = "session_turn:" <> scope["turn_id"]
    {:ok, pair_hash} = VectorRecord.payload_digest([scope["agent_id"], scope["human_id"]])

    {:ok, row_hash} =
      VectorRecord.payload_digest([scope["agent_id"], scope["human_id"], source_id])

    body = %{
      "content" => "User: source text\nAssistant: source answer",
      "metadata" => %{"type" => "conversation"},
      "source_id" => source_id,
      "conversation_scope" => scope
    }

    {:ok, body_digest} = VectorRecord.payload_digest(body)

    source =
      Map.merge(scope, %{
        "source_id" => source_id,
        "id" => "private_mem_" <> row_hash,
        "source_namespace" => "private_conversation_" <> pair_hash,
        "source_key" => "private_mem_" <> row_hash,
        "body_digest" => body_digest,
        "user_role" => "user",
        "assistant_role" => "assistant",
        "user_content_digest" =>
          Base.encode16(:crypto.hash(:sha256, "source text"), case: :lower),
        "assistant_content_digest" =>
          Base.encode16(:crypto.hash(:sha256, "source answer"), case: :lower)
      })

    {source, Map.merge(record, Map.take(source, Map.keys(record)))}
  end

  defp source_admission!(agent, human) do
    resource = "arbor://chat/agent/" <> agent.agent_id
    assert {:ok, signed} = SignedRequest.sign(resource, human.agent_id, human.private_key)

    assert {:ok, receipt} =
             Security.authorize_and_issue_delivery_receipt(human.agent_id, resource, :chat,
               signed_request: signed,
               expected_resource: resource
             )

    assert {:ok, admission} =
             Security.exchange_private_memory_receipt(receipt, agent.agent_id, human.agent_id, %{
               session_id: Identifiers.generate_id("session_"),
               turn_id: Identifiers.generate_id("turn_")
             })

    assert :ok = Security.activate_private_memory_admission(admission, "engagement_later")
    admission
  end

  defp put_legacy_split!(private_identity, public_identity) do
    assert :ok = put_legacy_private(private_identity)
    assert {:ok, _stored} = put_legacy_metadata(public_identity)
  end

  defp put_legacy_private(identity) do
    SigningKeyStore.put_keypair(
      @authority_signing_id,
      identity.private_key,
      identity.encryption_private_key
    )
  end

  defp put_legacy_metadata(identity) do
    data = %{
      "v" => 2,
      "agent_id" => identity.agent_id,
      "public_key" => Base.encode64(identity.public_key),
      "encryption_public_key" => Base.encode64(identity.encryption_public_key),
      "name" => identity.name,
      "created_at" => DateTime.to_iso8601(identity.created_at)
    }

    AuthorityStore.acknowledged_put(
      @authority_metadata_key,
      Record.new(@authority_metadata_key, data),
      name: @store_name
    )
  end

  defp clear_authority_records! do
    assert :ok = AuthorityStore.acknowledged_delete(@authority_signing_id, name: @store_name)
    assert :ok = AuthorityStore.acknowledged_delete(@authority_metadata_key, name: @store_name)
  end

  defp contains_private_material?(value, private_key) do
    encoded = Base.encode64(private_key)

    value
    |> nested_values()
    |> Enum.any?(fn candidate -> candidate == private_key or candidate == encoded end)
  end

  defp nested_values(map) when is_map(map),
    do: Enum.flat_map(map, fn {key, value} -> [key | nested_values(value)] end)

  defp nested_values(list) when is_list(list), do: Enum.flat_map(list, &nested_values/1)
  defp nested_values(value), do: [value]

  defp set_mode(table, key, value) do
    true = :ets.insert(table, {key, value})
    :ok
  end

  defp replace_signing_store!(table) do
    stop_signing_store!()

    case AuthorityStore.start_link(
           name: @store_name,
           backend: ControlledBackend,
           backend_opts: [table: table],
           namespace: "signing_keys",
           hydration_limit: 100
         ) do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, reason} ->
        raise "failed to start controlled signing store: #{inspect(reason)}"
    end
  end

  defp restart_signing_store!(table), do: replace_signing_store!(table)

  defp stop_signing_store! do
    case Supervisor.terminate_child(Arbor.Security.Supervisor, @store_name) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    case Supervisor.delete_child(Arbor.Security.Supervisor, @store_name) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, :running} -> raise "signing store remained running"
    end

    case Process.whereis(@store_name) do
      pid when is_pid(pid) -> GenServer.stop(pid, :normal, 5_000)
      nil -> :ok
    end
  end

  defp restart_system_authority! do
    case Supervisor.terminate_child(Arbor.Security.Supervisor, SystemAuthority) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    case Supervisor.restart_child(Arbor.Security.Supervisor, SystemAuthority) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
      {:error, reason} -> raise "failed to restart SystemAuthority: #{inspect(reason)}"
    end
  end

  defp wait_for_new_process(name, old_pid, attempts \\ 100)
  defp wait_for_new_process(_name, _old_pid, 0), do: nil

  defp wait_for_new_process(name, old_pid, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        Process.sleep(20)
        wait_for_new_process(name, old_pid, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_security, key, value)

  defp remove_fixture!(fixture_root) do
    tmp_root = Path.expand(System.tmp_dir!())
    expanded = Path.expand(fixture_root)

    unless Path.dirname(expanded) == tmp_root and
             String.starts_with?(Path.basename(expanded), "arbor_authority_v3_") do
      raise "refusing to remove invalid authority fixture"
    end

    case File.rm_rf(expanded) do
      {:ok, _removed} -> :ok
      {:error, reason, _path} -> raise "failed to remove authority fixture: #{inspect(reason)}"
    end
  end
end
