defmodule Arbor.Persistence.IndependenceSourceGuardTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  test "core has no host facade, SQL, Kernel, security or Signals source dependency" do
    files = Path.wildcard(Path.join(@root, "lib/**/*.ex"))
    assert length(files) >= 25

    modules =
      for file <- files,
          {:defmodule, _, [{:__aliases__, _, parts}, _]} <- forms(file),
          do: name(parts)

    assert "Arbor.Persistence.Core" in modules
    refute "Arbor.Persistence" in modules

    for file <- files, reference <- references(file), String.starts_with?(reference, "Arbor.") do
      assert reference != "Arbor.Persistence", "host facade reference in #{file}"

      assert reference in modules or
               Enum.any?(modules, &String.starts_with?(&1, reference <> ".")),
             "external Arbor reference #{reference} in #{file}"
    end
  end

  test "ordinary library metadata has no implicit process callback or Arbor dependency" do
    assert Application.spec(:arbor_persistence, :mod) in [nil, []]
    dependencies = Application.spec(:arbor_persistence, :applications)
    assert is_list(dependencies)

    refute Enum.any?(dependencies, fn app ->
             app |> Atom.to_string() |> String.starts_with?("arbor_")
           end)

    assert :crypto in dependencies
    assert :telemetry in dependencies
  end

  defp forms(file) do
    source = file |> File.read!() |> Code.string_to_quoted!()
    {_source, forms} = Macro.prewalk(source, [], fn node, acc -> {node, [node | acc]} end)
    forms
  end

  defp references(file) do
    source = file |> File.read!() |> Code.string_to_quoted!()

    {_source, references} =
      Macro.prewalk(source, [], fn
        {{:., _, [{:__aliases__, _, prefix}, :{}]}, _, suffixes}, acc ->
          references =
            for {:__aliases__, _, suffix} <- suffixes, do: name(prefix ++ suffix)

          {:processed_alias_group, references ++ acc}

        {:__aliases__, _, parts} = node, acc ->
          if Enum.all?(parts, &is_atom/1), do: {node, [name(parts) | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(references)
  end

  defp name(parts), do: Enum.map_join(parts, ".", &Atom.to_string/1)
end
