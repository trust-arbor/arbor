defmodule Arbor.Persistence.Ecto.IndependenceSourceGuardTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  test "compiled adapter references only its declared Core/adapter Arbor modules" do
    own_modules = Application.spec(:arbor_persistence_eventstore, :modules)
    core_modules = Application.spec(:arbor_persistence, :modules)
    assert is_list(own_modules) and own_modules != []
    assert is_list(core_modules) and core_modules != []
    assert Arbor.Persistence.Ecto.EventLog in own_modules
    # This is the adapter-owned registered supervisor name, not a module.
    registered_names = [Arbor.Persistence.Ecto.Supervisor]
    allowed = MapSet.new(own_modules ++ core_modules ++ registered_names)

    for module <- own_modules do
      {:ok, {^module, [abstract_code: {:raw_abstract_v1, forms}]}} =
        :beam_lib.chunks(:code.which(module), [:abstract_code])

      references =
        forms
        |> atoms()
        |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "Elixir.Arbor."))
        |> MapSet.new()

      assert MapSet.difference(references, allowed) == MapSet.new(),
             "foreign Arbor references in #{inspect(module)}: " <>
               inspect(MapSet.difference(references, allowed))
    end
  end

  defp atoms(value) when is_atom(value), do: [value]
  defp atoms(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.flat_map(&atoms/1)
  defp atoms(value) when is_list(value), do: Enum.flat_map(value, &atoms/1)
  defp atoms(value) when is_map(value), do: value |> Map.to_list() |> Enum.flat_map(&atoms/1)
  defp atoms(_value), do: []
end
