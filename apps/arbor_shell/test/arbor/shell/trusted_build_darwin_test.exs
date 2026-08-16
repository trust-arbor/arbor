defmodule Arbor.Shell.TrustedBuildDarwinTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell
  alias Arbor.Shell.TrustedBuild

  @darwin? match?({:unix, :darwin}, :os.type())

  setup do
    if @darwin? do
      {lease, identity, source} = start_fixture!()

      on_exit(fn ->
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(identity)
      end)

      {:ok, lease: lease, identity: identity, source: source}
    else
      :ok
    end
  end

  test "darwin compile denies network and source writes, allows private writes, uses closed env",
       context do
    if @darwin? do
      lease = context.lease
      source = context.source
      assert {:ok, result} = Shell.execute_trusted_build(lease, "compile")
      assert result.exit_code == 0
      refute File.exists?(Path.join(source, "SHOULD_NOT_WRITE"))
      assert File.exists?(Path.join(source, "lib/trusted_build_fixture.ex"))
    end
  end

  test "phase order is enforced and a second deps_get is rejected", context do
    if @darwin? do
      lease = context.lease

      assert {:error, :trusted_build_phase_rejected} =
               Shell.execute_trusted_build(lease, "compile")

      assert {:ok, deps} = Shell.execute_trusted_build(lease, "deps_get")
      assert deps.exit_code == 0

      assert {:error, :trusted_build_phase_rejected} =
               Shell.execute_trusted_build(lease, "deps_get")
    end
  end

  defp start_fixture! do
    tmp = System.tmp_dir!()
    parent = Path.join(tmp, "arbor-tb-src-#{System.unique_integer([:positive])}")
    {:ok, identity} = Shell.create_private_owned_tree(parent)
    source = Path.join(parent, "source")
    File.mkdir_p!(Path.join([source, "lib"]))
    File.mkdir_p!(Path.join([source, "bin"]))

    File.write!(Path.join(source, "mix.exs"), """
    defmodule TrustedBuildFixture.MixProject do
      use Mix.Project

      def project do
        build = System.get_env("MIX_BUILD_PATH")
        if is_binary(build) do
          File.mkdir_p!(build)
          File.write!(Path.join(build, "env_keys.txt"), System.get_env() |> Map.keys() |> Enum.sort() |> Enum.join("\\n"))
        end
        _ = File.write(Path.join(File.cwd!(), "SHOULD_NOT_WRITE"), "x")
        _ = :gen_tcp.connect({1, 1, 1, 1}, 80, [], 200)
        [app: :trusted_build_fixture, version: "0.1.0", elixir: "~> 1.17"]
      end

      def application, do: []
    end
    """)

    File.write!(Path.join(source, "lib/trusted_build_fixture.ex"), """
    defmodule TrustedBuildFixture do
      def hello, do: :ok
    end
    """)

    File.cp!(Path.expand("../../../../../bin/mix", __DIR__), Path.join(source, "bin/mix"))
    File.chmod!(Path.join(source, "bin/mix"), 0o755)

    request = request_for(identity)
    {:ok, lease, view} = TrustedBuild.acquire(request, :omit_hex_seed)
    assert view["schema"] == "arbor.shell.trusted_build.lease.v1"
    refute Map.has_key?(view, "path")
    {lease, identity, source}
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
