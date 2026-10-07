defmodule Arbor.Security.FileGuardTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Security
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
        expires_at: Keyword.get(opts, :expires_at),
        session_id: Keyword.get(opts, :session_id),
        task_id: Keyword.get(opts, :task_id),
        principal_scope: Keyword.get(opts, :principal_scope)
      )

    {:ok, signed} = SystemAuthority.sign_capability_for_test(cap)
    {:ok, :stored} = CapabilityStore.put_fixture(signed)
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
      n = System.unique_integer([:positive])
      parent = Path.join(System.tmp_dir!(), "file_guard_exact_#{n}")
      target = Path.join(parent, "missing_file.ex")

      File.mkdir_p!(parent)
      on_exit(fn -> File.rm_rf!(parent) end)

      refute File.exists?(target)
      {:ok, _cap} = grant_fs_capability(agent_id, :read, target)

      assert {:ok, expected} = SafePath.resolve_within(target, parent)
      assert {:ok, ^expected} = FileGuard.authorize(agent_id, target, :read)
    end

    test "authorizes via parent capability", %{agent_id: agent_id} do
      {:ok, _cap} = grant_fs_capability(agent_id, :read, "/workspace")

      assert {:ok, "/workspace/subdir/file.ex"} =
               FileGuard.authorize(agent_id, "/workspace/subdir/file.ex", :read)
    end

    test "security regression: parent fallback never accepts an unsigned stored capability",
         %{agent_id: agent_id} do
      previous = Application.get_env(:arbor_security, :capability_signing_required)
      Application.put_env(:arbor_security, :capability_signing_required, true)
      on_exit(fn -> restore_env(:capability_signing_required, previous) end)

      {:ok, unsigned} =
        Capability.new(
          resource_uri: FileGuard.resource_uri(:read, "/unsigned-parent"),
          principal_id: agent_id
        )

      assert {:ok, :stored} = CapabilityStore.put_fixture(unsigned)

      assert {:error, :no_capability} =
               FileGuard.authorize(agent_id, "/unsigned-parent/secret.txt", :read)
    end

    test "security regression: a directory capability does not cover a sibling prefix",
         %{agent_id: agent_id} do
      {:ok, _cap} = grant_fs_capability(agent_id, :read, "/workspace")

      assert {:error, :no_capability} =
               FileGuard.authorize(agent_id, "/workspace_evil/secret.txt", :read)
    end

    test "denies without any capability", %{agent_id: agent_id} do
      assert {:error, :no_capability} = FileGuard.authorize(agent_id, "/workspace/file.ex", :read)
    end

    test "denies path traversal", %{agent_id: agent_id} do
      {:ok, _cap} = grant_fs_capability(agent_id, :read, "/workspace")

      # Capability lookup may reject the escaped path before the later path
      # resolver classifies it. Both results are fail-closed.
      assert {:error, reason} =
               FileGuard.authorize(agent_id, "/workspace/../etc/passwd", :read)

      assert reason in [:no_capability, :path_traversal]
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

      {:ok, signed} = SystemAuthority.sign_capability_for_test(cap)
      expired = %{signed | expires_at: past}
      {:ok, :stored} = CapabilityStore.put_fixture(expired)

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

    test "security regression: repeated root text cannot under-count max_depth",
         %{agent_id: agent_id} do
      {:ok, _cap} =
        grant_fs_capability(agent_id, :read, "/a", constraints: %{max_depth: 1})

      assert {:error, :max_depth_exceeded} =
               FileGuard.authorize(agent_id, "/a/a/secret.txt", :read)
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

  describe "descriptor-bound Security.read_authorized_file/3" do
    @tag spec: "SSEC-015"
    test "security regression: reads through a scoped wildcard capability root", %{
      agent_id: agent_id
    } do
      root = Path.join(System.tmp_dir!(), "file_guard_descriptor_#{System.unique_integer()}")
      path = Path.join(root, "inside.txt")
      File.mkdir_p!(root)
      File.write!(path, "descriptor-bound")
      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, capability} = grant_fs_capability(agent_id, :read, root <> "/**")

      assert {:ok, "descriptor-bound", opened_path} =
               Security.read_authorized_file(agent_id, path, verify_identity: false)

      assert {:ok, canonical_path} = SafePath.resolve_real(path)
      assert opened_path == canonical_path
      assert capability.resource_uri == FileGuard.resource_uri(:read, root <> "/**")
    end

    @tag spec: "SSEC-015"
    test "security regression: an operation-wide read capability is rooted at filesystem root",
         %{agent_id: agent_id} do
      root = Path.join(System.tmp_dir!(), "file_guard_read_wildcard_#{System.unique_integer()}")
      path = Path.join(root, "inside.txt")
      File.mkdir_p!(root)
      File.write!(path, "wildcard-read")
      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, capability} = grant_fs_capability(agent_id, :read, "/**")

      assert {:ok, "wildcard-read", _opened_path} =
               Security.read_authorized_file(agent_id, path, verify_identity: false)

      assert capability.resource_uri == "arbor://fs/read/**"
    end

    @tag spec: "KSEC-012,SSEC-015"
    test "security regression: exact file authority cannot follow a replacement symlink",
         %{agent_id: agent_id} do
      root = Path.join(System.tmp_dir!(), "file_guard_exact_read_#{System.unique_integer()}")
      outside = Path.join(root, "sibling-secret.txt")
      path = Path.join(root, "candidate.txt")
      File.mkdir_p!(root)
      File.write!(path, "inside")
      File.write!(outside, "outside-secret")
      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, capability} = grant_fs_capability(agent_id, :read, path)
      File.rm!(path)
      File.ln_s!(outside, path)

      assert {:error, reason} =
               Security.read_authorized_file(agent_id, path,
                 verify_identity: false,
                 exact_capability_id: capability.id
               )

      assert reason in [:not_regular, :path_traversal, :path_changed, :unauthorized]
    end

    @tag spec: "SSEC-015"
    test "security regression: exact file reads preserve max-depth-zero semantics", %{
      agent_id: agent_id
    } do
      root = Path.join(System.tmp_dir!(), "file_guard_exact_depth_#{System.unique_integer()}")
      path = Path.join(root, "candidate.txt")
      File.mkdir_p!(root)
      File.write!(path, "exact-depth-zero")
      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, capability} =
        grant_fs_capability(agent_id, :read, path, constraints: %{max_depth: 0})

      assert {:ok, "exact-depth-zero", _opened_path} =
               Security.read_authorized_file(agent_id, path,
                 verify_identity: false,
                 exact_capability_id: capability.id
               )
    end

    @tag spec: "SSEC-015"
    test "security regression: a single wildcard cannot read nested descendants", %{
      agent_id: agent_id
    } do
      root = Path.join(System.tmp_dir!(), "file_guard_single_read_#{System.unique_integer()}")
      path = Path.join([root, "nested", "secret.txt"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "nested-secret")
      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, _capability} = grant_fs_capability(agent_id, :read, root <> "/*")

      assert {:error, :unauthorized} =
               Security.read_authorized_file(agent_id, path, verify_identity: false)
    end

    @tag spec: "KSEC-012,SSEC-015"
    test "security regression: a single wildcard cannot reach a deeper target through a direct-child symlink",
         %{agent_id: agent_id} do
      root = Path.join(System.tmp_dir!(), "file_guard_single_link_#{System.unique_integer()}")
      deep_path = Path.join([root, "nested", "secret.txt"])
      link = Path.join(root, "shortcut")
      File.mkdir_p!(Path.dirname(deep_path))
      File.write!(deep_path, "nested-secret")
      File.ln_s!(deep_path, link)
      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, _capability} = grant_fs_capability(agent_id, :read, root <> "/*")

      assert {:error, reason} =
               Security.read_authorized_file(agent_id, link, verify_identity: false)

      assert reason in [:no_capability, :unauthorized]
    end

    @tag spec: "SSEC-015"
    test "security regression: FileGuard exposes no capability-as-data read bypass" do
      refute function_exported?(FileGuard, :read_for_capability, 2)
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

      {:ok, signed_api} = SystemAuthority.sign_capability_for_test(api_cap)
      {:ok, :stored} = CapabilityStore.put_fixture(signed_api)

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

      {:ok, signed} = SystemAuthority.sign_capability_for_test(api_cap)
      {:ok, :stored} = CapabilityStore.put_fixture(signed)

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

      {:ok, identity} = Identity.generate(name: "file-guard-h2-#{n}")
      agent_id = identity.agent_id

      assert {:ok, _cap} = grant_fs_capability(agent_id, :read, workspace)

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

      assert {:error, reason} = result

      assert reason in [:no_capability, :path_traversal, :symlink_escape],
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

      assert {:error, reason} = result

      assert reason in [:no_capability, :path_traversal, :symlink_escape],
             "file under a symlinked ancestor directory must be rejected. Got: #{inspect(result)}"
    end

    test "security regression (ancestor-symlink): creating a file under a symlinked ancestor is rejected",
         %{agent_id: agent_id, workspace: workspace, outside: outside} do
      # The write/create variant: the target file does not exist yet, so
      # resolution falls to the ancestor chain. A symlinked ancestor must still
      # be detected (otherwise the future write lands outside the root).
      assert {:ok, _cap} = grant_fs_capability(agent_id, :write, workspace)

      anc_link = Path.join(workspace, "anc_link_w")
      File.ln_s!(outside, anc_link)
      requested = Path.join(anc_link, "new_file.txt")

      result = FileGuard.authorize(agent_id, requested, :write)

      assert {:error, reason} = result

      assert reason in [:no_capability, :path_traversal, :symlink_escape],
             "creating a file under a symlinked ancestor must be rejected. Got: #{inspect(result)}"
    end

    test "security regression: create under a DEEPLY-NESTED ancestor symlink requires BOTH controls",
         %{agent_id: agent_id, workspace: workspace, outside: outside} do
      # This case fails if EITHER piece of the control is missing:
      #   * Piece A — SafePath.resolve_real following symlinks at EVERY
      #     component (not just the leaf). Here the symlink `deep_link` is a
      #     GRANDPARENT of the requested file; leaf-only resolution never sees
      #     it.
      #   * Piece B — FileGuard resolving the nearest EXISTING parent when the
      #     target file doesn't exist yet (write/create). Without it, the
      #     missing target short-circuits to "looks contained".
      #
      # Layout: <ws>/deep_link -> <outside>, and <outside>/sub exists, but
      # <outside>/sub/new.txt does not. We request a write to
      # <ws>/deep_link/sub/new.txt. resolve_real(target) is :not_found (Piece B
      # walks up to <ws>/deep_link/sub, which exists), and resolving THAT path
      # must follow the grandparent `deep_link` (Piece A) to land in <outside>
      # and be flagged. Drop either piece and the escape authorizes.
      assert {:ok, _cap} = grant_fs_capability(agent_id, :write, workspace)

      File.mkdir_p!(Path.join(outside, "sub"))
      deep_link = Path.join(workspace, "deep_link")
      File.ln_s!(outside, deep_link)
      requested = Path.join([deep_link, "sub", "new.txt"])

      result = FileGuard.authorize(agent_id, requested, :write)

      assert {:error, reason} = result

      assert reason in [:no_capability, :path_traversal, :symlink_escape],
             "create under a deeply-nested ancestor symlink must be rejected (needs both controls). " <>
               "Got: #{inspect(result)}"
    end

    test "security regression (missing immediate parent): higher ancestor symlink is rejected",
         %{agent_id: agent_id, workspace: workspace, outside: outside} do
      assert {:ok, _cap} = grant_fs_capability(agent_id, :write, workspace)

      escape_link = Path.join(workspace, "escape_missing_parent")
      missing_parent = Path.join(escape_link, "missing_parent")
      requested = Path.join(missing_parent, "new_file.txt")

      File.ln_s!(outside, escape_link)

      refute File.exists?(missing_parent)
      refute File.exists?(requested)

      result = FileGuard.authorize(agent_id, requested, :write)

      assert {:error, reason} = result

      assert reason in [:no_capability, :path_traversal, :symlink_escape],
             "a missing immediate parent must not hide a higher symlink escape. " <>
               "Got: #{inspect(result)}"
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_security, key, value)
end
