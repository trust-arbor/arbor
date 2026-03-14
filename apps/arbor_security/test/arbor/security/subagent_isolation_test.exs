defmodule Arbor.Security.SubagentIsolationTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.SubagentIsolation

  @parent_id "agent_parent001"
  @worker_id "agent_worker001"

  setup do
    # Grant parent some capabilities
    {:ok, fs_cap} =
      Arbor.Security.grant(
        principal: @parent_id,
        resource: "arbor://fs/read/src"
      )

    {:ok, shell_cap} =
      Arbor.Security.grant(
        principal: @parent_id,
        resource: "arbor://shell/exec/test"
      )

    {:ok, api_cap} =
      Arbor.Security.grant(
        principal: @parent_id,
        resource: "arbor://api/call/openai"
      )

    on_exit(fn ->
      CapabilityStore.revoke_all(@parent_id)
      CapabilityStore.revoke_all(@worker_id)
    end)

    %{fs_cap: fs_cap, shell_cap: shell_cap, api_cap: api_cap}
  end

  describe "create_isolation/1" do
    @tag :fast
    test "creates task-scoped capabilities for worker" do
      {:ok, isolation} =
        SubagentIsolation.create_isolation(
          parent_id: @parent_id,
          worker_id: @worker_id,
          resource_uris: ["arbor://fs/read/src", "arbor://shell/exec/test"]
        )

      assert String.starts_with?(isolation.task_id, "task_")
      assert isolation.parent_id == @parent_id
      assert isolation.worker_id == @worker_id
      assert length(isolation.capabilities) == 2
      assert %DateTime{} = isolation.created_at
    end

    @tag :fast
    test "delegated caps are task-bound, single-use, non-delegatable" do
      {:ok, isolation} =
        SubagentIsolation.create_isolation(
          parent_id: @parent_id,
          worker_id: @worker_id,
          resource_uris: ["arbor://fs/read/src"]
        )

      [cap] = isolation.capabilities
      assert cap.task_id == isolation.task_id
      assert cap.max_uses == 1
      assert cap.delegation_depth == 0
      assert cap.principal_id == @worker_id
    end

    @tag :fast
    test "custom max_uses" do
      {:ok, isolation} =
        SubagentIsolation.create_isolation(
          parent_id: @parent_id,
          worker_id: @worker_id,
          resource_uris: ["arbor://fs/read/src"],
          max_uses: 5
        )

      [cap] = isolation.capabilities
      assert cap.max_uses == 5
    end

    @tag :fast
    test "custom task_id" do
      {:ok, isolation} =
        SubagentIsolation.create_isolation(
          parent_id: @parent_id,
          worker_id: @worker_id,
          resource_uris: ["arbor://fs/read/src"],
          task_id: "task_deploy_staging"
        )

      assert isolation.task_id == "task_deploy_staging"
      [cap] = isolation.capabilities
      assert cap.task_id == "task_deploy_staging"
    end

    @tag :fast
    test "session binding inherited" do
      {:ok, isolation} =
        SubagentIsolation.create_isolation(
          parent_id: @parent_id,
          worker_id: @worker_id,
          resource_uris: ["arbor://fs/read/src"],
          session_id: "session_main"
        )

      [cap] = isolation.capabilities
      assert cap.session_id == "session_main"
    end

    @tag :fast
    test "expires_in sets expiration" do
      {:ok, isolation} =
        SubagentIsolation.create_isolation(
          parent_id: @parent_id,
          worker_id: @worker_id,
          resource_uris: ["arbor://fs/read/src"],
          expires_in: 300
        )

      [cap] = isolation.capabilities
      assert cap.expires_at != nil
      # Should expire roughly 300 seconds from now
      diff = DateTime.diff(cap.expires_at, DateTime.utc_now(), :second)
      assert diff >= 295 and diff <= 305
    end

    @tag :fast
    test "skips resources parent doesn't have" do
      {:ok, isolation} =
        SubagentIsolation.create_isolation(
          parent_id: @parent_id,
          worker_id: @worker_id,
          resource_uris: ["arbor://fs/read/src", "arbor://nonexistent/resource"]
        )

      # Only the fs/read/src cap should be delegated
      assert length(isolation.capabilities) == 1
      [cap] = isolation.capabilities
      assert cap.resource_uri == "arbor://fs/read/src"
    end

    @tag :fast
    test "fails if no capabilities can be delegated" do
      assert {:error, :no_capabilities_delegated} =
               SubagentIsolation.create_isolation(
                 parent_id: @parent_id,
                 worker_id: @worker_id,
                 resource_uris: ["arbor://nonexistent/a", "arbor://nonexistent/b"]
               )
    end

    @tag :fast
    test "worker caps are stored and authorizable" do
      {:ok, isolation} =
        SubagentIsolation.create_isolation(
          parent_id: @parent_id,
          worker_id: @worker_id,
          resource_uris: ["arbor://fs/read/src"]
        )

      # Worker should be able to find the capability
      {:ok, found} = CapabilityStore.find_authorizing(@worker_id, "arbor://fs/read/src")
      assert found.task_id == isolation.task_id

      # Clean up
      SubagentIsolation.cleanup(isolation.task_id)
    end

    @tag :fast
    test "worker can't re-delegate (depth 0)" do
      {:ok, isolation} =
        SubagentIsolation.create_isolation(
          parent_id: @parent_id,
          worker_id: @worker_id,
          resource_uris: ["arbor://fs/read/src"]
        )

      [cap] = isolation.capabilities

      assert {:error, :delegation_depth_exhausted} =
               Arbor.Contracts.Security.Capability.delegate(cap, "agent_sneaky")

      SubagentIsolation.cleanup(isolation.task_id)
    end
  end

  describe "cleanup/1" do
    @tag :fast
    test "revokes all task-scoped capabilities" do
      {:ok, isolation} =
        SubagentIsolation.create_isolation(
          parent_id: @parent_id,
          worker_id: @worker_id,
          resource_uris: ["arbor://fs/read/src", "arbor://shell/exec/test"]
        )

      # Caps exist before cleanup
      assert {:ok, _} = CapabilityStore.find_authorizing(@worker_id, "arbor://fs/read/src")

      {:ok, count} = SubagentIsolation.cleanup(isolation.task_id)
      assert count == 2

      # Caps gone after cleanup
      assert {:error, :not_found} =
               CapabilityStore.find_authorizing(@worker_id, "arbor://fs/read/src")
    end

    @tag :fast
    test "cleanup is idempotent" do
      {:ok, isolation} =
        SubagentIsolation.create_isolation(
          parent_id: @parent_id,
          worker_id: @worker_id,
          resource_uris: ["arbor://fs/read/src"]
        )

      {:ok, 1} = SubagentIsolation.cleanup(isolation.task_id)
      {:ok, 0} = SubagentIsolation.cleanup(isolation.task_id)
    end

    @tag :fast
    test "cleanup doesn't affect other tasks" do
      {:ok, iso1} =
        SubagentIsolation.create_isolation(
          parent_id: @parent_id,
          worker_id: @worker_id,
          resource_uris: ["arbor://fs/read/src"],
          task_id: "task_one"
        )

      {:ok, _iso2} =
        SubagentIsolation.create_isolation(
          parent_id: @parent_id,
          worker_id: @worker_id,
          resource_uris: ["arbor://shell/exec/test"],
          task_id: "task_two"
        )

      # Clean up task_one only
      {:ok, 1} = SubagentIsolation.cleanup(iso1.task_id)

      # task_two's cap still exists
      {:ok, cap} = CapabilityStore.find_authorizing(@worker_id, "arbor://shell/exec/test")
      assert cap.task_id == "task_two"

      # Clean up task_two
      SubagentIsolation.cleanup("task_two")
    end
  end
end
