defmodule Arbor.Orchestrator.Middleware.Chain do
  @moduledoc """
  Builds and executes middleware chains for pipeline nodes.

  The chain is built from three sources (in order):
    1. Engine config middleware (applies to all nodes)
    2. Graph-level middleware attribute
    3. Node-level middleware attribute

  Nodes can also skip specific middleware via skip_middleware attribute.
  """

  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Middleware.Token

  @registry %{
    "secret_scan" => Arbor.Orchestrator.Middleware.SecretScan
  }

  @doc "Registers a middleware module under the given name for runtime lookup."
  @spec register(String.t(), module()) :: :ok
  def register(name, module) do
    current = :persistent_term.get({__MODULE__, :registry}, @registry)
    :persistent_term.put({__MODULE__, :registry}, Map.put(current, name, module))
    :ok
  end

  @doc "Returns the current middleware name-to-module registry."
  @spec registry() :: map()
  def registry do
    :persistent_term.get({__MODULE__, :registry}, @registry)
  end

  @doc """
  Builds an ordered list of middleware modules for a given node.

  Combines engine config, graph-level, and node-level middleware,
  then removes any listed in the node's skip_middleware attribute.
  """
  @spec build(keyword(), Arbor.Orchestrator.Graph.t(), Arbor.Orchestrator.Graph.Node.t() | nil) ::
          [module()]
  def build(opts, graph, node) do
    engine_mw = Keyword.get(opts, :middleware, [])
    graph_mw = resolve_names(Map.get(graph.attrs, "middleware", ""))

    {node_mw, skip} =
      if node do
        {resolve_names(Map.get(node.attrs, "middleware", "")),
         resolve_names(Map.get(node.attrs, "skip_middleware", ""))}
      else
        {[], []}
      end

    (engine_mw ++ graph_mw ++ node_mw)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in skip))
  end

  @doc """
  Runs before_node/1 on each middleware in order.

  Stops early if any middleware halts the token. When halted without
  an outcome, a failure outcome is created from the halt reason.
  """
  @spec run_before([module()], Token.t()) :: Token.t()
  def run_before(chain, %Token{} = token) do
    token =
      Enum.reduce_while(chain, token, fn middleware, acc ->
        result = middleware.before_node(acc)

        if result.halted do
          {:halt, result}
        else
          {:cont, result}
        end
      end)

    if token.halted and is_nil(token.outcome) do
      %{token | outcome: %Outcome{status: :fail, failure_reason: token.halt_reason}}
    else
      token
    end
  end

  @doc """
  Runs after_node/1 on each middleware in reverse order.

  Stops early if any middleware halts the token. When halted, overrides
  the outcome with a failure unless the middleware already set a custom outcome.
  """
  @spec run_after([module()], Token.t()) :: Token.t()
  def run_after(chain, %Token{} = token) do
    reversed = Enum.reverse(chain)
    outcome_before = token.outcome

    token =
      Enum.reduce_while(reversed, token, fn middleware, acc ->
        result = middleware.after_node(acc)

        if result.halted do
          {:halt, result}
        else
          {:cont, result}
        end
      end)

    if token.halted and token.outcome == outcome_before do
      %{token | outcome: %Outcome{status: :fail, failure_reason: token.halt_reason}}
    else
      token
    end
  end

  defp resolve_names(nil), do: []
  defp resolve_names(""), do: []

  defp resolve_names(names_string) when is_binary(names_string) do
    reg = registry()

    names_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Map.get(reg, &1))
    |> Enum.reject(&is_nil/1)
  end
end
