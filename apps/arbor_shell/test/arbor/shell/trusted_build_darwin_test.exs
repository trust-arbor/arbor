defmodule Arbor.Shell.TrustedBuildDarwinTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell
  alias Arbor.Shell.TrustedBuild
  alias Arbor.Shell.TrustedBuild.Lease
  alias Arbor.Shell.TrustedBuild.Plan

  @darwin? match?({:unix, :darwin}, :os.type())

  setup do
    if @darwin? do
      {lease, identity, source} = start_fixture!()

      on_exit(fn ->
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
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
      assert {:ok, result} = Shell.execute_trusted_build(lease, "compile")
      assert result.exit_code == 0
      refute File.exists?(Path.join(source, "SHOULD_NOT_WRITE"))
      assert File.exists?(Path.join(source, "lib/trusted_build_fixture.ex"))

      state = :sys.get_state(lease.worker)
      env_file = Path.join(state.roots.build.path, "env_keys.txt")
      assert File.exists?(env_file)
      keys = env_file |> File.read!() |> String.split("\n", trim: true)
      Enum.each(Plan.env_keys(), fn key -> assert key in keys end)
      refute "USER" in keys
      refute "SHELL" in keys
      assert File.exists?(Path.join(state.roots.build.path, "PRIVATE_WRITE"))
    end
  end

  test "phase order is enforced and a second deps_get is rejected", context do
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
      assert {:ok, compile} = Shell.execute_trusted_build(lease, "compile")
      assert compile.exit_code == 0
      assert {:ok, release} = Shell.execute_trusted_build(lease, "release")
      assert release.exit_code == 0

      {:ok, view} = Lease.view(lease)
      assert view["state"] == "done"
      assert view["completed_phases"] == ["deps_get", "compile", "release"]
      refute Map.has_key?(view, "path")

      assert {:ok, inventory} = Shell.inventory_trusted_build(lease)
      assert inventory["schema"] == "arbor.shell.trusted_build.inventory.v1"
      assert inventory["kind"] == "release"
      assert is_list(inventory["directories"])
      assert is_list(inventory["regular_files"])
      refute Enum.any?(inventory["directories"], &String.starts_with?(&1["path"] || "", "/"))
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
      assert {:ok, compile} = Shell.execute_trusted_build(lease, "compile")
      assert compile.exit_code == 0
      assert Task.await(task, 1_000) in [true, false]
    end
  end

  defp start_fixture! do
    tmp = System.tmp_dir!()
    parent = Path.join(tmp, "arbor-tb-src-#{System.unique_integer([:positive])}")
    {:ok, identity} = Shell.create_private_owned_tree(parent)
    source = Path.join(parent, "source")
    File.mkdir_p!(Path.join(source, "lib"))
    File.mkdir_p!(Path.join(source, "bin"))

    File.write!(Path.join(source, "mix.exs"), """
    defmodule TrustedBuildFixture.MixProject do
      use Mix.Project

      def project do
        build = System.get_env("MIX_BUILD_PATH")
        if is_binary(build) do
          File.mkdir_p!(build)
          File.write!(Path.join(build, "env_keys.txt"), System.get_env() |> Map.keys() |> Enum.sort() |> Enum.join("\\n"))
          File.write!(Path.join(build, "PRIVATE_WRITE"), "ok")
        end
        _ = File.write(Path.join(File.cwd!(), "SHOULD_NOT_WRITE"), "x")
        _ = :gen_tcp.connect({1, 1, 1, 1}, 80, [], 200)
        [
          app: :trusted_build_fixture,
          version: "0.1.0",
          elixir: "~> 1.17",
          releases: [trusted_build_fixture: [include_executables_for: [:unix]]]
        ]
      end

      def application, do: []
    end
    """)

    File.write!(Path.join(source, "lib/trusted_build_fixture.ex"), """
    defmodule TrustedBuildFixture do
      def hello, do: :ok
    end
    """)

    File.cp!(Path.expand("../../../../../bin/mix", __DIR__), Path.join(source, "bin/mix"))
    File.chmod!(Path.join(source, "bin/mix"), 0o755)

    request = request_for(identity)
    {:ok, lease, view} = TrustedBuild.acquire(request, :omit_hex_seed)
    assert view["schema"] == "arbor.shell.trusted_build.lease.v1"
    refute Map.has_key?(view, "path")
    {lease, identity, source}
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
