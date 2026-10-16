defmodule Arbor.Actions.Coding.WorkspaceRetentionJournalCoreTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.Coding.WorkspaceRetentionJournalCore, as: Core
  alias Arbor.Actions.Config

  @moduletag :fast

  test "decode_inventory keeps more than 256 live retained records" do
    count = Core.max_records() + 1
    {keys, values} = inventory_of(count, expires_at: future_iso())

    assert {:ok, records} = Core.decode_inventory(keys, values)
    assert length(records) == count
    assert Enum.all?(records, &(Core.restore_decision(&1) == :restore))
  end

  test "compact_inventory drops expired evidence and keeps every live retained record" do
    now = ~U[2026-10-15 00:00:00Z]
    live_count = Core.max_records() + 3

    {_live_keys, live_values} =
      inventory_of(live_count, expires_at: DateTime.to_iso8601(DateTime.add(now, 3600, :second)))

    {_expired_keys, expired_values} =
      inventory_of(4,
        expires_at: DateTime.to_iso8601(DateTime.add(now, -60, :second)),
        offset: 900
      )

    records =
      (Map.values(live_values) ++ Map.values(expired_values))
      |> Enum.map(fn value ->
        assert {:ok, record} = Core.decode_record(value)
        record
      end)

    assert function_exported?(Core, :compact_inventory, 2)

    assert {:ok, %{kept: kept, dropped: dropped}} =
             Core.compact_inventory(records, now: now)

    assert length(kept) == live_count
    assert length(dropped) == 4

    assert Enum.all?(kept, fn record ->
             {:ok, expires, _} = DateTime.from_iso8601(record.expires_at)
             DateTime.compare(expires, now) == :gt
           end)

    assert Enum.all?(dropped, fn record ->
             {:ok, expires, _} = DateTime.from_iso8601(record.expires_at)
             DateTime.compare(expires, now) != :gt
           end)
  end

  test "write-side max records is configurable up to the inventory ceiling" do
    previous = Application.get_env(:arbor_actions, :workspace_retention_max_records)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:arbor_actions, :workspace_retention_max_records)
      else
        Application.put_env(:arbor_actions, :workspace_retention_max_records, previous)
      end
    end)

    Application.delete_env(:arbor_actions, :workspace_retention_max_records)
    assert Config.workspace_retention_max_records() == Core.max_records()

    raised = Core.max_records() + 10
    Application.put_env(:arbor_actions, :workspace_retention_max_records, raised)
    assert Config.workspace_retention_max_records() == raised

    Application.put_env(
      :arbor_actions,
      :workspace_retention_max_records,
      Core.inventory_record_ceiling() + 50
    )

    assert Config.workspace_retention_max_records() == Core.inventory_record_ceiling()
  end

  defp inventory_of(count, opts) when is_integer(count) and count > 0 do
    expires_at = Keyword.fetch!(opts, :expires_at)
    offset = Keyword.get(opts, :offset, 0)

    Enum.reduce(1..count, {[], %{}}, fn i, {keys, values} ->
      index = offset + i
      workspace_id = "ws_cap_#{index}"
      {:ok, key} = Core.record_key(workspace_id)
      {keys ++ [key], Map.put(values, key, fixture_record(index, workspace_id, expires_at))}
    end)
  end

  defp fixture_record(index, workspace_id, expires_at) do
    worktree_path = "/tmp/arbor-retention-cap/worktree-#{index}"

    %{
      "schema_version" => Core.schema_version(),
      "workspace_id" => workspace_id,
      "task_id" => nil,
      "principal_id" => nil,
      "repo_path" => "/tmp/arbor-retention-cap/repo-#{index}",
      "worktree_path" => worktree_path,
      "display_worktree_path" => worktree_path,
      "branch" => "cap-#{index}",
      "base_commit" => "abc#{index}",
      "ownership" => "owned",
      "lifecycle" => "retained",
      "runtime_id" => "rt_cap_fixture",
      "lstat_identity" => %{
        "type" => "directory",
        "major_device" => 0,
        "minor_device" => 0,
        "inode" => index + 1
      },
      "worktree_registration" => %{
        "path" => worktree_path,
        "head" => "abc#{index}",
        "branch" => "cap-#{index}"
      },
      "expires_at" => expires_at,
      "retry_count" => 0
    }
  end

  defp future_iso do
    DateTime.utc_now() |> DateTime.add(120, :second) |> DateTime.to_iso8601()
  end
end
