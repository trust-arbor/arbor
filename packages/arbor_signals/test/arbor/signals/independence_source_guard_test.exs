defmodule Arbor.Signals.IndependenceSourceGuardTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  test "production sources depend only on Kernel's canonical taint contracts" do
    root = package_root(__DIR__)
    files = Path.wildcard(Path.join(root, "lib/**/*.ex"))
    assert length(files) >= 27

    for path <- files do
      ast = path |> File.read!() |> Code.string_to_quoted!(file: path)

      {_ast, dependencies} =
        Macro.prewalk(ast, [], fn
          {:use, meta, [{:__aliases__, _alias_meta, [:Boundary]} = boundary, opts]}, acc
          when is_list(opts) ->
            opts =
              Keyword.update(opts, :deps, [], fn deps ->
                Enum.reject(deps, &boundary_root?/1)
              end)

            {{:use, meta, [boundary, opts]}, acc}

          {:__aliases__, _meta, [:Arbor, :Contracts, :Security, owner]} = node, acc
          when owner in [:Taint, :TaintEnvelope] ->
            {node, acc}

          {:__aliases__, _meta, [:Arbor, namespace | _parts]} = node, acc
          when namespace != :Signals ->
            {node, [Macro.to_string(node) | acc]}

          literal, acc when is_atom(literal) ->
            name = Atom.to_string(literal)

            if String.starts_with?(name, "Elixir.Arbor.") and
                 name != "Elixir.Arbor.Signals" and
                 not String.starts_with?(name, "Elixir.Arbor.Signals.") and
                 name not in [
                   "Elixir.Arbor.Contracts.Security.Taint",
                   "Elixir.Arbor.Contracts.Security.TaintEnvelope"
                 ] do
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

  defp boundary_root?({:__aliases__, _meta, [:Arbor, :Contracts]}), do: true
  defp boundary_root?(Arbor.Contracts), do: true
  defp boundary_root?(_other), do: false

  defp package_root(dir) do
    cond do
      File.regular?(Path.join(dir, "lib/arbor/signals.ex")) -> dir
      Path.dirname(dir) == dir -> flunk("Signals package root not found")
      true -> package_root(Path.dirname(dir))
    end
  end
end
