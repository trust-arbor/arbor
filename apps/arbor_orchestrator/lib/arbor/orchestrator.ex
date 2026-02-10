defmodule Arbor.Orchestrator do
  @moduledoc """
  Attractor-spec orchestration runtime for Arbor.

  This app is intentionally built as a parallel implementation to existing SDLC
  automation and tracks implementation progress against three specs:

  - Attractor specification
  - Coding agent loop specification
  - Unified LLM client specification
  """

  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Transforms.ModelStylesheet
  alias Arbor.Orchestrator.Transforms.VariableExpansion
  alias Arbor.Orchestrator.Validation.Validator

  @type run_result :: {:ok, Engine.run_result()} | {:error, term()}

  @spec parse(String.t()) :: {:ok, Graph.t()} | {:error, term()}
  def parse(dot_source) when is_binary(dot_source), do: Parser.parse(dot_source)

  @spec validate(String.t() | Graph.t(), keyword()) ::
          [Arbor.Orchestrator.Validation.Diagnostic.t()]
  def validate(source_or_graph, opts \\ []) do
    with {:ok, graph} <- ensure_graph(source_or_graph, opts) do
      Validator.validate(graph)
    else
      {:error, reason} ->
        [
          Arbor.Orchestrator.Validation.Diagnostic.error(
            "parse_error",
            "Could not parse pipeline: #{inspect(reason)}"
          )
        ]
    end
  end

  @spec run(String.t() | Graph.t(), keyword()) :: run_result()
  def run(source_or_graph, opts \\ []) do
    with {:ok, graph} <- ensure_graph(source_or_graph, opts),
         :ok <- Validator.validate_or_error(graph) do
      Engine.run(graph, opts)
    end
  end

  @spec conformance_matrix() :: map()
  def conformance_matrix, do: Arbor.Orchestrator.Conformance.Matrix.summary()

  defp ensure_graph(%Graph{} = graph, opts), do: apply_transforms(graph, opts)

  defp ensure_graph(source, opts) when is_binary(source) do
    with {:ok, graph} <- Parser.parse(source) do
      apply_transforms(graph, opts)
    end
  end

  defp ensure_graph(_, _), do: {:error, :invalid_graph_input}

  defp apply_transforms(graph, opts) do
    transforms = [VariableExpansion, ModelStylesheet | Keyword.get(opts, :transforms, [])]

    Enum.reduce_while(transforms, {:ok, graph}, fn transform, {:ok, acc} ->
      case apply_transform(transform, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp apply_transform(module, graph) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, _} ->
        cond do
          function_exported?(module, :transform, 1) ->
            normalize_transform_result(module.transform(graph), module)

          function_exported?(module, :apply, 1) ->
            normalize_transform_result(module.apply(graph), module)

          true ->
            {:error, {:invalid_transform, module}}
        end

      {:error, _} ->
        {:error, {:invalid_transform, module}}
    end
  end

  defp apply_transform(fun, graph) when is_function(fun, 1) do
    normalize_transform_result(fun.(graph), fun)
  end

  defp apply_transform(other, _graph), do: {:error, {:invalid_transform, other}}

  defp normalize_transform_result({:ok, %Graph{} = graph}, _transform), do: {:ok, graph}
  defp normalize_transform_result(%Graph{} = graph, _transform), do: {:ok, graph}
  defp normalize_transform_result({:error, reason}, _transform), do: {:error, reason}

  defp normalize_transform_result(other, transform),
    do: {:error, {:transform_failed, transform, other}}
end
