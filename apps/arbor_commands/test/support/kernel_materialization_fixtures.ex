defmodule Arbor.Commands.KernelMaterializationFixtures do
  @moduledoc false

  alias Arbor.Commands.KernelMaterialization.Encode

  @spec fixture_files() :: [map()]
  def fixture_files do
    [
      file("apps/arbor_contracts/lib/a.ex", "a\n"),
      file("apps/arbor_contracts/mix.exs", "cmix\n"),
      file("apps/arbor_contracts/test/test_helper.exs", "cth\n"),
      file("apps/arbor_common/lib/b.ex", "b\n"),
      file("apps/arbor_common/mix.exs", "omix\n"),
      file("apps/arbor_common/test/test_helper.exs", "oth\n"),
      file("apps/arbor_signals/mix.exs", "smix\n"),
      file("apps/arbor_signals/test/test_helper.exs", "sth\n"),
      file("apps/arbor_monitor/mix.exs", "mmix\n"),
      file("apps/arbor_monitor/test/test_helper.exs", "mth\n"),
      file("apps/arbor_kernel/mix.exs", "kmix\n"),
      file("apps/arbor_kernel/test/test_helper.exs", "kth\n"),
      file("apps/arbor_kernel/lib/arbor/kernel.ex", "kern\n")
    ]
  end

  @spec file(String.t(), binary(), keyword()) :: map()
  def file(path, bytes, opts \\ []) do
    format = Keyword.get(opts, :format, "sha1")
    oid = Encode.git_blob_oid(bytes, format)

    %{
      path: path,
      mode: Keyword.get(opts, :mode, "100644"),
      blob_oid: oid,
      byte_size: byte_size(bytes),
      bytes: bytes
    }
  end

  @spec tmp_root() :: String.t()
  def tmp_root do
    dir =
      Path.join(
        System.tmp_dir!(),
        "k4a-fix-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(Path.join([dir, "apps", "arbor_commands"]))
    File.mkdir_p!(Path.join([dir, "apps", "arbor_kernel"]))
    File.write!(Path.join(dir, "mix.exs"), "defmodule Root.MixProject do\nend\n")
    File.write!(Path.join([dir, "apps", "arbor_commands", "mix.exs"]), "defmodule C do\nend\n")
    File.write!(Path.join([dir, "apps", "arbor_kernel", "mix.exs"]), "defmodule K do\nend\n")
    dir
  end
end
