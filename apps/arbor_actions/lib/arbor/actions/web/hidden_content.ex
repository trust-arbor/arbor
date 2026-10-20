defmodule Arbor.Actions.Web.HiddenContent do
  @moduledoc false

  # Strip CSS/ARIA-hidden prompt-injection payloads from fetched HTML.
  # Fetched pages can hide instructions from humans while still shipping them
  # to LLM extractors (`display:none`, `visibility:hidden`, `aria-hidden`,
  # the `hidden` attribute, and off-screen positioning). See
  # https://redact.dev/blog/whatsapp-help-pages-hidden-ai-instructions

  @empty_meta %{hidden_text_stripped: 0, hidden_text_present: false}

  @spec meta(non_neg_integer()) :: map()
  def meta(count) when is_integer(count) and count >= 0 do
    %{hidden_text_stripped: count, hidden_text_present: count > 0}
  end

  @spec strip(term()) :: {term(), map()}
  def strip(html) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        {cleaned, count} = prune_nodes(document, 0)

        if count == 0 do
          {html, @empty_meta}
        else
          {Floki.raw_html(cleaned), meta(count)}
        end

      {:error, _} ->
        {html, @empty_meta}
    end
  end

  def strip(other), do: {other, @empty_meta}

  @spec sanitize_result(term()) :: term()
  def sanitize_result(result) when is_map(result) do
    {updated, count} =
      {result, 0}
      |> maybe_strip_key(:content)
      |> maybe_strip_key("content")
      |> maybe_strip_key(:text)
      |> maybe_strip_key("text")
      |> maybe_strip_list_key(:texts)
      |> maybe_strip_list_key("texts")
      |> maybe_strip_elements()

    Map.merge(updated, meta(count))
  end

  def sanitize_result(other), do: other

  defp maybe_strip_key({result, count}, key) do
    case result do
      %{^key => value} when is_binary(value) ->
        {stripped, meta} = strip(value)
        {Map.put(result, key, stripped), count + meta.hidden_text_stripped}

      _other ->
        {result, count}
    end
  end

  defp maybe_strip_list_key({result, count}, key) do
    case result do
      %{^key => values} when is_list(values) ->
        {stripped, added} =
          Enum.map_reduce(values, 0, fn
            value, acc when is_binary(value) ->
              {text, meta} = strip(value)
              {text, acc + meta.hidden_text_stripped}

            value, acc ->
              {value, acc}
          end)

        {Map.put(result, key, stripped), count + added}

      _other ->
        {result, count}
    end
  end

  defp maybe_strip_elements({result, count}) do
    case result do
      %{elements: elements} when is_list(elements) ->
        {stripped, added} = strip_element_list(elements)
        {Map.put(result, :elements, stripped), count + added}

      %{"elements" => elements} when is_list(elements) ->
        {stripped, added} = strip_element_list(elements)
        {Map.put(result, "elements", stripped), count + added}

      _other ->
        {result, count}
    end
  end

  defp strip_element_list(elements) do
    Enum.map_reduce(elements, 0, fn
      element, acc when is_map(element) ->
        {updated, added} =
          {element, 0}
          |> maybe_strip_key(:text)
          |> maybe_strip_key("text")

        {updated, acc + added}

      element, acc ->
        {element, acc}
    end)
  end

  defp prune_nodes(nodes, count) when is_list(nodes) do
    Enum.reduce(nodes, {[], count}, fn node, {kept, acc} ->
      case prune_node(node, acc) do
        {:drop, acc} -> {kept, acc}
        {:keep, node, acc} -> {[node | kept], acc}
      end
    end)
    |> then(fn {kept, acc} -> {Enum.reverse(kept), acc} end)
  end

  defp prune_node({tag, attrs, children}, count) when is_list(attrs) and is_list(children) do
    if hidden_element?(attrs) do
      {:drop, count + 1}
    else
      {pruned_children, count} = prune_nodes(children, count)
      {:keep, {tag, attrs, pruned_children}, count}
    end
  end

  defp prune_node(node, count), do: {:keep, node, count}

  defp hidden_element?(attrs) do
    downcased =
      Map.new(attrs, fn {key, value} ->
        {String.downcase(to_string(key)), to_string(value)}
      end)

    Map.has_key?(downcased, "hidden") or
      String.downcase(Map.get(downcased, "aria-hidden", "false")) == "true" or
      hidden_style?(Map.get(downcased, "style", ""))
  end

  defp hidden_style?(style) do
    compact = style |> String.downcase() |> String.replace(~r/\s+/, "")

    String.contains?(compact, "display:none") or
      String.contains?(compact, "visibility:hidden") or
      offscreen?(compact)
  end

  defp offscreen?(style) do
    positioned? =
      String.contains?(style, "position:absolute") or String.contains?(style, "position:fixed")

    offset? = Regex.match?(~r/(?:left|right|top|bottom):-?\d{3,}px/, style)
    positioned? and offset?
  end
end
