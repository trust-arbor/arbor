defmodule Arbor.Security.SigningKeyAccessSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-002,SSEC-014"

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.MasterKeyAccessOwner
  alias Arbor.Security.OIDC.TokenCacheOwner
  alias Arbor.Security.SigningKeyStore
  alias Arbor.Security.SigningKeyStore.Owner
  alias Arbor.Security.SigningAuthorityBroker
  alias Arbor.Security.SigningAuthorityStateOwner
  alias Arbor.Security.Store.RecordAuthenticator

  @tag spec: "SSEC-002,SSEC-014"
  test "security regression: an arbitrary caller cannot load another principal's private key" do
    assert {:ok, identity} = Identity.generate(name: "private-key-boundary")
    assert :ok = Security.store_signing_key_fixture(identity.agent_id, identity.private_key)

    on_exit(fn -> Security.delete_signing_key_fixture(identity.agent_id) end)

    assert {:ok, :available} = Security.signing_key_status(identity.agent_id)
    assert {:error, :unauthorized} = Security.load_signing_key(identity.agent_id)
  end

  test "security regression: arbitrary processes cannot use master-key or key-mutation oracles" do
    assert {:ok, identity} = Identity.generate(name: "key-owner-boundary")
    parent = self()

    spawn(fn ->
      results = %{
        authenticate: SigningKeyStore.authenticate_with_master(:authority_record, "chosen"),
        verify: SigningKeyStore.verify_with_master(:authority_record, "chosen", <<0::256>>),
        seal: RecordAuthenticator.seal(%{"chosen" => true}, :authority_record, []),
        put: SigningKeyStore.put(identity.agent_id, identity.private_key),
        put_keypair: SigningKeyStore.put_keypair(identity.agent_id, identity.private_key, nil),
        delete: SigningKeyStore.delete(identity.agent_id),
        encrypt: SigningKeyStore.encrypt_with_master(:oidc_token_cache, "chosen"),
        decrypt:
          SigningKeyStore.decrypt_with_master(
            :oidc_token_cache,
            <<0>>,
            <<0::96>>,
            <<0::128>>
          )
      }

      send(parent, {:oracle_results, results})
    end)

    assert_receive {:oracle_results, results}
    assert results.authenticate == {:error, :master_key_access_unauthorized}
    assert results.verify == {:error, :master_key_access_unauthorized}
    assert results.seal == {:error, :record_authentication_unavailable}
    assert results.put == {:error, :key_mutation_unauthorized}
    assert results.put_keypair == {:error, :key_mutation_unauthorized}
    assert results.delete == {:error, :key_mutation_unauthorized}
    assert results.encrypt == {:error, :master_key_access_unauthorized}
    assert results.decrypt == {:error, :master_key_access_unauthorized}

    assert :ok = Security.store_signing_key_fixture(identity.agent_id, identity.private_key)
    assert {:ok, :available} = Security.signing_key_status(identity.agent_id)
    assert :ok = Security.delete_signing_key_fixture(identity.agent_id)
  end

  test "security regression: forged privileged from PID cannot read or mutate signing keys" do
    assert {:ok, identity} = Identity.generate(name: "raw-key-owner-forgery")
    assert :ok = Security.store_signing_key_fixture(identity.agent_id, identity.private_key)

    on_exit(fn -> Security.delete_signing_key_fixture(identity.agent_id) end)

    owner = Process.whereis(Owner)
    root = Process.whereis(Arbor.Security.SystemAuthority)
    assert is_pid(owner)
    assert is_pid(root)

    assert {:error, :key_mutation_unauthorized} =
             forged_call(owner, root, {:get, identity.agent_id})

    assert {:error, :key_mutation_unauthorized} =
             forged_call(owner, root, {:delete_authority_record, identity.agent_id})

    assert {:ok, :available} = Security.signing_key_status(identity.agent_id)
  end

  test "security regression: state replacement cannot seize signing-key owner roles" do
    assert {:ok, identity} = Identity.generate(name: "key-owner-state-replacement")
    assert :ok = Security.store_signing_key_fixture(identity.agent_id, identity.private_key)

    on_exit(fn -> Security.delete_signing_key_fixture(identity.agent_id) end)

    owner = Process.whereis(Owner)
    attacker = self()
    assert is_pid(owner)
    original_state = :sys.get_state(owner)

    assert Map.keys(original_state) |> Enum.sort() == [
             :authenticated_calls,
             :role_custody,
             :security_supervisor_pid
           ]

    assert %{private_state: custody} = original_state.role_custody
    assert :ets.info(custody, :owner) == owner
    assert :ets.info(custody, :protection) == :private
    assert_raise ArgumentError, fn -> :ets.tab2list(custody) end

    hostile = :ets.new(__MODULE__, [:set, :private])

    true =
      :ets.insert(
        hostile,
        {:signing_key_owner_role_custody_v1,
         %{
           bindings: %{system_authority: attacker},
           role_principals: %{},
           role_specs: %{
             system_authority: %{
               application: :arbor_security,
               path: [Owner],
               registered_name: Owner,
               purposes: []
             }
           }
         }}
      )

    try do
      :sys.replace_state(owner, fn state ->
        %{state | role_custody: %{private_state: hostile}}
      end)

      assert {:error, :unauthorized} = Owner.get(identity.agent_id)
      assert Process.alive?(owner)
    after
      :sys.replace_state(owner, fn _state -> original_state end)
      :ets.delete(hostile)
    end

    assert :ok = Security.store_signing_key_fixture(identity.agent_id, identity.private_key)
    assert {:ok, :available} = Security.signing_key_status(identity.agent_id)
    assert Process.alive?(owner)
  end

  test "security regression: store state exposes no master-key token and forged caller is denied" do
    store = Process.whereis(:arbor_security_capabilities)
    owner = Process.whereis(MasterKeyAccessOwner)
    assert is_pid(store)
    assert is_pid(owner)

    store_state = :sys.get_state(store)
    refute Map.has_key?(store_state, :backend_opts)
    assert %{private_state: _custody} = store_state.backend_custody

    assert {:error, :master_key_access_unauthorized} =
             forged_call(owner, store, {:authenticate, make_ref(), :authority_record, "chosen"})
  end

  test "security regression: broker state exposes no owner token and forged caller is denied" do
    broker = Process.whereis(SigningAuthorityBroker)
    owner = Process.whereis(SigningAuthorityStateOwner)
    assert is_pid(broker)
    assert is_pid(owner)

    assert %{private_state: _custody} = :sys.get_state(broker)
    refute Map.has_key?(:sys.get_state(broker), :state_owner_token)

    assert {:error, :unauthorized} = forged_call(owner, broker, {:load, make_ref()})
  end

  test "security regression: registered-name takeover cannot impersonate key owners" do
    assert {:ok, identity} = Identity.generate(name: "key-owner-name-takeover")

    assert_name_takeover_denied(Owner, fn ->
      assert {:error, :key_mutation_unauthorized} =
               SigningKeyStore.put(identity.agent_id, identity.private_key)
    end)

    assert_name_takeover_denied(MasterKeyAccessOwner, fn ->
      assert {:error, :master_key_access_unauthorized} =
               SigningKeyStore.authenticate_with_master(:authority_record, "chosen")
    end)
  end

  test "security regression: ETS owner-directory squatting cannot impersonate supervised owners" do
    assert {:ok, identity} = Identity.generate(name: "key-owner-table-squatting")

    assert_directory_squatting_denied(
      Owner,
      :arbor_security_signing_key_store_owner_directory,
      fn ->
        refute Owner.owner_process?()

        assert {:error, :key_mutation_unauthorized} =
                 SigningKeyStore.put_from_owner(identity.agent_id, identity.private_key)
      end
    )

    assert_directory_squatting_denied(
      MasterKeyAccessOwner,
      :arbor_security_master_key_access_owner_directory,
      fn ->
        refute MasterKeyAccessOwner.owner_process?()

        assert {:error, :master_key_access_unauthorized} =
                 SigningKeyStore.authenticate_with_master(:authority_record, "chosen")
      end
    )

    assert_directory_squatting_denied(
      TokenCacheOwner,
      :arbor_security_oidc_token_cache_owner_directory,
      fn ->
        refute TokenCacheOwner.owner_process?()

        assert {:error, :master_key_access_unauthorized} =
                 SigningKeyStore.encrypt_with_master(:oidc_token_cache, "chosen")
      end
    )
  end

  defp assert_name_takeover_denied(name, assertion) do
    original = Process.whereis(name)
    assert is_pid(original)
    assert Process.unregister(name)

    parent = self()

    attacker =
      spawn(fn ->
        receive do
          :run ->
            result =
              try do
                assertion.()
                :passed
              rescue
                error -> {:failed, Exception.message(error)}
              catch
                kind, reason -> {:failed, {kind, reason}}
              end

            send(parent, {:takeover_result, self(), result})

            receive do
              :stop -> :ok
            end
        end
      end)

    assert Process.register(attacker, name)
    send(attacker, :run)

    result =
      receive do
        {:takeover_result, ^attacker, result} -> result
      after
        1_000 -> :timeout
      end

    assert Process.unregister(name)
    assert Process.register(original, name)
    send(attacker, :stop)
    assert result == :passed
  end

  defp assert_directory_squatting_denied(child_id, directory, assertion) do
    supervisor = Process.whereis(Arbor.Security.Supervisor)
    assert is_pid(supervisor)
    assert :ok = Supervisor.terminate_child(supervisor, child_id)

    table = :ets.new(directory, [:named_table, :protected, :set])
    true = :ets.insert(table, {:owner, self()})

    try do
      assertion.()
    after
      if :ets.whereis(directory) != :undefined and :ets.info(directory, :owner) == self(),
        do: :ets.delete(directory)

      case Supervisor.restart_child(supervisor, child_id) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, :running} -> :ok
      end
    end
  end

  defp forged_call(server, asserted_pid, message) do
    reply = :erlang.alias()
    tag = [:alias | reply]
    send(server, {:"$gen_call", {asserted_pid, tag}, message})

    try do
      receive do
        {^tag, result} -> result
      after
        2_000 -> flunk("forged signing-key owner call did not settle")
      end
    after
      :erlang.unalias(reply)
    end
  end
end
