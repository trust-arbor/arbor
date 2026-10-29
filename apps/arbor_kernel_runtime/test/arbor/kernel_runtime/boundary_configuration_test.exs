defmodule Arbor.KernelRuntime.BoundaryConfigurationTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  @production_boundaries %{
    # These exports serve the management facade and the configured Signals
    # credential adapter. Keep the list exact: extraction changes ownership,
    # without granting access to other Kernel Runtime internals.
    Arbor.KernelRuntime => %{
      deps: [Arbor.Common, Arbor.Contracts, Arbor.Signals, Arbor.Monitor, Logger],
      exports: [SafeManagementSurface, Adapters.SignalAuthContext]
    },
    Arbor.Common => %{
      deps: [Arbor.Contracts, Arbor.Custody, Finch, Jason, Logger, Req, Zoi],
      exports: :all
    },
    Arbor.Eval => %{deps: [Arbor.Contracts, Arbor.Common, Jason], exports: :all},
    Arbor.Signals => %{
      app: :arbor_signals,
      deps: [Jason, Logger, TypedStruct],
      exports: :all
    },
    Arbor.Monitor => %{
      deps: [Arbor.Common, Arbor.Contracts, Arbor.Signals, Logger],
      exports: :all
    }
  }

  test "runtime kernel enables strict alias-aware Boundary compilation" do
    source = File.read!(Path.join(umbrella_root(), "apps/arbor_kernel_runtime/mix.exs"))

    assert source =~
             ~r/compilers:\s*\[:arbor_safe_path_reader,\s*:boundary\]\s*\+\+\s*Mix\.compilers\(\)/

    assert source =~ ~r/type:\s*:strict/
    assert source =~ ~r/check:\s*\[aliases:\s*true\]/
    assert source =~ ~r/\{:boundary,\s*"~> 0\.10",\s*runtime:\s*false\}/

    assert source =~
             ~r/\{:llm_db,\s*"~> 2026\.1",\s*optional:\s*true,\s*runtime:\s*false\}/

    assert source =~ ~r/\{:finch,\s*"~> 0\.24",\s*runtime:\s*false\}/
    assert source =~ ~r/\{:req,\s*"~> 0\.5",\s*runtime:\s*false\}/
    assert source =~ ~r/\{:recon,\s*"~> 2\.5",\s*runtime:\s*false\}/
    assert source =~ ~r/override:\s*true,\s*runtime:\s*false\}/

    refute source =~ "dirty_xrefs"

    refute :boundary in Application.spec(:arbor_kernel_runtime, :applications)
    refute :llm_db in Application.spec(:arbor_kernel_runtime, :applications)

    Enum.each([:os_mon, :finch, :mint, :req, :recon], fn app ->
      refute app in (Application.spec(:arbor_kernel_runtime, :applications) || [])
    end)
  end

  test "runtime production namespaces retain least-privilege declarations" do
    for {module, expected} <- @production_boundaries do
      definition = boundary_definition(module)
      opts = definition.opts

      assert definition.app == Map.get(expected, :app, :arbor_kernel_runtime)
      assert definition.mix_task? == false
      assert Keyword.fetch!(opts, :top_level?) == true
      assert Keyword.fetch!(opts, :deps) == expected.deps
      assert Keyword.fetch!(opts, :exports) == expected.exports
      refute Keyword.has_key?(opts, :dirty_xrefs)
      refute disabled_check?(opts)
    end
  end

  test "every runtime Mix task is explicitly classified as development tooling" do
    definition = boundary_definition(Arbor.KernelRuntime.DevTools)

    assert definition.app == :arbor_kernel_runtime
    assert definition.opts[:top_level?] == true
    assert definition.opts[:check] == [in: false, out: false]
    assert definition.opts[:exports] == []
    refute Keyword.has_key?(definition.opts, :dirty_xrefs)

    assert {:ok, modules} = :application.get_key(:arbor_kernel_runtime, :modules)

    tasks = Enum.filter(modules, &mix_task?/1)
    # Doctor is command-layer diagnostics; Kernel Runtime owns the remaining
    # development tasks and must keep each one explicitly classified.
    assert length(tasks) == 26

    for task <- tasks do
      task_definition = boundary_definition(task)
      assert task_definition.mix_task?
      assert task_definition.opts == [classify_to: Arbor.KernelRuntime.DevTools]
    end
  end

  test "test config helpers have explicit ExUnit-only boundaries" do
    for module <- [
          Arbor.Common.Config.Testing,
          Arbor.Signals.Config.Testing,
          Arbor.Monitor.Config.Testing,
          Arbor.KernelRuntime.BootProfileBinding.Testing
        ] do
      definition = boundary_definition(module)

      expected_app =
        if module == Arbor.Signals.Config.Testing, do: :arbor_signals, else: :arbor_kernel_runtime

      assert definition.app == expected_app
      assert definition.opts[:top_level?] == true
      assert definition.opts[:deps] == [ExUnit.Callbacks]
      assert definition.opts[:exports] == :all
      refute Keyword.has_key?(definition.opts, :dirty_xrefs)
      refute disabled_check?(definition.opts)
    end
  end

  test "the cross-application cluster harness is isolated as test tooling" do
    definition = boundary_definition(Arbor.Signals.ClusterTestHelpers)

    assert definition.app == :arbor_kernel_runtime
    assert definition.opts[:top_level?] == true
    assert definition.opts[:check] == [in: false, out: false]
    assert definition.opts[:exports] == []
    refute Keyword.has_key?(definition.opts, :dirty_xrefs)
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
