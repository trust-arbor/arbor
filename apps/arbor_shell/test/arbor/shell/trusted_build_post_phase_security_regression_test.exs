Code.require_file("trusted_build_test_helpers.exs", __DIR__)

defmodule Arbor.Shell.TrustedBuildPostPhaseSecurityRegressionTest do
  @moduledoc """
  Public-API security regression for E0B2C3a post-phase gates.

  Parent 368de84 admits compile after deps_get and ignores overlay drift.
  The candidate must reject compile until staging+deps inventory and lock
  when the pinned overlay is replaced or deleted after acquire.
  """

  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Shell
  alias Arbor.Shell.TrustedBuild.Lease
  alias Arbor.Shell.TrustedBuildTestHelpers, as: Helpers

  @staging_rel "native_overlay/v1/aarch64-apple-darwin/sqlite_vec/0.1.5/vec0.dylib"
  @overlay_size 126_600
  @overlay_sha256 "45d67c7868152c1b9b4b86cd1cea1d8834136e13f8e0348648b89f8aa90e7b5b"
  test "security regression: post-phase facade arities are closed" do
    assert Code.ensure_loaded?(Shell)
    assert function_exported?(Shell, :trusted_build_native_overlay_descriptor, 0)
    assert function_exported?(Shell, :stage_trusted_build_native, 1)
    assert function_exported?(Shell, :inventory_trusted_build_deps, 1)
    assert function_exported?(Shell, :remove_trusted_build_release_cookie, 1)
    assert function_exported?(Shell, :read_trusted_build_descriptor, 2)
    refute function_exported?(Shell, :stage_trusted_build_native, 2)
    refute function_exported?(Shell, :inventory_trusted_build_deps, 2)
    refute function_exported?(Shell, :remove_trusted_build_release_cookie, 2)
    refute function_exported?(Shell, :read_trusted_build_descriptor, 3)
    refute function_exported?(Shell, :trusted_build_native_overlay_descriptor, 1)
  end

  test "security regression: compile is rejected until native staging and deps inventory" do
    if match?({:unix, :darwin}, :os.type()) do
      {lease, identity, handle} = start_lease!()

      try do
        assert {:ok, deps} = Shell.execute_trusted_build(lease, "deps_get")
        assert deps.exit_code == 0

        assert {:error, :trusted_build_phase_rejected} =
                 Shell.execute_trusted_build(lease, "compile")
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "security regression: replacing the pinned overlay after acquire locks Mix" do
    if match?({:unix, :darwin}, :os.type()) do
      {lease, identity, handle} = start_lease!()

      try do
        overlay = Path.join(identity.path, @staging_rel)
        File.write!(overlay, :binary.copy(<<1>>, @overlay_size))

        assert {:error, reason} = Shell.execute_trusted_build(lease, "deps_get")
        assert is_atom(reason)
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "security regression: deleting the pinned overlay after acquire locks Mix" do
    if match?({:unix, :darwin}, :os.type()) do
      {lease, identity, handle} = start_lease!()

      try do
        overlay = Path.join(identity.path, @staging_rel)
        File.rm!(overlay)

        assert {:error, reason} = Shell.execute_trusted_build(lease, "deps_get")
        assert is_atom(reason)
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "security regression: owner loss during a phase settles after the final child commits" do
    if match?({:unix, :darwin}, :os.type()) do
      parent = self()

      owner =
        spawn(fn ->
          {lease, identity, handle} = start_lease!(:slow)
          {:ok, %{exit_code: 0}} = Shell.execute_trusted_build(lease, "deps_get")
          :ok = prepare_post_phase_if_available(lease)
          workspace = :sys.get_state(lease.worker).roots.parent.path
          send(parent, {:ready, lease.worker, identity, handle, workspace})
          _ = Shell.execute_trusted_build(lease, "compile")
        end)

      assert_receive {:ready, worker, identity, handle, workspace}, 5_000
      owner_mon = Process.monitor(owner)
      worker_mon = Process.monitor(worker)

      try do
        assert wait_until(fn ->
                 case safe_worker_state(worker) do
                   {:ok, state} -> state.in_flight == :compile
                   :down -> false
                 end
               end)

        Process.exit(owner, :kill)
        assert_receive {:DOWN, ^owner_mon, :process, ^owner, :killed}, 1_000
        assert wait_until(fn -> not Process.alive?(worker) end, 10_000)
        assert_receive {:DOWN, ^worker_mon, :process, ^worker, _reason}, 1_000
        refute File.exists?(workspace)
      after
        if Process.alive?(owner), do: Process.exit(owner, :kill)
        if Process.alive?(worker), do: Helpers.stop_retained_worker(worker)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "security regression: foreign callers cannot invoke post-phase operations" do
    if match?({:unix, :darwin}, :os.type()) do
      {lease, identity, handle} = start_lease!()

      try do
        results =
          Task.async(fn ->
            [
              Shell.stage_trusted_build_native(lease),
              Shell.inventory_trusted_build_deps(lease),
              Shell.remove_trusted_build_release_cookie(lease),
              Shell.inventory_trusted_build(lease),
              Shell.read_trusted_build_descriptor(lease, "arbor_trust.app")
            ]
          end)
          |> Task.await()

        assert Enum.all?(results, &(&1 == {:error, :foreign_caller}))
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "security regression: staged native replacement before inventory locks the lease" do
    if match?({:unix, :darwin}, :os.type()) do
      {lease, identity, handle} = start_lease!()

      try do
        assert {:ok, %{exit_code: 0}} = Shell.execute_trusted_build(lease, "deps_get")
        assert {:ok, _stage} = Shell.stage_trusted_build_native(lease)
        state = :sys.get_state(lease.worker)
        dest = Path.join(state.roots.deps.path, "sqlite_vec/priv/0.1.5/vec0.dylib")
        File.write!(dest, "replacement")

        assert {:error, reason} = Shell.inventory_trusted_build_deps(lease)
        assert reason in [:identity_mismatch, :identity_changed]
        assert {:ok, %{"locked" => true}} = Lease.view(lease)
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "security regression: staged native symlink race cannot mutate the private root" do
    if match?({:unix, :darwin}, :os.type()) do
      {lease, identity, handle} = start_lease!()

      try do
        assert {:ok, %{exit_code: 0}} = Shell.execute_trusted_build(lease, "deps_get")

        :sys.replace_state(
          lease.worker,
          &Map.put(&1, :fault, :force_native_dest_symlink_before_seal)
        )

        state = :sys.get_state(lease.worker)

        assert {:error, reason} = Shell.stage_trusted_build_native(lease)
        assert reason in [:symlink_rejected, :identity_changed, :identity_mismatch]
        assert Bitwise.band(File.stat!(state.roots.deps.path).mode, 0o777) == 0o700
        assert {:ok, %{"locked" => true}} = Lease.view(lease)
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "security regression: existing native FIFO cannot wedge staging" do
    if match?({:unix, :darwin}, :os.type()) do
      {lease, identity, handle} = start_lease!()

      try do
        assert {:ok, %{exit_code: 0}} = Shell.execute_trusted_build(lease, "deps_get")
        state = :sys.get_state(lease.worker)
        dest = Path.join(state.roots.deps.path, "sqlite_vec/priv/0.1.5/vec0.dylib")
        File.mkdir_p!(Path.dirname(dest))
        {_output, 0} = System.cmd("mkfifo", [dest])

        started = System.monotonic_time(:millisecond)
        assert {:error, :not_a_regular_file} = Shell.stage_trusted_build_native(lease)
        assert System.monotonic_time(:millisecond) - started < 500
        assert {:ok, %{"locked" => true}} = Lease.view(lease)
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "security regression: descriptor FIFO replacement cannot wedge the lease" do
    if match?({:unix, :darwin}, :os.type()) do
      {lease, identity, handle} = start_lease!()

      try do
        assert {:ok, %{exit_code: 0}} = Shell.execute_trusted_build(lease, "deps_get")
        :ok = Helpers.after_deps_get!(lease)
        assert {:ok, %{exit_code: 0}} = Shell.execute_trusted_build(lease, "compile")
        assert {:ok, %{exit_code: 0}} = Shell.execute_trusted_build(lease, "release")

        state = :sys.get_state(lease.worker)
        :ok = Helpers.plant_release_cookie!(state.roots.build.path)
        assert {:ok, _cookie} = Shell.remove_trusted_build_release_cookie(lease)
        assert {:ok, inventory} = Shell.inventory_trusted_build(lease)

        %{"path" => rel} =
          Enum.find(inventory["regular_files"], fn entry ->
            String.ends_with?(entry["path"], ".app") or
              String.ends_with?(entry["path"], ".rel")
          end) || flunk("release inventory contains no descriptor")

        descriptor = Path.join([state.roots.build.path, "rel", rel])

        try do
          File.rm!(descriptor)
          {_output, 0} = System.cmd("mkfifo", [descriptor])

          unblocker =
            spawn(fn ->
              Process.sleep(750)

              case :file.open(String.to_charlist(descriptor), [:read, :write, :raw, :binary]) do
                {:ok, io} -> :file.close(io)
                {:error, _reason} -> :ok
              end
            end)

          unblocker_ref = Process.monitor(unblocker)
          started = System.monotonic_time(:millisecond)

          assert {:error, :not_a_regular_file} =
                   Shell.read_trusted_build_descriptor(lease, rel)

          elapsed = System.monotonic_time(:millisecond) - started
          assert elapsed < 500
          assert_receive {:DOWN, ^unblocker_ref, :process, ^unblocker, _reason}, 1_500
        after
          _ = File.rm(descriptor)
        end
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  defp start_lease!(kind \\ :normal) do
    parent = Helpers.unique_source_root()
    {:ok, identity} = Shell.create_private_owned_tree(parent)
    source = Path.join(parent, "source")

    _project =
      Helpers.plant_production_child_project!(source, mix_project(), source_module(kind))

    plant_overlay!(identity.path)

    request = %{
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

    handle = Helpers.handle_for_owned!(identity)
    {:ok, lease, _view} = Shell.acquire_trusted_build_lease(request)
    {lease, identity, handle}
  end

  defp prepare_post_phase_if_available(lease) do
    if function_exported?(Shell, :stage_trusted_build_native, 1) do
      with {:ok, _staged} <- Shell.stage_trusted_build_native(lease),
           {:ok, _inventory} <- Shell.inventory_trusted_build_deps(lease) do
        :ok
      end
    else
      :ok
    end
  end

  defp safe_worker_state(worker) do
    {:ok, :sys.get_state(worker)}
  catch
    :exit, _reason -> :down
  end

  defp wait_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end

  defp plant_overlay!(owned_path) do
    dest = Path.join(owned_path, @staging_rel)
    File.mkdir_p!(Path.dirname(dest))
    {:ok, bytes} = overlay_bytes()
    File.write!(dest, bytes)
    File.chmod!(dest, 0o644)
    :ok
  end

  defp overlay_bytes do
    repo = Path.expand("../../../../..", __DIR__)
    deps = System.get_env("MIX_DEPS_PATH") || Path.join(repo, "deps")

    [
      Path.join(deps, "sqlite_vec/priv/0.1.5/vec0.dylib"),
      Path.join(repo, "deps/sqlite_vec/priv/0.1.5/vec0.dylib"),
      Path.join(
        repo,
        "apps/arbor_commands/priv/packaging/native_overlays/v1/aarch64-apple-darwin/sqlite_vec/0.1.5/vec0.dylib"
      )
    ]
    |> Enum.find_value(fn path ->
      case File.read(path) do
        {:ok, bytes} ->
          digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

          if byte_size(bytes) == @overlay_size and digest == @overlay_sha256 do
            {:ok, bytes}
          else
            false
          end

        {:error, _} ->
          false
      end
    end)
    |> case do
      {:ok, bytes} -> {:ok, bytes}
      _other -> flunk("trusted-build overlay bytes are unavailable")
    end
  end

  defp mix_project do
    """
    defmodule TrustedBuildFixture.MixProject do
      use Mix.Project
      def project do
        [
          app: :trusted_build_fixture,
          version: "0.1.0",
          elixir: "~> 1.17",
          releases: [trusted_build_fixture: [include_executables_for: [:unix]]]
        ]
      end
      def application, do: []
    end
    """
  end

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
end
