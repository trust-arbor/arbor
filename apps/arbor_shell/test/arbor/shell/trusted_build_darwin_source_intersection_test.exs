Code.require_file("trusted_build_test_helpers.exs", __DIR__)

defmodule Arbor.Shell.TrustedBuildDarwinSourceIntersectionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell
  alias Arbor.Shell.TrustedBuild
  alias Arbor.Shell.TrustedBuild.Plan
  alias Arbor.Shell.TrustedBuildTestHelpers, as: Helpers

  @darwin? match?({:unix, :darwin}, :os.type())
  @tmp_name "tmp_" <> String.duplicate("A", 64)
  @result_name "SOURCE_INTERSECTION_RESULT"
  @private_name "SOURCE_INTERSECTION_PRIVATE_WRITE"

  setup do
    if @darwin? do
      parent = Helpers.unique_source_root()
      {:ok, identity} = Shell.create_private_owned_tree(parent)
      handle = Helpers.handle_for_owned!(identity)

      on_exit(fn ->
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end)

      source = Path.join(identity.path, "source")
      outside_parent = Path.join([identity.path, "outside", "packages", "arbor_trust"])
      outside_tmp = Path.join(outside_parent, @tmp_name)
      File.mkdir_p!(outside_parent)

      _project =
        Helpers.plant_production_child_project!(
          source,
          fixture_project(outside_tmp),
          "defmodule TrustedBuildSourceIntersectionFixture, do: def hello, do: :ok\n"
        )

      :ok = Helpers.plant_fixed_overlay!(identity.path)
      {:ok, lease, _view} = TrustedBuild.acquire(request_for(identity), :omit_hex_seed)

      on_exit(fn ->
        _ = Shell.release_trusted_build_lease(lease)
      end)

      state = :sys.get_state(lease.worker)
      assert state.identities.source.path == source
      refute within?(source, outside_tmp)
      assert length(Plan.writable_names()) == 8

      Enum.each(Plan.writable_names(), fn name ->
        root = Map.fetch!(state.roots, String.to_existing_atom(name)).path
        refute within?(root, outside_tmp)
        refute within?(outside_tmp, root)
      end)

      refute File.exists?(Path.join([source, "packages", "arbor_trust", "SHOULD_NOT_WRITE"]))
      refute File.exists?(Path.join([source, "packages", "arbor_trust", @tmp_name]))
      refute File.exists?(outside_tmp)
      {:ok, lease: lease, build: state.roots.build.path}
    else
      :ok
    end
  end

  test "Darwin trusted-build denies ordinary SOURCE writes while retaining private and Hex tmp writes",
       context do
    if @darwin? do
      evidence = run_phase_and_read_evidence!(context)
      assert_retained_write_controls!(evidence, context.build)
      assert evidence.ordinary_write in [{:error, :eperm}, {:error, :eacces}]
      refute evidence.ordinary_present
    end
  end

  test "Darwin trusted-build denies a tmp-matching path outside SOURCE and every private writable root",
       context do
    if @darwin? do
      evidence = run_phase_and_read_evidence!(context)
      assert_retained_write_controls!(evidence, context.build)
      assert evidence.outside_mkdir in [{:error, :eperm}, {:error, :eacces}]
      refute evidence.outside_present
    end
  end

  defp run_phase_and_read_evidence!(context) do
    assert {:ok, result} = Shell.execute_trusted_build(context.lease, "deps_get")
    assert result.exit_code == 0
    path = Path.join(context.build, @result_name)
    assert {:ok, stat} = File.lstat(path)
    assert stat.type == :regular and stat.links == 1 and stat.size < 4_096
    path |> File.read!() |> :erlang.binary_to_term([:safe])
  end

  defp assert_retained_write_controls!(evidence, build) do
    assert evidence.inside_mkdir == :ok
    assert evidence.inside_rmdir == :ok
    assert evidence.private_write == :ok
    assert File.read!(Path.join(build, @private_name)) == "owned-private\n"
  end

  defp fixture_project(outside_tmp) do
    """
    defmodule TrustedBuildSourceIntersectionFixture.MixProject do
      use Mix.Project

      def project do
        build = System.fetch_env!("MIX_BUILD_PATH")
        ordinary = Path.join(File.cwd!(), "SHOULD_NOT_WRITE")
        inside = Path.join(File.cwd!(), #{inspect(@tmp_name)})
        outside = #{inspect(outside_tmp)}

        ordinary_write = File.write(ordinary, "owned-probe\n")
        ordinary_present = File.exists?(ordinary)
        if ordinary_write == :ok, do: File.rm!(ordinary)

        outside_mkdir = File.mkdir(outside)
        outside_present = File.dir?(outside)
        if outside_mkdir == :ok, do: File.rmdir!(outside)

        inside_mkdir = File.mkdir(inside)
        inside_rmdir = if inside_mkdir == :ok, do: File.rmdir(inside), else: nil
        private_write = File.write(Path.join(build, #{inspect(@private_name)}), "owned-private\n")

        # Restore only these fresh owned probe leaves when the old policy allows
        # them. The production phase must still pass its unchanged source digest.
        evidence = %{
          ordinary_write: ordinary_write,
          ordinary_present: ordinary_present,
          outside_mkdir: outside_mkdir,
          outside_present: outside_present,
          inside_mkdir: inside_mkdir,
          inside_rmdir: inside_rmdir,
          private_write: private_write
        }

        File.write!(Path.join(build, #{inspect(@result_name)}), :erlang.term_to_binary(evidence))
        [app: :trusted_build_source_intersection_fixture, version: "0.1.0"]
      end

      def application, do: []
    end
    """
  end

  defp within?(parent, child) do
    List.starts_with?(Path.split(child), Path.split(parent))
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
