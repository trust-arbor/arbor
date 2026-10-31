defmodule Arbor.Actions.ToolAdapterSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.Tool.FindTools
  alias Arbor.Common.CapabilityIndex
  alias Arbor.Contracts.CapabilityDescriptor

  @moduletag :fast
  @moduletag :security_regression

  defmodule MetadataAction do
    def to_tool do
      %{name: "port.metadata", description: "Synthetic discovery schema", parameters_schema: %{}}
    end

    def tags, do: []
  end

  defmodule IndexedProvider do
    def list_capabilities(_opts \\ []) do
      [
        %CapabilityDescriptor{
          id: "action:portdefinitions",
          name: "portdefinitions",
          kind: :action,
          provider: __MODULE__,
          source_ref: "port.synthetic",
          metadata: %{}
        },
        %CapabilityDescriptor{
          id: "action:portformat",
          name: "portformat",
          kind: :action,
          provider: __MODULE__,
          metadata: %{module: MetadataAction}
        }
      ]
    end
  end

  defmodule SelectedAdapter do
    def definitions(names) do
      send(self(), {:selected_definitions, names})
      if names == ["port.synthetic"], do: [schema("selected:definitions")], else: []
    end

    def to_openai_format(tool) do
      send(self(), {:selected_format, tool.name})
      schema("selected:" <> tool.name)
    end

    defp schema(name), do: %{"type" => "function", "function" => %{"name" => name}}
  end

  setup do
    previous = Application.fetch_env(:arbor_actions, :llm_tool_adapter)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_actions, :llm_tool_adapter, value)
        :error -> Application.delete_env(:arbor_actions, :llm_tool_adapter)
      end
    end)

    :ok
  end

  test "security regression: absent and malformed adapters cannot discover schemas through an implicit fallback" do
    refute Process.whereis(CapabilityIndex)
    start_supervised!({CapabilityIndex, providers: [IndexedProvider]})

    for setting <- [:absent, nil, false, "Elixir.Arbor.LLM.ArborActionsExecutor"] do
      if setting == :absent,
        do: Application.delete_env(:arbor_actions, :llm_tool_adapter),
        else: Application.put_env(:arbor_actions, :llm_tool_adapter, setting)

      for query <- ["portdefinitions", "portformat"] do
        assert {:ok, %{tools: [], count: 0, discovered_tool_names: []}} =
                 FindTools.run(%{query: query, limit: 1}, %{})
      end

      refute_receive {:selected_definitions, _}
      refute_receive {:selected_format, _}
    end
  end

  test "security regression: the trusted adapter retains source reference lookup and module schema formatting" do
    refute Process.whereis(CapabilityIndex)
    start_supervised!({CapabilityIndex, providers: [IndexedProvider]})
    Application.put_env(:arbor_actions, :llm_tool_adapter, SelectedAdapter)

    assert {:ok, %{discovered_tool_names: ["selected:definitions"]}} =
             FindTools.run(%{query: "portdefinitions", limit: 1}, %{})

    assert_receive {:selected_definitions, ["port.synthetic"]}

    assert {:ok, %{discovered_tool_names: ["selected:port.metadata"]}} =
             FindTools.run(%{query: "portformat", limit: 1}, %{})

    assert_receive {:selected_format, "port.metadata"}
  end

  test "security regression: fallback query formatting uses the selected adapter without requiring an index" do
    refute Process.whereis(CapabilityIndex)
    Application.put_env(:arbor_actions, :llm_tool_adapter, SelectedAdapter)

    assert {:ok, %{tools: [tool], count: 1, discovered_tool_names: [name]}} =
             FindTools.run(%{query: "file", limit: 1}, %{})

    assert_receive {:selected_format, _action_name}
    assert String.starts_with?(name, "selected:")
    assert get_in(tool, ["function", "name"]) == name
    refute_receive {:selected_definitions, _}
  end
end
