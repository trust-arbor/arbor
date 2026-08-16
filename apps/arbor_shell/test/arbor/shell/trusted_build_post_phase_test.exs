Code.require_file("trusted_build_test_helpers.exs", __DIR__)

defmodule Arbor.Shell.TrustedBuildPostPhaseTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell
  alias Arbor.Shell.OwnedTreeRegistry
  alias Arbor.Shell.TrustedBuild
  alias Arbor.Shell.TrustedBuild.Lease
  alias Arbor.Shell.TrustedBuild.NativeOverlay
  alias Arbor.Shell.TrustedBuildTestHelpers, as: Helpers

  @darwin? match?({:unix, :darwin}, :os.type())
  @cookie_quarantine ".arbor-trusted-build-release-cookie"

  test "Shell descriptor is closed and includes dest_rel" do
    desc = Shell.trusted_build_native_overlay_descriptor()
    assert desc["schema"] == "arbor.packaging.safe_recovery_native_overlay.v1"
    assert desc["dest_rel"] == "sqlite_vec/priv/0.1.5/vec0.dylib"
    assert desc["staging_rel"] == NativeOverlay.staging_rel()
    assert desc["size"] == NativeOverlay.size()
    assert desc["sha256"] == NativeOverlay.sha256()
  end

  test "acquire without overlay fails closed and creates no lease" do
    if @darwin? do
      parent = Helpers.unique_source_root()
      {:ok, identity} = Shell.create_private_owned_tree(parent)
      handle = Helpers.handle_for_owned!(identity)
      source = Path.join(parent, "source")
      File.mkdir_p!(Path.join([source, "bin"]))
      File.mkdir_p!(Path.join([source, "lib"]))
      File.write!(Path.join(source, "mix.exs"), "defmodule T, do: use Mix.Project\n")
      File.write!(Path.join(source, "lib/t.ex"), "defmodule T, do: :ok\n")
      File.cp!(Path.expand("../../../../../bin/mix", __DIR__), Path.join(source, "bin/mix"))
      File.chmod!(Path.join(source, "bin/mix"), 0o755)

      try do
        assert {:error, :trusted_build_native_overlay_unpinned} =
                 TrustedBuild.acquire(request_for(identity), :omit_hex_seed)
      after
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "stage and deps inventory are once-only and compile waits for both" do
    if @darwin? do
      {lease, identity, handle} = acquire!()

      try do
        assert {:error, :trusted_build_phase_rejected} = Shell.stage_trusted_build_native(lease)

        assert {:ok, deps} = Shell.execute_trusted_build(lease, "deps_get")
        assert deps.exit_code == 0

        assert {:error, :trusted_build_phase_rejected} =
                 Shell.inventory_trusted_build_deps(lease)

        assert {:error, :trusted_build_phase_rejected} =
                 Shell.execute_trusted_build(lease, "compile")

        assert {:ok, staged} = Shell.stage_trusted_build_native(lease)
        assert staged["path"] == NativeOverlay.dest_rel()
        assert {:error, :trusted_build_op_repeat} = Shell.stage_trusted_build_native(lease)

        assert {:error, :trusted_build_phase_rejected} =
                 Shell.execute_trusted_build(lease, "compile")

        assert {:ok, inventory} = Shell.inventory_trusted_build_deps(lease)
        assert inventory["kind"] == "deps"
        assert {:error, :trusted_build_op_repeat} = Shell.inventory_trusted_build_deps(lease)

        assert {:ok, compile} = Shell.execute_trusted_build(lease, "compile")
        assert compile.exit_code == 0
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "post-Mix overlay drift returns the verification error not Mix success" do
    if @darwin? do
      {lease, identity, handle} = acquire!(:force_source_overlay_drift_after_mix)

      try do
        assert {:error, reason} = Shell.execute_trusted_build(lease, "deps_get")
        assert reason in [:identity_mismatch, :identity_changed]
        {:ok, view} = Lease.view(lease)
        assert view["locked"] == true

        assert {:error, {:trusted_build_cleanup_attestation_failed, cleanup_reason}} =
                 Shell.release_trusted_build_lease(lease)

        assert cleanup_reason in [:identity_mismatch, :identity_changed]
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "deps mutation after inventory locks compile" do
    if @darwin? do
      {lease, identity, handle} = acquire!()

      try do
        assert {:ok, _} = Shell.execute_trusted_build(lease, "deps_get")
        :ok = Helpers.after_deps_get!(lease)
        state = :sys.get_state(lease.worker)
        File.write!(Path.join(state.roots.deps.path, "drift.txt"), "x")

        assert {:error, :identity_mismatch} = Shell.execute_trusted_build(lease, "compile")
        {:ok, view} = Lease.view(lease)
        assert view["locked"] == true

        assert {:error, {:trusted_build_cleanup_attestation_failed, :identity_mismatch}} =
                 Shell.release_trusted_build_lease(lease)
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "dest hardlink before admission locks staging" do
    if @darwin? do
      {lease, identity, handle} = acquire!(:force_native_dest_hardlink_before_admission)

      try do
        assert {:ok, _} = Shell.execute_trusted_build(lease, "deps_get")
        plant_dest!(lease)
        assert {:error, reason} = Shell.stage_trusted_build_native(lease)

        assert reason in [
                 :trusted_build_native_replacement,
                 :hardlink_rejected,
                 :identity_mismatch
               ]

        {:ok, view} = Lease.view(lease)
        assert view["locked"] == true
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "an exact existing native destination is admitted through the root-bound helper" do
    if @darwin? do
      {lease, identity, handle} = acquire!()

      try do
        assert {:ok, _} = Shell.execute_trusted_build(lease, "deps_get")
        plant_exact_dest!(lease)
        state = :sys.get_state(lease.worker)
        dest = Path.join(state.roots.deps.path, NativeOverlay.dest_rel())
        inode = File.stat!(dest).inode

        assert {:ok, staged} = Shell.stage_trusted_build_native(lease)
        assert staged["path"] == NativeOverlay.dest_rel()
        assert File.stat!(dest).inode == inode
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "mismatched existing dest locks staging" do
    if @darwin? do
      {lease, identity, handle} = acquire!()

      try do
        assert {:ok, _} = Shell.execute_trusted_build(lease, "deps_get")
        plant_dest!(lease)

        assert {:error, reason} = Shell.stage_trusted_build_native(lease)
        assert reason in [:trusted_build_native_replacement, :identity_changed]

        {:ok, view} = Lease.view(lease)
        assert view["locked"] == true
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "cookie absence is recoverable; cookie races lock" do
    if @darwin? do
      {lease, identity, handle} = acquire!()

      try do
        assert {:error, :trusted_build_phase_rejected} =
                 Shell.remove_trusted_build_release_cookie(lease)

        assert {:error, :trusted_build_release_absent} = Shell.inventory_trusted_build(lease)

        assert {:ok, _} = Shell.execute_trusted_build(lease, "deps_get")
        :ok = Helpers.after_deps_get!(lease)
        assert {:ok, _} = Shell.execute_trusted_build(lease, "compile")
        assert {:ok, _} = Shell.execute_trusted_build(lease, "release")

        assert {:error, :trusted_build_release_cookie_absent} =
                 Shell.remove_trusted_build_release_cookie(lease)

        state = :sys.get_state(lease.worker)
        :ok = Helpers.plant_release_cookie!(state.roots.build.path)
        cookie_path = Path.join(state.roots.build.path, "rel/arbor_trust/releases/COOKIE")
        # The root-bound native helper must not require read permission or
        # mutate release artifacts merely to retain unlink evidence.
        File.chmod!(cookie_path, 0o200)
        assert {:ok, cookie} = Shell.remove_trusted_build_release_cookie(lease)
        assert cookie["removed"] == true
        assert cookie["path"] == "arbor_trust/releases/COOKIE"

        assert Bitwise.band(
                 File.stat!(Path.join(state.roots.build.path, @cookie_quarantine)).mode,
                 0o777
               ) ==
                 0o200

        assert {:error, :trusted_build_op_repeat} =
                 Shell.remove_trusted_build_release_cookie(lease)

        assert {:ok, inventory} = Shell.inventory_trusted_build(lease)
        refute Enum.any?(inventory["regular_files"], &(&1["path"] == cookie["path"]))
        assert {:ok, ^inventory} = Shell.inventory_trusted_build(lease)

        assert {:error, :trusted_build_descriptor_unattested} =
                 Shell.read_trusted_build_descriptor(lease, "missing.app")

        assert {:error, :invalid_trusted_build_descriptor} =
                 Shell.read_trusted_build_descriptor(lease, "/abs.app")

        assert {:error, :invalid_trusted_build_descriptor} =
                 Shell.read_trusted_build_descriptor(lease, "../escape.app")

        assert {:error, :invalid_trusted_build_descriptor} =
                 Shell.read_trusted_build_descriptor(lease, 42)

        assert {:error, :trusted_build_descriptor_unattested} =
                 Shell.read_trusted_build_descriptor(lease, "arbor_trust.txt")

        maybe_read_attested(lease, inventory)
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "owner-read-only cookie is quarantined without a mode mutation" do
    if @darwin? do
      {lease, identity, handle} = acquire!()

      try do
        assert {:ok, _} = Shell.execute_trusted_build(lease, "deps_get")
        :ok = Helpers.after_deps_get!(lease)
        assert {:ok, _} = Shell.execute_trusted_build(lease, "compile")
        assert {:ok, _} = Shell.execute_trusted_build(lease, "release")

        state = :sys.get_state(lease.worker)
        :ok = Helpers.plant_release_cookie!(state.roots.build.path)
        cookie_path = Path.join(state.roots.build.path, "rel/arbor_trust/releases/COOKIE")
        File.chmod!(cookie_path, 0o400)

        assert {:ok, %{"removed" => true}} = Shell.remove_trusted_build_release_cookie(lease)
        refute File.exists?(cookie_path)

        quarantine = Path.join(state.roots.build.path, @cookie_quarantine)
        assert Bitwise.band(File.stat!(quarantine).mode, 0o777) == 0o400

        assert {:ok, inventory} = Shell.inventory_trusted_build(lease)
        refute Enum.any?(inventory["regular_files"], &(&1["path"] == @cookie_quarantine))
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "cleanup attestation survives a partial cleanup retry" do
    if @darwin? do
      {lease, identity, handle} = acquire!()

      try do
        assert {:ok, _} = Shell.execute_trusted_build(lease, "deps_get")
        :ok = Helpers.after_deps_get!(lease)

        assert :ok =
                 OwnedTreeRegistry.cas(
                   identity,
                   :trusted_build_source,
                   :trusted_build_workspace
                 )

        assert {:error, {:cleanup_retained, :owned_tree_purpose_mismatch, _evidence}} =
                 Shell.release_trusted_build_lease(lease)

        state = :sys.get_state(lease.worker)
        assert state.workspace_cleaned == true
        assert state.cleanup_attested == true
        assert state.cleanup_attestation_reason == nil

        assert :ok =
                 OwnedTreeRegistry.cas(
                   identity,
                   :trusted_build_workspace,
                   :trusted_build_source
                 )

        assert :ok = Shell.release_trusted_build_lease(lease)
      after
        _ = OwnedTreeRegistry.cas(identity, :trusted_build_workspace, :unbound)
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "cookie hardlink and recreate faults lock" do
    if @darwin? do
      {lease, identity, handle} = acquire!(:force_cookie_hardlink_before_unlink)

      try do
        assert {:ok, _} = Shell.execute_trusted_build(lease, "deps_get")
        :ok = Helpers.after_deps_get!(lease)
        assert {:ok, _} = Shell.execute_trusted_build(lease, "compile")
        assert {:ok, _} = Shell.execute_trusted_build(lease, "release")
        state = :sys.get_state(lease.worker)
        :ok = Helpers.plant_release_cookie!(state.roots.build.path)

        assert {:error, reason} = Shell.remove_trusted_build_release_cookie(lease)

        assert reason in [
                 :trusted_build_cookie_replacement,
                 :hardlink_rejected,
                 :identity_mismatch
               ]

        {:ok, view} = Lease.view(lease)
        assert view["locked"] == true
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "FIFO cookie is rejected without blocking the lease" do
    if @darwin? do
      {lease, identity, handle} = acquire!()

      try do
        assert {:ok, _} = Shell.execute_trusted_build(lease, "deps_get")
        :ok = Helpers.after_deps_get!(lease)
        assert {:ok, _} = Shell.execute_trusted_build(lease, "compile")
        assert {:ok, _} = Shell.execute_trusted_build(lease, "release")
        state = :sys.get_state(lease.worker)
        cookie = Path.join(state.roots.build.path, "rel/arbor_trust/releases/COOKIE")
        File.mkdir_p!(Path.dirname(cookie))
        _ = File.rm(cookie)
        {_output, 0} = System.cmd("mkfifo", [cookie])

        unblocker =
          spawn(fn ->
            Process.sleep(750)

            case :file.open(String.to_charlist(cookie), [:read, :write, :raw, :binary]) do
              {:ok, io} -> :file.close(io)
              {:error, _reason} -> :ok
            end
          end)

        unblocker_ref = Process.monitor(unblocker)
        started = System.monotonic_time(:millisecond)
        assert {:error, :not_a_regular_file} = Shell.remove_trusted_build_release_cookie(lease)
        elapsed = System.monotonic_time(:millisecond) - started
        assert elapsed < 500
        assert_receive {:DOWN, ^unblocker_ref, :process, ^unblocker, _reason}, 1_500
        File.rm!(cookie)
      after
        if Process.alive?(lease.worker) do
          state = :sys.get_state(lease.worker)
          _ = File.rm(Path.join(state.roots.build.path, "rel/arbor_trust/releases/COOKIE"))
        end

        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  defp maybe_read_attested(lease, inventory) do
    case Enum.find(inventory["regular_files"], fn file ->
           String.ends_with?(file["path"], ".app") or String.ends_with?(file["path"], ".rel")
         end) do
      %{"path" => path} ->
        assert {:ok, %{"path" => ^path, "bytes" => bytes}} =
                 Shell.read_trusted_build_descriptor(lease, path)

        assert is_binary(bytes)

      nil ->
        :ok
    end
  end

  defp acquire!(fault \\ :omit_hex_seed) do
    parent = Helpers.unique_source_root()
    {:ok, identity} = Shell.create_private_owned_tree(parent)
    handle = Helpers.handle_for_owned!(identity)
    source = Path.join(parent, "source")
    File.mkdir_p!(Path.join([source, "bin"]))
    File.mkdir_p!(Path.join([source, "lib"]))

    File.write!(Path.join(source, "mix.exs"), """
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
    """)

    File.write!(
      Path.join(source, "lib/trusted_build_fixture.ex"),
      """
      defmodule TrustedBuildFixture do
        def hello, do: :ok
      end
      """
    )

    File.cp!(Path.expand("../../../../../bin/mix", __DIR__), Path.join(source, "bin/mix"))
    File.chmod!(Path.join(source, "bin/mix"), 0o755)
    :ok = Helpers.plant_fixed_overlay!(identity.path)
    {:ok, lease, _view} = TrustedBuild.acquire(request_for(identity), fault)
    {lease, identity, handle}
  end

  defp plant_dest!(lease) do
    state = :sys.get_state(lease.worker)
    dest = Path.join(state.roots.deps.path, NativeOverlay.dest_rel())
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, "placeholder")
    File.chmod!(dest, 0o644)
    :ok
  end

  defp plant_exact_dest!(lease) do
    state = :sys.get_state(lease.worker)
    dest = Path.join(state.roots.deps.path, NativeOverlay.dest_rel())
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(state.identities.overlay.path, dest)
    File.chmod!(dest, 0o644)
    :ok
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
end
