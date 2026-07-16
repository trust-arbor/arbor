defmodule Arbor.Actions.Coding.WorkspaceRetentionDurableStoreTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Config
  alias Arbor.Actions.Coding.WorkspaceRetentionDurableStore
  alias Arbor.Actions.Coding.WorkspaceRetentionJournalCore, as: Core
  alias Arbor.Persistence

  test "runtime aggregate exhaustion is rejected without poisoning and restart remains healthy",
       %{
         tmp_dir: tmp_dir
       } do
    root = Path.join(tmp_dir, "journal")
    name = start_store(root)

    assert :ok = put(name, "retained:ws_aggregate_a", 900_000)
    assert :ok = put(name, "retained:ws_aggregate_b", 900_000)

    assert {:error, :retention_aggregate_bytes_exceeded} =
             put(name, "retained:ws_aggregate_c", 400_000)

    assert {:ok, keys} = Persistence.list(name, WorkspaceRetentionDurableStore)
    assert length(keys) == 2

    stop_store(name)
    start_store(root, name)
    assert {:ok, keys_after_restart} = Persistence.list(name, WorkspaceRetentionDurableStore)
    assert length(keys_after_restart) == 2
  end

  test "replacement delta rejects the new value while preserving the old evidence", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "replacement-journal")
    name = start_store(root)
    key = "retained:ws_replacement"

    assert :ok = put(name, key, 100_000)
    assert :ok = put(name, "retained:ws_replacement_b", 700_000)
    assert :ok = put(name, "retained:ws_replacement_c", 700_000)

    assert {:error, :retention_aggregate_bytes_exceeded} = put(name, key, 700_000)

    assert {:ok, %{"payload" => payload}} =
             Persistence.get(name, WorkspaceRetentionDurableStore, key)

    assert byte_size(payload) == 100_000

    stop_store(name)
    start_store(root, name)

    assert {:ok, %{"payload" => payload_after_restart}} =
             Persistence.get(name, WorkspaceRetentionDurableStore, key)

    assert byte_size(payload_after_restart) == 100_000
  end

  test "rejected oversized input stays healthy and does not poison valid evidence", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "input-size")
    name = start_store(root)
    key = "retained:ws_input_size"

    assert :ok = put(name, key, 1)

    assert {:error, :value_too_large} =
             put(name, "retained:ws_input_too_large", Core.max_snapshot_bytes())

    assert {:ok, [^key]} = Persistence.list(name, WorkspaceRetentionDurableStore)
    assert {:ok, %{"payload" => "x"}} = Persistence.get(name, WorkspaceRetentionDurableStore, key)
  end

  test "security regression: caller JSON duplicate members reject without poisoning evidence", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "caller-duplicate-json")
    name = start_store(root)
    key = "retained:ws_caller_duplicate"
    valid_value = %{"payload" => "valid evidence"}
    duplicate_member_value = %{"payload" => "string member", payload: "atom member"}

    assert :ok =
             Persistence.put(name, WorkspaceRetentionDurableStore, key, valid_value)

    assert {:error, :duplicate_json_member} =
             Persistence.put(
               name,
               WorkspaceRetentionDurableStore,
               key,
               duplicate_member_value
             )

    assert {:ok, ^valid_value} = Persistence.get(name, WorkspaceRetentionDurableStore, key)
    assert {:ok, [^key]} = Persistence.list(name, WorkspaceRetentionDurableStore)

    stop_store(name)
    start_store(root, name)

    assert {:ok, ^valid_value} = Persistence.get(name, WorkspaceRetentionDurableStore, key)
  end

  test "security regression: bounded pre-serialization rejects depth, nodes, and bytes without poisoning",
       %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "input-budget")
    name = start_store(root)
    key = "retained:ws_input_budget"
    assert :ok = put(name, key, 1)

    deeply_nested = Enum.reduce(1..10, "leaf", fn _, acc -> [acc] end)
    too_many_nodes = List.duplicate(nil, Core.max_json_nodes())
    too_many_binary_bytes = %{"payload" => String.duplicate("x", Core.max_snapshot_bytes())}
    huge_integer = Bitwise.bsl(1, 4_096)

    assert {:error, :retention_structure_oversized} =
             Persistence.put(
               name,
               WorkspaceRetentionDurableStore,
               "retained:ws_deep_input",
               deeply_nested
             )

    assert {:error, :retention_structure_oversized} =
             Persistence.put(
               name,
               WorkspaceRetentionDurableStore,
               "retained:ws_many_nodes",
               too_many_nodes
             )

    assert {:error, :value_too_large} =
             Persistence.put(
               name,
               WorkspaceRetentionDurableStore,
               "retained:ws_many_bytes",
               too_many_binary_bytes
             )

    assert {:error, :numeric_value_out_of_range} =
             Persistence.put(
               name,
               WorkspaceRetentionDurableStore,
               "retained:ws_huge_integer",
               %{"retry_count" => huge_integer}
             )

    assert {:error, :encode_failed} =
             Persistence.put(
               name,
               WorkspaceRetentionDurableStore,
               "retained:ws_custom_encoder",
               DateTime.utc_now()
             )

    assert {:ok, [^key]} = Persistence.list(name, WorkspaceRetentionDurableStore)
    assert {:ok, %{"payload" => "x"}} = Persistence.get(name, WorkspaceRetentionDurableStore, key)
  end

  test "security regression: post-start create drift poisons the cached inventory", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "create-drift")
    name = start_store(root)
    assert :ok = put(name, "retained:ws_create_drift", 1)

    File.write!(Path.join(root, "retained:ws_created_outside.json"), ~s({"outside":true}))
    :ok = File.chmod(Path.join(root, "retained:ws_created_outside.json"), 0o600)

    assert {:error, {:retention_inventory_drift, _}} =
             Persistence.list(name, WorkspaceRetentionDurableStore)
  end

  test "security regression: post-start deletion is corruption, not a cache miss", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "delete-drift")
    name = start_store(root)
    key = "retained:ws_delete_drift"
    assert :ok = put(name, key, 1)
    File.rm!(Path.join(root, key <> ".json"))

    assert {:error, {:retention_inventory_drift, _}} =
             Persistence.get(name, WorkspaceRetentionDurableStore, key)
  end

  test "security regression: post-start content and raw digest drift poisons the store", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "content-drift")
    name = start_store(root)
    key = "retained:ws_content_drift"
    path = Path.join(root, key <> ".json")
    assert :ok = put(name, key, 1)
    # Preserve inode and byte length so only the raw digest/value snapshot can
    # distinguish the external mutation.
    File.write!(path, ~s({"payload":"y"}))

    assert {:error, {:retention_inventory_drift, _}} =
             Persistence.get(name, WorkspaceRetentionDurableStore, key)
  end

  test "security regression: only exact stale temp grammar is recoverable", %{tmp_dir: tmp_dir} do
    recoverable_root = Path.join(tmp_dir, "recoverable-temp")
    File.mkdir_p!(recoverable_root)
    :ok = File.chmod(recoverable_root, 0o700)

    stale =
      Path.join(
        recoverable_root,
        ".arbor-retention-tmp-" <> String.duplicate("a", 32) <> ".json"
      )

    File.write!(stale, "partial")
    recoverable_name = start_store(recoverable_root)

    assert {:ok, []} = Persistence.list(recoverable_name, WorkspaceRetentionDurableStore)
    refute File.exists?(stale)

    malformed_root = Path.join(tmp_dir, "malformed-temp")
    File.mkdir_p!(malformed_root)
    :ok = File.chmod(malformed_root, 0o700)
    malformed = Path.join(malformed_root, ".arbor-retention-tmp-not-closed.json")
    File.write!(malformed, "partial")
    malformed_name = start_store(malformed_root)

    assert {:error, {:retention_store_poisoned, :invalid_retention_inventory_filename}} =
             Persistence.list(malformed_name, WorkspaceRetentionDurableStore)

    assert File.exists?(malformed)
  end

  test "security regression: unknown inventory filenames and keys are rejected", %{
    tmp_dir: tmp_dir
  } do
    valid_name = start_store(Path.join(tmp_dir, "valid-key"))

    assert {:error, :invalid_store_key} =
             Persistence.put(valid_name, WorkspaceRetentionDurableStore, "unknown", %{})

    root = Path.join(tmp_dir, "unknown-inventory")
    File.mkdir_p!(root)
    :ok = File.chmod(root, 0o700)
    File.write!(Path.join(root, "unknown.json"), ~s({"x":1}))
    name = start_store(root)

    assert {:error, {:retention_store_poisoned, :invalid_retention_inventory_filename}} =
             Persistence.list(name, WorkspaceRetentionDurableStore)

    assert {:error, :invalid_retention_key} = Core.decode_inventory(["unknown"], %{})
  end

  test "security regression: uppercase case-colliding put preserves lowercase evidence on restart",
       %{
         tmp_dir: tmp_dir
       } do
    root = Path.join(tmp_dir, "case-collision")
    name = start_store(root)
    lowercase_key = "retained:ws_case_collision"
    uppercase_key = "retained:WS_CASE_COLLISION"
    valid_value = %{"payload" => "lowercase evidence"}

    assert String.downcase(uppercase_key) == lowercase_key
    assert {:error, :invalid_workspace_id} = Core.record_key("WS_CASE_COLLISION")
    refute Core.retained_key?(uppercase_key)

    assert :ok =
             Persistence.put(name, WorkspaceRetentionDurableStore, lowercase_key, valid_value)

    assert {:error, :invalid_store_key} =
             Persistence.put(
               name,
               WorkspaceRetentionDurableStore,
               uppercase_key,
               %{"payload" => "collision overwrite"}
             )

    assert {:ok, ^valid_value} =
             Persistence.get(name, WorkspaceRetentionDurableStore, lowercase_key)

    assert {:ok, [^lowercase_key]} =
             Persistence.list(name, WorkspaceRetentionDurableStore)

    stop_store(name)
    start_store(root, name)

    assert {:ok, ^valid_value} =
             Persistence.get(name, WorkspaceRetentionDurableStore, lowercase_key)
  end

  test "security regression: a final root symlink cannot chmod its target", %{tmp_dir: tmp_dir} do
    target = Path.join(tmp_dir, "target")
    root = Path.join(tmp_dir, "journal-link")
    File.mkdir_p!(target)
    :ok = File.chmod(target, 0o755)
    File.ln_s!(target, root)

    name = start_store(root)

    assert {:error, {:retention_store_poisoned, :root_symlink}} =
             Persistence.list(name, WorkspaceRetentionDurableStore)

    assert {:ok, %File.Stat{mode: mode}} = File.lstat(target)
    assert Bitwise.band(mode, 0o777) == 0o755
  end

  test "security regression: pre-existing insecure roots are rejected without mode repair", %{
    tmp_dir: tmp_dir
  } do
    for mode <- [0o755, 0o777] do
      root = Path.join(tmp_dir, "preexisting-#{Integer.to_string(mode, 8)}")
      File.mkdir_p!(root)
      :ok = File.chmod(root, mode)

      name = start_store(root)

      assert {:error, {:retention_store_poisoned, :root_permissions_not_private}} =
               Persistence.list(name, WorkspaceRetentionDurableStore)

      assert {:ok, %File.Stat{mode: actual_mode}} = File.lstat(root)
      assert Bitwise.band(actual_mode, 0o777) == mode
    end
  end

  test "security regression: unsafe parent is rejected without creating the journal leaf", %{
    tmp_dir: tmp_dir
  } do
    parent = Path.join(tmp_dir, "unsafe-parent")
    root = Path.join(parent, "journal")
    File.mkdir_p!(parent)
    :ok = File.chmod(parent, 0o777)

    name = start_store(root)

    assert {:error, {:retention_store_poisoned, :parent_permissions_unsafe}} =
             Persistence.list(name, WorkspaceRetentionDurableStore)

    refute File.exists?(root)
  end

  test "security regression: parent mode drift poisons the live store", %{tmp_dir: tmp_dir} do
    parent = Path.join(tmp_dir, "parent-mode-drift")
    root = Path.join(parent, "journal")
    File.mkdir_p!(parent)
    :ok = File.chmod(parent, 0o755)
    name = start_store(root)
    assert :ok = put(name, "retained:ws_parent_mode_drift", 1)

    :ok = File.chmod(parent, 0o777)

    assert {:error, :parent_permissions_changed} =
             Persistence.list(name, WorkspaceRetentionDurableStore)

    assert {:error, {:retention_store_poisoned, :parent_permissions_changed}} =
             Persistence.list(name, WorkspaceRetentionDurableStore)
  end

  test "security regression: parent identity drift poisons without writing through replacement",
       %{
         tmp_dir: tmp_dir
       } do
    parent = Path.join(tmp_dir, "parent-identity-drift")
    moved_parent = Path.join(tmp_dir, "parent-identity-original")
    root = Path.join(parent, "journal")
    replacement_root = Path.join(parent, "journal")
    File.mkdir_p!(parent)
    :ok = File.chmod(parent, 0o755)
    name = start_store(root)
    assert :ok = put(name, "retained:ws_parent_identity_drift", 1)

    :ok = File.rename(parent, moved_parent)
    File.mkdir_p!(parent)
    :ok = File.chmod(parent, 0o755)

    assert {:error, :parent_identity_changed} =
             Persistence.list(name, WorkspaceRetentionDurableStore)

    assert {:error, {:retention_store_poisoned, :parent_identity_changed}} =
             Persistence.list(name, WorkspaceRetentionDurableStore)

    refute File.exists?(replacement_root)
    assert File.exists?(Path.join(moved_parent, "journal"))
  end

  test "security regression: reload rejects a non-private record file", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "public-record")
    key = "retained:ws_public_record"
    path = Path.join(root, key <> ".json")
    File.mkdir_p!(root)
    :ok = File.chmod(root, 0o700)
    File.write!(path, ~s({"payload":"x"}))
    :ok = File.chmod(path, 0o644)

    name = start_store(root)

    assert {:error, {:retention_store_poisoned, :record_permissions_not_private}} =
             Persistence.list(name, WorkspaceRetentionDurableStore)
  end

  test "security regression: private malformed JSON reaches decoding and poisons", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "malformed-json")
    key = "retained:ws_duplicate_json"
    path = Path.join(root, key <> ".json")
    File.mkdir_p!(root)
    :ok = File.chmod(root, 0o700)
    File.write!(path, ~s({"schema_version":1,"schema_version":2}))
    :ok = File.chmod(path, 0o600)

    name = start_store(root)

    assert {:error, {:retention_store_poisoned, {:corrupt_store_entry, ^key, reason}}} =
             Persistence.list(name, WorkspaceRetentionDurableStore)

    assert reason == :duplicate_json_member
  end

  test "security regression: private manual records reach the aggregate inventory gate", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "manual-aggregate")
    File.mkdir_p!(root)
    :ok = File.chmod(root, 0o700)

    for i <- 1..3 do
      path = Path.join(root, "retained:ws_manual_aggregate_#{i}.json")
      File.write!(path, Jason.encode!(%{"payload" => String.duplicate("x", 700_000)}))
      :ok = File.chmod(path, 0o600)
    end

    name = start_store(root)

    assert {:error, {:retention_store_poisoned, :retention_aggregate_bytes_exceeded}} =
             Persistence.list(name, WorkspaceRetentionDurableStore)
  end

  test "security regression: published records have exact private mode and reload", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "private-record")
    key = "retained:ws_private_record"
    path = Path.join(root, key <> ".json")
    name = start_store(root)

    assert :ok = put(name, key, 1)
    assert {:ok, %File.Stat{type: :regular, mode: mode}} = File.lstat(path)
    assert Bitwise.band(mode, 0o777) == 0o600

    stop_store(name)
    start_store(root, name)
    assert {:ok, %{"payload" => "x"}} = Persistence.get(name, WorkspaceRetentionDurableStore, key)
  end

  test "security regression: relative journal configuration never resolves against CWD" do
    previous_path = Application.fetch_env(:arbor_actions, :workspace_retention_journal_path)
    previous_home = System.get_env("ARBOR_HOME")

    on_exit(fn ->
      case previous_path do
        {:ok, value} ->
          Application.put_env(:arbor_actions, :workspace_retention_journal_path, value)

        :error ->
          Application.delete_env(:arbor_actions, :workspace_retention_journal_path)
      end

      if previous_home == nil,
        do: System.delete_env("ARBOR_HOME"),
        else: System.put_env("ARBOR_HOME", previous_home)
    end)

    absolute_root = Path.join(System.tmp_dir!(), "absolute-retention-root")

    Application.put_env(
      :arbor_actions,
      :workspace_retention_journal_path,
      absolute_root
    )

    assert Config.workspace_retention_journal_path() == Path.expand(absolute_root)

    Application.put_env(
      :arbor_actions,
      :workspace_retention_journal_path,
      "relative/journal"
    )

    assert_raise ArgumentError, ~r/must be an absolute path/, fn ->
      Config.workspace_retention_journal_path()
    end

    Application.delete_env(:arbor_actions, :workspace_retention_journal_path)
    System.put_env("ARBOR_HOME", absolute_root)

    assert Config.workspace_retention_journal_path() ==
             Path.join(Path.expand(absolute_root), "workspace_retention")

    System.put_env("ARBOR_HOME", "relative/arbor-home")

    assert_raise ArgumentError, ~r/must be an absolute path/, fn ->
      Config.workspace_retention_journal_path()
    end

    System.delete_env("ARBOR_HOME")
    assert Path.type(Config.workspace_retention_journal_path()) == :absolute
  end

  test "security regression: loosening root permissions poisons the live store", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "mode-drift")
    name = start_store(root)
    :ok = File.chmod(root, 0o755)

    assert {:error, :root_permissions_changed} =
             Persistence.list(name, WorkspaceRetentionDurableStore)

    assert {:error, {:retention_store_poisoned, :root_permissions_changed}} =
             Persistence.list(name, WorkspaceRetentionDurableStore)
  end

  defp start_store(root, name \\ nil) do
    name = name || String.to_atom("retention_store_#{System.unique_integer([:positive])}")
    start_supervised!({WorkspaceRetentionDurableStore, name: name, path: root}, id: name)
    name
  end

  defp stop_store(name), do: :ok = stop_supervised(name)

  defp put(name, workspace_suffix, payload_size) do
    value = %{"payload" => String.duplicate("x", payload_size)}
    Persistence.put(name, WorkspaceRetentionDurableStore, workspace_suffix, value)
  end
end
