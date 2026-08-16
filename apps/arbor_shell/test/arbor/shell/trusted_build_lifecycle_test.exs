defmodule Arbor.Shell.TrustedBuildLifecycleTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell
  alias Arbor.Shell.TrustedBuild
  alias Arbor.Shell.TrustedBuild.Lease

  @darwin? match?({:unix, :darwin}, :os.type())

  test "release proves workspace absence and cleanup fault is retained" do
    {_lease, identity} = start_source!()

    assert {:ok, fail_lease, _view} =
             TrustedBuild.acquire(
               request_for(identity),
               :force_cleanup_failure
             )

    assert {:error, {:cleanup_retained, :forced_cleanup_failure, evidence}} =
             Shell.release_trusted_build_lease(fail_lease)

    assert is_binary(evidence.path)
    assert is_integer(evidence.device)

    {_lease2, identity2} = start_source!()

    {:ok, ok_lease, _view} =
      TrustedBuild.acquire(request_for(identity2), :omit_hex_seed)

    assert :ok = Shell.release_trusted_build_lease(ok_lease)
    _ = Shell.remove_owned_tree(identity)
    _ = Shell.remove_owned_tree(identity2)
  end

  test "identity capture failure is not build success" do
    {_lease, identity} = start_source!()

    assert {:error, :root_identity_capture_failed} =
             TrustedBuild.acquire(
               request_for(identity),
               :force_identity_capture_failure
             )

    _ = Shell.remove_owned_tree(identity)
  end

  test "rebound source cannot be acquired twice" do
    if @darwin? do
      {_unused, identity} = start_source!()
      request = request_for(identity)
      {:ok, lease, _view} = TrustedBuild.acquire(request, :omit_hex_seed)

      assert {:error, :owned_tree_purpose_mismatch} =
               TrustedBuild.acquire(request, :omit_hex_seed)

      _ = Shell.release_trusted_build_lease(lease)
      _ = Shell.remove_owned_tree(identity)
    end
  end

  test "successful compile exhausts before reply" do
    if @darwin? do
      {lease, identity} = acquire_source!()

      try do
        assert {:ok, deps} = Shell.execute_trusted_build(lease, "deps_get")
        assert deps.exit_code == 0
        assert {:ok, result} = Shell.execute_trusted_build(lease, "compile")
        assert result.exit_code == 0
        refute trusted_build_running?()
        {:ok, view} = Lease.view(lease)
        assert view["completed_phases"] == ["deps_get", "compile"]
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
      end
    end
  end

  test "nonzero mix result locks the lease" do
    if @darwin? do
      {lease, identity} = acquire_source!(:broken)

      try do
        assert {:ok, result} = Shell.execute_trusted_build(lease, "compile")
        assert result.exit_code != 0
        refute trusted_build_running?()
        assert {:error, :trusted_build_phase_locked} =
                 Shell.execute_trusted_build(lease, "deps_get")
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
      end
    end
  end

  test "timeout and overflow lock and exhaust" do
    if @darwin? do
      {timeout_lease, timeout_id} = acquire_source!(:ok, :force_phase_timeout)

      try do
        assert {:ok, result} = Shell.execute_trusted_build(timeout_lease, "compile")
        assert result.timed_out or result.killed
        refute trusted_build_running?()
        {:ok, view} = Lease.view(timeout_lease)
        assert view["locked"] == true
      after
        _ = Shell.release_trusted_build_lease(timeout_lease)
        _ = Shell.remove_owned_tree(timeout_id)
      end

      {overflow_lease, overflow_id} = acquire_source!(:ok, :force_output_overflow)

      try do
        assert {:ok, result} = Shell.execute_trusted_build(overflow_lease, "compile")
        assert result.output_limit_exceeded or result.killed or result.exit_code != 0
        refute trusted_build_running?()
      after
        _ = Shell.release_trusted_build_lease(overflow_lease)
        _ = Shell.remove_owned_tree(overflow_id)
      end
    end
  end

  test "explicit cancellation reaches the port owner" do
    if @darwin? do
      {lease, identity} = acquire_source!()

      try do
        helper =
          spawn(fn ->
            wait_until(fn ->
              state = :sys.get_state(lease.worker)
              is_reference(state.cancel_id) and is_pid(state.port_owner_pid)
            end)

            state = :sys.get_state(lease.worker)

            if is_reference(state.cancel_id) do
              send(self_owner(lease), {:cancel_shell_execution, state.cancel_id})
            end
          end)

        _ = helper
        result = Shell.execute_trusted_build(lease, "compile")
        assert match?({:ok, %{killed: true}}, result) or match?({:ok, %{cancelled: true}}, result) or
                 match?({:ok, %{exit_code: 137}}, result) or match?({:error, _}, result)
        refute trusted_build_running?()
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
      end
    end
  end

  test "phase crash locks without reporting success" do
    if @darwin? do
      {lease, identity} = acquire_source!(:ok, :crash_phase)

      try do
        assert {:error, _reason} = Shell.execute_trusted_build(lease, "compile")
        {:ok, view} = Lease.view(lease)
        assert view["locked"] == true
        refute trusted_build_running?()
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
      end
    end
  end

  test "setup failure locks and does not leave a launcher" do
    if @darwin? do
      {lease, identity, source} = acquire_source_path!()

      try do
        File.write!(Path.join(source, "bin/mix"), "#!/bin/sh\necho forged\n")
        File.chmod!(Path.join(source, "bin/mix"), 0o755)
        assert {:error, _reason} = Shell.execute_trusted_build(lease, "deps_get")
        refute trusted_build_running?()
        assert {:error, :trusted_build_phase_locked} =
                 Shell.execute_trusted_build(lease, "compile")
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
      end
    end
  end

  test "initiating owner loss does not report build success" do
    if @darwin? do
      parent = self()

      owner =
        spawn(fn ->
          {lease, identity} = acquire_source!()
          send(parent, {:ready, lease.worker, identity})
          _ = Shell.execute_trusted_build(lease, "compile")
        end)

      assert_receive {:ready, worker, identity}, 5_000
      wait_until(fn -> Process.alive?(worker) end)
      Process.exit(owner, :kill)
      wait_until(fn -> not Process.alive?(worker) or not Process.alive?(owner) end)
      refute trusted_build_running?()
      _ = Shell.remove_owned_tree(identity)
    end
  end

  test "descendants and double-fork are exhausted before reply" do
    if @darwin? do
      {lease, identity} = acquire_source!(:fork)

      try do
        result = Shell.execute_trusted_build(lease, "compile")
        assert match?({:ok, _}, result) or match?({:error, _}, result)
        refute trusted_build_running?()
        refute Enum.any?(os_processes(), &String.contains?(&1.command, "arbor-tb-fork-marker"))
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
      end
    end
  end

  defp start_source!(kind \\ :ok) do
    parent = Path.join(System.tmp_dir!(), "arbor-tb-src-#{System.unique_integer([:positive])}")
    {:ok, identity} = Shell.create_private_owned_tree(parent)
    source = Path.join(parent, "source")
    File.mkdir_p!(Path.join([source, "bin"]))
    File.mkdir_p!(Path.join([source, "lib"]))
    File.write!(Path.join(source, "mix.exs"), mix_project(kind))
    File.write!(Path.join(source, "lib/trusted_build_fixture.ex"), source_module(kind))
    File.cp!(Path.expand("../../../../../bin/mix", __DIR__), Path.join(source, "bin/mix"))
    File.chmod!(Path.join(source, "bin/mix"), 0o755)
    {nil, identity}
  end

  defp acquire_source!(kind \\ :ok, fault \\ :omit_hex_seed) do
    {_unused, identity} = start_source!(kind)
    {:ok, lease, _view} = TrustedBuild.acquire(request_for(identity), fault)
    {lease, identity}
  end

  defp acquire_source_path! do
    {_unused, identity} = start_source!()
    {:ok, lease, _view} = TrustedBuild.acquire(request_for(identity), :omit_hex_seed)
    {lease, identity, Path.join(identity.path, "source")}
  end

  defp mix_project(:broken) do
    """
    defmodule TrustedBuildFixture.MixProject do
      use Mix.Project
      def project, do: [app: :trusted_build_fixture, version: "0.1.0"]
      this is not elixir
    end
    """
  end

  defp mix_project(:fork) do
    """
    defmodule TrustedBuildFixture.MixProject do
      use Mix.Project
      def project do
        _ = Port.open({:spawn_executable, ~c"/bin/sleep"}, [:binary, args: [~c"2"]])
        _ = Port.open({:spawn_executable, ~c"/bin/sleep"}, [:binary, args: [~c"2"]])
        [app: :trusted_build_fixture, version: "0.1.0"]
      end
      def application, do: []
    end
    """
  end

  defp mix_project(_kind) do
    """
    defmodule TrustedBuildFixture.MixProject do
      use Mix.Project
      def project, do: [app: :trusted_build_fixture, version: "0.1.0"]
      def application, do: []
    end
    """
  end

  defp source_module(:broken), do: "defmodule TrustedBuildFixture do\n"
  defp source_module(_kind), do: "defmodule TrustedBuildFixture, do: def hello, do: :ok\n"

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

  defp trusted_build_running? do
    Enum.any?(os_processes(), &String.contains?(&1.command, "arbor_shell_launcher trusted-build"))
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

  defp wait_until(fun, timeout \\ 5_000) do
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

  defp self_owner(%Lease.Handle{owner: owner}), do: owner
end
