defmodule Arbor.Contracts.FeatureTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Arbor.Contracts.Feature

  test "publishes the exact passive declaration ABI and three optional callbacks" do
    assert Enum.sort(apply(Feature, :behaviour_info, [:callbacks])) ==
             Enum.sort(
               id: 0,
               requires: 0,
               children: 1,
               action_modules: 0,
               graphs: 0,
               uri_prefixes: 0,
               routes: 0,
               commands: 0,
               health: 0
             )

    assert Enum.sort(apply(Feature, :behaviour_info, [:optional_callbacks])) ==
             Enum.sort(graphs: 0, routes: 0, commands: 0)
  end

  test "compiler requires health while allowing absent optional contributions" do
    assert {:health, 0} in apply(Feature, :behaviour_info, [:callbacks])
    fixture = Module.concat(__MODULE__, CompilerMissingHealth)

    on_exit(fn ->
      :code.purge(fixture)
      :code.delete(fixture)
    end)

    warning =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(fixture)} do
          @behaviour Arbor.Contracts.Feature
          @impl true
          def id, do: :compiler_fixture
          @impl true
          def requires, do: []
          @impl true
          def children(_config), do: []
          @impl true
          def action_modules, do: []
          @impl true
          def uri_prefixes, do: []
        end
        """)
      end)

    assert warning =~ "health/0"
    assert warning =~ "Arbor.Contracts.Feature"
    refute warning =~ "function graphs/0"
    refute warning =~ "function routes/0"
    refute warning =~ "function commands/0"
  end

  test "the public contract registry includes the Feature behaviour" do
    assert Feature in Arbor.Contracts.list_contracts()
  end
end
