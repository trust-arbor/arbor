defmodule Arbor.Common.SafePathTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.SafePath

  @moduletag :fast

  setup do
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    root = Path.join(System.tmp_dir!(), "safe-path-" <> token)
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{tmp_dir: root}
  end

  describe "validate/1" do
    test "accepts normal paths" do
      assert :ok = SafePath.validate("file.txt")
      assert :ok = SafePath.validate("subdir/file.txt")
      assert :ok = SafePath.validate("deep/nested/path/file.txt")
      assert :ok = SafePath.validate("/absolute/path/file.txt")
    end

    test "rejects empty paths" do
      assert {:error, :empty_path} = SafePath.validate("")
    end

    test "allows literal .. (security enforced by resolve_within)" do
      # validate/1 allows literal ".." - the actual security check is in
      # resolve_within/2 which verifies resolved paths stay within bounds
      assert :ok = SafePath.validate("..")
      assert :ok = SafePath.validate("../file.txt")
      assert :ok = SafePath.validate("subdir/../file.txt")
      assert :ok = SafePath.validate("subdir/../../etc/passwd")
    end

    test "rejects URL-encoded traversal sequences" do
      assert {:error, :traversal_sequence} = SafePath.validate("%2e%2e/etc/passwd")
      assert {:error, :traversal_sequence} = SafePath.validate("%2E%2E/etc/passwd")
      assert {:error, :traversal_sequence} = SafePath.validate("subdir/%2e%2e/etc/passwd")
    end

    test "rejects paths with null bytes" do
      assert {:error, :null_byte} = SafePath.validate("file.txt\x00.jpg")
      assert {:error, :null_byte} = SafePath.validate("path/to\x00/file")
    end

    test "accepts paths with dots that aren't traversal" do
      assert :ok = SafePath.validate("file.txt")
      assert :ok = SafePath.validate(".hidden")
      assert :ok = SafePath.validate("path/.config")
      assert :ok = SafePath.validate("file.name.with.dots.txt")
    end
  end

  describe "validate!/1" do
    test "returns :ok for valid paths" do
      assert :ok = SafePath.validate!("safe/path/file.txt")
    end

    test "raises TraversalError for encoded traversal" do
      assert_raise SafePath.TraversalError, ~r/traversal/i, fn ->
        SafePath.validate!("%2e%2e/evil")
      end
    end

    test "raises TraversalError for null bytes" do
      assert_raise SafePath.TraversalError, ~r/null/i, fn ->
        SafePath.validate!("file\x00.txt")
      end
    end
  end

  describe "within?/2" do
    test "returns true for paths within root" do
      assert SafePath.within?("/workspace/file.txt", "/workspace")
      assert SafePath.within?("/workspace/subdir/file.txt", "/workspace")
      assert SafePath.within?("/workspace/deep/nested/path.txt", "/workspace")
    end

    test "returns false for paths outside root" do
      refute SafePath.within?("/etc/passwd", "/workspace")
      refute SafePath.within?("/workspace/../etc/passwd", "/workspace")
      refute SafePath.within?("/other/path", "/workspace")
    end

    test "handles relative paths against root" do
      # Relative paths are resolved relative to root
      assert SafePath.within?("file.txt", "/workspace")
      assert SafePath.within?("subdir/file.txt", "/workspace")
    end

    test "rejects relative path traversal escapes" do
      refute SafePath.within?("../etc/passwd", "/workspace")
      refute SafePath.within?("subdir/../../etc/passwd", "/workspace")
    end

    test "handles root path exactly" do
      assert SafePath.within?("/workspace", "/workspace")
    end

    test "rejects paths that are prefixes but not children" do
      # /workspace2 is not within /workspace even though it starts with /workspace
      refute SafePath.within?("/workspace2/file.txt", "/workspace")
    end
  end

  describe "resolve_within/2" do
    test "returns resolved path for valid paths" do
      assert {:ok, "/workspace/file.txt"} = SafePath.resolve_within("file.txt", "/workspace")

      assert {:ok, "/workspace/subdir/file.txt"} =
               SafePath.resolve_within("subdir/file.txt", "/workspace")
    end

    test "resolves . and .. within bounds" do
      assert {:ok, "/workspace/file.txt"} = SafePath.resolve_within("./file.txt", "/workspace")

      assert {:ok, "/workspace/file.txt"} =
               SafePath.resolve_within("subdir/../file.txt", "/workspace")
    end

    test "returns error for escaping paths" do
      assert {:error, :path_traversal} = SafePath.resolve_within("../etc/passwd", "/workspace")
      # This one escapes: a/b/c + 4 levels up goes above /workspace
      assert {:error, :path_traversal} =
               SafePath.resolve_within("a/b/c/../../../../etc/passwd", "/workspace")
    end

    test "allows .. that stays within bounds" do
      # a/b/c + 3 levels up = /workspace, then /etc/passwd = /workspace/etc/passwd (within bounds)
      assert {:ok, "/workspace/etc/passwd"} =
               SafePath.resolve_within("a/b/c/../../../etc/passwd", "/workspace")
    end

    @tag spec: "KSEC-012"
    test "security regression: resolves ancestor symlinks before checking containment", %{
      tmp_dir: tmp_dir
    } do
      root = Path.join(tmp_dir, "root")
      outside = Path.join(tmp_dir, "outside")
      File.mkdir!(root)
      File.mkdir!(outside)
      File.write!(Path.join(outside, "secret"), "secret")
      File.ln_s!(outside, Path.join(root, "escape"))

      assert {:error, :path_traversal} = SafePath.resolve_within("escape/secret", root)
      assert {:error, :path_traversal} = SafePath.safe_join(root, "escape/secret")
    end

    @tag spec: "KSEC-012"
    test "security regression: applies dot-dot after resolving a symlink", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "root")
      outside = Path.join(tmp_dir, "outside")
      outside_child = Path.join(outside, "child")
      File.mkdir!(root)
      File.mkdir_p!(outside_child)
      File.write!(Path.join(outside, "secret"), "secret")
      File.ln_s!(outside_child, Path.join(root, "escape"))

      assert {:error, :path_traversal} = SafePath.resolve_within("escape/../secret", root)
    end

    test "accepts symlinks whose resolved target stays inside the root", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "root")
      target = Path.join(root, "target")
      File.mkdir!(root)
      File.mkdir!(target)
      File.write!(Path.join(target, "file"), "ok")
      File.ln_s!(target, Path.join(root, "inside"))

      assert {:ok, resolved} = SafePath.resolve_within("inside/file", root)
      assert {:ok, canonical_target} = SafePath.resolve_real(Path.join(target, "file"))
      assert resolved == canonical_target
    end
  end

  describe "safe_join/2" do
    test "joins paths safely" do
      assert {:ok, "/workspace/file.txt"} = SafePath.safe_join("/workspace", "file.txt")

      assert {:ok, "/workspace/subdir/file.txt"} =
               SafePath.safe_join("/workspace", "subdir/file.txt")
    end

    test "rejects traversal attempts" do
      assert {:error, :path_traversal} = SafePath.safe_join("/workspace", "../etc/passwd")

      assert {:error, :path_traversal} =
               SafePath.safe_join("/workspace", "subdir/../../etc/passwd")
    end

    test "rejects absolute user paths" do
      assert {:error, :path_traversal} = SafePath.safe_join("/workspace", "/etc/passwd")
      assert {:error, :path_traversal} = SafePath.safe_join("/workspace", "/absolute/path")
    end
  end

  describe "read_within/2" do
    @tag spec: "KSEC-012"
    test "security regression: the native reader is BEAM-embedded and never resolved from priv" do
      artifact = Arbor.Common.SafePath.NativeReaderArtifact

      assert {:module, ^artifact} = Code.ensure_loaded(artifact)
      binary = artifact.binary()
      assert is_binary(binary)
      assert byte_size(binary) > 0

      assert artifact.binary_sha256() ==
               Base.encode16(:crypto.hash(:sha256, binary), case: :lower)

      safe_path_beam = :code.which(SafePath)
      assert is_list(safe_path_beam)

      assert {:ok, {_module, [{:imports, imports}]}} =
               :beam_lib.chunks(safe_path_beam, [:imports])

      refute {:code, :priv_dir, 1} in imports
      refute {:code, :lib_dir, 1} in imports
    end

    @tag spec: "KSEC-012"
    test "security regression: materialized helper is sealed against same-uid file writes", %{
      tmp_dir: tmp_dir
    } do
      root = Path.join(tmp_dir, "root")
      File.mkdir!(root)
      File.write!(Path.join(root, "file.txt"), "inside")
      test_process = self()

      sealed_hook = fn directory, executable ->
        assert {:ok, %File.Stat{type: :directory, mode: directory_mode}} =
                 File.lstat(directory, time: :posix)

        assert {:ok, %File.Stat{type: :regular, mode: executable_mode}} =
                 File.lstat(executable, time: :posix)

        assert Bitwise.band(directory_mode, 0o777) == 0o500
        assert Bitwise.band(executable_mode, 0o777) == 0o500
        assert {:error, write_reason} = File.write(executable, "attacker-native-image")
        assert write_reason in [:eacces, :eperm]
        send(test_process, {:sealed_materialization, directory, executable})
        :ok
      end

      assert {:ok, "inside", _resolved} =
               SafePath.read_within_materialization_fixture(
                 "file.txt",
                 root,
                 fn -> :ok end,
                 sealed_hook
               )

      assert_received {:sealed_materialization, directory, executable}
      refute File.exists?(executable)
      refute File.exists?(directory)
    end

    @tag spec: "KSEC-012"
    test "security regression: caller death during materialization cannot strand a native helper",
         %{
           tmp_dir: tmp_dir
         } do
      root = Path.join(tmp_dir, "root")
      File.mkdir!(root)
      File.write!(Path.join(root, "file.txt"), "inside")
      test_process = self()

      sealed_hook = fn directory, executable ->
        send(test_process, {:blocked_materialization, directory, executable})

        receive do
          :never_released -> :ok
        end
      end

      {caller, caller_monitor} =
        spawn_monitor(fn ->
          SafePath.read_within_materialization_fixture(
            "file.txt",
            root,
            fn -> :ok end,
            sealed_hook
          )
        end)

      assert_receive {:blocked_materialization, directory, executable}, 1_000
      assert File.exists?(directory)
      assert File.exists?(executable)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000

      assert eventually(fn ->
               not File.exists?(executable) and not File.exists?(directory)
             end)
    end

    test "reads a regular file through its verified descriptor", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "root")
      File.mkdir!(root)
      File.write!(Path.join(root, "file.txt"), "inside")

      assert {:ok, "inside", resolved} = SafePath.read_within("file.txt", root)
      assert {:ok, canonical} = SafePath.resolve_real(Path.join(root, "file.txt"))
      assert resolved == canonical
    end

    @tag spec: "KSEC-012"
    test "security regression: checked validation runs before descriptor data is read", %{
      tmp_dir: tmp_dir
    } do
      root = Path.join(tmp_dir, "root")
      candidate = Path.join(root, "candidate.txt")
      File.mkdir!(root)
      File.write!(candidate, "before-validation")
      assert {:ok, canonical_candidate} = SafePath.resolve_real(candidate)

      validator = fn opened_path ->
        assert opened_path == canonical_candidate
        File.write!(candidate, "after-validation")
        :ok
      end

      assert {:ok, "after-validation", ^canonical_candidate} =
               SafePath.read_within_checked(candidate, root, validator)
    end

    @tag spec: "KSEC-012"
    test "security regression: validator denial closes the opened descriptor without DATA", %{
      tmp_dir: tmp_dir
    } do
      root = Path.join(tmp_dir, "root")
      candidate = Path.join(root, "candidate.txt")
      File.mkdir!(root)
      File.write!(candidate, "must-not-be-returned")
      assert {:ok, canonical_candidate} = SafePath.resolve_real(candidate)
      test_process = self()

      validator = fn opened_path ->
        send(test_process, {:validated, opened_path})
        {:error, :constraint_denied}
      end

      assert {:error, :constraint_denied} =
               SafePath.read_within_checked(candidate, root, validator)

      assert_received {:validated, ^canonical_candidate}
    end

    @tag spec: "KSEC-012"
    test "security regression: a bound root replacement is rejected before read", %{
      tmp_dir: tmp_dir
    } do
      root = Path.join(tmp_dir, "root")
      original_root = Path.join(tmp_dir, "original-root")
      File.mkdir!(root)
      File.write!(Path.join(root, "candidate.txt"), "inside")
      assert {:ok, canonical_root} = SafePath.resolve_real(root)
      assert {:ok, binding} = SafePath.bind_root(root)
      assert SafePath.binding_root(binding) == canonical_root

      File.rename!(root, original_root)
      File.mkdir!(root)
      File.write!(Path.join(root, "candidate.txt"), "outside-secret")

      assert {:error, :path_changed} =
               SafePath.read_within_bound_checked("candidate.txt", binding, fn _path -> :ok end)

      assert {:error, :path_changed} =
               SafePath.read_exact_bound_checked("candidate.txt", binding, fn _path -> :ok end)
    end

    @tag spec: "KSEC-012"
    test "security regression: native protocol self-unlinks before READY and X emits no DATA", %{
      tmp_dir: tmp_dir
    } do
      token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      helper_directory = Path.join("/tmp", "arbor-safe-path-reader-" <> token)
      helper = Path.join(helper_directory, "reader")
      root = Path.join(tmp_dir, "root")
      File.mkdir!(helper_directory)

      on_exit(fn ->
        _ = File.chmod(helper_directory, 0o700)
        File.rm_rf!(helper_directory)
      end)

      File.write!(helper, Arbor.Common.SafePath.NativeReaderArtifact.binary())
      File.chmod!(helper, 0o500)
      File.chmod!(helper_directory, 0o500)
      File.mkdir!(root)
      File.write!(Path.join(root, "candidate.txt"), "must-not-be-emitted")

      assert {:ok, canonical_root} = SafePath.resolve_real(root)
      assert {:ok, %File.Stat{major_device: device, inode: inode}} = File.stat(canonical_root)

      args = [
        helper_directory,
        helper,
        canonical_root,
        Integer.to_string(device),
        Integer.to_string(inode),
        "candidate.txt"
      ]

      port =
        Port.open({:spawn_executable, to_charlist(helper)}, [
          :binary,
          :exit_status,
          :use_stdio,
          args: Enum.map(args, &to_charlist/1)
        ])

      assert_receive {^port, {:data, "READY\n"}}, 1_000
      refute File.exists?(helper)
      refute File.exists?(helper_directory)
      assert Port.command(port, "O")
      assert_receive {^port, {:data, "FILE\n"}}, 1_000
      assert Port.command(port, "X")
      assert_receive {^port, {:exit_status, 0}}, 1_000
      refute_receive {^port, {:data, _unexpected}}, 100
    end

    @tag spec: "KSEC-012"
    test "security regression: a symlink swap between check and open cannot escape", %{
      tmp_dir: tmp_dir
    } do
      root = Path.join(tmp_dir, "root")
      outside = Path.join(tmp_dir, "outside.txt")
      candidate = Path.join(root, "candidate.txt")
      File.mkdir!(root)
      File.write!(candidate, "inside")
      File.write!(outside, "outside-secret")

      swap = fn ->
        File.rm!(candidate)
        File.ln_s!(outside, candidate)
        :ok
      end

      assert {:error, reason} = SafePath.read_within_fixture("candidate.txt", root, swap)
      assert reason in [:path_changed, :path_traversal]
    end

    @tag spec: "KSEC-012"
    test "security regression: the opened root stays pinned across a pathname replacement", %{
      tmp_dir: tmp_dir
    } do
      root = Path.join(tmp_dir, "root")
      pinned_root = Path.join(tmp_dir, "pinned-root")
      outside = Path.join(tmp_dir, "outside")
      File.mkdir!(root)
      File.mkdir!(outside)
      File.write!(Path.join(root, "candidate.txt"), "inside")
      File.write!(Path.join(outside, "candidate.txt"), "outside-secret")
      assert {:ok, canonical_candidate} = SafePath.resolve_real(Path.join(root, "candidate.txt"))

      replace_root = fn ->
        File.rename!(root, pinned_root)
        File.ln_s!(outside, root)
        :ok
      end

      assert {:ok, "inside", resolved} =
               SafePath.read_within_fixture("candidate.txt", root, replace_root)

      assert resolved == canonical_candidate
    end

    @tag spec: "KSEC-012"
    test "security regression: an ancestor replacement cannot redirect the descriptor walk", %{
      tmp_dir: tmp_dir
    } do
      root = Path.join(tmp_dir, "root")
      ancestor = Path.join(root, "ancestor")
      pinned_ancestor = Path.join(root, "pinned-ancestor")
      outside = Path.join(tmp_dir, "outside")
      File.mkdir_p!(ancestor)
      File.mkdir!(outside)
      File.write!(Path.join(ancestor, "candidate.txt"), "inside")
      File.write!(Path.join(outside, "candidate.txt"), "outside-secret")

      replace_ancestor = fn ->
        File.rename!(ancestor, pinned_ancestor)
        File.ln_s!(outside, ancestor)
        :ok
      end

      result =
        SafePath.read_within_fixture("ancestor/candidate.txt", root, replace_ancestor)

      case result do
        {:ok, content, _resolved} -> assert content == "inside"
        {:error, _reason} -> :ok
      end
    end
  end

  describe "read_exact/2" do
    test "reads only the exact regular-file leaf", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "root")
      candidate = Path.join(root, "candidate.txt")
      File.mkdir!(root)
      File.write!(candidate, "inside")

      assert {:ok, "inside", resolved} = SafePath.read_exact(candidate, root)
      assert {:ok, canonical} = SafePath.resolve_real(candidate)
      assert resolved == canonical
    end

    @tag spec: "KSEC-012"
    test "security regression: an exact leaf swap is rejected before descriptor data is returned",
         %{
           tmp_dir: tmp_dir
         } do
      root = Path.join(tmp_dir, "root")
      candidate = Path.join(root, "candidate.txt")
      sibling = Path.join(root, "sibling-secret.txt")
      File.mkdir!(root)
      File.write!(candidate, "inside")
      File.write!(sibling, "sibling-secret")

      swap = fn ->
        File.rm!(candidate)
        File.ln_s!(sibling, candidate)
        :ok
      end

      assert {:error, reason} = SafePath.read_exact_fixture(candidate, root, swap)
      assert reason in [:not_regular, :path_changed, :path_traversal]
    end
  end

  describe "safe_join!/2" do
    test "returns path for valid joins" do
      assert "/workspace/file.txt" = SafePath.safe_join!("/workspace", "file.txt")
    end

    test "raises for invalid joins" do
      assert_raise SafePath.TraversalError, fn ->
        SafePath.safe_join!("/workspace", "../escape")
      end
    end
  end

  describe "normalize/1" do
    test "resolves . components" do
      assert "/workspace/file.txt" = SafePath.normalize("/workspace/./file.txt")
      assert "/workspace/file.txt" = SafePath.normalize("/workspace/./subdir/../file.txt")
    end

    test "resolves .. components" do
      assert "/workspace/file.txt" = SafePath.normalize("/workspace/subdir/../file.txt")
      assert "/file.txt" = SafePath.normalize("/workspace/../file.txt")
    end

    test "handles multiple consecutive separators" do
      normalized = SafePath.normalize("/workspace//subdir///file.txt")
      assert String.contains?(normalized, "workspace")
      assert String.contains?(normalized, "file.txt")
    end
  end

  describe "absolute?/1 and relative?/1" do
    test "correctly identifies absolute paths" do
      assert SafePath.absolute?("/absolute/path")
      assert SafePath.absolute?("/")
      refute SafePath.absolute?("relative/path")
      refute SafePath.absolute?("./relative")
    end

    test "correctly identifies relative paths" do
      assert SafePath.relative?("relative/path")
      assert SafePath.relative?("./relative")
      assert SafePath.relative?("file.txt")
      refute SafePath.relative?("/absolute/path")
    end
  end

  describe "safe_basename/1" do
    test "extracts safe basenames" do
      assert {:ok, "file.txt"} = SafePath.safe_basename("/path/to/file.txt")
      assert {:ok, "file.txt"} = SafePath.safe_basename("file.txt")
      assert {:ok, "file"} = SafePath.safe_basename("/path/to/file")
    end

    test "rejects traversal in basename" do
      assert {:error, :traversal_sequence} = SafePath.safe_basename("/path/to/..")
      assert {:error, :traversal_sequence} = SafePath.safe_basename("..")
    end

    test "handles trailing slashes" do
      # Path.basename strips trailing slash, so "/path/to/" becomes "to"
      assert {:ok, "to"} = SafePath.safe_basename("/path/to/")
    end

    test "rejects root path" do
      assert {:error, :empty_path} = SafePath.safe_basename("/")
    end
  end

  describe "sanitize_filename/1" do
    test "keeps safe filenames unchanged" do
      assert "file.txt" = SafePath.sanitize_filename("file.txt")
      assert "my-file_name.txt" = SafePath.sanitize_filename("my-file_name.txt")
    end

    test "removes path separators" do
      assert "etc_passwd" = SafePath.sanitize_filename("etc/passwd")
      assert "etc_passwd" = SafePath.sanitize_filename("etc\\passwd")
    end

    test "removes leading dots" do
      assert "hidden" = SafePath.sanitize_filename("..hidden")
      assert "file.txt" = SafePath.sanitize_filename("...file.txt")
    end

    test "removes traversal sequences" do
      result = SafePath.sanitize_filename("../../../etc/passwd")
      refute String.contains?(result, "..")
      refute String.contains?(result, "/")
    end

    test "removes null bytes" do
      result = SafePath.sanitize_filename("file\x00.txt")
      refute String.contains?(result, <<0>>)
    end

    test "returns 'unnamed' for completely invalid input" do
      assert "unnamed" = SafePath.sanitize_filename("..")
      assert "unnamed" = SafePath.sanitize_filename("...")
      assert "unnamed" = SafePath.sanitize_filename("/")
    end

    test "respects max_length option" do
      long_name = String.duplicate("a", 300)
      result = SafePath.sanitize_filename(long_name, max_length: 100)
      assert String.length(result) == 100
    end

    test "uses custom replacement character" do
      assert "etc-passwd" = SafePath.sanitize_filename("etc/passwd", replacement: "-")
    end
  end

  describe "resolve_real/1" do
    test "resolves existing paths", %{tmp_dir: tmp_dir} do
      # Create a test file
      test_file = Path.join(tmp_dir, "test.txt")
      File.write!(test_file, "test")

      assert {:ok, resolved} = SafePath.resolve_real(test_file)
      assert String.ends_with?(resolved, "test.txt")
    end

    test "returns error for non-existent paths" do
      assert {:error, :not_found} = SafePath.resolve_real("/definitely/does/not/exist/12345")
    end

    test "follows symlinks", %{tmp_dir: tmp_dir} do
      # Create a file and a symlink to it
      real_file = Path.join(tmp_dir, "real.txt")
      link_file = Path.join(tmp_dir, "link.txt")

      File.write!(real_file, "test")
      File.ln_s!(real_file, link_file)

      assert {:ok, resolved} = SafePath.resolve_real(link_file)
      assert String.ends_with?(resolved, "real.txt")
    end
  end

  # ==========================================================================
  # Encoded traversal edge cases
  # ==========================================================================

  describe "encoded traversal patterns" do
    test "rejects double-encoded traversal sequences" do
      assert {:error, :traversal_sequence} = SafePath.validate("%252e%252e/etc/passwd")
      assert {:error, :traversal_sequence} = SafePath.validate("subdir/%252e%252e/etc/passwd")
    end

    test "rejects mixed encoding traversal sequences" do
      assert {:error, :traversal_sequence} = SafePath.validate("%2e./etc/passwd")
      assert {:error, :traversal_sequence} = SafePath.validate(".%2e/etc/passwd")
    end

    test "rejects case-insensitive encoded traversal" do
      # Upper/lower mix beyond what's already tested
      assert {:error, :traversal_sequence} = SafePath.validate("%2E%2e/etc/passwd")
      assert {:error, :traversal_sequence} = SafePath.validate("%2e%2E/etc/passwd")
    end

    test "encoded traversal rejected by resolve_within before path resolution" do
      assert {:error, :traversal_sequence} =
               SafePath.resolve_within("%2e%2e/etc/passwd", "/workspace")

      assert {:error, :traversal_sequence} =
               SafePath.resolve_within("%252e%252e/secret", "/workspace")
    end

    test "encoded traversal rejected by safe_join" do
      assert {:error, :traversal_sequence} = SafePath.safe_join("/workspace", "%2e%2e/escape")
      assert {:error, :traversal_sequence} = SafePath.safe_join("/workspace", ".%2e/escape")
    end
  end

  # ==========================================================================
  # Invalid encoding edge cases
  # ==========================================================================

  describe "invalid encoding" do
    test "rejects invalid UTF-8 sequences" do
      # 0xFF is not valid UTF-8 start byte
      assert {:error, :invalid_encoding} = SafePath.validate(<<0xFF, 0xFE>>)
    end

    test "rejects truncated multi-byte UTF-8" do
      # 0xC3 starts a 2-byte sequence but is alone
      assert {:error, :invalid_encoding} = SafePath.validate(<<0xC3>>)
    end

    test "validate! raises for invalid encoding" do
      assert_raise SafePath.TraversalError, ~r/invalid encoding/i, fn ->
        SafePath.validate!(<<0xFF, 0xFE>>)
      end
    end
  end

  # ==========================================================================
  # safe_basename edge cases
  # ==========================================================================

  describe "safe_basename edge cases" do
    test "single dot returns traversal error" do
      assert {:error, :traversal_sequence} = SafePath.safe_basename(".")
    end

    test "path ending in single dot" do
      assert {:error, :traversal_sequence} = SafePath.safe_basename("/path/to/.")
    end

    test "hidden file is allowed" do
      assert {:ok, ".gitignore"} = SafePath.safe_basename("/path/.gitignore")
    end
  end

  # ==========================================================================
  # Backslash and platform edge cases
  # ==========================================================================

  describe "platform edge cases" do
    test "backslash is treated as literal character in paths (Unix)" do
      # On Unix, backslash is a valid filename character, not a separator
      # validate/1 doesn't reject it
      assert :ok = SafePath.validate("file\\name.txt")
    end

    test "sanitize_filename strips backslashes" do
      # sanitize_filename treats backslash as separator and replaces it
      assert "dir_file.txt" = SafePath.sanitize_filename("dir\\file.txt")
    end

    test "backslash traversal doesn't bypass resolve_within" do
      # Even if someone tries Windows-style traversal, resolve_within
      # treats the backslash as a literal character, not a separator
      result = SafePath.resolve_within("..\\..\\etc\\passwd", "/workspace")
      # The path resolves within /workspace since \ is literal on Unix
      assert {:ok, resolved} = result
      assert String.starts_with?(resolved, "/workspace")
    end
  end

  # ==========================================================================
  # Symlink chain resolution
  # ==========================================================================

  describe "resolve_real edge cases" do
    @tag spec: "KSEC-012"
    test "security regression: does not collapse dot-dot before following a symlink", %{
      tmp_dir: tmp_dir
    } do
      root = Path.join(tmp_dir, "root")
      outside = Path.join(tmp_dir, "outside")
      outside_child = Path.join(outside, "child")
      File.mkdir!(root)
      File.mkdir_p!(outside_child)
      File.write!(Path.join(outside, "secret"), "secret")
      File.ln_s!(outside_child, Path.join(root, "link"))

      assert {:ok, resolved} = SafePath.resolve_real(Path.join(root, "link/../secret"))
      assert {:ok, canonical_outside} = SafePath.resolve_real(Path.join(outside, "secret"))
      assert resolved == canonical_outside
    end

    test "resolves symlink chains", %{tmp_dir: tmp_dir} do
      real_file = Path.join(tmp_dir, "real.txt")
      link1 = Path.join(tmp_dir, "link1.txt")
      link2 = Path.join(tmp_dir, "link2.txt")

      File.write!(real_file, "test")
      File.ln_s!(real_file, link1)
      File.ln_s!(link1, link2)

      assert {:ok, resolved} = SafePath.resolve_real(link2)
      assert String.ends_with?(resolved, "real.txt")
    end

    test "resolves relative symlinks", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(subdir)

      real_file = Path.join(subdir, "target.txt")
      File.write!(real_file, "test")

      # Create a relative symlink from tmp_dir pointing into subdir
      link = Path.join(tmp_dir, "rel_link.txt")
      File.ln_s!("subdir/target.txt", link)

      assert {:ok, resolved} = SafePath.resolve_real(link)
      assert String.ends_with?(resolved, "target.txt")
    end
  end

  describe "TraversalError" do
    test "has meaningful messages for all reason types" do
      assert Exception.message(%SafePath.TraversalError{reason: :path_traversal}) =~
               "traversal"

      assert Exception.message(%SafePath.TraversalError{reason: :traversal_sequence}) =~
               "traversal sequence"

      assert Exception.message(%SafePath.TraversalError{reason: :null_byte}) =~
               "null"

      assert Exception.message(%SafePath.TraversalError{reason: :empty_path}) =~
               "empty"

      assert Exception.message(%SafePath.TraversalError{reason: :invalid_encoding}) =~
               "invalid encoding"

      assert Exception.message(%SafePath.TraversalError{reason: :absolute_in_relative_context}) =~
               "Absolute path"

      assert Exception.message(%SafePath.TraversalError{reason: :custom_reason}) =~
               "custom_reason"
    end
  end

  describe "lexical_child/2" do
    test "keeps a leaf symlink instead of returning its target", %{tmp_dir: tmp_dir} do
      {:ok, canonical} = SafePath.resolve_real(tmp_dir)
      target = Path.join(canonical, "target.txt")
      link = Path.join(canonical, "link.txt")
      File.write!(target, "payload")
      :ok = File.ln_s(target, link)

      assert {:ok, ^link} = SafePath.lexical_child(tmp_dir, "link.txt")
      assert {:ok, ^target} = SafePath.resolve_real(link)
    end

    test "rebases a non-canonical absolute path onto the resolved root", %{tmp_dir: tmp_dir} do
      {:ok, canonical} = SafePath.resolve_real(tmp_dir)
      file = Path.join(canonical, "notes.txt")
      File.write!(file, "notes")

      assert {:ok, ^file} = SafePath.lexical_child(tmp_dir, file)
    end

    test "rejects a lexical escape", %{tmp_dir: tmp_dir} do
      assert {:error, :path_traversal} = SafePath.lexical_child(tmp_dir, "../outside.txt")
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
