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
    source = File.read!(Path.join(umbrella_root(), "apps/arbor_kernel/mix.exs"))

    assert source =~ ~r/compilers:\s*\[:boundary\]\s*\+\+\s*Mix\.compilers\(\)/
    assert source =~ ~r/type:\s*:strict/
    assert source =~ ~r/check:\s*\[aliases:\s*true\]/
    assert source =~ ~r/\{:boundary,\s*"~> 0\.10",\s*runtime:\s*false\}/
    refute source =~ "dirty_xrefs"

    lock_source = File.read!(Path.join(umbrella_root(), "mix.lock"))

    assert lock_source =~
             ~r/"boundary":\s*\{:hex,\s*:boundary,\s*"0\.10\.4"/

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

  test "the contracts census is explicitly classified as development tooling" do
    definition = boundary_definition(Arbor.Kernel.DevTools)

    assert definition.app == :arbor_kernel
    assert definition.opts[:top_level?] == true
    assert definition.opts[:check] == [in: false, out: false]
    assert definition.opts[:exports] == []
    refute Keyword.has_key?(definition.opts, :dirty_xrefs)

    assert {:ok, modules} = :application.get_key(:arbor_kernel, :modules)

    tasks = Enum.filter(modules, &mix_task?/1)
    assert tasks == [Mix.Tasks.Arbor.Contracts.Census]

    for task <- tasks do
      task_definition = boundary_definition(task)
      assert task_definition.mix_task?
      assert task_definition.opts == [classify_to: Arbor.Kernel.DevTools]
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

  defp mix_task?(module), do: String.starts_with?(Atom.to_string(module), "Elixir.Mix.Tasks.")

  defp umbrella_root do
    Path.expand("../../../../..", __DIR__)
  end
end
