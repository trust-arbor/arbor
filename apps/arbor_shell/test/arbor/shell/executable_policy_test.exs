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

  describe "compiled fixed path set" do
    test "exposes the exact Apple control/runtime fixed paths" do
      assert ExecutablePolicy.apple_fixed_executable_paths() == [
               "/usr/local/bin/container",
               "/usr/bin/codesign",
               "/bin/launchctl",
               "/usr/bin/id",
               "/usr/bin/sw_vers"
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
      assert Map.get(by_name, exe.name) == exe

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

    test "fixed basename deterministically overrides a PATH-discovered same basename" do
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

      assert %Executable{} = fixed = Map.fetch!(merged_name, name)
      assert fixed.path == canonicalize(path)
      refute fixed.path == path_discovered.path
      assert Map.get(merged_path, fixed.path) == fixed
      # Prior PATH entry remains by exact path key but basename points at fixed.
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

      # Basename resolve also returns the fixed identity.
      assert {:ok, %Executable{path: resolved}} = ExecutablePolicy.resolve(Path.basename(path))
      assert resolved == exe.path

      assert :ok = ExecutablePolicy.verify_pinned(exe)
    end

    test "fixed container path resolves when present without /usr/local/bin on PATH" do
      case TrustedPath.pin_root_owned_regular_file(@fixed_container, executable: true) do
        {:ok, _} ->
          replace_policy_with_startup_path!("/bin:/usr/bin")
          assert {:ok, %Executable{path: path}} = ExecutablePolicy.resolve(@fixed_container)
          assert path == canonicalize(@fixed_container)

        {:error, _} ->
          # Host without a root-owned Arbor/Apple container CLI — merge helper still covers logic.
          {by_name, by_path} =
            ExecutablePolicy.__merge_fixed_executables_for_test__(%{}, %{}, [@fixed_container])

          assert by_name == %{} or Map.has_key?(by_name, "container")
          assert is_map(by_path)
      end
    end
  end

  describe "security regression" do
    @tag :security_regression
    test "security regression: no startup option or Application env nominates additional fixed paths" do
      source =
        File.read!(
          Path.expand(
            "../../../lib/arbor/shell/executable_policy.ex",
            __DIR__
          )
        )

      # Production init must pin only the compiled constant list.
      assert source =~ "@apple_fixed_executable_paths"
      assert source =~ "merge_fixed_executables("
      assert source =~ "@apple_fixed_executable_paths"

      # Must not read fixed paths from Application env or start opts.
      refute source =~ ~r/Application\.get_env\([^\n]*fixed/
      refute source =~ ~r/Keyword\.get\([^\n]*:fixed/
      refute source =~ ~r/Keyword\.get_lazy\([^\n]*:fixed/
      refute source =~ ":fixed_executable_paths"
      refute source =~ ":fixed_paths"

      # Caller-supplied option must not expand the fixed set through public start.
      # The only merge entry point outside init is the doc-false test helper.
      assert function_exported?(ExecutablePolicy, :__merge_fixed_executables_for_test__, 3)
      refute function_exported?(ExecutablePolicy, :merge_fixed_executables, 3)

      # Nominating via Application env has no effect on the compiled list.
      previous = Application.get_env(:arbor_shell, :fixed_executable_paths)

      try do
        Application.put_env(:arbor_shell, :fixed_executable_paths, ["/evil/bin/tool"])

        assert ExecutablePolicy.apple_fixed_executable_paths() == [
                 "/usr/local/bin/container",
                 "/usr/bin/codesign",
                 "/bin/launchctl",
                 "/usr/bin/id",
                 "/usr/bin/sw_vers"
               ]

        refute "/evil/bin/tool" in ExecutablePolicy.apple_fixed_executable_paths()
      after
        case previous do
          nil -> Application.delete_env(:arbor_shell, :fixed_executable_paths)
          value -> Application.put_env(:arbor_shell, :fixed_executable_paths, value)
        end
      end
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
