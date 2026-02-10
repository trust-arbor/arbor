defmodule Arbor.Orchestrator.Dot.Parser do
  @moduledoc """
  Parser for a strict subset of Graphviz DOT used by Attractor.

  Supported in this first conformance milestone:
  - `digraph Name { ... }`
  - graph attrs (`key=value` and `graph [k=v,...]`)
  - node/edge defaults (`node [k=v,...]`, `edge [k=v,...]`)
  - node statements (`node_id [k=v,...]`)
  - edge statements (`a -> b`, `a -> b -> c`, optional attrs)
  - subgraph flattening (`subgraph x { ... }`)
  - `//` and `/* */` comments
  """

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}

  @spec parse(String.t()) :: {:ok, Graph.t()} | {:error, term()}
  def parse(source) when is_binary(source) do
    cleaned = source |> strip_comments() |> String.trim()

    with {:ok, graph_id, body} <- split_graph(cleaned) do
      initial = %{graph: %Graph{id: graph_id}, node_defaults: %{}, edge_defaults: %{}}

      body
      |> statements()
      |> Enum.reduce_while({:ok, initial}, fn statement, {:ok, state} ->
        case parse_statement(statement, state) do
          {:ok, next_state} -> {:cont, {:ok, next_state}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, %{graph: graph}} -> {:ok, graph}
        {:error, _} = error -> error
      end
    end
  end

  defp split_graph(source) do
    regex = ~r/^digraph\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{([\s\S]*)\}$/

    case Regex.run(regex, source) do
      [_, graph_id, body] -> {:ok, graph_id, body}
      _ -> {:error, :invalid_graph_header}
    end
  end

  defp strip_comments(source) do
    source
    |> String.replace(~r/\/\*[\s\S]*?\*\//, "")
    |> String.replace(~r/\/\/.*$/m, "")
  end

  defp statements(body) do
    {parts, current, _depth, _in_quote, _escaped} =
      body
      |> String.graphemes()
      |> Enum.reduce({[], "", 0, false, false}, fn ch,
                                                   {parts, current, depth, in_quote, escaped} ->
        cond do
          escaped ->
            {parts, current <> ch, depth, in_quote, false}

          ch == "\\" and in_quote ->
            {parts, current <> ch, depth, in_quote, true}

          ch == "\"" ->
            {parts, current <> ch, depth, not in_quote, false}

          ch == "[" and not in_quote ->
            {parts, current <> ch, depth + 1, in_quote, false}

          ch == "]" and not in_quote and depth > 0 ->
            {parts, current <> ch, depth - 1, in_quote, false}

          (ch == ";" or ch == "\n") and not in_quote and depth == 0 ->
            next_parts = if String.trim(current) == "", do: parts, else: parts ++ [current]
            {next_parts, "", depth, in_quote, false}

          true ->
            {parts, current <> ch, depth, in_quote, false}
        end
      end)

    final_parts =
      if String.trim(current) == "", do: parts, else: parts ++ [current]

    final_parts
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 in ["", "{", "}"]))
  end

  defp parse_statement("subgraph " <> _rest, state), do: {:ok, state}

  defp parse_statement("node " <> attrs_part, %{node_defaults: current} = state) do
    with {:ok, attrs} <- parse_attrs_block(attrs_part) do
      {:ok, %{state | node_defaults: Map.merge(current, attrs)}}
    end
  end

  defp parse_statement("edge " <> attrs_part, %{edge_defaults: current} = state) do
    with {:ok, attrs} <- parse_attrs_block(attrs_part) do
      {:ok, %{state | edge_defaults: Map.merge(current, attrs)}}
    end
  end

  defp parse_statement("graph " <> attrs_part, %{graph: graph} = state) do
    with {:ok, attrs} <- parse_attrs_block(attrs_part) do
      {:ok, %{state | graph: %{graph | attrs: Map.merge(graph.attrs, attrs)}}}
    end
  end

  defp parse_statement(statement, state) do
    cond do
      String.contains?(statement, "->") ->
        parse_edge_statement(statement, state)

      String.contains?(statement, "=") and not String.contains?(statement, "[") ->
        parse_graph_attr_decl(statement, state)

      true ->
        parse_node_statement(statement, state)
    end
  end

  defp parse_graph_attr_decl(statement, %{graph: graph} = state) do
    case String.split(statement, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)
        value = parse_value(String.trim(value))
        {:ok, %{state | graph: %{graph | attrs: Map.put(graph.attrs, key, value)}}}

      _ ->
        {:error, {:invalid_graph_attr, statement}}
    end
  end

  defp parse_node_statement(statement, %{graph: graph, node_defaults: defaults} = state) do
    {node_id, attrs_part} = split_identifier_and_attrs(statement)

    if valid_identifier?(node_id) do
      with {:ok, attrs} <- parse_attrs_block(attrs_part) do
        merged_attrs = Map.merge(defaults, attrs)
        node = %Node{id: node_id, attrs: merged_attrs}
        {:ok, %{state | graph: Graph.add_node(graph, node)}}
      end
    else
      {:error, {:invalid_node_id, node_id}}
    end
  end

  defp parse_edge_statement(statement, %{edge_defaults: edge_defaults} = state) do
    {chain_part, attrs_part} = split_edge_chain_and_attrs(statement)

    with {:ok, attrs} <- parse_attrs_block(attrs_part) do
      ids =
        chain_part
        |> String.split("->")
        |> Enum.map(&String.trim/1)

      if Enum.all?(ids, &valid_identifier?/1) and length(ids) >= 2 do
        graph = ensure_nodes_exist(state, ids)
        edge_attrs = Map.merge(edge_defaults, attrs)

        graph =
          ids
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.reduce(graph, fn [from, to], acc ->
            Graph.add_edge(acc, %Edge{from: from, to: to, attrs: edge_attrs})
          end)

        {:ok, %{state | graph: graph}}
      else
        {:error, {:invalid_edge_chain, statement}}
      end
    end
  end

  defp ensure_nodes_exist(%{graph: graph, node_defaults: defaults}, ids) do
    Enum.reduce(ids, graph, fn id, acc ->
      if Map.has_key?(acc.nodes, id) do
        acc
      else
        Graph.add_node(acc, %Node{id: id, attrs: defaults})
      end
    end)
  end

  defp split_identifier_and_attrs(statement) do
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)(\s*\[[\s\S]*\])?$/, statement) do
      [_, node_id, attrs] -> {node_id, attrs || ""}
      [_, node_id] -> {node_id, ""}
      _ -> {statement, ""}
    end
  end

  defp split_edge_chain_and_attrs(statement) do
    case Regex.run(~r/^(.*?)(\s*\[[\s\S]*\])?$/, statement) do
      [_, chain, attrs] -> {String.trim(chain), attrs || ""}
      [_, chain] -> {String.trim(chain), ""}
      _ -> {statement, ""}
    end
  end

  defp parse_attrs_block(attrs_part) do
    trimmed = String.trim(attrs_part || "")

    cond do
      trimmed == "" ->
        {:ok, %{}}

      String.starts_with?(trimmed, "[") and String.ends_with?(trimmed, "]") ->
        inner = trimmed |> String.trim_leading("[") |> String.trim_trailing("]")

        attrs =
          inner
          |> split_attr_pairs()
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.reduce_while(%{}, fn pair, acc ->
            case String.split(pair, "=", parts: 2) do
              [k, v] -> {:cont, Map.put(acc, String.trim(k), parse_value(String.trim(v)))}
              _ -> {:halt, :error}
            end
          end)

        if attrs == :error, do: {:error, {:invalid_attrs, attrs_part}}, else: {:ok, attrs}

      true ->
        {:error, {:invalid_attrs_block, attrs_part}}
    end
  end

  defp split_attr_pairs(inner) do
    {parts, current, _in_quote, _escaped} =
      inner
      |> String.graphemes()
      |> Enum.reduce({[], "", false, false}, fn ch, {parts, current, in_quote, escaped} ->
        cond do
          escaped ->
            {parts, current <> ch, in_quote, false}

          ch == "\\" and in_quote ->
            {parts, current <> ch, in_quote, true}

          ch == "\"" ->
            {parts, current <> ch, not in_quote, false}

          ch == "," and not in_quote ->
            {parts ++ [current], "", in_quote, false}

          true ->
            {parts, current <> ch, in_quote, false}
        end
      end)

    parts ++ [current]
  end

  defp parse_value(value) do
    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value |> String.slice(1, String.length(value) - 2) |> String.replace("\\\"", "\"")

      value in ["true", "false"] ->
        value == "true"

      Regex.match?(~r/^-?\d+$/, value) ->
        String.to_integer(value)

      Regex.match?(~r/^-?\d+\.\d+$/, value) ->
        String.to_float(value)

      true ->
        value
    end
  end

  defp valid_identifier?(id), do: Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, id)
end
