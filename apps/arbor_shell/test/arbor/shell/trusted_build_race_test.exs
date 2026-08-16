defmodule Arbor.Shell.TrustedBuildRaceTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell
  alias Arbor.Shell.TrustedBuild

  test "replacing wrapper or source after acquire fails closed" do
    if match?({:unix, :darwin}, :os.type()) do
      {lease, identity, source} = start_fixture!()

      try do
        File.write!(Path.join(source, "bin/mix"), "#!/bin/sh\necho forged\n")
        File.chmod!(Path.join(source, "bin/mix"), 0o755)

        assert {:error, _reason} = Shell.execute_trusted_build(lease, "deps_get")

        assert {:error, :trusted_build_phase_locked} =
                 Shell.execute_trusted_build(lease, "compile")
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
      end
    end
  end

  test "replacing a writable root after acquire fails closed" do
    if match?({:unix, :darwin}, :os.type()) do
      {lease, identity, _source} = start_fixture!()

      try do
        # Last-boundary re-pins every 0700 child. Swapping the lease worker's
        # private tree is not caller-visible; replacing source cwd is.
        File.rm_rf!(Path.join(identity.path, "source"))
        File.mkdir_p!(Path.join(identity.path, "source"))

        assert {:error, _reason} = Shell.execute_trusted_build(lease, "deps_get")
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
      end
    end
  end

  defp start_fixture! do
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
    {lease, identity, source}
  end
end
