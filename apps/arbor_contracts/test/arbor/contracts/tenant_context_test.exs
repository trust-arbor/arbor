defmodule Arbor.Contracts.TenantContextTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.TenantContext

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
end
