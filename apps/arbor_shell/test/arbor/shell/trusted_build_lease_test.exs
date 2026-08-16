Code.require_file("trusted_build_test_helpers.exs", __DIR__)

defmodule Arbor.Shell.TrustedBuildLeaseTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell
  alias Arbor.Shell.Executor
  alias Arbor.Shell.OwnedTreeRegistry
  alias Arbor.Shell.ProcessGroup
  alias Arbor.Shell.TrustedBuild
  alias Arbor.Shell.TrustedBuild.FallbackOwner
  alias Arbor.Shell.TrustedBuild.Lease
  alias Arbor.Shell.TrustedBuildTestHelpers, as: Helpers
  alias Arbor.Shell.TrustedBuildToolchainAuthority

  @darwin? match?({:unix, :darwin}, :os.type())

  test "token forgery and foreign callers are rejected" do
    if @darwin? do
      {lease, identity, handle} = acquire_fixture!()

      try do
        assert {:ok, view} = Lease.view(lease)
        assert view["schema"] == "arbor.shell.trusted_build.lease.v1"
        refute Map.has_key?(view, "path")

        forged = %{lease | token: :crypto.strong_rand_bytes(32)}
        assert {:error, :foreign_caller} = Lease.view(forged)
        assert {:error, :invalid_lease} = Shell.execute_trusted_build(%{}, "deps_get")

        dead = %Lease.Handle{token: lease.token, worker: self(), owner: self()}
        assert {:error, :invalid_lease} = Shell.execute_trusted_build(dead, "deps_get")

        assert {:error, :foreign_caller} = Lease.checkout_launch(lease.worker, make_ref())
        assert {:error, :foreign_caller} = Lease.take_launch(lease.worker, make_ref())

        assert {:error, :trusted_build_launch_unauthorized} =
                 Lease.checkout_fallback(lease.worker, make_ref())
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "checkout_launch cannot run before attach or without go" do
    if @darwin? do
      {lease, identity, handle} = acquire_fixture!()

      try do
        {:ok, session} = Lease.begin_phase(lease, :deps_get, self())

        assert {:error, :foreign_caller} =
                 Lease.checkout_launch(session.lease_pid, session.launch_ticket)

        refute trusted_build_running?()

        parent = self()

        phase =
          spawn(fn ->
            receive do
              {:trusted_build_phase_go, ticket} ->
                send(parent, {:got_go, ticket})
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
        assert_receive {:got_go, ticket}, 2_000
        assert ticket == session.launch_ticket
        assert_receive {:first, {:ok, descriptor}}, 2_000
        assert is_reference(descriptor.launch_permit)
        assert_receive {:second, {:error, :trusted_build_launch_unauthorized}}, 2_000

        assert {:error, :foreign_caller} =
                 Lease.take_launch(session.lease_pid, descriptor.launch_permit)

        send(phase, :stop)
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "commit success requires exhaustion and is acknowledged before phase DOWN" do
    if @darwin? do
      {lease, identity, handle} = acquire_fixture!()

      try do
        {:ok, session} = Lease.begin_phase(lease, :deps_get, self())
        parent = self()

        phase =
          spawn(fn ->
            receive do
              {:trusted_build_phase_go, _} -> :ok
            end

            owner =
              spawn(fn ->
                receive do
                  :record ->
                    :ok = Lease.record_exhaustion(session.lease_pid, :normal)
                    Process.sleep(50)
                end
              end)

            :ok = Lease.register_port_owner(session.lease_pid, owner)
            send(owner, :record)
            wait_until(fn -> :sys.get_state(session.lease_pid).port_owner_exhausted end)

            :ok =
              Lease.commit_phase_result(
                session.lease_pid,
                {:ok, %{exit_code: 0, timed_out: false, killed: false}}
              )

            send(parent, :committed)
          end)

        assert :ok = Lease.attach_phase(lease, phase)
        mon = Process.monitor(phase)
        assert_receive :committed, 2_000
        assert_receive {:DOWN, ^mon, :process, ^phase, _reason}, 2_000

        {:ok, view} = Lease.view(lease)
        assert view["locked"] == false
        assert view["completed_phases"] == ["deps_get"]
        assert view["state"] == "ready"
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "commit without exhaustion is not owner-visible success" do
    if @darwin? do
      {lease, identity, handle} = acquire_fixture!()

      try do
        {:ok, session} = Lease.begin_phase(lease, :deps_get, self())

        phase =
          spawn(fn ->
            receive do
              {:trusted_build_phase_go, _} -> :ok
            end

            result =
              Lease.commit_phase_result(
                session.lease_pid,
                {:ok, %{exit_code: 0, timed_out: false, killed: false}}
              )

            send(session.owner_pid, {:commit_ack, result})
          end)

        assert :ok = Lease.attach_phase(lease, phase)
        assert_receive {:commit_ack, {:error, :trusted_build_exhaustion_unproven}}, 2_000
        {:ok, view} = Lease.view(lease)
        assert view["locked"] == true
        assert view["completed_phases"] == []
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "raw ProcessGroup and Executor calls without a live permit cannot fork" do
    refute function_exported?(ProcessGroup, :run_trusted_build_executable, 6)
    assert function_exported?(ProcessGroup, :run_trusted_build_executable, 2)
    refute function_exported?(FallbackOwner, :run, 3)
    refute function_exported?(FallbackOwner, :start, 1)
    refute function_exported?(FallbackOwner, :start_link, 1)

    assert {:error, :trusted_build_launch_unauthorized} =
             ProcessGroup.run_trusted_build_executable(self(), make_ref())

    assert {:error, :trusted_build_launch_unauthorized} =
             Executor.run_trusted_build(self(), make_ref())

    refute Enum.any?(os_processes(), &String.contains?(&1.command, "trusted-build"))
  end

  test "bound source removal is denied and successful release unbinds for reacquire" do
    if @darwin? do
      {lease, identity, handle} = acquire_fixture!()

      try do
        request = request_for(identity)

        assert {:error, :owned_tree_purpose_mismatch} =
                 TrustedBuild.acquire(request, :omit_hex_seed)

        assert {:error, :owned_tree_purpose_mismatch} = Shell.remove_owned_tree(identity)
        assert File.dir?(identity.path)

        assert :ok = Shell.release_trusted_build_lease(lease)
        assert {:error, :invalid_lease} = Shell.release_trusted_build_lease(lease)

        {:ok, lease2, _view} = TrustedBuild.acquire(request, :omit_hex_seed)
        assert :ok = Shell.release_trusted_build_lease(lease2)
        assert :ok = Shell.remove_owned_tree(identity)
      after
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "a second release cannot overwrite a deferred caller" do
    if @darwin? do
      {lease, identity, handle} = acquire_fixture!()

      try do
        assert self() == lease.owner
        {:ok, _session} = Lease.begin_phase(lease, :deps_get, self())

        phase =
          spawn(fn ->
            receive do
              {:trusted_build_phase_go, _} -> :ok
            end

            receive do
              :stop -> :ok
            end
          end)

        assert :ok = Lease.attach_phase(lease, phase)

        req_id = GenServer.send_request(lease.worker, {:owner_request, lease.token, :release})

        assert wait_until(fn ->
                 match?(
                   {pid, _tag} when pid == self(),
                   :sys.get_state(lease.worker).release_from
                 )
               end)

        assert :timeout = GenServer.wait_response(req_id, 0)

        assert {:error, :trusted_build_release_in_flight} =
                 Shell.release_trusted_build_lease(lease)

        assert :timeout = GenServer.wait_response(req_id, 0)
        state = :sys.get_state(lease.worker)
        assert match?({pid, _tag} when pid == self(), state.release_from)

        send(phase, :stop)
        assert {:reply, reply} = GenServer.wait_response(req_id, 5_000)
        assert reply == :ok or match?({:error, {:cleanup_retained, _, _}}, reply)
      after
        if Process.alive?(lease.worker) do
          assert :ok = Helpers.stop_retained_worker(lease.worker)
        end

        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "unregistered live tree is not deleted; absent unregistered is ok" do
    parent = Helpers.unique_source_root()
    {:ok, identity} = Shell.create_private_owned_tree(parent)
    handle = Helpers.handle_for_owned!(identity)

    try do
      :ok = OwnedTreeRegistry.delete(identity)
      assert File.dir?(identity.path)
      assert {:error, :owned_tree_not_registered} = Shell.remove_owned_tree(identity)
      assert File.dir?(identity.path)

      assert :ok = Helpers.rm_fixture!(handle)
      assert :ok = Shell.remove_owned_tree(identity)
    after
      _ = Helpers.rm_fixture!(handle)
    end
  end

  test "registry generation mismatch locks begin_phase" do
    if @darwin? do
      {lease, identity, handle} = acquire_fixture!()
      old = Process.whereis(OwnedTreeRegistry)

      try do
        Process.exit(old, :kill)

        wait_until(fn ->
          pid = Process.whereis(OwnedTreeRegistry)
          is_pid(pid) and pid != old
        end)

        assert {:error, :trusted_build_toolchain_generation_mismatch} =
                 Lease.begin_phase(lease, :deps_get, self())

        {:ok, view} = Lease.view(lease)
        assert view["locked"] == true
      after
        _ = Shell.release_trusted_build_lease(lease)
        assert :ok = Helpers.stop_retained_worker(lease.worker)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "fallback checkout stays dispatched during owner-loss wait and is single-use" do
    if @darwin? do
      {lease, identity, handle} = acquire_fixture!(:force_kill_helper_failure)

      try do
        {:ok, session} = Lease.begin_phase(lease, :deps_get, self())
        parent = self()

        phase =
          spawn(fn ->
            receive do
              {:trusted_build_phase_go, _} -> :ok
            end

            owner =
              spawn(fn ->
                receive do
                  :die -> :ok
                end
              end)

            :ok = Lease.register_port_owner(session.lease_pid, owner)
            :ok = Lease.record_group_id(session.lease_pid, 65_534)
            send(parent, {:owner_ready, owner})

            receive do
              :hold -> :ok
            end
          end)

        assert :ok = Lease.attach_phase(lease, phase)
        assert_receive {:owner_ready, owner}, 2_000
        Process.exit(owner, :kill)

        wait_until(fn ->
          state = :sys.get_state(lease.worker)
          state.fallback_used == true
        end)

        state = :sys.get_state(lease.worker)
        assert state.fallback_used == true
        assert is_pid(state.fallback_pid)

        assert {:error, :trusted_build_launch_unauthorized} =
                 Lease.checkout_fallback(lease.worker, make_ref())

        wait_until(fn ->
          st = :sys.get_state(lease.worker)
          st.fallback_pending == false and st.locked == true
        end)

        st = :sys.get_state(lease.worker)
        assert st.port_owner_exhausted != true
        assert st.fallback_used == true

        Process.exit(owner, :kill)
        Process.sleep(50)
        st2 = :sys.get_state(lease.worker)
        assert st2.fallback_used == true
      after
        _ = Shell.release_trusted_build_lease(lease)
        assert :ok = Helpers.stop_retained_worker(lease.worker)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "missing group_id retains workspace identity" do
    if @darwin? do
      {lease, identity, handle} = acquire_fixture!()

      try do
        {:ok, session} = Lease.begin_phase(lease, :deps_get, self())

        phase =
          spawn(fn ->
            receive do
              {:trusted_build_phase_go, _} -> :ok
            end

            owner = spawn(fn -> Process.sleep(20) end)
            :ok = Lease.register_port_owner(session.lease_pid, owner)

            receive do
              :hold -> :ok
            end
          end)

        assert :ok = Lease.attach_phase(lease, phase)

        wait_until(fn ->
          st = :sys.get_state(lease.worker)
          st.port_owner_registered == true and st.port_owner_pid == nil
        end)

        st = :sys.get_state(lease.worker)
        assert st.locked == true
        assert st.fallback_used == false
        assert File.dir?(st.roots.parent.path)

        assert {:error, {:cleanup_retained, :exhaustion_unproven, _evidence}} =
                 Shell.release_trusted_build_lease(lease)
      after
        assert :ok = Helpers.stop_retained_worker(lease.worker)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "post-phase ops reject wrong order and remain releasable" do
    if @darwin? do
      {lease, identity, handle} = acquire_fixture!()

      try do
        assert {:error, :trusted_build_phase_rejected} = Shell.stage_trusted_build_native(lease)

        assert {:error, :trusted_build_phase_rejected} =
                 Shell.inventory_trusted_build_deps(lease)

        assert {:error, :trusted_build_phase_rejected} =
                 Shell.remove_trusted_build_release_cookie(lease)

        assert {:error, :trusted_build_release_absent} =
                 Shell.read_trusted_build_descriptor(lease, "releases/arbor_trust.app")

        assert :ok = Shell.release_trusted_build_lease(lease)
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  defp acquire_fixture!(fault \\ :omit_hex_seed) do
    parent = Helpers.unique_source_root()
    {:ok, identity} = Shell.create_private_owned_tree(parent)
    handle = Helpers.handle_for_owned!(identity)
    source = Path.join(parent, "source")
    File.mkdir_p!(Path.join(source, "bin"))
    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, "mix.exs"), mix_project())

    File.write!(
      Path.join(source, "lib/trusted_build_fixture.ex"),
      "defmodule TrustedBuildFixture, do: def hello, do: :ok\n"
    )

    File.cp!(Path.expand("../../../../../bin/mix", __DIR__), Path.join(source, "bin/mix"))
    File.chmod!(Path.join(source, "bin/mix"), 0o755)
    :ok = Helpers.plant_fixed_overlay!(identity.path)
    {:ok, lease, _view} = TrustedBuild.acquire(request_for(identity), fault)
    {lease, identity, handle}
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
end
