Code.require_file("trusted_build_test_helpers.exs", __DIR__)

defmodule Arbor.Shell.TrustedBuildProjectRootSecurityRegressionTest do
  @moduledoc """
  Public-facade security regression for the fixed child-project Mix cwd.

  Parent 467b0238daa9bb1c681331cd2dc4b126c545cab6 uses the reconstructed
  source root as Mix cwd and has no child-root preflight. The candidate
  must fail closed on a missing fixed child before mutation.
  """

  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Shell
  alias Arbor.Shell.TrustedBuildTestHelpers, as: Helpers

  test "security regression: missing fixed child project root fails closed on the public acquire facade" do
    {identity, handle, request} = start_root_only_fixture!()

    try do
      assert {:error, :path_not_found} = Shell.acquire_trusted_build_lease(request)
    after
      _ = Shell.remove_owned_tree(identity)
      assert :ok = Helpers.rm_fixture!(handle)
    end
  end

  test "security regression: callers cannot select the Mix project root through the public request" do
    identity = %{
      "path" => "/tmp/arbor-tb-project-root",
      "type" => "directory",
      "device" => 1,
      "minor_device" => 0,
      "inode" => 1
    }

    Enum.each(["project_root", "cwd", "child", "mix_cwd", "project"], fn key ->
      assert {:error, :invalid_trusted_build_request} =
               Shell.acquire_trusted_build_lease(%{
                 "schema" => "arbor.shell.trusted_build.request.v1",
                 "source" => %{
                   "schema" => "arbor.shell.trusted_build.source.v1",
                   "identity" => identity
                 },
                 key => "/evil"
               })

      assert {:error, :invalid_trusted_build_request} =
               Shell.acquire_trusted_build_lease(%{
                 "schema" => "arbor.shell.trusted_build.request.v1",
                 "source" => %{
                   "schema" => "arbor.shell.trusted_build.source.v1",
                   "identity" => identity,
                   key => "/evil"
                 }
               })
    end)
  end

  test "security regression: a symlink child project root is rejected without following" do
    {identity, handle, request, source} = start_owned_source_fixture!()

    try do
      real = Path.join(handle.root, "real-project")
      File.mkdir_p!(Path.join(real, "lib"))
      File.write!(Path.join(real, "mix.exs"), valid_mix_project())
      File.mkdir_p!(Path.join(source, "apps"))
      File.ln_s!(real, Path.join([source, "apps", "arbor_trust"]))

      assert {:error, :symlink_rejected} = Shell.acquire_trusted_build_lease(request)
    after
      _ = Shell.remove_owned_tree(identity)
      assert :ok = Helpers.rm_fixture!(handle)
    end

    {identity2, handle2, request2, source2} = start_owned_source_fixture!()

    try do
      real_apps = Path.join(handle2.root, "real-apps")
      File.mkdir_p!(Path.join([real_apps, "arbor_trust", "lib"]))
      File.write!(Path.join([real_apps, "arbor_trust", "mix.exs"]), valid_mix_project())
      File.ln_s!(real_apps, Path.join(source2, "apps"))

      assert {:error, :symlink_rejected} = Shell.acquire_trusted_build_lease(request2)
    after
      _ = Shell.remove_owned_tree(identity2)
      assert :ok = Helpers.rm_fixture!(handle2)
    end
  end

  test "security regression: replacing the pinned child after acquire fails closed" do
    if match?({:unix, :darwin}, :os.type()) do
      {lease, identity, handle, source} = acquire_production_fixture!()

      try do
        project = Path.join([source, "apps", "arbor_trust"])
        File.rename!(project, project <> ".old")
        File.mkdir_p!(project)
        File.chmod!(project, 0o755)

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

  defp start_root_only_fixture! do
    parent = Helpers.unique_source_root()
    {:ok, identity} = Shell.create_private_owned_tree(parent)
    handle = Helpers.handle_for_owned!(identity)
    source = Path.join(parent, "source")
    File.mkdir_p!(Path.join(source, "lib"))
    File.mkdir_p!(Path.join(source, "bin"))
    File.write!(Path.join(source, "mix.exs"), valid_mix_project())

    File.write!(
      Path.join(source, "lib/trusted_build_fixture.ex"),
      "defmodule TrustedBuildFixture, do: def hello, do: :ok\n"
    )

    File.cp!(Path.expand("../../../../../bin/mix", __DIR__), Path.join(source, "bin/mix"))
    File.chmod!(Path.join(source, "bin/mix"), 0o755)
    :ok = Helpers.plant_fixed_overlay!(identity.path)
    {identity, handle, request_for(identity)}
  end

  defp start_owned_source_fixture! do
    parent = Helpers.unique_source_root()
    {:ok, identity} = Shell.create_private_owned_tree(parent)
    handle = Helpers.handle_for_owned!(identity)
    source = Path.join(parent, "source")
    File.mkdir_p!(Path.join(source, "bin"))
    File.cp!(Path.expand("../../../../../bin/mix", __DIR__), Path.join(source, "bin/mix"))
    File.chmod!(Path.join(source, "bin/mix"), 0o755)
    :ok = Helpers.plant_fixed_overlay!(identity.path)
    {identity, handle, request_for(identity), source}
  end

  defp acquire_production_fixture! do
    parent = Helpers.unique_source_root()
    {:ok, identity} = Shell.create_private_owned_tree(parent)
    handle = Helpers.handle_for_owned!(identity)
    source = Path.join(parent, "source")

    _project =
      Helpers.plant_production_child_project!(
        source,
        valid_mix_project(),
        "defmodule TrustedBuildFixture, do: def hello, do: :ok\n"
      )

    :ok = Helpers.plant_fixed_overlay!(identity.path)
    {:ok, lease, _view} = Shell.acquire_trusted_build_lease(request_for(identity))
    {lease, identity, handle, source}
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

  defp valid_mix_project do
    """
    defmodule TrustedBuildFixture.MixProject do
      use Mix.Project
      def project, do: [app: :trusted_build_fixture, version: "0.1.0"]
      def application, do: []
    end
    """
  end
end
