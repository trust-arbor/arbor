defmodule Arbor.Shell.TrustedBuildLifecycleTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell

  test "release proves workspace absence and cleanup fault is retained" do
    {lease, identity} = start_source!()

    assert {:ok, fail_lease, _view} =
             Shell.acquire_trusted_build_lease_for_test(
               request_for(identity),
               :force_cleanup_failure
             )

    assert {:error, {:cleanup_retained, :forced_cleanup_failure, evidence}} =
             Shell.release_trusted_build_lease(fail_lease)

    assert is_binary(evidence.path)
    assert is_integer(evidence.device)

    {lease2, identity2} = start_source!()

    {:ok, ok_lease, _view} =
      Shell.acquire_trusted_build_lease_for_test(request_for(identity2), :omit_hex_seed)

    assert :ok = Shell.release_trusted_build_lease(ok_lease)
    refute File.exists?(workspace_gone_probe(ok_lease))
    _ = Shell.remove_owned_tree(identity)
    _ = Shell.remove_owned_tree(identity2)
    _ = lease
  end

  test "identity capture failure is not build success" do
    {_lease, identity} = start_source!()

    assert {:error, :root_identity_capture_failed} =
             Shell.acquire_trusted_build_lease_for_test(
               request_for(identity),
               :force_identity_capture_failure
             )

    _ = Shell.remove_owned_tree(identity)
  end

  test "rebound source cannot be acquired twice" do
    if match?({:unix, :darwin}, :os.type()) do
      {_unused, identity} = start_source!()
      request = request_for(identity)
      {:ok, lease, _view} = Shell.acquire_trusted_build_lease_for_test(request, :omit_hex_seed)

      assert {:error, :owned_tree_purpose_mismatch} =
               Shell.acquire_trusted_build_lease_for_test(request, :omit_hex_seed)

      _ = Shell.release_trusted_build_lease(lease)
      _ = Shell.remove_owned_tree(identity)
    end
  end

  defp start_source! do
    parent = Path.join(System.tmp_dir!(), "arbor-tb-src-#{System.unique_integer([:positive])}")
    {:ok, identity} = Shell.create_private_owned_tree(parent)
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
    {nil, identity}
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

  defp workspace_gone_probe(_lease), do: "/nonexistent-trusted-build-workspace"
end
