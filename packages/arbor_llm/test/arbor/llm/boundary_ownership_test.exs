defmodule Arbor.LLM.BoundaryOwnershipTest do
  use ExUnit.Case, async: true

  alias Boundary.Mix.Classifier

  @moduletag :fast

  test "the historical helper namespaces retain the canonical LLM application owner" do
    modules = Application.spec(:arbor_llm, :modules) || []

    for module <- [Arbor, Arbor.LLM, Arbor.AI.LLMError, Arbor.Orchestrator.ToolHooks] do
      assert module in modules
      assert Application.get_application(module) == :arbor_llm
    end

    assert Arbor.__info__(:functions) == []
    assert Application.spec(:arbor_llm, :mod) == {Arbor.LLM.Application, []}
    assert is_pid(Process.whereis(Arbor.LLM.Supervisor))
  end

  test "the common namespace boundary retains strict checks and exact public exports" do
    [definition] = Keyword.fetch!(Arbor.__info__(:attributes), Boundary)

    assert definition.app == :arbor_llm
    assert definition.opts[:top_level?] == true
    assert definition.opts[:type] == :strict

    assert definition.opts[:exports] == [
             {LLM, []},
             {Contracts, []},
             AI.LLMError,
             Orchestrator.ToolHooks
           ]

    refute Keyword.has_key?(definition.opts, :classify_to)
    refute Keyword.has_key?(definition.opts, :dirty_xrefs)
    refute ExUnit in definition.opts[:deps]

    check = Keyword.get(definition.opts, :check, [])
    refute Keyword.get(check, :in, true) == false
    refute Keyword.get(check, :out, true) == false
  end

  test "the actual Boundary classifier never absorbs foreign application modules by prefix" do
    modules = Application.spec(:arbor_llm, :modules) || []
    assert modules != []

    boundaries =
      for root <- [Arbor, Arbor.LLM.TestSupport] do
        [definition] = Keyword.fetch!(root.__info__(:attributes), Boundary)

        :arbor_llm
        |> Boundary.Definition.normalize(root, definition.opts)
        |> Map.put(:name, root)
      end

    classifier =
      Classifier.classify(
        Classifier.new(),
        :arbor_llm,
        modules,
        boundaries
      )

    for module <- modules do
      if module == Arbor or String.starts_with?(Atom.to_string(module), "Elixir.Arbor.") do
        expected =
          if module == Arbor.LLM.TestSupport or
               String.starts_with?(Atom.to_string(module), "Elixir.Arbor.LLM.TestSupport."),
             do: Arbor.LLM.TestSupport,
             else: Arbor

        assert classifier.modules[module] == expected
      else
        assert Code.ensure_loaded?(module)
        assert function_exported?(module, :__impl__, 1)
        refute Map.has_key?(classifier.modules, module)
      end
    end

    for {module, owner} <- [
          {Arbor.Contracts.Security.Taint, :arbor_kernel},
          {Arbor.Eval.Subject, :arbor_kernel},
          {Arbor.Common.SensitivityClassifier, :arbor_support}
        ] do
      assert Application.get_application(module) == owner
      refute module in modules
      refute Map.has_key?(classifier.modules, module)
    end
  end

  test "LLM code dependencies do not start Signals or product authority applications" do
    applications = Application.spec(:arbor_llm, :applications) || []

    assert Enum.sort(
             Enum.filter(applications, fn app ->
               String.starts_with?(Atom.to_string(app), "arbor_")
             end)
           ) == [:arbor_kernel, :arbor_oauth, :arbor_support]

    refute :arbor_signals in applications
    refute :arbor_kernel_runtime in applications
    refute :arbor_capabilities in applications
    refute :arbor_ai in applications
    refute :arbor_orchestrator in applications
    refute :boundary in applications
  end
end
