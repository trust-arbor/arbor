defmodule Arbor.Actions.Coding.ResourceInventoryTest do
  use Arbor.Actions.ActionCase, async: true

  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry

  @moduletag :fast

  test "empty state is a bounded JSON-clean inventory" do
    server = start_registry("empty")

    assert {:ok, inventory} = Actions.coding_resource_inventory(server: server)
    assert inventory["resources"] == []
    assert inventory["counts"]["available"] == 0
    assert inventory["counts"]["returned"] == 0
    assert inventory["journal"] == %{"status" => "disabled", "quarantined" => false}
    assert_json_clean(inventory)
  end

  test "projects live, retained, and validation resources through workspace joins" do
    server = start_registry("joins")

    replace_registry_state(server, fn state ->
      %{
        state
        | leases: %{"ws-live" => active_lease("ws-live", "task-live", "principal-live")},
          retained_by_id: %{
            "ws-retained" => retained_record("ws-retained", "task-retained", "principal-retained")
          },
          validation_resources: %{
            "validation-live" => validation_resource("validation-live", "ws-live"),
            "validation-retained" => validation_resource("validation-retained", "ws-retained")
          }
      }
    end)

    assert {:ok, inventory} = Actions.coding_resource_inventory(server: server)

    assert Enum.map(inventory["resources"], & &1["resource_type"]) == [
             "live_workspace_lease",
             "retained_workspace_record",
             "validation_resource",
             "validation_resource"
           ]

    [live, retained, validation_live, validation_retained] = inventory["resources"]
    assert live["task_id"] == "task-live"
    assert live["principal_id"] == "principal-live"
    assert retained["lifecycle"] == "retained"
    assert retained["dormant"] == true
    assert validation_live["task_id"] == "task-live"
    assert validation_live["principal_id"] == "principal-live"
    assert validation_retained["task_id"] == "task-retained"
    assert validation_retained["principal_id"] == "principal-retained"
    assert_json_clean(inventory)
  end

  test "filters, hard bounds, and deterministic ordering are explicit" do
    server = start_registry("bounds")

    replace_registry_state(server, fn state ->
      leases =
        [
          active_lease("ws-b", "task-a", "principal-a"),
          active_lease("ws-a", "task-a", "principal-a"),
          active_lease("ws-c", "task-b", "principal-b")
        ]
        |> Map.new(&{&1.workspace_id, &1})

      %{state | leases: leases}
    end)

    opts = [server: server, task_id: "task-a", principal_id: "principal-a", max_items: 1]
    assert {:ok, first} = Actions.coding_resource_inventory(opts)
    assert {:ok, second} = Actions.coding_resource_inventory(opts)
    assert first == second
    assert first["counts"]["matching"] == 2
    assert first["counts"]["returned"] == 1
    assert first["counts"]["truncated"] == 1
    assert first["truncated"] == true
    assert hd(first["resources"])["resource_id"] == "ws-a"

    assert {:error, :invalid_coding_resource_inventory_options} =
             Actions.coding_resource_inventory(server: server, unknown: true)

    assert {:error, :invalid_coding_resource_inventory_options} =
             Actions.coding_resource_inventory(task_id: "task-a", task_id: "task-b")

    assert {:error, :invalid_coding_resource_inventory_options} =
             Actions.coding_resource_inventory(server: server, task_id: "")

    assert {:error, :invalid_coding_resource_inventory_options} =
             Actions.coding_resource_inventory(server: server, max_items: 257)
  end

  test "observation does not mutate registry state and redacts ownership internals" do
    server = start_registry("readonly")

    replace_registry_state(server, fn state ->
      %{state | leases: %{"ws-live" => active_lease("ws-live", "task", "principal")}}
    end)

    before = :sys.get_state(server)
    assert {:ok, inventory} = Actions.coding_resource_inventory(server: server)
    after_state = :sys.get_state(server)

    assert before == after_state
    assert_json_clean(inventory)

    forbidden = ~w(
      owner_pid owner_ref resource_owner_pid resource_owner_ref dependency_lease
      capability signing_material journal_mutation_token cleanup_failure
    )

    refute contains_forbidden_key?(inventory, forbidden)
  end

  test "poisoned durable evidence becomes bounded quarantine without raw reasons" do
    server = start_registry("poisoned")
    secret = "journal-secret-that-must-not-cross-the-boundary"

    replace_registry_state(server, fn state ->
      %{
        state
        | retention_journal:
            state.retention_journal
            |> Map.put(:status, :poisoned)
            |> Map.put(:reason, {:corrupt_retention_record, "retained:ws-poisoned", secret})
      }
    end)

    assert {:ok, inventory} = Actions.coding_resource_inventory(server: server)

    assert inventory["journal"] == %{
             "status" => "degraded",
             "quarantined" => true,
             "failure_category" => "retention_journal_poisoned"
           }

    [quarantine] = inventory["resources"]
    assert quarantine["resource_type"] == "quarantine"
    assert quarantine["quarantine_reason"] == "poisoned_journal"
    refute String.contains?(Jason.encode!(inventory), secret)
    assert_json_clean(inventory)
  end

  defp start_registry(label) do
    server = {:global, {__MODULE__, label, System.unique_integer([:positive])}}
    start_supervised!({WorkspaceLeaseRegistry, name: server, retention_journal: :disabled})
    server
  end

  defp replace_registry_state({:global, name}, update) do
    name
    |> :global.whereis_name()
    |> :sys.replace_state(update)
  end

  defp active_lease(workspace_id, task_id, principal_id) do
    %{
      workspace_id: workspace_id,
      owner_pid: self(),
      owner_ref: make_ref(),
      task_id: task_id,
      principal_id: principal_id,
      repo_path: "/repo",
      worktree_path: "/worktrees/" <> workspace_id,
      branch: "feature/" <> workspace_id,
      base_commit: String.duplicate("a", 40),
      ownership: :owned,
      branch_provenance: :created,
      active: true,
      cleanup_armed: true,
      owner_death_retry_count: 1,
      owner_death_retry_limit: 3
    }
  end

  defp retained_record(workspace_id, task_id, principal_id) do
    %{
      workspace_id: workspace_id,
      owner_pid: nil,
      task_id: task_id,
      principal_id: principal_id,
      repo_path: "/repo",
      worktree_path: "/worktrees/" <> workspace_id,
      branch: "feature/" <> workspace_id,
      base_commit: String.duplicate("b", 40),
      ownership: :owned,
      branch_provenance: :reused,
      lifecycle: :retained,
      dormant: true,
      retry_count: 8,
      retained_cleanup_retry_limit: 8,
      expires_at: ~U[2026-07-22 12:00:00Z]
    }
  end

  defp validation_resource(resource_id, workspace_id) do
    %{
      resource_id: resource_id,
      workspace_id: workspace_id,
      repo_path: "/repo",
      candidate_path: "/private/validation/" <> resource_id,
      candidate_commit: String.duplicate("c", 40),
      base_commit: String.duplicate("b", 40),
      base_worktree_path: "/private/validation/" <> resource_id <> "/base",
      setup_status: :active,
      resource_owner_pid: self(),
      resource_owner_ref: make_ref(),
      resource_owner_cleanup_retry_count: 0,
      resource_owner_cleanup_dormant: false
    }
  end

  defp assert_json_clean(value) do
    assert {:ok, _encoded} = Jason.encode(value)
    assert json_clean?(value)
  end

  defp json_clean?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_clean?(nested) end)
  end

  defp json_clean?(value) when is_list(value), do: Enum.all?(value, &json_clean?/1)
  defp json_clean?(value) when is_binary(value) or is_boolean(value) or is_number(value), do: true
  defp json_clean?(nil), do: true
  defp json_clean?(_value), do: false

  defp contains_forbidden_key?(value, forbidden) when is_map(value) do
    Enum.any?(value, fn {key, nested} ->
      key in forbidden or contains_forbidden_key?(nested, forbidden)
    end)
  end

  defp contains_forbidden_key?(value, forbidden) when is_list(value),
    do: Enum.any?(value, &contains_forbidden_key?(&1, forbidden))

  defp contains_forbidden_key?(_value, _forbidden), do: false
end
