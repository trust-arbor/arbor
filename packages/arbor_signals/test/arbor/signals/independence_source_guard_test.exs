defmodule Arbor.Signals.IndependenceSourceGuardTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  test "production sources have no static dependency on another Arbor library" do
    root = package_root(__DIR__)
    files = Path.wildcard(Path.join(root, "lib/**/*.ex"))
    assert length(files) >= 27

    for path <- files do
      ast = path |> File.read!() |> Code.string_to_quoted!(file: path)

      {_ast, dependencies} =
        Macro.prewalk(ast, [], fn
          {:__aliases__, _meta, [:Arbor, namespace | _parts]} = node, acc
          when namespace != :Signals ->
            {node, [Macro.to_string(node) | acc]}

          literal, acc when is_atom(literal) ->
            name = Atom.to_string(literal)

            if String.starts_with?(name, "Elixir.Arbor.") and
                 not String.starts_with?(name, "Elixir.Arbor.Signals") do
              {literal, [name | acc]}
            else
              {literal, acc}
            end

          node, acc ->
            {node, acc}
        end)

      assert dependencies == [],
             "#{Path.relative_to(path, root)} depends on #{inspect(Enum.uniq(dependencies))}"
    end
  end

  defp package_root(dir) do
    cond do
      File.regular?(Path.join(dir, "lib/arbor/signals.ex")) -> dir
      Path.dirname(dir) == dir -> flunk("Signals package root not found")
      true -> package_root(Path.dirname(dir))
    end
  end
end
