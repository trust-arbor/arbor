defmodule Arbor.Orchestrator.Viz.DotSerializer do
  @moduledoc """
  Serializes a Graph struct back to canonical DOT format.

  Produces clean, human-readable DOT output suitable for round-trip
  parsing and debugging. Strips execution-only attributes (content_hash,
  internal state) by default.

  ## Usage

      dot_string = DotSerializer.serialize(graph)
      dot_string = DotSerializer.serialize(graph, strip_internal: false)
  """

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}

  # Attributes that are internal to the engine and should be stripped
  @internal_attrs ~w(content_hash auto_status)

  # Attributes that are derived from the attrs map (typed struct fields)
  # and don't need to be serialized separately
  @derived_attrs ~w(from to id)

  @doc """
  Serialize a Graph struct to a DOT-format string.

  ## Options
  - `:strip_internal` — remove engine-internal attributes (default: true)
  - `:indent` — indentation string (default: "  ")
  """
  @spec serialize(Graph.t(), keyword()) :: String.t()
  def serialize(%Graph{} = graph, opts \\ []) do
    strip = Keyword.get(opts, :strip_internal, true)
    indent = Keyword.get(opts, :indent, "  ")

    lines = []

    # Graph header
    graph_id = escape_id(graph.id || "Pipeline")
    lines = lines ++ ["digraph #{graph_id} {"]

    # Graph attributes
    graph_attrs = serialize_graph_attrs(graph.attrs, strip)

    lines =
      if graph_attrs != "" do
        lines ++ ["#{indent}graph [#{graph_attrs}];", ""]
      else
        lines
      end

    # Node defaults
    lines =
      if graph.node_defaults != %{} do
        lines ++ ["#{indent}node [#{serialize_attrs(graph.node_defaults, strip)}];"]
      else
        lines
      end

    # Edge defaults
    lines =
      if graph.edge_defaults != %{} do
        lines ++ ["#{indent}edge [#{serialize_attrs(graph.edge_defaults, strip)}];"]
      else
        lines
      end

    # Add blank line after defaults if any were emitted
    lines =
      if graph.node_defaults != %{} or graph.edge_defaults != %{} do
        lines ++ [""]
      else
        lines
      end

    # Subgraphs
    lines =
      Enum.reduce(graph.subgraphs, lines, fn subgraph, acc ->
        acc ++ serialize_subgraph(subgraph, indent, strip)
      end)

    # Nodes (sorted by ID for deterministic output)
    nodes =
      graph.nodes
      |> Map.values()
      |> Enum.sort_by(& &1.id)

    lines =
      Enum.reduce(nodes, lines, fn node, acc ->
        acc ++ [serialize_node(node, indent, strip)]
      end)

    # Blank line between nodes and edges
    lines = if graph.edges != [], do: lines ++ [""], else: lines

    # Edges (in original order, reversed since they're prepended)
    edges = Enum.reverse(graph.edges)

    lines =
      Enum.reduce(edges, lines, fn edge, acc ->
        acc ++ [serialize_edge(edge, indent, strip)]
      end)

    # Close graph
    lines = lines ++ ["}"]

    Enum.join(lines, "\n") <> "\n"
  end

  defp serialize_node(%Node{} = node, indent, strip) do
    attrs = serialize_attrs(node.attrs, strip)

    if attrs == "" do
      "#{indent}#{escape_id(node.id)};"
    else
      "#{indent}#{escape_id(node.id)} [#{attrs}];"
    end
  end

  defp serialize_edge(%Edge{} = edge, indent, strip) do
    attrs = serialize_attrs(edge.attrs, strip)

    base = "#{indent}#{escape_id(edge.from)} -> #{escape_id(edge.to)}"

    if attrs == "" do
      "#{base};"
    else
      "#{base} [#{attrs}];"
    end
  end

  defp serialize_subgraph(subgraph, indent, strip) when is_map(subgraph) do
    name = Map.get(subgraph, :id) || Map.get(subgraph, "id", "cluster_0")
    attrs = Map.get(subgraph, :attrs) || Map.get(subgraph, "attrs", %{})
    node_ids = Map.get(subgraph, :nodes) || Map.get(subgraph, "nodes", [])

    lines = ["#{indent}subgraph #{escape_id(name)} {"]

    sub_attrs = serialize_attrs(attrs, strip)

    lines =
      if sub_attrs != "" do
        lines ++ ["#{indent}#{indent}graph [#{sub_attrs}];"]
      else
        lines
      end

    lines =
      Enum.reduce(node_ids, lines, fn node_id, acc ->
        acc ++ ["#{indent}#{indent}#{escape_id(node_id)};"]
      end)

    lines ++ ["#{indent}}", ""]
  end

  defp serialize_graph_attrs(attrs, strip) do
    attrs
    |> maybe_strip(strip)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{quote_value(v)}" end)
  end

  defp serialize_attrs(attrs, strip) do
    attrs
    |> maybe_strip(strip)
    |> Map.drop(@derived_attrs)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{quote_value(v)}" end)
  end

  defp maybe_strip(attrs, true) do
    Map.drop(attrs, @internal_attrs)
  end

  defp maybe_strip(attrs, false), do: attrs

  defp quote_value(value) when is_binary(value) do
    if simple_id?(value) do
      value
    else
      "\"#{escape_dot_string(value)}\""
    end
  end

  defp quote_value(value) when is_integer(value), do: Integer.to_string(value)
  defp quote_value(value) when is_float(value), do: Float.to_string(value)
  defp quote_value(true), do: "true"
  defp quote_value(false), do: "false"
  defp quote_value(value), do: "\"#{escape_dot_string(to_string(value))}\""

  defp escape_id(id) when is_binary(id) do
    if simple_id?(id) do
      id
    else
      "\"#{escape_dot_string(id)}\""
    end
  end

  # A simple ID is alphanumeric + underscores, starting with a letter or underscore
  defp simple_id?(str) when is_binary(str) do
    Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, str)
  end

  defp escape_dot_string(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end
end
