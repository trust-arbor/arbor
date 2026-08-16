Code.require_file("trusted_build_test_helpers.exs", __DIR__)

defmodule Arbor.Shell.TrustedBuildRaceTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell
  alias Arbor.Shell.TrustedBuild
  alias Arbor.Shell.TrustedBuildTestHelpers, as: Helpers

  test "replacing wrapper or source after acquire fails closed" do
    if match?({:unix, :darwin}, :os.type()) do
      {lease, identity, source, handle} = start_fixture!()

      try do
        File.write!(Path.join(source, "bin/mix"), "#!/bin/sh\necho forged\n")
        File.chmod!(Path.join(source, "bin/mix"), 0o755)

        assert {:error, _reason} = Shell.execute_trusted_build(lease, "deps_get")

        assert {:error, :trusted_build_phase_locked} =
                 Shell.execute_trusted_build(lease, "compile")
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "replacing a writable root after acquire fails closed" do
    if match?({:unix, :darwin}, :os.type()) do
      {lease, identity, _source, handle} = start_fixture!()

      try do
        state = :sys.get_state(lease.worker)
        build = state.roots.build.path
        File.rename!(build, build <> ".old")
        File.mkdir_p!(build)
        File.chmod!(build, 0o700)

        assert {:error, _reason} = Shell.execute_trusted_build(lease, "deps_get")

        assert {:error, :trusted_build_phase_locked} =
                 Shell.execute_trusted_build(lease, "compile")
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "symlink, hardlink, and ancestor replacement fail closed" do
    if match?({:unix, :darwin}, :os.type()) do
      {lease, identity, source, handle} = start_fixture!()

      try do
        wrapper = Path.join(source, "bin/mix")
        File.rename!(wrapper, wrapper <> ".real")
        File.ln_s!(wrapper <> ".real", wrapper)
        assert {:error, _reason} = Shell.execute_trusted_build(lease, "deps_get")
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end

      {lease2, identity2, source2, handle2} = start_fixture!()

      try do
        wrapper = Path.join(source2, "bin/mix")
        extra = wrapper <> ".link"
        File.ln!(wrapper, extra)
        assert {:error, _reason} = Shell.execute_trusted_build(lease2, "deps_get")
      after
        _ = Shell.release_trusted_build_lease(lease2)
        _ = Shell.remove_owned_tree(identity2)
        assert :ok = Helpers.rm_fixture!(handle2)
      end

      {lease3, identity3, source3, handle3} = start_fixture!()

      try do
        bin = Path.join(source3, "bin")
        File.rename!(bin, bin <> ".old")
        File.mkdir_p!(bin)
        File.ln_s!(bin <> ".old/mix", Path.join(bin, "mix"))
        assert {:error, _reason} = Shell.execute_trusted_build(lease3, "deps_get")
      after
        _ = Shell.release_trusted_build_lease(lease3)
        _ = Shell.remove_owned_tree(identity3)
        assert :ok = Helpers.rm_fixture!(handle3)
      end
    end
  end

  test "archive content replacement fails closed through owned writable setup" do
    if match?({:unix, :darwin}, :os.type()) do
      {lease, identity, _source, handle} = start_fixture!()

      try do
        state = :sys.get_state(lease.worker)
        archives = state.identities.archives.path
        File.chmod!(archives, 0o700)
        File.write!(Path.join(archives, "forged"), "x")
        File.chmod!(archives, 0o555)
        assert {:error, _reason} = Shell.execute_trusted_build(lease, "deps_get")
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "archive symlink and group-writable mutation fail closed" do
    if match?({:unix, :darwin}, :os.type()) do
      {lease, identity, _source, handle} = start_fixture!()

      try do
        state = :sys.get_state(lease.worker)
        archives = state.identities.archives.path
        File.chmod!(archives, 0o700)
        File.ln_s!("/etc/hosts", Path.join(archives, "link"))
        File.chmod!(archives, 0o555)
        assert {:error, _reason} = Shell.execute_trusted_build(lease, "deps_get")
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end

      {lease2, identity2, _source2, handle2} = start_fixture!()

      try do
        state = :sys.get_state(lease2.worker)
        archives = state.identities.archives.path
        File.chmod!(archives, 0o722)
        assert {:error, _reason} = Shell.execute_trusted_build(lease2, "deps_get")
      after
        _ = Shell.release_trusted_build_lease(lease2)
        _ = Shell.remove_owned_tree(identity2)
        assert :ok = Helpers.rm_fixture!(handle2)
      end

      {lease3, identity3, _source3, handle3} = start_fixture!()

      try do
        state = :sys.get_state(lease3.worker)
        archives = state.identities.archives.path
        File.chmod!(archives, 0o700)
        file = Path.join(archives, "body")
        File.write!(file, "x")
        File.ln!(file, file <> ".link")
        File.chmod!(archives, 0o555)
        assert {:error, _reason} = Shell.execute_trusted_build(lease3, "deps_get")
      after
        _ = Shell.release_trusted_build_lease(lease3)
        _ = Shell.remove_owned_tree(identity3)
        assert :ok = Helpers.rm_fixture!(handle3)
      end
    end
  end

  defp start_fixture! do
    parent = Helpers.unique_source_root()
    {:ok, identity} = Shell.create_private_owned_tree(parent)
    handle = Helpers.handle_for_owned!(identity)
    source = Path.join(parent, "source")
    File.mkdir_p!(Path.join([source, "bin"]))
    File.mkdir_p!(Path.join([source, "lib"]))

    File.write!(Path.join(source, "mix.exs"), """
    defmodule TrustedBuildFixture.MixProject do
      use Mix.Project
      def project, do: [app: :trusted_build_fixture, version: "0.1.0"]
      def application, do: []
    end
    """)

    File.write!(
      Path.join(source, "lib/trusted_build_fixture.ex"),
      "defmodule TrustedBuildFixture, do: def hello, do: :ok\n"
    )

    File.cp!(Path.expand("../../../../../bin/mix", __DIR__), Path.join(source, "bin/mix"))
    File.chmod!(Path.join(source, "bin/mix"), 0o755)
    :ok = Helpers.plant_fixed_overlay!(identity.path)

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

    {:ok, lease, _view} = TrustedBuild.acquire(request, :omit_hex_seed)
    {lease, identity, source, handle}
  end
end
