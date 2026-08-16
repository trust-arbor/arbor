defmodule Arbor.Shell.TrustedBuildLeaseTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell
  alias Arbor.Shell.Executor
  alias Arbor.Shell.OwnedTreeRegistry
  alias Arbor.Shell.ProcessGroup
  alias Arbor.Shell.TrustedBuild
  alias Arbor.Shell.TrustedBuild.Lease
  alias Arbor.Shell.TrustedBuildToolchainAuthority

  @darwin? match?({:unix, :darwin}, :os.type())

  test "token forgery and foreign callers are rejected" do
    if @darwin? do
    {lease, identity} = acquire_fixture!()

    try do
      assert {:ok, view} = Lease.view(lease)
      assert view["schema"] == "arbor.shell.trusted_build.lease.v1"
      refute Map.has_key?(view, "path")

      forged = %{lease | token: :crypto.strong_rand_bytes(32)}
      assert {:error, :foreign_caller} = Lease.view(forged)
      assert {:error, :invalid_lease} = Shell.execute_trusted_build(%{}, "deps_get")
      assert {:error, :foreign_caller} = Lease.checkout_launch(lease.worker, make_ref())
      assert {:error, :foreign_caller} = Lease.take_launch(lease.worker, make_ref())
    after
      _ = Shell.release_trusted_build_lease(lease)
      _ = Shell.remove_owned_tree(identity)
    end
    end
  end

  test "checkout_launch is single-use and take_launch requires the port owner" do
    if @darwin? do
    {lease, identity} = acquire_fixture!()

    try do
      {:ok, session} = Lease.begin_phase(lease, :deps_get, self())
      parent = self()

      phase =
        spawn(fn ->
          receive do
            :go -> :ok
          end

          first = Lease.checkout_launch(session.lease_pid, session.launch_ticket)
          send(parent, {:first, first})
          second = Lease.checkout_launch(session.lease_pid, session.launch_ticket)
          send(parent, {:second, second})

          receive do
            :stop -> :ok
          end
        end)

      assert :ok = Lease.attach_phase(lease, phase)
      send(phase, :go)
      assert_receive {:first, {:ok, descriptor}}, 2_000
      assert is_reference(descriptor.launch_permit)
      assert_receive {:second, {:error, :trusted_build_launch_unauthorized}}, 2_000

      assert {:error, :foreign_caller} =
               Lease.take_launch(session.lease_pid, descriptor.launch_permit)

      send(phase, :stop)
    after
      _ = Shell.release_trusted_build_lease(lease)
      _ = Shell.remove_owned_tree(identity)
    end
    end
  end

  test "commit then phase DOWN does not lock a successful phase" do
    if @darwin? do
    {lease, identity} = acquire_fixture!()

    try do
      {:ok, session} = Lease.begin_phase(lease, :deps_get, self())

      phase =
        spawn(fn ->
          receive do
            :go -> :ok
          end

          :ok =
            Lease.commit_phase_result(session.lease_pid, {:ok, %{exit_code: 0, timed_out: false, killed: false}})
        end)

      assert :ok = Lease.attach_phase(lease, phase)
      mon = Process.monitor(phase)
      send(phase, :go)
      assert_receive {:DOWN, ^mon, :process, ^phase, _reason}, 2_000

      {:ok, view} = Lease.view(lease)
      assert view["locked"] == false
      assert view["completed_phases"] == ["deps_get"]
      assert view["state"] == "ready"
    after
      _ = Shell.release_trusted_build_lease(lease)
      _ = Shell.remove_owned_tree(identity)
    end
    end
  end

  test "raw ProcessGroup and Executor calls without a live permit cannot fork" do
    refute function_exported?(ProcessGroup, :run_trusted_build_executable, 6)
    assert function_exported?(ProcessGroup, :run_trusted_build_executable, 2)

    assert {:error, :trusted_build_launch_unauthorized} =
             ProcessGroup.run_trusted_build_executable(self(), make_ref())

    assert {:error, :trusted_build_launch_unauthorized} =
             Executor.run_trusted_build(self(), make_ref())

    refute Enum.any?(os_processes(), &String.contains?(&1.command, "trusted-build"))
  end

  test "registry purpose rebound is rejected and generation mismatch locks" do
    if @darwin? do
    {_unused, identity} = acquire_fixture!()

    try do
      request = request_for(identity)
      {:ok, lease, _view} = TrustedBuild.acquire(request, :omit_hex_seed)

      assert {:error, :owned_tree_purpose_mismatch} =
               TrustedBuild.acquire(request, :omit_hex_seed)

      {:ok, _pid, gen} = OwnedTreeRegistry.checkout()
      assert is_reference(gen)

      {:ok, _binding, auth_pid, auth_gen} = TrustedBuildToolchainAuthority.checkout()
      assert is_pid(auth_pid)
      assert is_reference(auth_gen)

      _ = Shell.release_trusted_build_lease(lease)
    after
      _ = Shell.remove_owned_tree(identity)
    end
    end
  end

  test "reserved C3 ops fail closed" do
    if @darwin? do
      {lease, identity} = acquire_fixture!()

      try do
        assert {:error, :trusted_build_op_reserved} = Lease.reserved(lease, :stage_native_cache)
        assert {:error, :trusted_build_op_reserved} = Lease.reserved(lease, :inventory_deps)
        assert {:error, :trusted_build_op_reserved} = Lease.reserved(lease, :remove_release_cookie)
        assert {:error, :trusted_build_op_reserved} = Lease.reserved(lease, :read_descriptor)
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
      end
    end
  end

  defp acquire_fixture! do
    parent = Path.join(System.tmp_dir!(), "arbor-tb-src-#{System.unique_integer([:positive])}")
    {:ok, identity} = Shell.create_private_owned_tree(parent)
    source = Path.join(parent, "source")
    File.mkdir_p!(Path.join(source, "bin"))
    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, "mix.exs"), mix_project())
    File.write!(Path.join(source, "lib/trusted_build_fixture.ex"), "defmodule TrustedBuildFixture, do: def hello, do: :ok\n")
    File.cp!(Path.expand("../../../../../bin/mix", __DIR__), Path.join(source, "bin/mix"))
    File.chmod!(Path.join(source, "bin/mix"), 0o755)
    {:ok, lease, _view} = TrustedBuild.acquire(request_for(identity), :omit_hex_seed)
    {lease, identity}
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

  defp mix_project do
    """
    defmodule TrustedBuildFixture.MixProject do
      use Mix.Project
      def project, do: [app: :trusted_build_fixture, version: "0.1.0"]
      def application, do: []
    end
    """
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
end
