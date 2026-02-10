defmodule Arbor.Orchestrator.Transforms.ModelStylesheet do
  @moduledoc """
  Applies CSS-like model stylesheet rules to graph nodes.

  Supported selectors:
  - `*`
  - `shape_name` (e.g. `box`, `diamond`)
  - `#node_id`
  - `.class_name` (matches node class list in `class="a,b"`)

  Supported properties:
  - `llm_model`
  - `llm_provider`
  - `reasoning_effort`
  """

  alias Arbor.Orchestrator.Graph

  @allowed_props ~w(llm_model llm_provider reasoning_effort)

  @spec apply(Graph.t()) :: Graph.t()
  def apply(%Graph{} = graph) do
    stylesheet = Map.get(graph.attrs, "model_stylesheet", "")

    if stylesheet in [nil, ""] do
      graph
    else
      rules = parse_rules(stylesheet)

      nodes =
        graph.nodes
        |> Enum.map(fn {id, node} -> {id, apply_rules_to_node(node, rules)} end)
        |> Map.new()

      %{graph | nodes: nodes}
    end
  end

  @spec parse_rules(String.t()) :: [map()]
  def parse_rules(stylesheet) when is_binary(stylesheet) do
    stylesheet
    |> scan_rules()
    |> Enum.with_index()
    |> Enum.map(fn {{selector, body}, index} ->
      %{
        selector: selector,
        declarations: parse_declarations(body),
        specificity: specificity(selector),
        order: index
      }
    end)
  end

  defp parse_declarations(body) do
    Regex.scan(~r/([a-z_][a-z0-9_]*)\s*:\s*("[^"]*"|[^;]+)\s*;?/i, body)
    |> Enum.reduce(%{}, fn [_, raw_key, raw_value], acc ->
      key = String.trim(raw_key)
      value = String.trim(raw_value)

      if key in @allowed_props do
        Map.put(acc, key, trim_quotes(value))
      else
        acc
      end
    end)
  end

  defp apply_rules_to_node(node, rules) do
    applicable =
      rules
      |> Enum.filter(&selector_match?(&1.selector, node))
      |> Enum.sort_by(fn rule -> {rule.specificity, rule.order} end)

    merged_from_rules =
      Enum.reduce(applicable, %{}, fn rule, acc ->
        Map.merge(acc, rule.declarations)
      end)

    attrs =
      merged_from_rules
      |> Enum.reduce(node.attrs, fn {key, value}, acc ->
        if Map.has_key?(acc, key) do
          acc
        else
          Map.put(acc, key, value)
        end
      end)

    %{node | attrs: attrs}
  end

  defp selector_match?("*", _node), do: true

  defp selector_match?("#" <> node_id, node) do
    node.id == node_id
  end

  defp selector_match?("." <> class_name, node) do
    classes =
      node.attrs
      |> Map.get("class", "")
      |> to_string()
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    class_name in classes
  end

  defp selector_match?(shape_name, node) when is_binary(shape_name) do
    Map.get(node.attrs, "shape", "box") == shape_name
  end

  defp specificity("*"), do: 0
  defp specificity("." <> _), do: 2
  defp specificity("#" <> _), do: 3

  defp specificity(shape_name) when is_binary(shape_name),
    do:
      if(String.starts_with?(shape_name, ".") or String.starts_with?(shape_name, "#"),
        do: 0,
        else: 1
      )

  defp specificity(_), do: 0

  defp trim_quotes(value) do
    value
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
  end

  defp scan_rules(stylesheet) do
    chars = String.to_charlist(stylesheet)
    do_scan_rules(chars, [], [])
  end

  defp do_scan_rules([], current, acc) do
    acc =
      case parse_rule_fragment(current) do
        nil -> acc
        pair -> acc ++ [pair]
      end

    acc
  end

  defp do_scan_rules([char | rest], current, acc) do
    cond do
      char == ?} ->
        fragment = current ++ [char]

        acc =
          case parse_rule_fragment(fragment) do
            nil -> acc
            pair -> acc ++ [pair]
          end

        do_scan_rules(rest, [], acc)

      true ->
        do_scan_rules(rest, current ++ [char], acc)
    end
  end

  defp parse_rule_fragment(chars) do
    fragment = chars |> to_string() |> String.trim()

    case Regex.run(
           ~r/^([*]|[A-Za-z_][A-Za-z0-9_]*|#[A-Za-z_][A-Za-z0-9_]*|\.[a-z0-9-]+)\s*\{([\s\S]*)\}$/,
           fragment
         ) do
      [_, selector, body] -> {selector, body}
      _ -> nil
    end
  end
end
