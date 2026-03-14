defmodule Arbor.Contracts.TenantContextTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.TenantContext
  alias Arbor.Contracts.Security.Capability

  @moduletag :fast

  describe "new/2" do
    test "creates context with principal_id" do
      ctx = TenantContext.new("human_abc123")
      assert ctx.principal_id == "human_abc123"
      assert ctx.workspace_root == nil
      assert ctx.display_name == nil
      assert ctx.metadata == %{}
    end

    test "creates context with all options" do
      ctx =
        TenantContext.new("human_abc123",
          workspace_root: "/home/user/.arbor/workspace/human_abc123",
          display_name: "Alice",
          metadata: %{email: "alice@example.com"}
        )

      assert ctx.principal_id == "human_abc123"
      assert ctx.workspace_root == "/home/user/.arbor/workspace/human_abc123"
      assert ctx.display_name == "Alice"
      assert ctx.metadata == %{email: "alice@example.com"}
    end
  end

  describe "principal_id/1" do
    test "returns principal_id from context" do
      ctx = TenantContext.new("human_abc123")
      assert TenantContext.principal_id(ctx) == "human_abc123"
    end

    test "returns nil for nil context" do
      assert TenantContext.principal_id(nil) == nil
    end
  end

  describe "workspace_root/1" do
    test "returns workspace_root from context" do
      ctx = TenantContext.new("human_abc123", workspace_root: "/workspace/abc")
      assert TenantContext.workspace_root(ctx) == "/workspace/abc"
    end

    test "returns nil when workspace_root not set" do
      ctx = TenantContext.new("human_abc123")
      assert TenantContext.workspace_root(ctx) == nil
    end

    test "returns nil for nil context" do
      assert TenantContext.workspace_root(nil) == nil
    end
  end

  describe "to_signal_metadata/1" do
    test "returns principal_id in metadata" do
      ctx = TenantContext.new("human_abc123")
      assert TenantContext.to_signal_metadata(ctx) == %{principal_id: "human_abc123"}
    end

    test "returns empty map for nil context" do
      assert TenantContext.to_signal_metadata(nil) == %{}
    end
  end

  describe "JSON encoding" do
    test "encodes to JSON" do
      ctx = TenantContext.new("human_abc123", display_name: "Alice")
      assert {:ok, json} = Jason.encode(ctx)
      decoded = Jason.decode!(json)
      assert decoded["principal_id"] == "human_abc123"
      assert decoded["display_name"] == "Alice"
    end
  end

  describe "Capability principal_scope integration" do
    test "capability with principal_scope matches correct principal" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/workspace",
          principal_id: "agent_abc",
          principal_scope: "human_abc123"
        )

      assert cap.principal_scope == "human_abc123"
      assert Capability.scope_matches?(cap, principal_scope: "human_abc123")
      refute Capability.scope_matches?(cap, principal_scope: "human_other")
    end

    test "capability without principal_scope matches any principal" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/workspace",
          principal_id: "agent_abc"
        )

      assert cap.principal_scope == nil
      assert Capability.scope_matches?(cap, principal_scope: "human_abc123")
      assert Capability.scope_matches?(cap, principal_scope: "human_other")
      assert Capability.scope_matches?(cap, [])
    end

    test "delegated capability inherits principal_scope" do
      {:ok, parent} =
        Capability.new(
          resource_uri: "arbor://fs/read/workspace",
          principal_id: "agent_abc",
          principal_scope: "human_abc123",
          delegation_depth: 3
        )

      {:ok, child} = Capability.delegate(parent, "agent_sub1")
      assert child.principal_scope == "human_abc123"
      assert child.delegation_depth == 2
    end

    test "delegated capability cannot remove principal_scope" do
      {:ok, parent} =
        Capability.new(
          resource_uri: "arbor://fs/read/workspace",
          principal_id: "agent_abc",
          principal_scope: "human_abc123",
          delegation_depth: 3
        )

      # Even if opts try to clear it, parent's scope is inherited
      {:ok, child} = Capability.delegate(parent, "agent_sub1", principal_scope: nil)
      assert child.principal_scope == "human_abc123"
    end

    test "scope_matches? checks all three dimensions" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/workspace",
          principal_id: "agent_abc",
          session_id: "session_1",
          task_id: "task_1",
          principal_scope: "human_abc123"
        )

      # All match
      assert Capability.scope_matches?(cap,
               session_id: "session_1",
               task_id: "task_1",
               principal_scope: "human_abc123"
             )

      # Principal mismatch
      refute Capability.scope_matches?(cap,
               session_id: "session_1",
               task_id: "task_1",
               principal_scope: "human_other"
             )

      # Session mismatch
      refute Capability.scope_matches?(cap,
               session_id: "session_2",
               task_id: "task_1",
               principal_scope: "human_abc123"
             )
    end
  end
end
