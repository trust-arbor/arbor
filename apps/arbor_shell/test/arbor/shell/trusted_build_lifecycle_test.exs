Code.require_file("trusted_build_test_helpers.exs", __DIR__)

defmodule Arbor.Shell.TrustedBuildLifecycleTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell
  alias Arbor.Shell.OwnedTreeRegistry
  alias Arbor.Shell.TrustedBuild
  alias Arbor.Shell.TrustedBuild.Lease
  alias Arbor.Shell.TrustedBuildTestHelpers, as: Helpers

  @darwin? match?({:unix, :darwin}, :os.type())

  test "release proves workspace absence and cleanup fault is retained" do
    {_lease, identity, handle} = start_source!()

    assert {:ok, fail_lease, _view} =
             TrustedBuild.acquire(request_for(identity), :force_cleanup_failure)

    assert {:error, {:cleanup_retained, :forced_cleanup_failure, evidence}} =
             Shell.release_trusted_build_lease(fail_lease)

    assert is_binary(evidence.path)
    assert is_integer(evidence.device)
    assert :ok = Helpers.stop_retained_worker(fail_lease.worker)

    {_lease2, identity2, handle2} = start_source!()
    {:ok, ok_lease, _view} = TrustedBuild.acquire(request_for(identity2), :omit_hex_seed)
    assert :ok = Shell.release_trusted_build_lease(ok_lease)
    assert {:error, :invalid_lease} = Shell.release_trusted_build_lease(ok_lease)
    _ = Shell.remove_owned_tree(identity)
    _ = Shell.remove_owned_tree(identity2)
    assert :ok = Helpers.rm_fixture!(handle)
    assert :ok = Helpers.rm_fixture!(handle2)
  end

  test "identity capture failure is not build success" do
    {_lease, identity, handle} = start_source!()

    assert {:error, :root_identity_capture_failed} =
             TrustedBuild.acquire(request_for(identity), :force_identity_capture_failure)

    _ = Shell.remove_owned_tree(identity)
    assert :ok = Helpers.rm_fixture!(handle)
  end

  test "acquire-path source-unbind failure is propagated" do
    if @darwin? do
      {_lease, identity, handle} = start_source!()

      try do
        result = TrustedBuild.acquire(request_for(identity), :force_source_unbind_failure)

        assert {:error,
                {:trusted_build_source_unbind_failed, :owned_tree_purpose_mismatch,
                 :forced_source_unbind_failure}} = result

        refute match?({:error, :forced_source_unbind_failure}, result)

        assert {:ok, :trusted_build_workspace, _} = OwnedTreeRegistry.fetch(identity)
        assert :ok = OwnedTreeRegistry.cas(identity, :trusted_build_workspace, :unbound)
        assert :ok = Shell.remove_owned_tree(identity)
      after
        _ = OwnedTreeRegistry.cas(identity, :trusted_build_workspace, :unbound)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "rebound source cannot be acquired twice" do
    if @darwin? do
      {_unused, identity, handle} = start_source!()
      request = request_for(identity)
      {:ok, lease, _view} = TrustedBuild.acquire(request, :omit_hex_seed)

      assert {:error, :owned_tree_purpose_mismatch} =
               TrustedBuild.acquire(request, :omit_hex_seed)

      _ = Shell.release_trusted_build_lease(lease)
      _ = Shell.remove_owned_tree(identity)
      assert :ok = Helpers.rm_fixture!(handle)
    end
  end

  test "successful compile exhausts before reply" do
    if @darwin? do
      {lease, identity, handle} = acquire_source!()

      try do
        assert {:ok, deps} = Shell.execute_trusted_build(lease, "deps_get")
        assert deps.exit_code == 0
        assert deps.timed_out == false
        :ok = Helpers.after_deps_get!(lease)
        assert {:ok, result} = Shell.execute_trusted_build(lease, "compile")
        assert result.exit_code == 0
        assert result.timed_out == false
        refute trusted_build_running?()
        {:ok, view} = Lease.view(lease)
        assert view["completed_phases"] == ["deps_get", "compile"]
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "nonzero mix result locks the lease" do
    if @darwin? do
      {lease, identity, handle} = acquire_source!(:broken)

      try do
        assert {:ok, result} = Shell.execute_trusted_build(lease, "deps_get")
        assert result.exit_code != 0
        refute trusted_build_running?()

        assert {:error, :trusted_build_phase_locked} =
                 Shell.execute_trusted_build(lease, "compile")
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "timeout and overflow lock and exhaust" do
    if @darwin? do
      {timeout_lease, timeout_id, timeout_handle} = acquire_source!(:ok, :force_phase_timeout)

      try do
        assert {:ok, result} = Shell.execute_trusted_build(timeout_lease, "deps_get")
        assert result.timed_out == true or result.killed == true
        refute trusted_build_running?()
        {:ok, view} = Lease.view(timeout_lease)
        assert view["locked"] == true
      after
        _ = Shell.release_trusted_build_lease(timeout_lease)
        _ = Shell.remove_owned_tree(timeout_id)
        assert :ok = Helpers.rm_fixture!(timeout_handle)
      end

      {overflow_lease, overflow_id, overflow_handle} =
        acquire_source!(:ok, :force_output_overflow)

      try do
        assert {:ok, result} = Shell.execute_trusted_build(overflow_lease, "deps_get")

        assert result.output_limit_exceeded == true or result.killed == true or
                 result.exit_code != 0

        refute trusted_build_running?()
      after
        _ = Shell.release_trusted_build_lease(overflow_lease)
        _ = Shell.remove_owned_tree(overflow_id)
        assert :ok = Helpers.rm_fixture!(overflow_handle)
      end
    end
  end

  test "explicit cancellation reaches the port owner" do
    if @darwin? do
      {lease, identity, handle} = acquire_source!(:slow)

      try do
        assert {:ok, %{exit_code: 0}} = Shell.execute_trusted_build(lease, "deps_get")
        :ok = Helpers.after_deps_get!(lease)

        helper =
          spawn(fn ->
            wait_until(fn ->
              state = :sys.get_state(lease.worker)
              is_reference(state.cancel_id) and is_pid(state.port_owner_pid)
            end)

            state = :sys.get_state(lease.worker)

            if is_reference(state.cancel_id) do
              send(state.port_owner_pid, {:cancel_shell_execution, state.cancel_id})
            end
          end)

        _ = helper
        result = Shell.execute_trusted_build(lease, "compile")

        assert match?({:ok, %{killed: true}}, result) or match?({:ok, %{cancelled: true}}, result) or
                 match?({:ok, %{exit_code: 137}}, result)

        refute trusted_build_running?()
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "phase crash locks without reporting success" do
    if @darwin? do
      {lease, identity, handle} = acquire_source!(:ok, :crash_phase)

      try do
        assert {:error, _reason} = Shell.execute_trusted_build(lease, "deps_get")
        {:ok, view} = Lease.view(lease)
        assert view["locked"] == true
        refute trusted_build_running?()
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "setup failure locks and does not leave a launcher" do
    if @darwin? do
      {lease, identity, source, handle} = acquire_source_path!()

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
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "initiating owner loss does not report build success" do
    if @darwin? do
      parent = self()

      owner =
        spawn(fn ->
          {lease, identity, handle} = acquire_source!(:slow)
          {:ok, %{exit_code: 0}} = Shell.execute_trusted_build(lease, "deps_get")
          :ok = Helpers.after_deps_get!(lease)
          workspace = :sys.get_state(lease.worker).roots.parent.path
          send(parent, {:ready, lease.worker, identity, handle, workspace})
          _ = Shell.execute_trusted_build(lease, "compile")
        end)

      assert_receive {:ready, worker, identity, handle, workspace}, 5_000
      wait_until(fn -> Process.alive?(worker) end)
      state = :sys.get_state(worker)
      workspace_path = state.roots.parent.path
      assert workspace_path == workspace
      registry_gen = state.registry_gen
      worker_mon = Process.monitor(worker)

      assert wait_until(fn ->
               case safe_worker_state(worker) do
                 {:ok, st} -> st.in_flight == :compile
                 :down -> false
               end
             end)

      Process.exit(owner, :kill)
      wait_until(fn -> not Process.alive?(owner) end)
      refute trusted_build_running?()

      assert wait_until(
               fn ->
                 cond do
                   not Process.alive?(worker) ->
                     true

                   true ->
                     case safe_worker_state(worker) do
                       {:ok, st} ->
                         not (st.workspace_cleaned == true and st.source_unbound == true) and
                           (st.cleanup_dormant == true or st.cleanup_reason != nil or
                              is_reference(st.cleanup_timer)) and File.exists?(workspace_path)

                       :down ->
                         true
                     end
                 end
               end,
               10_000
             ),
             "owner-death settlement stalled: #{inspect(owner_death_state(worker))}"

      case Process.alive?(worker) && safe_worker_state(worker) do
        {:ok, st} ->
          refute st.workspace_cleaned == true and st.source_unbound == true
          assert st.cleanup_dormant == true or st.cleanup_reason != nil
          assert File.exists?(workspace_path)
          assert :ok = Helpers.stop_retained_worker(worker)

        _other ->
          assert_receive {:DOWN, ^worker_mon, :process, ^worker, _reason}, 1_000
          assert {:error, :enoent} = File.lstat(workspace_path)
          assert {:ok, :unbound, ^registry_gen} = OwnedTreeRegistry.fetch(identity)
      end

      _ = Shell.remove_owned_tree(identity)
      assert :ok = Helpers.rm_fixture!(handle)
    end
  end

  test "descendants and double-fork are exhausted before reply" do
    if @darwin? do
      {lease, identity, handle} = acquire_source!(:fork)

      try do
        result = Shell.execute_trusted_build(lease, "deps_get")
        assert match?({:ok, _}, result) or match?({:error, _}, result)
        refute trusted_build_running?()
        refute Enum.any?(os_processes(), &String.contains?(&1.command, "arbor-tb-fork-marker"))
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  defp start_source!(kind \\ :ok) do
    parent = Helpers.unique_source_root()
    {:ok, identity} = Shell.create_private_owned_tree(parent)
    handle = Helpers.handle_for_owned!(identity)
    source = Path.join(parent, "source")

    _project =
      Helpers.plant_production_child_project!(source, mix_project(kind), source_module(kind))

    :ok = Helpers.plant_fixed_overlay!(identity.path)
    {nil, identity, handle}
  end

  defp acquire_source!(kind \\ :ok, fault \\ :omit_hex_seed) do
    {_unused, identity, handle} = start_source!(kind)
    {:ok, lease, _view} = TrustedBuild.acquire(request_for(identity), fault)
    {lease, identity, handle}
  end

  defp acquire_source_path! do
    {_unused, identity, handle} = start_source!()
    {:ok, lease, _view} = TrustedBuild.acquire(request_for(identity), :omit_hex_seed)
    {lease, identity, Path.join(identity.path, "source"), handle}
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

  defp source_module(:slow) do
    """
    defmodule TrustedBuildFixture do
      Process.sleep(2_000)
      def hello, do: :ok
    end
    """
  end

  defp source_module(_kind) do
    """
    defmodule TrustedBuildFixture do
      def hello, do: :ok
    end
    """
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

  defp safe_worker_state(worker) do
    {:ok, :sys.get_state(worker)}
  catch
    :exit, _ -> :down
  end

  defp owner_death_state(worker) do
    case safe_worker_state(worker) do
      {:ok, state} ->
        Map.take(state, [
          :owner_dead,
          :in_flight,
          :phase_pid,
          :port_owner_pid,
          :port_owner_exhausted,
          :fallback_pending,
          :workspace_cleaned,
          :source_unbound,
          :cleanup_reason,
          :cleanup_timer,
          :cleanup_dormant,
          :cleanup_attempts,
          :locked
        ])

      :down ->
        :down
    end
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
end
