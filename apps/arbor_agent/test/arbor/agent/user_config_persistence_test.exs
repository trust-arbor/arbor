defmodule Arbor.Agent.UserConfigPersistenceTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.{IdentityAliasProof, IdentityAliases, UserConfig}
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag :tmp_dir

  setup context do
    start_store(context.tmp_dir)
    :ok
  end

  test "regression: linked identities remain visible after a cold JSON-store restart", context do
    {:ok, caller} = Arbor.Security.generate_identity()
    :ok = Arbor.Security.register_identity(caller)

    {:ok, cap} =
      Arbor.Security.grant(principal: caller.agent_id, resource: "arbor://identity/alias/manage")

    on_exit(fn ->
      Arbor.Security.revoke(cap.id)
      Arbor.Security.deregister_identity(caller.agent_id)
    end)

    primary = "human_persisted_primary"
    secondary = "human_persisted_secondary"

    {:ok, proof} = IdentityAliasProof.sign(caller, {:link, secondary, primary})
    assert :ok = IdentityAliases.link(caller.agent_id, secondary, primary, signed_request: proof)
    assert IdentityAliases.list_aliases(primary) == [secondary]

    restart_store(context.tmp_dir)

    assert IdentityAliases.resolve(secondary) == primary
    assert IdentityAliases.list_aliases(primary) == [secondary]

    {:ok, unlink_proof} = IdentityAliasProof.sign(caller, {:unlink, secondary})

    assert :ok =
             IdentityAliases.unlink(caller.agent_id, secondary, signed_request: unlink_proof)

    restart_store(context.tmp_dir)

    assert IdentityAliases.resolve(secondary) == secondary
    assert IdentityAliases.list_aliases(primary) == []
  end

  test "settings retain false and nil values after a cold JSON-store restart", context do
    assert :ok =
             UserConfig.put_many("human_settings", %{timezone: "UTC", enabled: false, name: nil})

    restart_store(context.tmp_dir)

    assert UserConfig.get("human_settings", :timezone) == "UTC"
    assert UserConfig.get("human_settings", :enabled) == false
    assert UserConfig.get("human_settings", :name) == nil
  end

  test "updating a persisted setting removes its old JSON key", context do
    assert :ok = UserConfig.put("human_settings", :timezone, "UTC")
    restart_store(context.tmp_dir)
    assert :ok = UserConfig.put("human_settings", :timezone, "America/Chicago")
    assert_single_key("human_settings", "timezone")
    restart_store(context.tmp_dir)
    assert UserConfig.get("human_settings", :timezone) == "America/Chicago"
  end

  test "put_many replaces equivalent persisted keys and preserves unrelated settings", context do
    assert :ok =
             UserConfig.put_many("human_settings", %{timezone: "UTC", default_model: "model-a"})

    restart_store(context.tmp_dir)
    assert :ok = UserConfig.put_many("human_settings", %{timezone: "America/Chicago"})
    assert_single_key("human_settings", "timezone")
    restart_store(context.tmp_dir)
    assert UserConfig.get("human_settings", :timezone) == "America/Chicago"
    assert UserConfig.get("human_settings", :default_model) == "model-a"
  end

  test "deleting a persisted setting does not leave its JSON key behind", context do
    assert :ok =
             UserConfig.put_many("human_settings", %{timezone: "UTC", default_model: "model-a"})

    restart_store(context.tmp_dir)
    assert :ok = UserConfig.delete("human_settings", :timezone)
    restart_store(context.tmp_dir)

    config = UserConfig.get_all("human_settings")
    refute Map.has_key?(config, "timezone")
    refute Map.has_key?(config, :timezone)
    assert UserConfig.get("human_settings", :default_model) == "model-a"
  end

  test "provider-key settings survive cold restart and replacement", context do
    assert :ok = UserConfig.put_api_key("human_settings", :anthropic, "test-only-key-a")
    restart_store(context.tmp_dir)
    assert UserConfig.get_api_key("human_settings", :anthropic) == "test-only-key-a"
    assert :ok = UserConfig.put_api_key("human_settings", :anthropic, "test-only-key-b")
    assert map_size(UserConfig.get("human_settings", :api_keys)) == 1
    restart_store(context.tmp_dir)
    assert UserConfig.get_api_key("human_settings", :anthropic) == "test-only-key-b"
  end

  defp assert_single_key(principal, key) do
    assert {:ok, %Record{data: data}} = BufferedStore.get(principal, name: :arbor_user_config)
    assert Enum.count(Map.keys(data), &(to_string(&1) == key)) == 1
  end

  defp restart_store(root) do
    stop_supervised!(:arbor_user_config_persistence_test)
    start_store(root)
  end

  defp start_store(root) do
    start_supervised!(
      Supervisor.child_spec(
        {BufferedStore,
         name: :arbor_user_config,
         backend: Arbor.Security.Store.JSONFile,
         backend_opts: [base_dir: root],
         write_mode: :sync,
         collection: "user_config_persistence_test"},
        id: :arbor_user_config_persistence_test
      )
    )
  end
end
