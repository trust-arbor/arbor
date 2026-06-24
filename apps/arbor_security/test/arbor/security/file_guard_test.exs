defmodule Arbor.Security.FileGuardTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.FileGuard
  alias Arbor.Security.SystemAuthority

  @moduletag :fast

  setup do
    agent_id = "agent_fg_#{:erlang.unique_integer([:positive])}"
    {:ok, agent_id: agent_id}
  end

  defp grant_fs_capability(agent_id, operation, path, opts \\ []) do
    uri = FileGuard.resource_uri(operation, path)

    {:ok, cap} =
      Capability.new(
        resource_uri: uri,
        principal_id: agent_id,
        constraints: Keyword.get(opts, :constraints, %{}),
        expires_at: Keyword.get(opts, :expires_at)
      )

    {:ok, signed} = SystemAuthority.sign_capability(cap)
    {:ok, :stored} = CapabilityStore.put(signed)
    {:ok, signed}
  end

  # ===========================================================================
  # URI building and parsing
  # ===========================================================================

  describe "resource_uri/2" do
    test "builds correct URI for all operations" do
      assert "arbor://fs/read/workspace" = FileGuard.resource_uri(:read, "/workspace")
      assert "arbor://fs/write/data" = FileGuard.resource_uri(:write, "/data")
      assert "arbor://fs/execute/scripts" = FileGuard.resource_uri(:execute, "/scripts")
      assert "arbor://fs/delete/tmp" = FileGuard.resource_uri(:delete, "/tmp")
      assert "arbor://fs/list/docs" = FileGuard.resource_uri(:list, "/docs")
    end

    test "handles paths without leading slash" do
      assert "arbor://fs/read/workspace" = FileGuard.resource_uri(:read, "workspace")
    end

    test "handles nested paths" do
      assert "arbor://fs/read/workspace/project/src" =
               FileGuard.resource_uri(:read, "/workspace/project/src")
    end
  end

  describe "parse_resource_uri/1" do
    test "parses valid fs URI with path" do
      assert {:ok, :read, "/workspace/project"} =
               FileGuard.parse_resource_uri("arbor://fs/read/workspace/project")
    end

    test "parses all operation types" do
      assert {:ok, :read, "/p"} = FileGuard.parse_resource_uri("arbor://fs/read/p")
      assert {:ok, :write, "/p"} = FileGuard.parse_resource_uri("arbor://fs/write/p")
      assert {:ok, :execute, "/p"} = FileGuard.parse_resource_uri("arbor://fs/execute/p")
      assert {:ok, :delete, "/p"} = FileGuard.parse_resource_uri("arbor://fs/delete/p")
      assert {:ok, :list, "/p"} = FileGuard.parse_resource_uri("arbor://fs/list/p")
    end

    test "parses URI with operation only (no path)" do
      assert {:ok, :read, "/"} = FileGuard.parse_resource_uri("arbor://fs/read")
    end

    test "returns error for non-fs URI" do
      assert {:error, :not_fs_resource} = FileGuard.parse_resource_uri("arbor://api/call/service")
    end

    test "returns error for completely different URI" do
      assert {:error, :not_fs_resource} = FileGuard.parse_resource_uri("https://example.com")
    end

    test "returns error for invalid operation" do
      assert {:error, {:unknown_operation, "invalid"}} =
               FileGuard.parse_resource_uri("arbor://fs/invalid/path")
    end
  end

  # ===========================================================================
  # Authorization (integration with CapabilityStore)
  # ===========================================================================

  describe "authorize/3" do
    test "authorizes when capability matches exactly", %{agent_id: agent_id} do
      {:ok, _cap} = grant_fs_capability(agent_id, :read, "/workspace/file.ex")

      assert {:ok, "/workspace/file.ex"} =
               FileGuard.authorize(agent_id, "/workspace/file.ex", :read)
    end

    test "authorizes via parent capability", %{agent_id: agent_id} do
      {:ok, _cap} = grant_fs_capability(agent_id, :read, "/workspace")

      assert {:ok, "/workspace/subdir/file.ex"} =
               FileGuard.authorize(agent_id, "/workspace/subdir/file.ex", :read)
    end

    test "denies without any capability", %{agent_id: agent_id} do
      assert {:error, :no_capability} = FileGuard.authorize(agent_id, "/workspace/file.ex", :read)
    end

    test "denies path traversal", %{agent_id: agent_id} do
      {:ok, _cap} = grant_fs_capability(agent_id, :read, "/workspace")

      assert {:error, :path_traversal} =
               FileGuard.authorize(agent_id, "/workspace/../etc/passwd", :read)
    end

    test "denies for wrong operation", %{agent_id: agent_id} do
      {:ok, _cap} = grant_fs_capability(agent_id, :read, "/workspace")

      assert {:error, :no_capability} =
               FileGuard.authorize(agent_id, "/workspace/file.ex", :write)
    end

    test "denies for expired capability", %{agent_id: agent_id} do
      # Create a capability that's already expired.
      # CapabilityStore filters expired capabilities during lookup,
      # so this surfaces as :no_capability rather than :expired.
      past = DateTime.add(DateTime.utc_now(), -3600)
      uri = FileGuard.resource_uri(:read, "/workspace")

      {:ok, cap} =
        Capability.new(
          resource_uri: uri,
          principal_id: agent_id,
          expires_at: DateTime.add(DateTime.utc_now(), 1)
        )

      {:ok, signed} = SystemAuthority.sign_capability(cap)
      expired = %{signed | expires_at: past}
      {:ok, :stored} = CapabilityStore.put(expired)

      assert {:error, :no_capability} = FileGuard.authorize(agent_id, "/workspace/file.ex", :read)
    end

    test "authorizes across all operation types", %{agent_id: agent_id} do
      for op <- [:read, :write, :execute, :delete, :list] do
        path = "/workspace_#{op}"
        {:ok, _cap} = grant_fs_capability(agent_id, op, path)
        assert {:ok, _} = FileGuard.authorize(agent_id, "#{path}/file.ex", op)
      end
    end
  end

  describe "authorize/3 with constraints" do
    test "allows file matching pattern constraint", %{agent_id: agent_id} do
      {:ok, _cap} =
        grant_fs_capability(agent_id, :read, "/workspace",
          constraints: %{patterns: ["*.ex", "*.exs"]}
        )

      assert {:ok, _} = FileGuard.authorize(agent_id, "/workspace/file.ex", :read)
    end

    test "denies file not matching pattern constraint", %{agent_id: agent_id} do
      {:ok, _cap} =
        grant_fs_capability(agent_id, :read, "/workspace",
          constraints: %{patterns: ["*.ex", "*.exs"]}
        )

      assert {:error, :pattern_mismatch} =
               FileGuard.authorize(agent_id, "/workspace/file.txt", :read)
    end

    test "denies file matching exclude constraint", %{agent_id: agent_id} do
      {:ok, _cap} =
        grant_fs_capability(agent_id, :read, "/workspace",
          constraints: %{exclude: [".env", "*.secret"]}
        )

      assert {:error, :excluded_pattern} = FileGuard.authorize(agent_id, "/workspace/.env", :read)

      assert {:error, :excluded_pattern} =
               FileGuard.authorize(agent_id, "/workspace/api.secret", :read)
    end

    test "allows file not matching exclude constraint", %{agent_id: agent_id} do
      {:ok, _cap} =
        grant_fs_capability(agent_id, :read, "/workspace", constraints: %{exclude: [".env"]})

      assert {:ok, _} = FileGuard.authorize(agent_id, "/workspace/config.exs", :read)
    end

    test "enforces max_depth constraint", %{agent_id: agent_id} do
      {:ok, _cap} =
        grant_fs_capability(agent_id, :read, "/workspace", constraints: %{max_depth: 2})

      # Depth 1: allowed
      assert {:ok, _} = FileGuard.authorize(agent_id, "/workspace/file.ex", :read)
      # Depth 2: allowed
      assert {:ok, _} = FileGuard.authorize(agent_id, "/workspace/src/file.ex", :read)
      # Depth 3: denied
      assert {:error, :max_depth_exceeded} =
               FileGuard.authorize(agent_id, "/workspace/src/deep/file.ex", :read)
    end

    test "no constraints allows everything", %{agent_id: agent_id} do
      {:ok, _cap} = grant_fs_capability(agent_id, :read, "/workspace")
      assert {:ok, _} = FileGuard.authorize(agent_id, "/workspace/any/deep/path/file.txt", :read)
    end
  end

  # ===========================================================================
  # Boolean check
  # ===========================================================================

  describe "can?/3" do
    test "returns true with valid capability", %{agent_id: agent_id} do
      {:ok, _cap} = grant_fs_capability(agent_id, :read, "/workspace")
      assert FileGuard.can?(agent_id, "/workspace/file.ex", :read)
    end

    test "returns false without capability", %{agent_id: agent_id} do
      refute FileGuard.can?(agent_id, "/workspace/file.ex", :read)
    end

    test "returns false for path traversal", %{agent_id: agent_id} do
      {:ok, _cap} = grant_fs_capability(agent_id, :read, "/workspace")
      refute FileGuard.can?(agent_id, "/workspace/../etc/passwd", :read)
    end
  end

  # ===========================================================================
  # Authorize with capability return
  # ===========================================================================

  describe "authorize_with_capability/3" do
    test "returns capability alongside resolved path", %{agent_id: agent_id} do
      {:ok, granted} = grant_fs_capability(agent_id, :read, "/workspace")

      assert {:ok, resolved, cap} =
               FileGuard.authorize_with_capability(agent_id, "/workspace/file.ex", :read)

      assert resolved == "/workspace/file.ex"
      assert cap.id == granted.id
      assert cap.principal_id == agent_id
    end

    test "returns error when not authorized", %{agent_id: agent_id} do
      assert {:error, :no_capability} =
               FileGuard.authorize_with_capability(agent_id, "/workspace/file.ex", :read)
    end
  end

  # ===========================================================================
  # List FS capabilities
  # ===========================================================================

  describe "list_fs_capabilities/1" do
    test "returns only fs capabilities", %{agent_id: agent_id} do
      # Grant an fs capability
      {:ok, _fs_cap} = grant_fs_capability(agent_id, :read, "/workspace")

      # Grant a non-fs capability directly
      {:ok, api_cap} =
        Capability.new(
          resource_uri: "arbor://api/call/service",
          principal_id: agent_id
        )

      {:ok, signed_api} = SystemAuthority.sign_capability(api_cap)
      {:ok, :stored} = CapabilityStore.put(signed_api)

      {:ok, fs_caps} = FileGuard.list_fs_capabilities(agent_id)

      assert fs_caps != []
      assert Enum.all?(fs_caps, &String.starts_with?(&1.resource_uri, "arbor://fs/"))
    end

    test "returns empty list when no fs capabilities", %{agent_id: agent_id} do
      # Grant only a non-fs capability
      {:ok, api_cap} =
        Capability.new(
          resource_uri: "arbor://api/call/service",
          principal_id: agent_id
        )

      {:ok, signed} = SystemAuthority.sign_capability(api_cap)
      {:ok, :stored} = CapabilityStore.put(signed)

      {:ok, fs_caps} = FileGuard.list_fs_capabilities(agent_id)
      assert fs_caps == []
    end
  end

  describe "symlink escape (H2 regression)" do
    setup do
      # Create a temp workspace with a symlink that points outside it.
      n = System.unique_integer([:positive])
      workspace = Path.join(System.tmp_dir!(), "h2_workspace_#{n}")
      outside = Path.join(System.tmp_dir!(), "h2_outside_#{n}")

      File.mkdir_p!(workspace)
      File.mkdir_p!(outside)

      target = Path.join(outside, "secret.txt")
      File.write!(target, "secret_content")

      symlink_in_workspace = Path.join(workspace, "escape_link")
      File.ln_s!(target, symlink_in_workspace)

      on_exit(fn ->
        File.rm_rf!(workspace)
        File.rm_rf!(outside)
      end)

      agent_id = "h2_test_#{n}"

      now = DateTime.utc_now()

      cap = %Capability{
        id: "cap_h2_#{n}",
        principal_id: agent_id,
        resource_uri: "arbor://fs/read#{workspace}",
        granted_at: now,
        expires_at: DateTime.add(now, 3600, :second)
      }

      CapabilityStore.put(cap)

      %{
        agent_id: agent_id,
        workspace: workspace,
        outside: outside,
        symlink: symlink_in_workspace
      }
    end

    test "security regression (H2): symlink pointing outside the authorized root is rejected",
         %{agent_id: agent_id, symlink: symlink} do
      # H2: pre-fix, FileGuard.resolve_and_validate_path called
      # SafePath.resolve_within (string normalization only — does NOT follow
      # symlinks) and authorized the symlink as if it were inside the
      # workspace. The actual I/O against `symlink_in_workspace` would have
      # then read `outside/secret.txt`. The fix calls SafePath.resolve_real
      # after normalization and verifies the real path stays within root.
      result = FileGuard.authorize(agent_id, symlink, :read)

      assert {:error, :symlink_escape} = result,
             "Symlink pointing outside authorized root must be rejected — H2 regression. " <>
               "Got: #{inspect(result)}"
    end

    test "non-symlink files inside the authorized root still authorize",
         %{agent_id: agent_id, workspace: workspace} do
      legitimate = Path.join(workspace, "real.txt")
      File.write!(legitimate, "ok")

      assert {:ok, _resolved} = FileGuard.authorize(agent_id, legitimate, :read)
    end

    test "security regression (ancestor-symlink): a file UNDER a symlinked ancestor dir is rejected",
         %{agent_id: agent_id, workspace: workspace, outside: outside} do
      # codex path-traversal.fileguard-ancestor-symlink (HIGH): pre-fix,
      # SafePath.resolve_real only followed the LEAF symlink, never ancestor
      # components. So `<workspace>/anc_link/secret.txt`, where `anc_link` is a
      # symlink to `outside/`, normalized lexically inside the workspace and the
      # real-path check (which also missed the ancestor link) passed — the read
      # actually hit `outside/secret.txt`. The fix resolves symlinks at every
      # component, so the ancestor link is followed and the escape is caught.
      anc_link = Path.join(workspace, "anc_link")
      File.ln_s!(outside, anc_link)
      requested = Path.join(anc_link, "secret.txt")

      result = FileGuard.authorize(agent_id, requested, :read)

      assert {:error, :symlink_escape} = result,
             "file under a symlinked ancestor directory must be rejected. Got: #{inspect(result)}"
    end

    test "security regression (ancestor-symlink): creating a file under a symlinked ancestor is rejected",
         %{agent_id: agent_id, workspace: workspace, outside: outside} do
      # The write/create variant: the target file does not exist yet, so
      # resolution falls to the ancestor chain. A symlinked ancestor must still
      # be detected (otherwise the future write lands outside the root).
      now = DateTime.utc_now()

      CapabilityStore.put(%Capability{
        id: "cap_h2_write_#{agent_id}",
        principal_id: agent_id,
        resource_uri: "arbor://fs/write#{workspace}",
        granted_at: now,
        expires_at: DateTime.add(now, 3600, :second)
      })

      anc_link = Path.join(workspace, "anc_link_w")
      File.ln_s!(outside, anc_link)
      requested = Path.join(anc_link, "new_file.txt")

      result = FileGuard.authorize(agent_id, requested, :write)

      assert {:error, :symlink_escape} = result,
             "creating a file under a symlinked ancestor must be rejected. Got: #{inspect(result)}"
    end
  end
end
