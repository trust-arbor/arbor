defmodule Arbor.Orchestrator.Dot.Parser do
  @moduledoc """
  Recursive-descent parser for a strict subset of Graphviz DOT used by Attractor.

  Supported features:
  - `digraph Name { ... }`
  - graph attrs (`key=value` and `graph [k=v,...]`)
  - node/edge defaults (`node [k=v,...]`, `edge [k=v,...]`)
  - node statements (`node_id [k=v,...]`)
  - edge chains (`a -> b -> c [attrs]`)
  - subgraph flattening (`subgraph x { ... }`) with CSS class derivation
  - bare attributes (`[nullable]` → `%{"nullable" => "true"}`)
  - qualified/dotted keys (`manager.actions="observe"`)
  - full string escapes (`\\n`, `\\t`, `\\\\`, `\\"`)
  - `//` and `/* */` comments
  - duration parsing utility
  - line-number tracking in error messages
  - error accumulation mode (`accumulate_errors: true`)
  """

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}

  # ── ParseState ────────────────────────────────────────────────────

  defmodule ParseState do
    @moduledoc false
    defstruct rest: "",
              source: "",
              graph_id: "",
              graph_attrs: %{},
              node_defaults: %{},
              edge_defaults: %{},
              nodes: %{},
              edges: [],
              subgraphs: [],
              errors: [],
              accumulate_errors: false
  end

  # ── Public API ────────────────────────────────────────────────────

  @doc "Parse a DOT source file from disk."
  @spec parse_file(Path.t(), keyword()) ::
          {:ok, Graph.t()} | {:ok, Graph.t(), [String.t()]} | {:error, String.t() | [String.t()]}
  def parse_file(path, opts \\ []) when is_binary(path) do
    case File.read(path) do
      {:ok, source} -> parse(source, opts)
      {:error, reason} -> {:error, "Could not read #{path}: #{reason}"}
    end
  end

  @doc """
  Parse a DOT source string.

  Options:
  - `:accumulate_errors` — when `true`, collect parse errors and attempt to
    continue via skip-to-next-statement recovery. Returns `{:ok, graph, errors}`
    when recoverable errors were found. Default: `false`.
  """
  @spec parse(String.t(), keyword()) ::
          {:ok, Graph.t()} | {:ok, Graph.t(), [String.t()]} | {:error, String.t() | [String.t()]}
  def parse(source, opts \\ []) when is_binary(source) do
    accumulate = Keyword.get(opts, :accumulate_errors, false)

    processed =
      source
      |> strip_comments()
      |> String.trim_trailing()

    case parse_digraph(processed, accumulate) do
      {:ok, state} ->
        if accumulate and state.errors != [] do
          {:ok, build_graph(state), Enum.reverse(state.errors)}
        else
          {:ok, build_graph(state)}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc "Parse a duration string like \"900s\", \"5m\", \"2h\" into seconds."
  @spec parse_duration(String.t()) :: {:ok, number()} | :error
  def parse_duration(str) when is_binary(str) do
    case Regex.run(~r/^(\d+(?:\.\d+)?)\s*(ms|s|m|h)$/, str) do
      [_, num, "ms"] -> {:ok, parse_number(num) / 1000}
      [_, num, "s"] -> {:ok, parse_number(num)}
      [_, num, "m"] -> {:ok, parse_number(num) * 60}
      [_, num, "h"] -> {:ok, parse_number(num) * 3600}
      _ -> :error
    end
  end

  @doc "Unescape a DOT string: \\\" → \", \\n → newline, \\t → tab, \\\\\\\\ → backslash."
  @spec unescape_string(String.t()) :: String.t()
  def unescape_string(str), do: do_unescape(str, [])

  @doc false
  def derive_class(label) do
    label
    |> String.downcase()
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/[^a-z0-9\-]/, "")
  end

  # ── Comment Stripping ────────────────────────────────────────────

  defp strip_comments(source) do
    source
    |> replace_block_comments()
    |> String.replace(~r/\/\/.*$/m, "")
  end

  # Replace block comments with equivalent newlines to preserve line numbers
  defp replace_block_comments(source) do
    Regex.replace(~r/\/\*[\s\S]*?\*\//, source, fn match ->
      String.duplicate("\n", count_newlines(match))
    end)
  end

  # ── Top-Level: digraph ───────────────────────────────────────────

  defp parse_digraph(source, accumulate) do
    with {:ok, rest} <- consume_keyword(source, "digraph"),
         {id, rest} when id != "" <- read_identifier(skip_ws(rest)),
         {:ok, rest} <- consume_char(skip_ws(rest), ?{, "Expected '{' after digraph identifier") do
      state = %ParseState{
        rest: rest,
        source: source,
        graph_id: id,
        accumulate_errors: accumulate
      }

      finish_digraph(parse_statements(state))
    else
      {"", _rest} -> {:error, "Expected digraph identifier"}
      {:error, _} = err -> err
    end
  end

  defp finish_digraph({:ok, %ParseState{rest: rest} = state}) do
    case consume_char(skip_ws(rest), ?}, with_line(state, "Expected closing '}' for digraph")) do
      {:ok, rest} -> {:ok, %{state | rest: rest}}
      {:error, _} = err -> err
    end
  end

  defp finish_digraph({:error, _} = err), do: err

  # ── Statement Loop ───────────────────────────────────────────────

  defp parse_statements(%ParseState{} = state) do
    rest = skip_ws(state.rest)

    cond do
      rest == "" ->
        # Reached EOF — let the caller check for closing brace
        {:ok, %{state | rest: rest}}

      String.starts_with?(rest, "}") ->
        # End of block — leave the '}' for the caller to consume
        {:ok, %{state | rest: rest}}

      true ->
        case parse_statement(%{state | rest: rest}) do
          {:ok, next_state} ->
            next_state = %{next_state | rest: skip_separator(next_state.rest)}
            parse_statements(next_state)

          {:error, msg} ->
            if state.accumulate_errors do
              skipped_rest = skip_to_next_statement(rest)
              next_state = %{state | rest: skipped_rest, errors: [msg | state.errors]}
              parse_statements(next_state)
            else
              {:error, msg}
            end
        end
    end
  end

  # ── Statement Dispatch ───────────────────────────────────────────

  defp parse_statement(%ParseState{rest: rest} = state) do
    trimmed = skip_ws(rest)

    cond do
      keyword_match?(trimmed, "graph") -> parse_graph_defaults(%{state | rest: trimmed})
      keyword_match?(trimmed, "node") -> parse_node_defaults(%{state | rest: trimmed})
      keyword_match?(trimmed, "edge") -> parse_edge_defaults(%{state | rest: trimmed})
      keyword_match?(trimmed, "subgraph") -> parse_subgraph(%{state | rest: trimmed})
      true -> parse_node_or_edge_or_attr(%{state | rest: trimmed})
    end
  end

  # ── graph [attrs] ────────────────────────────────────────────────

  defp parse_graph_defaults(%ParseState{rest: rest} = state) do
    {_, rest} = consume_word(rest, "graph")

    case parse_attrs(skip_ws(rest)) do
      {:ok, attrs, rest} ->
        {:ok, %{state | rest: rest, graph_attrs: Map.merge(state.graph_attrs, attrs)}}

      {:error, _} = err ->
        err
    end
  end

  # ── node [attrs] / edge [attrs] ──────────────────────────────────

  defp parse_node_defaults(%ParseState{rest: rest} = state) do
    {_, rest} = consume_word(rest, "node")

    case parse_attrs(skip_ws(rest)) do
      {:ok, attrs, rest} ->
        {:ok, %{state | rest: rest, node_defaults: Map.merge(state.node_defaults, attrs)}}

      {:error, _} = err ->
        err
    end
  end

  defp parse_edge_defaults(%ParseState{rest: rest} = state) do
    {_, rest} = consume_word(rest, "edge")

    case parse_attrs(skip_ws(rest)) do
      {:ok, attrs, rest} ->
        {:ok, %{state | rest: rest, edge_defaults: Map.merge(state.edge_defaults, attrs)}}

      {:error, _} = err ->
        err
    end
  end

  # ── Subgraph ─────────────────────────────────────────────────────

  defp parse_subgraph(%ParseState{rest: rest} = state) do
    {_, rest} = consume_word(rest, "subgraph")
    {sub_id, rest} = read_identifier(skip_ws(rest))

    case consume_char(
           skip_ws(rest),
           ?{,
           with_line(state, "Expected '{' after subgraph identifier")
         ) do
      {:ok, rest} ->
        sub_state = %ParseState{
          rest: rest,
          source: state.source,
          graph_id: sub_id,
          node_defaults: state.node_defaults,
          edge_defaults: state.edge_defaults,
          accumulate_errors: state.accumulate_errors
        }

        with {:ok, sub_done} <- parse_statements(sub_state),
             {:ok, after_brace} <-
               consume_char(
                 skip_ws(sub_done.rest),
                 ?},
                 with_line(sub_done, "Expected closing '}' for subgraph")
               ) do
          merge_subgraph(state, sub_done, sub_id, after_brace)
        end

      {:error, _} = err ->
        err
    end
  end

  defp merge_subgraph(state, sub_done, sub_id, rest_after) do
    sub_attrs = sub_done.graph_attrs
    label = sub_attrs["label"] || sub_id
    derived_class = derive_class(label)

    # Apply derived class to child nodes that lack an explicit class
    nodes_with_class =
      Map.new(sub_done.nodes, fn {nid, node} ->
        if Map.has_key?(node.attrs, "class") do
          {nid, node}
        else
          {nid, %{node | attrs: Map.put(node.attrs, "class", derived_class)}}
        end
      end)

    subgraph_meta = %{
      id: sub_id,
      label: label,
      derived_class: derived_class,
      attrs: sub_attrs
    }

    # Merge accumulated errors from subgraph back to parent
    merged_errors = sub_done.errors ++ state.errors

    {:ok,
     %{
       state
       | rest: rest_after,
         nodes: Map.merge(state.nodes, nodes_with_class),
         edges: state.edges ++ sub_done.edges,
         node_defaults: Map.merge(state.node_defaults, sub_done.node_defaults),
         edge_defaults: Map.merge(state.edge_defaults, sub_done.edge_defaults),
         subgraphs: state.subgraphs ++ [subgraph_meta],
         errors: merged_errors
     }}
  end

  # ── Node / Edge / Bare Graph Attr ────────────────────────────────

  defp parse_node_or_edge_or_attr(%ParseState{rest: rest} = state) do
    {id, after_id} = read_identifier(skip_ws(rest))

    if id == "" do
      {:ok, %{state | rest: skip_to_next_statement(rest)}}
    else
      dispatch_after_id(state, id, after_id)
    end
  end

  defp dispatch_after_id(state, id, after_id) do
    trimmed = skip_ws(after_id)

    cond do
      # Edge chain: id -> ...
      match?("->" <> _, trimmed) ->
        parse_edge_chain(state, [id], trimmed)

      # Qualified key at graph level: key.sub = value
      match?("." <> _, trimmed) ->
        {qualified, rest2} = read_qualified_key_continuation(id, trimmed)
        rest2 = skip_ws(rest2)

        if match?("=" <> _, rest2) do
          parse_bare_graph_attr(state, qualified, rest2)
        else
          {:ok, %{state | rest: skip_to_next_statement(after_id)}}
        end

      # Bare graph attr: key = value (not key=[...)
      match?("=" <> _, trimmed) and not match?("=[" <> _, trimmed) ->
        parse_bare_graph_attr(state, id, trimmed)

      # Node: id [attrs] or just id
      true ->
        parse_node(state, id, trimmed)
    end
  end

  # ── Edge Chain Parsing ───────────────────────────────────────────

  defp parse_edge_chain(state, chain, rest) do
    # consume "->"
    <<"->"::binary, rest::binary>> = rest
    rest = skip_ws(rest)
    {next_id, after_next} = read_identifier(rest)

    if next_id == "" do
      {:error, with_line(%{state | rest: rest}, "Expected node identifier after '->'")}
    else
      chain = chain ++ [next_id]
      after_next_trimmed = skip_ws(after_next)

      if match?("->" <> _, after_next_trimmed) do
        parse_edge_chain(state, chain, after_next_trimmed)
      else
        finish_edge_chain(state, chain, after_next_trimmed)
      end
    end
  end

  defp finish_edge_chain(state, chain, rest) do
    {attrs, rest} = try_parse_attrs(rest)
    edge_attrs = Map.merge(state.edge_defaults, attrs)

    # Ensure all nodes in chain exist (auto-create with node_defaults)
    nodes =
      Enum.reduce(chain, state.nodes, fn nid, acc ->
        if Map.has_key?(acc, nid) do
          acc
        else
          Map.put(acc, nid, Node.from_attrs(nid, state.node_defaults))
        end
      end)

    # Build pairwise edges
    edges =
      chain
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] -> Edge.from_attrs(from, to, edge_attrs) end)

    {:ok, %{state | rest: rest, nodes: nodes, edges: state.edges ++ edges}}
  end

  # ── Bare Graph Attribute (key = value at top level) ──────────────

  defp parse_bare_graph_attr(state, key, rest) do
    <<"="::binary, rest::binary>> = rest
    rest = skip_ws(rest)
    {value, rest} = read_value(rest)
    {:ok, %{state | rest: rest, graph_attrs: Map.put(state.graph_attrs, key, value)}}
  end

  # ── Node Statement ───────────────────────────────────────────────

  defp parse_node(state, id, rest) do
    {attrs, rest} = try_parse_attrs(rest)
    merged = Map.merge(state.node_defaults, attrs)
    node = Node.from_attrs(id, merged)
    {:ok, %{state | rest: rest, nodes: Map.put(state.nodes, id, node)}}
  end

  # ── Attribute Block Parsing ──────────────────────────────────────

  defp try_parse_attrs(rest) do
    if match?("[" <> _, rest) do
      case parse_attrs(rest) do
        {:ok, attrs, rest} -> {attrs, rest}
        {:error, _} -> {%{}, rest}
      end
    else
      {%{}, rest}
    end
  end

  defp parse_attrs(rest) do
    case rest do
      "[" <> inner ->
        parse_attr_pairs(skip_ws(inner), %{})

      _ ->
        {:ok, %{}, rest}
    end
  end

  defp parse_attr_pairs(rest, acc) do
    rest = skip_ws(rest)

    cond do
      rest == "" ->
        {:ok, acc, rest}

      match?("]" <> _, rest) ->
        "]" <> rest = rest
        {:ok, acc, rest}

      true ->
        case parse_one_attr(rest) do
          {:ok, key, value, rest} ->
            rest = rest |> skip_ws() |> skip_attr_separator()
            parse_attr_pairs(rest, Map.put(acc, key, value))

          {:error, _} = err ->
            err
        end
    end
  end

  defp parse_one_attr(rest) do
    {key, rest} = read_qualified_key(rest)

    if key == "" do
      {:error, "Expected attribute key"}
    else
      rest = skip_ws(rest)

      if match?("=" <> _, rest) do
        <<"="::binary, rest::binary>> = rest
        rest = skip_ws(rest)
        {value, rest} = read_value(rest)
        {:ok, key, value, rest}
      else
        # Bare attribute: key without =value → "true"
        {:ok, key, "true", rest}
      end
    end
  end

  # ── Qualified Key Reading ────────────────────────────────────────

  defp read_qualified_key(rest) do
    {id, rest} = read_identifier(rest)

    if id == "" do
      {"", rest}
    else
      read_qualified_key_continuation(id, rest)
    end
  end

  defp read_qualified_key_continuation(prefix, "." <> rest) do
    {next, rest} = read_identifier(rest)

    if next == "" do
      {prefix, "." <> rest}
    else
      read_qualified_key_continuation(prefix <> "." <> next, rest)
    end
  end

  defp read_qualified_key_continuation(prefix, rest), do: {prefix, rest}

  # ── Value Reading ────────────────────────────────────────────────

  defp read_value("\"" <> rest), do: read_string(rest, [])
  defp read_value(rest), do: read_bare_value(rest)

  # Quoted string — collects chars between opening and closing quote
  defp read_string("", acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}
  defp read_string("\\\\" <> rest, acc), do: read_string(rest, ["\\" | acc])
  defp read_string("\\\"" <> rest, acc), do: read_string(rest, ["\"" | acc])
  defp read_string("\\n" <> rest, acc), do: read_string(rest, ["\n" | acc])
  defp read_string("\\t" <> rest, acc), do: read_string(rest, ["\t" | acc])
  defp read_string("\"" <> rest, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp read_string(<<ch::utf8, rest::binary>>, acc),
    do: read_string(rest, [<<ch::utf8>> | acc])

  # Bare value — read until delimiter, then coerce type
  defp read_bare_value(rest) do
    {token, rest} = collect_bare_value(rest, [])

    value =
      case token do
        "true" -> true
        "false" -> false
        _ -> maybe_parse_number(token)
      end

    {value, rest}
  end

  defp collect_bare_value("", acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp collect_bare_value(<<ch::utf8, _::binary>> = str, acc)
       when ch in [?,, ?;, ?], ?}, ?\s, ?\t, ?\n, ?\r] do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), str}
  end

  defp collect_bare_value(<<ch::utf8, rest::binary>>, acc),
    do: collect_bare_value(rest, [<<ch::utf8>> | acc])

  defp maybe_parse_number(str) do
    cond do
      match?({_, ""}, Integer.parse(str)) ->
        {n, ""} = Integer.parse(str)
        n

      match?({_, ""}, Float.parse(str)) ->
        {f, ""} = Float.parse(str)
        f

      true ->
        str
    end
  end

  # ── String Unescape (standalone utility) ─────────────────────────

  defp do_unescape("", acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp do_unescape("\\\\" <> rest, acc), do: do_unescape(rest, ["\\" | acc])
  defp do_unescape("\\\"" <> rest, acc), do: do_unescape(rest, ["\"" | acc])
  defp do_unescape("\\n" <> rest, acc), do: do_unescape(rest, ["\n" | acc])
  defp do_unescape("\\t" <> rest, acc), do: do_unescape(rest, ["\t" | acc])

  defp do_unescape(<<ch::utf8, rest::binary>>, acc),
    do: do_unescape(rest, [<<ch::utf8>> | acc])

  # ── Helper: Whitespace & Separators ──────────────────────────────

  defp skip_ws(str), do: String.trim_leading(str)

  defp skip_separator(rest) do
    rest = skip_ws(rest)

    case rest do
      ";" <> rest -> skip_ws(rest)
      "\n" <> _ -> skip_ws(rest)
      _ -> rest
    end
  end

  defp skip_attr_separator(rest) do
    case rest do
      "," <> rest -> skip_ws(rest)
      ";" <> rest -> skip_ws(rest)
      _ -> rest
    end
  end

  # ── Helper: Consume ──────────────────────────────────────────────

  defp consume_keyword(source, keyword) do
    trimmed = skip_ws(source)
    klen = byte_size(keyword)

    if String.starts_with?(trimmed, keyword) do
      after_kw = binary_part(trimmed, klen, byte_size(trimmed) - klen)

      case after_kw do
        "" ->
          {:ok, ""}

        <<ch::utf8, _::binary>>
        when ch in ?A..?Z or ch in ?a..?z or ch in ?0..?9 or ch == ?_ ->
          {:error, "Expected '#{keyword}' keyword"}

        _ ->
          {:ok, after_kw}
      end
    else
      {:error, "Expected '#{keyword}' keyword"}
    end
  end

  defp consume_char(str, char, error_msg) when is_integer(char) do
    trimmed = skip_ws(str)

    case trimmed do
      <<^char::utf8, rest::binary>> -> {:ok, rest}
      _ -> {:error, error_msg}
    end
  end

  defp consume_word(str, word) do
    trimmed = skip_ws(str)

    if String.starts_with?(trimmed, word) do
      {word, binary_part(trimmed, byte_size(word), byte_size(trimmed) - byte_size(word))}
    else
      {"", trimmed}
    end
  end

  # ── Helper: Identifier Reading ───────────────────────────────────

  defp read_identifier(str) do
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)/, str) do
      [match, id] ->
        rest = binary_part(str, byte_size(match), byte_size(str) - byte_size(match))
        {id, rest}

      _ ->
        {"", str}
    end
  end

  # ── Helper: Keyword Detection ────────────────────────────────────

  defp keyword_match?(str, keyword) do
    klen = byte_size(keyword)

    String.starts_with?(str, keyword) and
      (byte_size(str) == klen or
         not identifier_char?(binary_part(str, klen, 1)))
  end

  defp identifier_char?(<<ch::utf8>>)
       when ch in ?A..?Z or ch in ?a..?z or ch in ?0..?9 or ch == ?_,
       do: true

  defp identifier_char?(_), do: false

  # ── Helper: Skip Unknown ─────────────────────────────────────────

  defp skip_to_next_statement(rest) do
    case :binary.match(rest, [";", "\n"]) do
      {pos, 1} -> binary_part(rest, pos + 1, byte_size(rest) - pos - 1)
      :nomatch -> ""
    end
  end

  # ── Helper: Number Parsing ───────────────────────────────────────

  defp parse_number(str) do
    case Float.parse(str) do
      {f, ""} -> f
      _ -> 0
    end
  end

  # ── Helper: Line Tracking ────────────────────────────────────────

  # Compute the current line number based on how much of the source has been consumed.
  # This works because `rest` is always a contiguous suffix of `source` —
  # the parser only consumes from the front, never rearranges.
  defp current_line(%ParseState{source: source, rest: rest}) do
    consumed = byte_size(source) - byte_size(rest)

    if consumed > 0 and consumed <= byte_size(source) do
      source |> binary_part(0, consumed) |> count_newlines() |> Kernel.+(1)
    else
      1
    end
  end

  defp with_line(%ParseState{} = state, msg), do: "Line #{current_line(state)}: #{msg}"

  defp count_newlines(str), do: str |> :binary.matches("\n") |> length()

  # ── Graph Construction ───────────────────────────────────────────

  defp build_graph(%ParseState{} = state) do
    base = %Graph{
      id: state.graph_id,
      attrs: state.graph_attrs,
      subgraphs: state.subgraphs,
      node_defaults: state.node_defaults,
      edge_defaults: state.edge_defaults
    }

    graph =
      state.nodes
      |> Map.values()
      |> Enum.reduce(base, fn node, g -> Graph.add_node(g, node) end)

    # Graph.add_edge prepends to adjacency; outgoing_edges reverses.
    # Iterate in declaration order so adjacency ends up reversed (as expected).
    Enum.reduce(state.edges, graph, fn edge, g -> Graph.add_edge(g, edge) end)
  end
end
