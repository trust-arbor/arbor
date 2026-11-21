defmodule Arbor.Kernel.BoundaryConfigurationTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  @production_boundaries %{
    Arbor.Kernel => %{deps: [], exports: []},
    Arbor.Types => %{deps: [], exports: :all},
    Arbor.Identifiers => %{deps: [Arbor.Types], exports: :all},
    Arbor.Contracts => %{
      deps: [Arbor.Types, Arbor.Identifiers, Jason, TypedStruct],
      exports: :all
    }
  }

  test "passive kernel enables strict alias-aware Boundary compilation" do
    source = File.read!(Path.join(umbrella_root(), "packages/arbor_kernel/mix.exs"))

    assert source =~ ~r/compilers:\s*\[:boundary\]\s*\+\+\s*Mix\.compilers\(\)/
    assert source =~ ~r/type:\s*:strict/
    assert source =~ ~r/check:\s*\[aliases:\s*true\]/
    assert source =~ ~r/\{:boundary,\s*"~> 0\.10",\s*runtime:\s*false\}/
    refute source =~ "dirty_xrefs"

    lock_source = File.read!(Path.join(umbrella_root(), "mix.lock"))

    assert lock_source =~
             ~r/"boundary":\s*\{:hex,\s*:boundary,\s*"0\.11\.0"/

    refute :boundary in Application.spec(:arbor_kernel, :applications)
  end

  test "passive production namespaces retain least-privilege declarations" do
    for {module, expected} <- @production_boundaries do
      definition = boundary_definition(module)
      opts = definition.opts

      assert definition.app == :arbor_kernel
      assert definition.mix_task? == false
      assert Keyword.fetch!(opts, :top_level?) == true
      assert Keyword.fetch!(opts, :deps) == expected.deps
      assert Keyword.fetch!(opts, :exports) == expected.exports
      refute Keyword.has_key?(opts, :dirty_xrefs)
      refute disabled_check?(opts)
    end
  end

  defp boundary_definition(module) do
    [definition] = Keyword.fetch!(module.__info__(:attributes), Boundary)
    definition
  end

  defp disabled_check?(opts) do
    check = Keyword.get(opts, :check, [])
    Keyword.get(check, :in, true) == false or Keyword.get(check, :out, true) == false
  end

  defp umbrella_root do
    Path.expand("../../../../..", __DIR__)
  end
end
