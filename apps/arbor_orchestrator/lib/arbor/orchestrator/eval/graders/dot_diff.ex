defmodule Arbor.Orchestrator.Eval.Graders.DotDiff do
  @moduledoc """
  Grader that structurally compares two DOT pipeline files.
  Parses both actual and expected as DOT strings, then scores similarity
  across 4 dimensions: node count, edge count, handler type distribution,
  and prompt keyword coverage.
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @shape_to_handler %{
    "Mdiamond" => "start",
    "Msquare" => "exit",
    "box" => "codergen",
    "diamond" => "conditional",
    "hexagon" => "wait.human",
    "parallelogram" => "tool",
    "component" => "parallel",
    "tripleoctagon" => "parallel.fan_in",
    "house" => "stack.manager_loop"
  }

  @stopwords MapSet.new(~w(
    a an the and or but in on at to for of with is it as by
    be do if so no not are was has had will can may this that
    from each all any its you your use new file the
  ))

  @impl true
  def grade(actual, expected, opts \\ []) do
    actual_str = to_string(actual)
    expected_str = to_string(expected)

    # Parse expected (should always work — it's our ground truth)
    case Arbor.Orchestrator.parse(expected_str) do
      {:ok, expected_graph} ->
        # Try parsing actual output
        case Arbor.Orchestrator.parse(actual_str) do
          {:ok, actual_graph} ->
            score_graphs(actual_graph, expected_graph, opts)

          {:error, _parse_reason} ->
            # Try extracting DOT from markdown fences or thinking blocks
            case extract_dot(actual_str) do
              {:ok, extracted} ->
                case Arbor.Orchestrator.parse(extracted) do
                  {:ok, actual_graph} ->
                    result = score_graphs(actual_graph, expected_graph, opts)
                    %{result | detail: "[extracted from markdown] " <> result.detail}

                  {:error, _} ->
                    parse_failure_result(actual_str)
                end

              :none ->
                parse_failure_result(actual_str)
            end
        end

      {:error, reason} ->
        %{
          score: 0.0,
          passed: false,
          parseable: false,
          detail: "Expected DOT parse error (bug in dataset): #{inspect(reason)}"
        }
    end
  end

  defp score_graphs(actual_graph, expected_graph, opts) do
    actual_nodes = Map.values(actual_graph.nodes)
    expected_nodes = Map.values(expected_graph.nodes)

    node_sim = count_similarity(length(actual_nodes), length(expected_nodes))
    edge_sim = count_similarity(length(actual_graph.edges), length(expected_graph.edges))
    handler_sim = handler_distribution_similarity(actual_graph, expected_graph)
    keyword_sim = keyword_coverage(actual_graph, expected_graph)

    w = Map.merge(default_weights(), Keyword.get(opts, :weights, %{}))

    score =
      w.node_count * node_sim +
        w.edge_count * edge_sim +
        w.handler_dist * handler_sim +
        w.keyword_coverage * keyword_sim

    threshold = Keyword.get(opts, :pass_threshold, 0.5)

    %{
      score: score,
      passed: score >= threshold,
      parseable: true,
      detail:
        build_detail(
          node_sim,
          edge_sim,
          handler_sim,
          keyword_sim,
          actual_graph,
          expected_graph
        )
    }
  end

  defp parse_failure_result(actual_str) do
    trimmed = String.trim(actual_str)
    preview = trimmed |> String.split("\n") |> List.first("") |> String.slice(0, 100)
    contains_digraph = String.contains?(trimmed, "digraph")

    %{
      score: 0.0,
      passed: false,
      parseable: false,
      detail:
        "Not valid DOT (#{String.length(trimmed)} chars, " <>
          "contains_digraph=#{contains_digraph}). " <>
          "First line: #{preview}"
    }
  end

  # Try to extract DOT content from markdown fences or after thinking blocks
  defp extract_dot(text) do
    # Strip <think>...</think> blocks (common with thinking models)
    stripped = Regex.replace(~r/<think>[\s\S]*?<\/think>/m, text, "")

    # Try markdown code fence extraction
    case Regex.run(~r/```(?:dot|graphviz)?\s*\n([\s\S]*?)```/m, stripped) do
      [_, dot_content] ->
        dot = String.trim(dot_content)
        if String.contains?(dot, "digraph"), do: {:ok, dot}, else: :none

      nil ->
        # Try bare digraph extraction
        case Regex.run(~r/(digraph\s+\w+\s*\{[\s\S]*\})/m, stripped) do
          [_, dot_content] -> {:ok, String.trim(dot_content)}
          nil -> :none
        end
    end
  end

  defp count_similarity(a, b) when a == 0 and b == 0, do: 1.0

  defp count_similarity(a, b) do
    1.0 - abs(a - b) / max(a, b, 1)
  end

  defp max(a, b, minimum) do
    Enum.max([a, b, minimum])
  end

  defp handler_distribution_similarity(graph_a, graph_b) do
    nodes_a = Map.values(graph_a.nodes)
    nodes_b = Map.values(graph_b.nodes)

    if nodes_a == [] and nodes_b == [] do
      1.0
    else
      freq_a = build_handler_freq(nodes_a)
      freq_b = build_handler_freq(nodes_b)
      cosine_similarity(freq_a, freq_b)
    end
  end

  defp build_handler_freq(nodes) do
    Enum.reduce(nodes, %{}, fn node, acc ->
      handler = resolve_handler_type(node)
      Map.update(acc, handler, 1, &(&1 + 1))
    end)
  end

  defp cosine_similarity(freq_a, freq_b) do
    all_keys = MapSet.union(MapSet.new(Map.keys(freq_a)), MapSet.new(Map.keys(freq_b)))

    {dot, mag_a, mag_b} =
      Enum.reduce(all_keys, {0.0, 0.0, 0.0}, fn key, {dot_acc, ma, mb} ->
        va = Map.get(freq_a, key, 0)
        vb = Map.get(freq_b, key, 0)
        {dot_acc + va * vb, ma + va * va, mb + vb * vb}
      end)

    mag_a = :math.sqrt(mag_a)
    mag_b = :math.sqrt(mag_b)

    if mag_a == 0.0 or mag_b == 0.0 do
      0.0
    else
      dot / (mag_a * mag_b)
    end
  end

  defp keyword_coverage(actual_graph, expected_graph) do
    actual_kw = extract_keywords(actual_graph)
    expected_kw = extract_keywords(expected_graph)

    intersection = MapSet.intersection(actual_kw, expected_kw)
    union = MapSet.union(actual_kw, expected_kw)

    if MapSet.size(union) == 0 do
      1.0
    else
      MapSet.size(intersection) / MapSet.size(union)
    end
  end

  defp extract_keywords(graph) do
    graph.nodes
    |> Map.values()
    |> Enum.reduce(MapSet.new(), fn node, acc ->
      prompt = Map.get(node.attrs, "prompt", "")
      label = Map.get(node.attrs, "label", "")
      text = "#{prompt} #{label}"

      tokens =
        text
        |> String.split(~r/[\s\p{P}]+/u)
        |> Enum.map(&String.downcase/1)
        |> Enum.reject(&(String.length(&1) < 3 or stopword?(&1)))

      Enum.reduce(tokens, acc, &MapSet.put(&2, &1))
    end)
  end

  defp stopword?(word), do: MapSet.member?(@stopwords, word)

  defp resolve_handler_type(node) do
    type = Map.get(node.attrs, "type", "")
    shape = Map.get(node.attrs, "shape", "")

    if type != "" and type != nil do
      type
    else
      Map.get(@shape_to_handler, shape, "codergen")
    end
  end

  defp build_detail(node_sim, edge_sim, handler_sim, keyword_sim, actual_graph, expected_graph) do
    actual_nodes = Map.values(actual_graph.nodes)
    expected_nodes = Map.values(expected_graph.nodes)

    "nodes: #{length(actual_nodes)} vs #{length(expected_nodes)} (sim: #{Float.round(node_sim, 3)}), " <>
      "edges: #{length(actual_graph.edges)} vs #{length(expected_graph.edges)} (sim: #{Float.round(edge_sim, 3)}), " <>
      "handlers: cosine=#{Float.round(handler_sim, 3)}, " <>
      "keywords: jaccard=#{Float.round(keyword_sim, 3)}"
  end

  defp default_weights do
    %{node_count: 0.20, edge_count: 0.20, handler_dist: 0.30, keyword_coverage: 0.30}
  end
end
