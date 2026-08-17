Code.require_file("trusted_build_test_helpers.exs", __DIR__)

defmodule Arbor.Shell.TrustedBuildDarwinTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell
  alias Arbor.Shell.TrustedBuild
  alias Arbor.Shell.TrustedBuild.Lease
  alias Arbor.Shell.TrustedBuild.Plan
  alias Arbor.Shell.TrustedBuildTestHelpers, as: Helpers

  @darwin? match?({:unix, :darwin}, :os.type())

  setup do
    if @darwin? do
      {lease, identity, source, handle} = start_fixture!()

      on_exit(fn ->
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end)

      {:ok, lease: lease, identity: identity, source: source}
    else
      :ok
    end
  end

  test "darwin compile denies network and source writes, allows private writes, uses closed env",
       context do
    if @darwin? do
      lease = context.lease
      source = context.source
      assert {:ok, deps} = Shell.execute_trusted_build(lease, "deps_get")
      assert deps.exit_code == 0
      :ok = Helpers.after_deps_get!(lease)
      assert {:ok, result} = Shell.execute_trusted_build(lease, "compile")
      assert result.exit_code == 0
      refute File.exists?(Path.join(source, "SHOULD_NOT_WRITE"))
      refute File.exists?(Path.join(source, "apps/arbor_trust/SHOULD_NOT_WRITE"))
      assert File.exists?(Path.join(source, "apps/arbor_trust/lib/trusted_build_fixture.ex"))

      state = :sys.get_state(lease.worker)
      assert File.exists?(Path.join(state.roots.build.path, "HEX_TMP_WRITE"))
      assert File.exists?(Path.join(state.roots.deps.path, "COMPILE_DEPS_WRITE"))
      env_file = Path.join(state.roots.build.path, "env_keys.txt")
      assert File.exists?(env_file)
      keys = env_file |> File.read!() |> String.split("\n", trim: true)
      Enum.each(Plan.env_keys(), fn key -> assert key in keys end)
      refute "USER" in keys
      refute "SHELL" in keys
      lock_file = Path.join(state.roots.build.path, "mix_os_concurrency_lock.txt")
      assert File.exists?(lock_file)
      assert String.trim(File.read!(lock_file)) == "0"
      assert File.exists?(Path.join(state.roots.build.path, "PRIVATE_WRITE"))
      net_file = Path.join(state.roots.build.path, "net.txt")
      assert File.exists?(net_file)
      net = File.read!(net_file)
      refute net =~ "{:ok,"

      assert net =~ ":timeout" or net =~ ":ehostunreach" or net =~ ":enetunreach" or
               net =~ ":econnrefused" or net =~ "error"
    end
  end

  test "out-of-order rejection leaves the lease usable and a repeated phase is rejected",
       context do
    if @darwin? do
      lease = context.lease

      assert {:error, :trusted_build_phase_rejected} =
               Shell.execute_trusted_build(lease, "compile")

      assert {:ok, deps} = Shell.execute_trusted_build(lease, "deps_get")
      assert deps.exit_code == 0

      assert {:error, :trusted_build_phase_rejected} =
               Shell.execute_trusted_build(lease, "deps_get")
    end
  end

  test "ordered deps_get compile release and relative inventory", context do
    if @darwin? do
      lease = context.lease

      assert {:ok, deps} = Shell.execute_trusted_build(lease, "deps_get")
      assert deps.exit_code == 0
      :ok = Helpers.after_deps_get!(lease)
      assert {:ok, compile} = Shell.execute_trusted_build(lease, "compile")
      assert compile.exit_code == 0
      assert {:ok, release} = Shell.execute_trusted_build(lease, "release")
      assert release.exit_code == 0

      {:ok, view} = Lease.view(lease)
      assert view["state"] == "done"
      assert view["completed_phases"] == ["deps_get", "compile", "release"]
      refute Map.has_key?(view, "path")

      state = :sys.get_state(lease.worker)
      :ok = Helpers.plant_release_cookie!(state.roots.build.path)
      assert {:ok, _cookie} = Shell.remove_trusted_build_release_cookie(lease)

      assert {:ok, inventory} = Shell.inventory_trusted_build(lease)
      assert inventory["schema"] == "arbor.shell.trusted_build.inventory.v1"
      assert inventory["kind"] == "release"
      assert is_list(inventory["directories"])
      assert is_list(inventory["regular_files"])
      assert inventory["regular_files"] != []
      refute Enum.any?(inventory["directories"], &String.starts_with?(&1["path"] || "", "/"))
      refute Enum.any?(inventory["regular_files"], &String.starts_with?(&1["path"] || "", "/"))
    end
  end

  test "deps_get evaluates only the fixed child project and never the unselected root mix.exs" do
    if @darwin? do
      parent = Helpers.unique_source_root()
      {:ok, identity} = Shell.create_private_owned_tree(parent)
      source = Path.join(parent, "source")

      _project =
        Helpers.plant_production_child_project!(
          source,
          """
          defmodule TrustedBuildFixture.MixProject do
            use Mix.Project
            def project, do: [app: :trusted_build_fixture, version: "0.1.0"]
            def application, do: []
          end
          """,
          "defmodule TrustedBuildFixture, do: def hello, do: :ok\n"
        )

      File.write!(Path.join(source, "mix.exs"), """
      defmodule PoisonRoot.MixProject do
        use Mix.Project

        def project do
          build = System.get_env("MIX_BUILD_PATH")

          if is_binary(build) do
            File.mkdir_p!(build)
            File.write!(Path.join(build, "ROOT_MIX_EVALUATED"), "yes")
          end

          raise "unselected root mix.exs evaluated"
        end
      end
      """)

      :ok = Helpers.plant_fixed_overlay!(identity.path)
      handle = Helpers.handle_for_owned!(identity)
      {:ok, lease, _view} = TrustedBuild.acquire(request_for(identity), :omit_hex_seed)

      try do
        assert {:ok, deps} = Shell.execute_trusted_build(lease, "deps_get")
        assert deps.exit_code == 0
        state = :sys.get_state(lease.worker)
        refute File.exists?(Path.join(state.roots.build.path, "ROOT_MIX_EVALUATED"))
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "exact trusted-build argv is observed", context do
    if @darwin? do
      lease = context.lease

      task =
        Task.async(fn ->
          wait_until(fn ->
            Enum.any?(os_processes(), fn process ->
              String.contains?(process.command, "arbor_shell_launcher trusted-build") and
                String.contains?(process.command, "compile --warnings-as-errors")
            end)
          end)
        end)

      assert {:ok, _deps} = Shell.execute_trusted_build(lease, "deps_get")
      :ok = Helpers.after_deps_get!(lease)
      assert {:ok, compile} = Shell.execute_trusted_build(lease, "compile")
      assert compile.exit_code == 0
      assert Task.await(task, 15_000) == true
    end
  end

  defp start_fixture! do
    parent = Helpers.unique_source_root()
    {:ok, identity} = Shell.create_private_owned_tree(parent)
    source = Path.join(parent, "source")

    _project =
      Helpers.plant_production_child_project!(
        source,
        """
        defmodule TrustedBuildFixture.MixProject do
          use Mix.Project

          def project do
            build = System.get_env("MIX_BUILD_PATH")
            if is_binary(build) do
              File.mkdir_p!(build)
              File.write!(
                Path.join(build, "env_keys.txt"),
                System.get_env() |> Map.keys() |> Enum.sort() |> Enum.join("\\n")
              )
              File.write!(
                Path.join(build, "mix_os_concurrency_lock.txt"),
                System.get_env("MIX_OS_CONCURRENCY_LOCK") || ""
              )
              File.write!(Path.join(build, "PRIVATE_WRITE"), "ok")
              deps = System.get_env("MIX_DEPS_PATH")

              if is_binary(deps) and File.dir?(deps) and "compile" in System.argv() do
                File.write!(Path.join(deps, "COMPILE_DEPS_WRITE"), "ok")
              end

              hex_tmp = Path.join(File.cwd!(), "tmp_" <> String.duplicate("A", 64))

              case File.mkdir(hex_tmp) do
                :ok ->
                  _ = File.rmdir(hex_tmp)
                  File.write!(Path.join(build, "HEX_TMP_WRITE"), "ok")

                _other ->
                  :ok
              end
            end
            _ = File.write(Path.join(File.cwd!(), "SHOULD_NOT_WRITE"), "x")
            net =
              inspect({
                :gen_tcp.connect({1, 1, 1, 1}, 80, [], 200),
                :gen_tcp.connect({127, 0, 0, 1}, 80, [], 200),
                :gen_tcp.connect({0, 0, 0, 0, 0, 0, 0, 1}, 80, [:inet6], 200)
              })
            if is_binary(build), do: File.write!(Path.join(build, "net.txt"), net)
            [
              app: :trusted_build_fixture,
              version: "0.1.0",
              elixir: "~> 1.17",
              releases: [trusted_build_fixture: [include_executables_for: [:unix]]]
            ]
          end

          def application, do: []
        end
        """,
        """
        defmodule TrustedBuildFixture do
          def hello, do: :ok
        end
        """
      )

    :ok = Helpers.plant_fixed_overlay!(identity.path)

    handle = Helpers.handle_for_owned!(identity)
    request = request_for(identity)
    {:ok, lease, view} = TrustedBuild.acquire(request, :omit_hex_seed)
    assert view["schema"] == "arbor.shell.trusted_build.lease.v1"
    refute Map.has_key?(view, "path")
    {lease, identity, source, handle}
  end

  defp request_for(identity) do
    %{
      "schema" => "arbor.shell.trusted_build.request.v1",
      "source" => %{
        "schema" => "arbor.shell.trusted_build.source.v1",
        "identity" => %{
          "path" => identity.path,
          "type" => "directory",
          "device" => identity.device,
          "minor_device" => identity.minor_device,
          "inode" => identity.inode
        }
      }
    }
  end

  defp os_processes do
    {output, 0} = System.cmd("ps", ["-ax", "-o", "pid=,command="])

    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(String.trim(line), " ", parts: 2) do
        [pid, command] -> %{pid: pid, command: command}
        _other -> %{pid: "", command: line}
      end
    end)
  end

  defp wait_until(fun, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(20)
        do_wait_until(fun, deadline)
      else
        false
      end
    end
  end
end
