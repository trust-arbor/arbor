defmodule Arbor.Shell.TrustedBuild.BeamIdentityTest do
  use ExUnit.Case, async: false

  import Bitwise

  @moduletag :fast

  alias Arbor.Shell.TrustedBuild.BeamIdentity

  @lease_a "/private/tmp/lease-aaa"
  @lease_b "/private/tmp/lease-bbb"
  @workspace_a "/private/tmp/ws-aaa"
  @workspace_b "/private/tmp/ws-bbb"

  test "isolated @external_resource and Line paths become identical after rewrite" do
    mod = Module.concat(__MODULE__, "Same")
    beam_a = compile_external!(mod, @lease_a)
    purge(mod)
    beam_b = compile_external!(mod, @lease_b)

    try do
      assert beam_a != beam_b

      reps_a = BeamIdentity.replacements([@lease_a], [@workspace_a])
      reps_b = BeamIdentity.replacements([@lease_b], [@workspace_b])

      assert {:ok, normalized_a} = BeamIdentity.normalize_beam(beam_a, reps_a)
      assert {:ok, normalized_b} = BeamIdentity.normalize_beam(beam_b, reps_b)
      assert normalized_a == normalized_b
      assert {:ok, ^normalized_a} = BeamIdentity.normalize_beam(normalized_a, reps_a)
    after
      purge(mod)
      File.rm_rf!(@lease_a)
      File.rm_rf!(@lease_b)
    end
  end

  test "compile-time vsn is pinned so __DIR__ modules from isolated trees compare equal" do
    mod = Module.concat(__MODULE__, "DirMod")
    beam_a = compile_dir_module!(mod, @lease_a)
    purge(mod)
    beam_b = compile_dir_module!(mod, @lease_b)

    try do
      assert beam_a != beam_b
      reps_a = BeamIdentity.replacements([@lease_a], [@workspace_a])
      reps_b = BeamIdentity.replacements([@lease_b], [@workspace_b])
      assert {:ok, normalized_a} = BeamIdentity.normalize_beam(beam_a, reps_a)
      assert {:ok, normalized_b} = BeamIdentity.normalize_beam(beam_b, reps_b)
      assert normalized_a == normalized_b
      {:ok, {_, [attributes: attrs]}} = :beam_lib.chunks(normalized_a, [:attributes])
      assert attrs[:vsn] == [0]
    after
      purge(mod)
      File.rm_rf!(@lease_a)
      File.rm_rf!(@lease_b)
    end
  end

  test "prefix replacement is segment-aware and does not rewrite a longer sibling" do
    reps = BeamIdentity.replacements([@lease_a], [@workspace_a])
    lease_a = @lease_a
    {^lease_a, identity_canon} = List.keyfind(reps, lease_a, 0)
    assert byte_size(identity_canon) == byte_size(lease_a)
    sibling = @lease_a <> "2/apps/kernel.ex"
    nested = @lease_a <> "/apps/kernel.ex"

    assert BeamIdentity.rewrite_paths(sibling, reps) == sibling
    assert BeamIdentity.rewrite_paths(nested, reps) == identity_canon <> "/apps/kernel.ex"
  end

  test "normalize_release_tree rewrites regular beams and rejects a symlink beam" do
    root = Path.join("/private/tmp", "arbor-beam-id-#{System.unique_integer([:positive])}")
    ebin = Path.join(root, "rel/arbor_trust/lib/demo-0.1.0/ebin")
    File.mkdir_p!(ebin)

    {mod, beam} = compile_named_external!(@lease_a)

    try do
      beam_path = Path.join(ebin, "Elixir.Demo.beam")
      File.write!(beam_path, beam)
      File.chmod!(beam_path, 0o444)

      reps = BeamIdentity.replacements([@lease_a], [@workspace_a])
      assert :ok = BeamIdentity.normalize_release_tree(Path.join(root, "rel"), reps)

      rewritten = File.read!(beam_path)
      assert rewritten != beam
      assert {:ok, rewritten} == BeamIdentity.normalize_beam(beam, reps)
      assert (File.lstat!(beam_path).mode &&& 0o777) == 0o444

      File.rm!(beam_path)
      File.ln_s!("/etc/passwd", beam_path)

      assert {:error, :symlink_rejected} =
               BeamIdentity.normalize_release_tree(Path.join(root, "rel"), reps)
    after
      purge(mod)
      File.rm_rf!(root)
    end
  end

  test "normalize_release_tree rewrites sys.config lease prefixes" do
    root = Path.join("/private/tmp", "arbor-beam-cfg-#{System.unique_integer([:positive])}")
    rel = Path.join(root, "rel/arbor_trust/releases/0.1.0")
    File.mkdir_p!(rel)
    config = Path.join(rel, "sys.config")

    File.write!(
      config,
      ~s([{elixir,[{config_path,<<"#{@lease_a}/source/config/config.exs">>}]}].\n)
    )

    reps = BeamIdentity.replacements([@lease_a], [@workspace_a])
    lease_a = @lease_a
    {^lease_a, identity_canon} = List.keyfind(reps, lease_a, 0)
    assert :ok = BeamIdentity.normalize_release_tree(Path.join(root, "rel"), reps)
    assert File.read!(config) =~ identity_canon <> "/source/config/config.exs"
    refute File.read!(config) =~ @lease_a
    File.rm_rf!(root)
  end

  test "invalid BEAM bytes fail closed" do
    reps = BeamIdentity.replacements([@lease_a], [@workspace_a])

    assert {:error, :trusted_build_beam_identity} =
             BeamIdentity.normalize_beam("not-a-beam", reps)
  end

  defp compile_named_external!(prefix) do
    id = System.unique_integer([:positive])
    mod = Module.concat(__MODULE__, "M#{id}")
    {mod, compile_external!(mod, prefix)}
  end

  defp compile_external!(mod, prefix) do
    dir = Path.join(prefix, "lib")
    File.mkdir_p!(dir)
    src = Path.join(dir, "m.ex")
    resource = Path.join(prefix, "apps/arbor_kernel/lib/arbor/kernel.ex")

    File.write!(src, """
    defmodule #{inspect(mod)} do
      @external_resource #{inspect(resource)}
      def id, do: :ok
    end
    """)

    [{^mod, raw}] = Code.compile_file(src)
    {:ok, stripped} = Mix.Release.strip_beam(raw)
    stripped
  end

  defp compile_dir_module!(mod, prefix) do
    dir = Path.join(prefix, "lib")
    File.mkdir_p!(dir)
    src = Path.join(dir, "dir.ex")

    File.write!(src, """
    defmodule #{inspect(mod)} do
      def dir, do: __DIR__
      def wrap, do: fn -> __DIR__ end
    end
    """)

    [{^mod, raw}] = Code.compile_file(src)
    {:ok, stripped} = Mix.Release.strip_beam(raw)
    stripped
  end

  defp purge(mod) do
    :code.purge(mod)
    :code.delete(mod)
  end
end
