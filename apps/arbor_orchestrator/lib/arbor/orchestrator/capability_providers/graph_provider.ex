defmodule Arbor.Orchestrator.CapabilityProviders.GraphProvider do
  @moduledoc """
  CapabilityProvider adapter for the GraphRegistry.

  Converts registered DOT pipeline graphs into `CapabilityDescriptor`s
  for the unified capability index.
  """

  @behaviour Arbor.Contracts.CapabilityProvider

  alias Arbor.Orchestrator.GraphRegistry
  alias Arbor.Contracts.CapabilityDescriptor

  @impl true
  def list_capabilities(_opts \\ []) do
    GraphRegistry.list()
    |> Enum.map(&graph_to_descriptor/1)
  end

  @impl true
  def describe(id) do
    case parse_pipeline_id(id) do
      {:ok, name} ->
        if name in GraphRegistry.list() do
          {:ok, graph_to_descriptor(name)}
        else
          {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @impl true
  def execute(id, input, _opts) do
    case parse_pipeline_id(id) do
      {:ok, name} ->
        case GraphRegistry.resolve(name) do
          {:ok, dot_string} ->
            {:ok, %{graph_name: name, dot: dot_string, input: input}}

          {:error, _} = err ->
            err
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc false
  def graph_to_descriptor(name) when is_binary(name) do
    source = Map.get(GraphRegistry.snapshot(), name)

    %CapabilityDescriptor{
      id: "pipeline:#{name}",
      name: humanize_name(name),
      kind: :pipeline,
      description: "DOT pipeline: #{name}",
      tags: extract_tags(name),
      trust_required: :new,
      provider: __MODULE__,
      source_ref: source,
      metadata: %{}
    }
  end

  defp parse_pipeline_id("pipeline:" <> name), do: {:ok, name}
  defp parse_pipeline_id(_), do: :error

  defp humanize_name(name) do
    name
    |> String.split("-")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp extract_tags(name) do
    # Extract meaningful tags from the graph name
    name
    |> String.split(~r/[-_]/)
    |> Enum.reject(&(String.length(&1) < 3))
  end
end
