defmodule Arbor.Shell.TrustedBuildBeamIdentitySecurityRegressionTest do
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Shell.TrustedBuild.BeamIdentity

  test "security regression: Attr term that would create a new atom is rejected" do
    {mod, beam} = compile_module!()

    try do
      atom_name =
        "arbor_trusted_build_new_atom_" <>
          Integer.to_string(System.unique_integer([:positive])) <>
          "_" <>
          Integer.to_string(:erlang.unique_integer([:positive]))

      refute atom_exists?(atom_name)

      rebuilt = replace_attr!(beam, atom_ext(atom_name))

      assert {:error, :trusted_build_beam_identity} =
               BeamIdentity.normalize_beam(rebuilt, [])

      refute atom_exists?(atom_name)
    after
      purge(mod)
    end
  end

  defp atom_exists?(name) do
    _ = String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end

  defp atom_ext(name) when is_binary(name) and byte_size(name) <= 255 do
    <<131, 100, byte_size(name)::16, name::binary>>
  end

  defp replace_attr!(beam, attr_bin) do
    info = :beam_lib.info(beam)
    refute match?({:error, :beam_lib, _}, info)

    names =
      info
      |> Keyword.fetch!(:chunks)
      |> Enum.map(fn {name, _pos, _len} -> name end)

    {:ok, {_module, chunks}} = :beam_lib.chunks(beam, names)

    replaced =
      Enum.map(chunks, fn
        {~c"Attr", _old} -> {~c"Attr", attr_bin}
        other -> other
      end)

    {:ok, rebuilt} = :beam_lib.build_module(replaced)
    rebuilt
  end

  defp compile_module! do
    id = System.unique_integer([:positive])
    mod = Module.concat(__MODULE__, "M#{id}")
    dir = Path.join(System.tmp_dir!(), "arbor-beam-safe-#{id}")
    File.mkdir_p!(dir)
    src = Path.join(dir, "m.ex")

    File.write!(src, """
    defmodule #{inspect(mod)} do
      def id, do: :ok
    end
    """)

    try do
      [{^mod, raw}] = Code.compile_file(src)
      {:ok, stripped} = Mix.Release.strip_beam(raw)
      {mod, stripped}
    after
      File.rm_rf!(dir)
    end
  end

  defp purge(mod) do
    :code.purge(mod)
    :code.delete(mod)
  end
end
