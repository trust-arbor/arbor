defmodule Arbor.Shell.ExecutablePolicyTest do
  @moduledoc """
  Focused tests for ExecutablePolicy fixed Apple absolute-path pinning.

  Production fixed paths are a compiled constant. Temporary user-owned fixtures
  cannot satisfy TrustedPath root-owned rules; tests use the doc-false merge
  helper with real system root-owned binaries when present, plus pure map
  precedence checks.
  """

  use ExUnit.Case, async: false

  alias Arbor.Shell.ExecutablePolicy
  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Shell.TrustedPath

  @moduletag :fast

  @fixed_id "/usr/bin/id"
  @fixed_sw_vers "/usr/bin/sw_vers"
  @fixed_launchctl "/bin/launchctl"
  @fixed_codesign "/usr/bin/codesign"
  @fixed_container "/usr/local/bin/container"
  @fixed_shlock "/usr/bin/shlock"

  describe "compiled fixed path set" do
    test "exposes the exact Apple control/runtime fixed paths" do
      assert ExecutablePolicy.apple_fixed_executable_paths() == [
               "/usr/local/bin/container",
               "/usr/bin/codesign",
               "/bin/launchctl",
               "/usr/bin/id",
               "/usr/bin/sw_vers",
               "/usr/bin/shlock"
             ]
    end
  end

  describe "merge_fixed_executables test helper" do
    test "pins an exact valid fixed executable without scanning its parent" do
      path =
        first_pinnable([@fixed_id, @fixed_sw_vers, @fixed_launchctl, "/bin/ls", "/usr/bin/true"])

      {by_name, by_path} =
        ExecutablePolicy.__merge_fixed_executables_for_test__(%{}, %{}, [path])

      assert {:ok, %Executable{} = exe} = Map.fetch(by_path, canonicalize(path))
      assert exe.name == Path.basename(path)
      # Fixed pinning must not grant basename authority.
      assert by_name == %{}
      refute Map.has_key?(by_name, exe.name)

      # Sibling names under the parent must not appear solely from fixed pinning.
      parent = Path.dirname(path)

      case File.ls(parent) do
        {:ok, entries} ->
          siblings =
            entries
            |> Enum.reject(&(&1 == Path.basename(path)))
            |> Enum.take(5)

          for sibling <- siblings do
            sibling_path = Path.join(parent, sibling)
            refute Map.has_key?(by_path, sibling_path)
            refute Map.has_key?(by_path, canonicalize_if_possible(sibling_path))
          end

        {:error, _} ->
          :ok
      end
    end

    test "ignores missing, relative, untrusted, and non-executable fixed paths" do
      root = tmp_root()
      user_exec = Path.join(root, "tool")
      user_data = Path.join(root, "data")
      File.mkdir_p!(root)
      File.write!(user_exec, "#!/bin/sh\necho hi\n")
      File.chmod!(user_exec, 0o755)
      File.write!(user_data, "not-exec\n")
      File.chmod!(user_data, 0o644)

      try do
        {by_name, by_path} =
          ExecutablePolicy.__merge_fixed_executables_for_test__(%{}, %{}, [
            "/no/such/executable-#{System.unique_integer([:positive])}",
            "relative/bin/tool",
            user_exec,
            user_data,
            ""
          ])

        assert by_name == %{}
        assert by_path == %{}
      after
        File.rm_rf!(root)
      end
    end

    test "fixed path pin does not override or create basename authority" do
      path = first_pinnable([@fixed_id, @fixed_sw_vers, "/bin/ls", "/usr/bin/true"])
      name = Path.basename(path)

      path_discovered = %Executable{
        name: name,
        path: "/tmp/fake-#{name}",
        device: 1,
        inode: 2,
        size: 3,
        mtime: 4,
        ctime: 5,
        mode: 0o100755,
        sha256: String.duplicate("ab", 32)
      }

      by_name = %{name => path_discovered}
      by_path = %{path_discovered.path => path_discovered}

      {merged_name, merged_path} =
        ExecutablePolicy.__merge_fixed_executables_for_test__(by_name, by_path, [path])

      # Basename map is unchanged — PATH discovery wins / fixed does not inject.
      assert Map.fetch!(merged_name, name) == path_discovered
      assert map_size(merged_name) == map_size(by_name)

      assert %Executable{} = fixed = Map.fetch!(merged_path, canonicalize(path))
      assert fixed.path == canonicalize(path)
      refute fixed.path == path_discovered.path
      # Prior PATH entry remains by exact path key.
      assert Map.get(merged_path, path_discovered.path) == path_discovered
    end

    test "does not add fixed parent directories as discoverable search roots" do
      # Merge never expands to parent directory members; empty input stays empty
      # when the fixed path is unpinnable.
      {by_name, by_path} =
        ExecutablePolicy.__merge_fixed_executables_for_test__(%{}, %{}, [
          "/tmp/definitely-not-root-owned-#{System.unique_integer([:positive])}"
        ])

      assert by_name == %{}
      assert by_path == %{}
    end
  end

  describe "live resolve with PATH excluding fixed parent" do
    setup do
      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_policy!(previous_path)
      end)

      :ok
    end

    test "resolves a fixed absolute path even when its parent is absent from search_paths" do
      # Prefer /usr/bin/* so we can keep only /bin (or /sbin) on the trusted PATH.
      path = first_pinnable([@fixed_id, @fixed_sw_vers, @fixed_codesign])
      parent = Path.dirname(path)

      # Build a startup PATH from trusted dirs that deliberately omit the parent.
      alt_dirs =
        ["/bin", "/sbin", "/usr/sbin"]
        |> Enum.reject(&(&1 == parent))
        |> Enum.filter(&File.dir?/1)

      assert alt_dirs != [], "need at least one alternate trusted directory for this host"

      replace_policy_with_startup_path!(Enum.join(alt_dirs, ":"))

      assert {:ok, %Executable{} = exe} = ExecutablePolicy.resolve(path)
      assert exe.path == canonicalize(path)
      assert exe.name == Path.basename(path)

      assert :ok = ExecutablePolicy.verify_pinned(exe)
    end

    test "fixed container path resolves when present without /usr/local/bin on PATH" do
      case TrustedPath.pin_root_owned_regular_file(@fixed_container, executable: true) do
        {:ok, _} ->
          replace_policy_with_startup_path!("/bin:/usr/bin")
          assert {:ok, %Executable{path: path}} = ExecutablePolicy.resolve(@fixed_container)
          assert path == canonicalize(@fixed_container)
          # Basename must not gain fixed-path authority solely from the pin.
          assert {:error, :executable_not_found} = ExecutablePolicy.resolve("container")

        {:error, _} ->
          # Host without a root-owned Arbor/Apple container CLI — merge helper still covers logic.
          {by_name, by_path} =
            ExecutablePolicy.__merge_fixed_executables_for_test__(%{}, %{}, [@fixed_container])

          assert by_name == %{}
          assert is_map(by_path)
      end
    end
  end

  describe "security regression" do
    setup do
      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_policy!(previous_path)
      end)

      :ok
    end

    @tag :security_regression
    test "security regression: mutating a resolved executable name fails verify_pinned" do
      # ProcessGroup uses Executable.name as multi-call argv0. verify_pinned must
      # bind that name to a real by-name or exact by-path registry entry — not only
      # device/inode/hash via by-path — or a forged applet name reuses a stolen
      # busybox identity and selects different behavior.
      replace_policy_with_startup_path!(System.get_env("PATH", "/bin:/usr/bin"))

      assert {:ok, %Executable{} = exe} = ExecutablePolicy.resolve("echo")
      assert :ok = ExecutablePolicy.verify_pinned(exe)

      mutated_name = %{exe | name: exe.name <> "-mutated"}
      assert mutated_name.name != exe.name
      assert same_device_inode?(mutated_name, exe)

      assert {:error, :executable_not_pinned} =
               ExecutablePolicy.verify_pinned(mutated_name)

      # Freeform multi-call argv0 with stolen identity must fail even when the
      # name is a plausible single path component.
      freeform_applet = %{exe | name: "not-a-registered-applet"}

      assert {:error, :executable_not_pinned} =
               ExecutablePolicy.verify_pinned(freeform_applet)

      # Path-like names are rejected before registry lookup.
      path_like = %{exe | name: "evil/echo"}
      assert {:error, :executable_not_pinned} = ExecutablePolicy.verify_pinned(path_like)

      # Unmutated resolve result remains pinned (by-name binding).
      assert :ok = ExecutablePolicy.verify_pinned(exe)
    end

    @tag :security_regression
    test "security regression: fixed absolute pin does not grant basename authority when PATH excludes parent" do
      # With a trusted search PATH that excludes /usr/bin, /usr/bin/id must still
      # resolve and verify as pinned, while basename "id" must not gain the fixed
      # identity (not found unless PATH independently supplied it).
      assert {:ok, _} = TrustedPath.pin_root_owned_regular_file(@fixed_id, executable: true)

      alt_dirs =
        ["/bin", "/sbin", "/usr/sbin"]
        |> Enum.reject(&(&1 == "/usr/bin"))
        |> Enum.filter(&File.dir?/1)

      assert alt_dirs != [], "need at least one alternate trusted directory for this host"

      # Ensure none of the alternate dirs independently supply basename "id".
      refute Enum.any?(alt_dirs, fn dir ->
               case File.ls(dir) do
                 {:ok, entries} -> "id" in entries
                 _ -> false
               end
             end),
             "alternate PATH dirs must not independently contain basename id"

      replace_policy_with_startup_path!(Enum.join(alt_dirs, ":"))

      assert {:ok, %Executable{} = exe} = ExecutablePolicy.resolve(@fixed_id)
      assert exe.path == canonicalize(@fixed_id)
      assert :ok = ExecutablePolicy.verify_pinned(exe)

      # Basename must not resolve to the fixed identity (or any identity) when
      # PATH discovery never saw it.
      assert {:error, :executable_not_found} = ExecutablePolicy.resolve("id")
    end

    @tag :security_regression
    test "security regression: /usr/bin/shlock is fixed-path only without basename or sibling authority" do
      case TrustedPath.pin_root_owned_regular_file(@fixed_shlock, executable: true) do
        {:ok, _} ->
          alt_dirs =
            ["/bin", "/sbin", "/usr/sbin"]
            |> Enum.reject(&(&1 == "/usr/bin"))
            |> Enum.filter(&File.dir?/1)

          assert alt_dirs != [], "need at least one alternate trusted directory for this host"

          refute Enum.any?(alt_dirs, fn dir ->
                   case File.ls(dir) do
                     {:ok, entries} -> "shlock" in entries
                     _ -> false
                   end
                 end),
                 "alternate PATH dirs must not independently contain basename shlock"

          replace_policy_with_startup_path!(Enum.join(alt_dirs, ":"))

          assert {:ok, %Executable{} = exe} = ExecutablePolicy.resolve(@fixed_shlock)
          assert exe.path == canonicalize(@fixed_shlock)
          assert exe.name == "shlock"
          assert :ok = ExecutablePolicy.verify_pinned(exe)

          # Fixed pin must not grant basename authority or sibling tools under /usr/bin.
          assert {:error, :executable_not_found} = ExecutablePolicy.resolve("shlock")
          assert {:error, :executable_not_found} = ExecutablePolicy.resolve("/usr/bin/true")

        {:error, _} ->
          # Non-macOS / missing shlock: still assert the compiled constant and merge shape.
          assert @fixed_shlock in ExecutablePolicy.apple_fixed_executable_paths()

          {by_name, by_path} =
            ExecutablePolicy.__merge_fixed_executables_for_test__(%{}, %{}, [@fixed_shlock])

          assert by_name == %{}
          refute Map.has_key?(by_path, "shlock")
      end
    end

    @tag :security_regression
    test "security regression: compiled fixed list is not nominatable via Application env" do
      # Nominating via Application env has no effect on the compiled list.
      previous = Application.get_env(:arbor_shell, :fixed_executable_paths)

      try do
        Application.put_env(:arbor_shell, :fixed_executable_paths, ["/evil/bin/tool"])

        assert ExecutablePolicy.apple_fixed_executable_paths() == [
                 "/usr/local/bin/container",
                 "/usr/bin/codesign",
                 "/bin/launchctl",
                 "/usr/bin/id",
                 "/usr/bin/sw_vers",
                 "/usr/bin/shlock"
               ]

        refute "/evil/bin/tool" in ExecutablePolicy.apple_fixed_executable_paths()
      after
        case previous do
          nil -> Application.delete_env(:arbor_shell, :fixed_executable_paths)
          value -> Application.put_env(:arbor_shell, :fixed_executable_paths, value)
        end
      end

      # Public merge is test-only; production does not export a nominatable merge API.
      assert function_exported?(ExecutablePolicy, :__merge_fixed_executables_for_test__, 3)
      refute function_exported?(ExecutablePolicy, :merge_fixed_executables, 3)
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp first_pinnable(paths) do
    Enum.find_value(paths, fn path ->
      case TrustedPath.pin_root_owned_regular_file(path, executable: true) do
        {:ok, %{path: pinned}} -> pinned
        _ -> nil
      end
    end) ||
      flunk("no pinnable root-owned executable among #{inspect(paths)} on this host")
  end

  defp canonicalize(path) do
    case TrustedPath.canonicalize_absolute(path) do
      {:ok, canonical} -> canonical
      _ -> path
    end
  end

  defp same_device_inode?(%Executable{} = left, %Executable{} = right) do
    left.device == right.device and left.inode == right.inode and left.sha256 == right.sha256
  end

  defp canonicalize_if_possible(path) do
    case TrustedPath.canonicalize_absolute(path) do
      {:ok, canonical} -> canonical
      _ -> path
    end
  end

  defp tmp_root do
    base =
      System.tmp_dir!()
      |> Path.join("arbor-exec-policy-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    base
  end

  defp replace_policy_with_startup_path!(startup_path) when is_binary(startup_path) do
    supervisor = Arbor.Shell.Supervisor

    case Supervisor.terminate_child(supervisor, ExecutablePolicy) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    case Supervisor.delete_child(supervisor, ExecutablePolicy) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    case Supervisor.start_child(
           supervisor,
           {ExecutablePolicy, startup_path: startup_path}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> flunk("failed to start ExecutablePolicy: #{inspect(reason)}")
    end
  end

  defp restore_policy!(previous_path) do
    path = previous_path || System.get_env("PATH", "/usr/bin:/bin")
    replace_policy_with_startup_path!(path)
  end
end
