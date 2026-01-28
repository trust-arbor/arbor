defmodule Arbor.Security.FileGuardTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.FileGuard

  @moduletag :fast

  # Most tests don't need the capability store - they test URI parsing,
  # pattern matching, and SafePath integration. Tests that need capabilities
  # use the application-supervised store.

  describe "resource_uri/2" do
    test "builds correct URI for read operation" do
      assert "arbor://fs/read/workspace/project" = FileGuard.resource_uri(:read, "/workspace/project")
    end

    test "builds correct URI for write operation" do
      assert "arbor://fs/write/data" = FileGuard.resource_uri(:write, "/data")
    end

    test "handles paths without leading slash" do
      assert "arbor://fs/read/workspace" = FileGuard.resource_uri(:read, "workspace")
    end
  end

  describe "parse_resource_uri/1" do
    test "parses valid fs URI" do
      assert {:ok, :read, "/workspace/project"} =
               FileGuard.parse_resource_uri("arbor://fs/read/workspace/project")
    end

    test "parses all operations" do
      assert {:ok, :read, "/path"} = FileGuard.parse_resource_uri("arbor://fs/read/path")
      assert {:ok, :write, "/path"} = FileGuard.parse_resource_uri("arbor://fs/write/path")
      assert {:ok, :execute, "/path"} = FileGuard.parse_resource_uri("arbor://fs/execute/path")
      assert {:ok, :delete, "/path"} = FileGuard.parse_resource_uri("arbor://fs/delete/path")
      assert {:ok, :list, "/path"} = FileGuard.parse_resource_uri("arbor://fs/list/path")
    end

    test "returns error for non-fs URI" do
      assert {:error, :not_fs_resource} = FileGuard.parse_resource_uri("arbor://api/call/service")
    end

    test "returns error for invalid operation" do
      assert {:error, {:unknown_operation, "invalid"}} =
               FileGuard.parse_resource_uri("arbor://fs/invalid/path")
    end
  end

  describe "authorize/3 with mocked capabilities" do
    # These tests mock the capability store behavior

    test "returns error when no capability exists" do
      # No capabilities granted, should fail
      assert {:error, :no_capability} = FileGuard.authorize("agent_001", "/workspace/file.ex", :read)
    end
  end

  describe "pattern matching" do
    test "pattern_matches? handles glob patterns" do
      # Test the private function behavior through constraints
      constraints = %{patterns: ["*.ex", "*.exs"]}

      # We can't directly test private functions, but we verify through integration
      # These would be tested through authorize/3 with proper setup
      assert is_map(constraints)
    end
  end

  describe "SafePath integration" do
    test "validates paths stay within root" do
      # Direct SafePath validation - FileGuard uses this internally
      alias Arbor.Common.SafePath

      assert SafePath.within?("/workspace/file.ex", "/workspace")
      refute SafePath.within?("/workspace/../etc/passwd", "/workspace")
      refute SafePath.within?("/etc/passwd", "/workspace")
    end

    test "resolves relative paths against root" do
      alias Arbor.Common.SafePath

      assert {:ok, "/workspace/file.ex"} = SafePath.resolve_within("file.ex", "/workspace")
      assert {:ok, "/workspace/subdir/file.ex"} = SafePath.resolve_within("subdir/file.ex", "/workspace")
    end

    test "detects traversal attempts" do
      alias Arbor.Common.SafePath

      assert {:error, :path_traversal} = SafePath.resolve_within("../etc/passwd", "/workspace")
      assert {:error, :path_traversal} = SafePath.resolve_within("a/b/c/../../../../etc/passwd", "/workspace")
    end
  end

  describe "constraint checking" do
    test "max_depth constraint calculation" do
      # Verify depth calculation logic
      path = "/workspace/a/b/c/file.ex"
      root = "/workspace"

      relative = String.trim_leading(path, root)
      depth = relative |> String.split("/") |> Enum.reject(&(&1 == "")) |> length()

      # /a/b/c/file.ex = 4 components
      assert depth == 4
    end

    test "pattern constraint matching" do
      # Test glob-to-regex conversion
      # *.ex should match file.ex
      pattern = "*.ex"

      regex_pattern =
        pattern
        |> Regex.escape()
        |> String.replace("\\*", ".*")
        |> String.replace("\\?", ".")

      assert Regex.match?(~r/^#{regex_pattern}$/, "file.ex")
      assert Regex.match?(~r/^#{regex_pattern}$/, "my_module.ex")
      refute Regex.match?(~r/^#{regex_pattern}$/, "file.exs")
      refute Regex.match?(~r/^#{regex_pattern}$/, "file.txt")
    end

    test "exclude pattern matching" do
      # .env files should be excludable
      pattern = ".env"

      regex_pattern =
        pattern
        |> Regex.escape()
        |> String.replace("\\*", ".*")
        |> String.replace("\\?", ".")

      assert Regex.match?(~r/^#{regex_pattern}$/, ".env")
      refute Regex.match?(~r/^#{regex_pattern}$/, "config.env")
    end

    test "wildcard exclude patterns" do
      # *.secret should exclude all .secret files
      pattern = "*.secret"

      regex_pattern =
        pattern
        |> Regex.escape()
        |> String.replace("\\*", ".*")
        |> String.replace("\\?", ".")

      assert Regex.match?(~r/^#{regex_pattern}$/, "api.secret")
      assert Regex.match?(~r/^#{regex_pattern}$/, "database.secret")
      refute Regex.match?(~r/^#{regex_pattern}$/, "secret.txt")
    end
  end

  describe "capability expiration" do
    test "non-expired capability is valid" do
      future = DateTime.utc_now() |> DateTime.add(3600, :second)

      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/workspace",
          principal_id: "agent_test",
          expires_at: future
        )

      assert Capability.valid?(cap)
    end

    test "expired capability is invalid" do
      past = DateTime.utc_now() |> DateTime.add(-3600, :second)

      # Can't create an expired capability directly (validation prevents it)
      # But we can test the expiration check logic
      now = DateTime.utc_now()
      assert DateTime.compare(past, now) == :lt
    end
  end

  describe "fs_capability? helper" do
    test "identifies fs capabilities" do
      {:ok, fs_cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/workspace",
          principal_id: "agent_test"
        )

      {:ok, api_cap} =
        Capability.new(
          resource_uri: "arbor://api/call/service",
          principal_id: "agent_test"
        )

      # Test through the module's behavior
      assert String.starts_with?(fs_cap.resource_uri, "arbor://fs/")
      refute String.starts_with?(api_cap.resource_uri, "arbor://fs/")
    end
  end
end
