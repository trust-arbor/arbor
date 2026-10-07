defmodule Arbor.Security.SubagentIsolationTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.SubagentIsolation

  @parent_key {__MODULE__, :parent_id}
  @worker_key {__MODULE__, :worker_id}
  @authority_key {__MODULE__, :actor_authority}

  setup do
    {:ok, parent} = Identity.generate(name: "subagent-isolation-parent")
    :ok = Security.register_identity_fixture(Identity.public_only(parent))

    :ok =
      Security.store_signing_keypair_fixture(
        parent.agent_id,
        parent.private_key,
        parent.encryption_private_key
      )

    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        parent.agent_id,
        parent.private_key,
        purpose: :subagent_isolation_test,
        owner: self()
      )

    {:ok, actor_authority} = Security.open_signing_authority(proof)
    worker_id = "agent_worker#{System.unique_integer([:positive])}"

    Process.put(@parent_key, parent.agent_id)
    Process.put(@worker_key, worker_id)
    Process.put(@authority_key, actor_authority)

    # Grant parent some capabilities
    {:ok, fs_cap} =
      Arbor.Security.grant_fixture(
        principal: parent_id(),
        resource: "arbor://fs/read/src"
      )

    {:ok, shell_cap} =
      Arbor.Security.grant_fixture(
        principal: parent_id(),
        resource: "arbor://shell/exec/test"
      )

    {:ok, api_cap} =
      Arbor.Security.grant_fixture(
        principal: parent_id(),
        resource: "arbor://api/call/openai"
      )

    {:ok, _scope_revocation_cap} =
      Arbor.Security.grant_fixture(
        principal: parent_id(),
        resource: "arbor://security/revoke/scope"
      )

    on_exit(fn ->
      CapabilityStore.revoke_all_fixture(parent.agent_id)
      CapabilityStore.revoke_all_fixture(worker_id)
      Security.delete_signing_key_fixture(parent.agent_id)
      Security.deregister_identity_fixture(parent.agent_id)
    end)

    %{fs_cap: fs_cap, shell_cap: shell_cap, api_cap: api_cap}
  end

  describe "create_isolation/1" do
    @tag :fast
    test "creates task-scoped capabilities for worker" do
      {:ok, isolation} =
        create_isolation(
          parent_id: parent_id(),
          worker_id: worker_id(),
          resource_uris: ["arbor://fs/read/src", "arbor://shell/exec/test"]
        )

      assert String.starts_with?(isolation.task_id, "task_")
      assert isolation.parent_id == parent_id()
      assert isolation.worker_id == worker_id()
      assert length(isolation.capabilities) == 2
      assert %DateTime{} = isolation.created_at
    end

    @tag :fast
    test "delegated caps are task-bound, single-use, non-delegatable" do
      {:ok, isolation} =
        create_isolation(
          parent_id: parent_id(),
          worker_id: worker_id(),
          resource_uris: ["arbor://fs/read/src"]
        )

      [cap] = isolation.capabilities
      assert cap.task_id == isolation.task_id
      assert cap.max_uses == 1
      assert cap.delegation_depth == 0
      assert cap.principal_id == worker_id()
    end

    @tag :fast
    test "custom max_uses" do
      {:ok, isolation} =
        create_isolation(
          parent_id: parent_id(),
          worker_id: worker_id(),
          resource_uris: ["arbor://fs/read/src"],
          max_uses: 5
        )

      [cap] = isolation.capabilities
      assert cap.max_uses == 5
    end

    @tag :fast
    test "custom task_id" do
      {:ok, isolation} =
        create_isolation(
          parent_id: parent_id(),
          worker_id: worker_id(),
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
        create_isolation(
          parent_id: parent_id(),
          worker_id: worker_id(),
          resource_uris: ["arbor://fs/read/src"],
          session_id: "session_main"
        )

      [cap] = isolation.capabilities
      assert cap.session_id == "session_main"
    end

    @tag :fast
    test "expires_in sets expiration" do
      {:ok, isolation} =
        create_isolation(
          parent_id: parent_id(),
          worker_id: worker_id(),
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
        create_isolation(
          parent_id: parent_id(),
          worker_id: worker_id(),
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
               create_isolation(
                 parent_id: parent_id(),
                 worker_id: worker_id(),
                 resource_uris: ["arbor://nonexistent/a", "arbor://nonexistent/b"]
               )
    end

    @tag :fast
    test "worker caps are stored and authorizable" do
      {:ok, isolation} =
        create_isolation(
          parent_id: parent_id(),
          worker_id: worker_id(),
          resource_uris: ["arbor://fs/read/src"]
        )

      # Worker should be able to find the capability
      {:ok, found} = CapabilityStore.find_authorizing(worker_id(), "arbor://fs/read/src")
      assert found.task_id == isolation.task_id

      # Clean up
      cleanup_isolation(isolation.task_id)
    end

    @tag :fast
    test "security regression: delegated worker caps authorize when signing is required" do
      previous = Application.get_env(:arbor_security, :capability_signing_required)
      Application.put_env(:arbor_security, :capability_signing_required, true)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:arbor_security, :capability_signing_required)
          value -> Application.put_env(:arbor_security, :capability_signing_required, value)
        end
      end)

      {:ok, isolation} =
        create_isolation(
          parent_id: parent_id(),
          worker_id: worker_id(),
          resource_uris: ["arbor://fs/read/src"],
          max_uses: 2
        )

      [cap] = isolation.capabilities
      assert is_binary(cap.issuer_signature)

      assert {:ok, :authorized} =
               Arbor.Security.authorize(worker_id(), "arbor://fs/read/src", :read,
                 verify_identity: false,
                 task_id: isolation.task_id
               )
    end

    @tag :fast
    test "worker can't re-delegate (depth 0)" do
      {:ok, isolation} =
        create_isolation(
          parent_id: parent_id(),
          worker_id: worker_id(),
          resource_uris: ["arbor://fs/read/src"]
        )

      [cap] = isolation.capabilities

      assert {:error, :delegation_depth_exhausted} =
               Arbor.Contracts.Security.Capability.delegate(cap, "agent_sneaky")

      cleanup_isolation(isolation.task_id)
    end
  end

  describe "cleanup/1" do
    @tag :fast
    test "revokes all task-scoped capabilities" do
      {:ok, isolation} =
        create_isolation(
          parent_id: parent_id(),
          worker_id: worker_id(),
          resource_uris: ["arbor://fs/read/src", "arbor://shell/exec/test"]
        )

      # Caps exist before cleanup
      assert {:ok, _} = CapabilityStore.find_authorizing(worker_id(), "arbor://fs/read/src")

      {:ok, count} = cleanup_isolation(isolation.task_id)
      assert count == 2

      # Caps gone after cleanup
      assert {:error, :not_found} =
               CapabilityStore.find_authorizing(worker_id(), "arbor://fs/read/src")
    end

    @tag :fast
    test "cleanup is idempotent" do
      {:ok, isolation} =
        create_isolation(
          parent_id: parent_id(),
          worker_id: worker_id(),
          resource_uris: ["arbor://fs/read/src"]
        )

      {:ok, 1} = cleanup_isolation(isolation.task_id)
      {:ok, 0} = cleanup_isolation(isolation.task_id)
    end

    @tag :fast
    test "cleanup doesn't affect other tasks" do
      {:ok, iso1} =
        create_isolation(
          parent_id: parent_id(),
          worker_id: worker_id(),
          resource_uris: ["arbor://fs/read/src"],
          task_id: "task_one"
        )

      {:ok, _iso2} =
        create_isolation(
          parent_id: parent_id(),
          worker_id: worker_id(),
          resource_uris: ["arbor://shell/exec/test"],
          task_id: "task_two"
        )

      # Clean up task_one only
      {:ok, 1} = cleanup_isolation(iso1.task_id)

      # task_two's cap still exists
      {:ok, cap} = CapabilityStore.find_authorizing(worker_id(), "arbor://shell/exec/test")
      assert cap.task_id == "task_two"

      # Clean up task_two
      cleanup_isolation("task_two")
    end
  end

  defp create_isolation(opts) do
    SubagentIsolation.create_isolation(Keyword.put(opts, :actor_authority, actor_authority()))
  end

  defp cleanup_isolation(task_id) do
    SubagentIsolation.cleanup(task_id, actor_authority: actor_authority())
  end

  defp parent_id, do: Process.get(@parent_key)
  defp worker_id, do: Process.get(@worker_key)
  defp actor_authority, do: Process.get(@authority_key)
end
