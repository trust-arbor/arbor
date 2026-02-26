defmodule Arbor.Orchestrator do
  @moduledoc """
  DOT-based pipeline orchestration runtime for Arbor.

  Provides a graph-driven execution engine where pipelines are defined as
  DOT digraphs with typed handler nodes. Supports 31+ handler types
  (LLM calls, tool dispatch, consensus, memory, security, etc.) and
  12 session types for multi-turn agent interactions.

  ## Quick Start

      # Parse and run a DOT pipeline
      {:ok, result} = Arbor.Orchestrator.run(dot_source)

      # Run from a .dot file
      {:ok, result} = Arbor.Orchestrator.run_file("pipelines/my_pipeline.dot")

      # Compile for analysis (taint tracking, capability requirements)
      {:ok, compiled} = Arbor.Orchestrator.compile(dot_source)
      diagnostics = Arbor.Orchestrator.validate_typed(compiled)

  ## Architecture

      DOT source → Parser → Graph → IR.Compiler → Compiled Graph
                                                        ↓
                                               Engine.run (step loop)
                                                        ↓
                                               Handler dispatch per node

  The engine walks the graph node-by-node, dispatching each to its typed
  handler. Handlers receive node attributes and return results that flow
  to downstream nodes via edges. Edge conditions gate transitions.

  ## Key Subsystems

  - **UnifiedLLM** — Provider-agnostic LLM client (14 adapters, embeddings)
  - **Sessions** — Multi-turn stateful interactions (DOT-as-session-graph)
  - **Eval** — Pipeline and agent evaluation framework
  - **IR** — Typed intermediate representation for security analysis
  """

  alias Arbor.Orchestrator.Conformance
  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.IR
  alias Arbor.Orchestrator.Transforms.ModelStylesheet
  alias Arbor.Orchestrator.Transforms.VariableExpansion
  alias Arbor.Orchestrator.Validation.Diagnostic
  alias Arbor.Orchestrator.Validation.Validator

  @type run_result :: {:ok, Engine.run_result()} | {:error, term()}

  @doc "Parse a DOT source string into a Graph struct."
  @spec parse(String.t()) :: {:ok, Graph.t()} | {:error, term()}
  def parse(dot_source) when is_binary(dot_source), do: Parser.parse(dot_source)

  @doc "Run structural validation on a DOT source or Graph, returning diagnostics."
  @spec validate(String.t() | Graph.t(), keyword()) ::
          [Arbor.Orchestrator.Validation.Diagnostic.t()]
  def validate(source_or_graph, opts \\ []) do
    case ensure_graph(source_or_graph, opts) do
      {:ok, graph} ->
        Validator.validate(graph)

      {:error, reason} ->
        [
          Diagnostic.error(
            "parse_error",
            "Could not parse pipeline: #{inspect(reason)}"
          )
        ]
    end
  end

  @doc "Parse, compile, validate, and execute a DOT pipeline. Returns the engine result."
  @spec run(String.t() | Graph.t(), keyword()) :: run_result()
  def run(source_or_graph, opts \\ []) do
    with {:ok, graph} <- ensure_graph(source_or_graph, opts),
         :ok <- Validator.validate_or_error(graph) do
      Engine.run(graph, opts)
    end
  end

  @doc "Read a .dot file from disk and execute it as a pipeline."
  @spec run_file(String.t(), keyword()) :: run_result()
  def run_file(path, opts \\ []) do
    with {:ok, source} <- File.read(path) do
      run(source, opts)
    end
  end

  @doc """
  Compile a DOT source or Graph into an enriched Graph with typed IR fields.

  The compilation step resolves handler types, validates attribute schemas,
  computes capabilities, data classifications, and parses edge conditions —
  enabling security analysis (taint tracking, capability requirements, loop bounds).
  """
  @spec compile(String.t() | Graph.t(), keyword()) ::
          {:ok, Graph.t()} | {:error, term()}
  def compile(source_or_graph, opts \\ []) do
    with {:ok, graph} <- ensure_graph(source_or_graph, opts) do
      IR.Compiler.compile(graph)
    end
  end

  @doc """
  Run typed validation passes on a compiled Graph.

  Returns diagnostics from schema validation, capability analysis,
  taint reachability, loop detection, and resource bounds checking.
  These passes complement the structural validation from `validate/2`.
  """
  @spec validate_typed(String.t() | Graph.t(), keyword()) ::
          [Arbor.Orchestrator.Validation.Diagnostic.t()]
  def validate_typed(%Graph{compiled: true} = compiled, _opts) do
    IR.Validator.validate(compiled)
  end

  def validate_typed(source_or_graph, opts) do
    case compile(source_or_graph, opts) do
      {:ok, compiled} ->
        IR.Validator.validate(compiled)

      {:error, reason} ->
        [
          Diagnostic.error(
            "compile_error",
            "Could not compile to typed IR: #{inspect(reason)}"
          )
        ]
    end
  end

  @doc "Return the spec conformance matrix summary."
  @spec conformance_matrix() :: map()
  def conformance_matrix, do: Conformance.Matrix.summary()

  # Already compiled — just apply transforms
  defp ensure_graph(%Graph{compiled: true} = graph, opts), do: apply_transforms(graph, opts)

  # Uncompiled Graph struct — compile then apply transforms
  defp ensure_graph(%Graph{} = graph, opts) do
    with {:ok, compiled} <- IR.Compiler.compile(graph) do
      apply_transforms(compiled, opts)
    end
  end

  defp ensure_graph(source, opts) when is_binary(source) do
    if Keyword.get(opts, :cache, true) do
      ensure_graph_cached(source, opts)
    else
      with {:ok, graph} <- Parser.parse(source),
           {:ok, compiled} <- IR.Compiler.compile(graph) do
        apply_transforms(compiled, opts)
      end
    end
  end

  defp ensure_graph(_, _), do: {:error, :invalid_graph_input}

  defp ensure_graph_cached(source, opts) do
    alias Arbor.Orchestrator.DotCache

    cache_key = DotCache.cache_key(source)

    case DotCache.get(cache_key) do
      {:ok, graph} ->
        apply_transforms(graph, opts)

      miss_or_stale when miss_or_stale in [:miss, :stale] ->
        with {:ok, graph} <- Parser.parse(source),
             {:ok, compiled} <- IR.Compiler.compile(graph) do
          DotCache.put(cache_key, compiled)
          apply_transforms(compiled, opts)
        end
    end
  rescue
    # Cache unavailable (GenServer not started) — fall back to uncached
    ArgumentError ->
      with {:ok, graph} <- Parser.parse(source),
           {:ok, compiled} <- IR.Compiler.compile(graph) do
        apply_transforms(compiled, opts)
      end
  end

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
