defmodule Arbor.KernelRuntime.TrustHistorianPackageAdoptionTest do
  use ExUnit.Case, async: true

  @moduletag :fast
  @root Path.expand("../../../../..", __DIR__)
  @families [
    {"trust", "Arbor.Trust",
     ~w(Arbor.Trust Arbor.Trust.Application Arbor.Trust.PolicyHost Arbor.Trust.ConfirmationTracker Arbor.Trust.CapabilityGrantOwner)},
    {"historian", "Arbor.Historian",
     ~w(Arbor.Historian Arbor.Historian.Application Arbor.Historian.AuthorityAuditPuller)}
  ]

  test "canonical active families have one physical mechanism owner and passive product hosts" do
    for {family, namespace, modules} <- @families do
      package = Path.join(@root, "packages/arbor_#{family}")
      host = Path.join(@root, "apps/arbor_#{family}_host")
      refute File.exists?(Path.join(@root, "apps/arbor_#{family}/mix.exs"))
      package_modules = module_names(Path.join(package, "lib"))
      host_modules = module_names(Path.join(host, "lib"))

      for module <- modules do
        assert Enum.count(package_modules, &(&1 == module)) == 1
        refute module in host_modules
      end

      assert MapSet.disjoint?(MapSet.new(package_modules), MapSet.new(host_modules))
      assert File.read!(Path.join(package, "mix.exs")) =~ "mod: {#{namespace}.Application"
      host_source = File.read!(Path.join(host, "mix.exs"))
      refute host_source =~ "mod: {"
      refute host_source =~ "registered:"
      assert host_source =~ ":arbor_kernel_runtime"
      assert host_source =~ "../../packages/arbor_#{family}"
      [runtime_position] = positions(host_source, "{:arbor_kernel_runtime")
      [package_position] = positions(host_source, "{:arbor_#{family},")
      assert runtime_position < package_position
    end
  end

  test "root composition keeps canonical packages build available without making them product roots" do
    root_project = File.read!(Path.join(@root, "mix.exs"))

    for {family, _namespace, _modules} <- @families do
      assert root_project =~ "path: \"packages/arbor_#{family}\""

      for consumer <-
            ~w(arbor_agent arbor_actions arbor_memory arbor_orchestrator arbor_dashboard) do
        source = File.read!(Path.join(@root, "apps/#{consumer}/mix.exs"))
        assert source =~ "../../packages/arbor_#{family}"
        assert source =~ "{:arbor_#{family}_host, in_umbrella: true}"
        refute source =~ "{:arbor_#{family}, in_umbrella: true}"
      end
    end
  end

  defp module_names(root) do
    root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

      {_ast, names} =
        Macro.prewalk(ast, [], fn
          {:defmodule, _, [{:__aliases__, _, parts}, _]} = node, acc ->
            if Enum.all?(parts, &is_atom/1),
              do: {node, [Enum.map_join(parts, ".", &Atom.to_string/1) | acc]},
              else: {node, acc}

          node, acc ->
            {node, acc}
        end)

      names
    end)
  end

  defp positions(source, literal), do: :binary.matches(source, literal) |> Enum.map(&elem(&1, 0))
end
