defmodule Arbor.Agent.ReleaseNoMixDependencyPlanTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @fixture Path.expand("../../release_no_mix", __DIR__)
  @root Path.expand("../../../..", @fixture)

  test "the real release fixture resolves direct libraries to their canonical source owners" do
    previous_project = Mix.Project.get()
    previous_config = Mix.Project.config()
    previous_directory = File.cwd!()

    dependencies =
      Mix.Project.in_project(:arbor_agent_release_gate, @fixture, fn _project ->
        Keyword.fetch!(Mix.Project.config(), :deps)
      end)

    assert Mix.Project.get() == previous_project
    assert Mix.Project.config() == previous_config
    assert File.cwd!() == previous_directory

    library_dependencies =
      Enum.filter(dependencies, fn
        {application, options} when is_atom(application) and is_list(options) ->
          application |> Atom.to_string() |> String.starts_with?("arbor_")

        _other ->
          false
      end)

    assert library_dependencies != []
    assert [kernel_options] = Keyword.get_values(library_dependencies, :arbor_kernel)
    kernel_source = Path.join(@root, "packages/arbor_kernel")
    assert Keyword.fetch!(kernel_options, :path) == kernel_source
    assert File.regular?(Path.join(kernel_source, "mix.exs"))

    Enum.each(library_dependencies, fn {application, options} ->
      owners =
        for scope <- ["apps", "packages"],
            source = Path.join([@root, scope, Atom.to_string(application)]),
            File.regular?(Path.join(source, "mix.exs")),
            do: source

      assert [owner] = owners,
             "#{application} must have exactly one canonical source owner, got: #{inspect(owners)}"

      assert Keyword.fetch!(options, :path) == owner,
             "#{application} release dependency does not resolve to its existing source owner"
    end)
  end
end
