defmodule Arbor.Security.SystemAuthorityPersistenceTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.AuthorityStore
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
