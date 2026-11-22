defmodule Arbor.Support.PrerequisiteAdoptionTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  @boundaries %{
    Arbor.Common.PromptSanitizer => [Arbor.Common.Sanitizers.PromptInjection],
    Arbor.Common.Sanitizers.PromptInjection => [Arbor.Contracts],
    Arbor.Common.SensitivityClassifier => [Arbor.Common.SensitiveData]
  }

  test "prompt and sensitivity helpers retain one support application owner" do
    package_modules = Application.spec(:arbor_support, :modules) || []
    runtime_modules = Application.spec(:arbor_kernel_runtime, :modules) || []

    for module <- Map.keys(@boundaries) do
      assert module in package_modules
      refute module in runtime_modules
      assert Application.get_application(module) == :arbor_support
    end

    assert Application.get_application(Arbor.Contracts.Security.Sanitizer) == :arbor_kernel
    assert Application.get_application(Arbor.Contracts.Security.Taint) == :arbor_kernel
    refute Arbor.Contracts.Security.Taint in package_modules
  end

  test "moved helper boundaries expose only their existing root APIs" do
    for {module, deps} <- @boundaries do
      [definition] = Keyword.fetch!(module.__info__(:attributes), Boundary)

      assert definition.app == :arbor_support
      assert definition.opts[:top_level?] == true
      assert definition.opts[:deps] == deps
      assert definition.opts[:exports] == []
      refute Keyword.has_key?(definition.opts, :dirty_xrefs)
      check = Keyword.get(definition.opts, :check, [])
      refute Keyword.get(check, :in, true) == false
      refute Keyword.get(check, :out, true) == false
    end
  end

  test "support depends only on the passive kernel and starts no owner" do
    applications = Application.spec(:arbor_support, :applications) || []

    assert Enum.filter(applications, fn app ->
             String.starts_with?(Atom.to_string(app), "arbor_")
           end) == [:arbor_kernel]

    assert Application.spec(:arbor_support, :mod) in [nil, []]
    assert Application.spec(:arbor_support, :registered) in [nil, []]
    assert Application.spec(:arbor_kernel, :mod) in [nil, []]
    refute :boundary in applications
    refute :arbor_kernel_runtime in applications
  end
end
