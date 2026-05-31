defmodule Arbor.Actions.Skill.DotSerializer do
  @moduledoc """
  Pure (CRC-style) serializer: a structured pipeline spec → Arbor DOT source.

  This is the **deterministic counterpart to the LLM "assemble" stage** of
  `Arbor.Actions.Skill.StagedCompiler`. The staged compiler's design stage
  already produces a structured node/edge spec (Stage-2 JSON). Rather than ask
  an LLM to *serialize that spec into DOT syntax* — the single most
  format-error-prone step, and the thing weak local models fail at — this module
  turns the spec into guaranteed-valid, parser-clean DOT with zero side effects
  and no LLM call.

  Division of labour:

    * The LLM does **semantics**: classify, decompose into phases, choose handler
      types, and write node prompts as data.
    * This module does **syntax**: valid `digraph`, the `// Category:` comment,
      attribute quoting/escaping, identifier sanitization, edge rendering.

  That means the structural and "is it valid DOT" gates pass *by construction*,
  and the weak model never has to emit a single character of DOT.

  ## Validation boundary

  `new/1` rejects specs that can't produce *syntactically* sound DOT (no nodes,
  a node missing id/type, duplicate ids, an edge pointing at an unknown node).
  It deliberately does NOT enforce *semantic* rules (start/exit presence,
  reachability, handler legality) — those belong to the real Arbor validator
  (`mix arbor.pipeline.validate` / `Arbor.Orchestrator.Validation`), which the
  eval harness already runs as a separate gate.

  ## Spec shape (string- or atom-keyed)

      %{
        "name" => "docker_reference",          # digraph name (optional; defaulted + sanitized)
        "category" => "reference",             # // Category comment (optional; defaults to "pipeline")
        "nodes" => [
          %{"id" => "start", "type" => "start", "label" => "start"},
          %{"id" => "reference", "type" => "llm", "label" => "Docker Reference",
            "prompt" => "...", "attributes" => %{"simulate" => false}},
          %{"id" => "done", "type" => "exit"}
        ],
        "connections" => [                      # also accepts "edges"; from/to also accept source/target
          %{"from" => "start", "to" => "reference"},
          %{"from" => "reference", "to" => "done", "condition" => "context.k=v", "label" => "ok"}
        ]
      }

  > NOTE (placement convention): the `// Category:` comment is emitted as the
  > first line *inside* the `digraph` block, matching the hand-authored
  > `expected_dot` fixtures in `evals/promptfoo/dot-compilation`. If the Arbor
  > parser expects it *before* the `digraph` keyword instead, flip `to_dot/1` —
  > this is the one convention worth confirming against the parser.
  """

  defstruct name: "compiled_pipeline",
            category: "pipeline",
            description: nil,
            nodes: [],
            connections: []

  @type attrs :: %{optional(String.t()) => String.t()}
  @type node_t :: %{
          id: String.t(),
          type: String.t(),
          label: String.t(),
          prompt: String.t() | nil,
          attrs: attrs()
        }
  @type conn_t :: %{
          from: String.t(),
          to: String.t(),
          condition: String.t() | nil,
          label: String.t() | nil
        }
  @type t :: %__MODULE__{
          name: String.t(),
          category: String.t(),
          description: String.t() | nil,
          nodes: [node_t()],
          connections: [conn_t()]
        }

  # Keys handled explicitly; never duplicated into the generic attribute bag.
  @reserved_node_attrs ~w(id type label prompt)

  @doc """
  Construct and validate a serializer struct from a Stage-2 structured spec.

  Returns `{:ok, t}` or `{:error, reason}` where reason describes the first
  syntactic problem found.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(spec) when is_map(spec) do
    name = to_s(get(spec, ["name", :name])) || "compiled_pipeline"
    category = to_s(get(spec, ["category", :category]))
    description = to_s(get(spec, ["description", :description]))
    raw_nodes = get(spec, ["nodes", :nodes]) || []
    raw_conns = get(spec, ["connections", :connections, "edges", :edges]) || []

    with {:ok, nodes} <- normalize_nodes(raw_nodes),
         ids = MapSet.new(nodes, & &1.id),
         {:ok, conns} <- normalize_connections(raw_conns, ids) do
      {:ok,
       %__MODULE__{
         name: sanitize_ident(name),
         category: if(category in [nil, ""], do: "pipeline", else: category),
         description: if(blank?(description), do: nil, else: comment_clean(description)),
         nodes: nodes,
         connections: conns
       }}
    end
  end

  def new(_), do: {:error, :spec_not_a_map}

  @doc "Serialize a validated struct to Arbor DOT source (ends with a newline)."
  @spec to_dot(t()) :: String.t()
  def to_dot(%__MODULE__{} = s) do
    header =
      ["digraph #{s.name} {", "  // Category: #{s.category}"] ++
        if(s.description, do: ["  // Description: #{s.description}"], else: []) ++
        [""]

    lines =
      header ++
        Enum.map(s.nodes, &node_line/1) ++
        ["" | Enum.map(s.connections, &edge_line/1)] ++
        ["}"]

    Enum.join(lines, "\n") <> "\n"
  end

  @doc """
  Convenience: structured spec map → `{:ok, dot_string}` or `{:error, reason}`.
  """
  @spec compile(map()) :: {:ok, String.t()} | {:error, term()}
  def compile(spec) do
    with {:ok, s} <- new(spec), do: {:ok, to_dot(s)}
  end

  # --- node / edge rendering --------------------------------------------------

  defp node_line(node) do
    base = [{"label", node.label}, {"type", node.type}]
    prompt = if blank?(node.prompt), do: [], else: [{"prompt", node.prompt}]
    extra = node.attrs |> Map.to_list() |> Enum.sort_by(&elem(&1, 0))

    attr_str =
      (base ++ prompt ++ extra)
      |> Enum.map(fn {k, v} -> ~s(#{k}="#{escape(v)}") end)
      |> Enum.join(" ")

    "  #{node.id} [#{attr_str}]"
  end

  defp edge_line(conn) do
    extra =
      [{"condition", conn.condition}, {"label", conn.label}]
      |> Enum.reject(fn {_k, v} -> blank?(v) end)
      |> Enum.map(fn {k, v} -> ~s(#{k}="#{escape(v)}") end)
      |> Enum.join(" ")

    case extra do
      "" -> "  #{conn.from} -> #{conn.to}"
      s -> "  #{conn.from} -> #{conn.to} [#{s}]"
    end
  end

  # --- normalization ----------------------------------------------------------

  defp normalize_nodes([]), do: {:error, :no_nodes}

  defp normalize_nodes(nodes) when is_list(nodes) do
    reduced =
      Enum.reduce_while(nodes, {:ok, []}, fn raw, {:ok, acc} ->
        case normalize_node(raw) do
          {:ok, n} -> {:cont, {:ok, [n | acc]}}
          {:error, _} = e -> {:halt, e}
        end
      end)

    with {:ok, rev} <- reduced do
      norm = Enum.reverse(rev)
      ids = Enum.map(norm, & &1.id)
      dupes = ids -- Enum.uniq(ids)
      if dupes == [], do: {:ok, norm}, else: {:error, {:duplicate_node_ids, Enum.uniq(dupes)}}
    end
  end

  defp normalize_nodes(_), do: {:error, :nodes_not_a_list}

  defp normalize_node(raw) when is_map(raw) do
    id = to_s(get(raw, ["id", :id]))
    type = to_s(get(raw, ["type", :type]))

    cond do
      blank?(id) ->
        {:error, {:node_missing_id, raw}}

      blank?(type) ->
        {:error, {:node_missing_type, id}}

      true ->
        label = to_s(get(raw, ["label", :label]))
        attrs = normalize_attrs(get(raw, ["attributes", :attributes, "attrs", :attrs]))

        {:ok,
         %{
           id: sanitize_ident(id),
           type: type,
           label: if(blank?(label), do: id, else: label),
           prompt: to_s(get(raw, ["prompt", :prompt])),
           attrs: attrs
         }}
    end
  end

  defp normalize_node(_), do: {:error, :node_not_a_map}

  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs
    |> Enum.reject(fn {k, _v} -> to_string(k) in @reserved_node_attrs end)
    |> Map.new(fn {k, v} -> {to_string(k), to_s(v) || ""} end)
  end

  defp normalize_attrs(_), do: %{}

  defp normalize_connections(conns, valid_ids) when is_list(conns) do
    reduced =
      Enum.reduce_while(conns, {:ok, []}, fn raw, {:ok, acc} ->
        case normalize_conn(raw, valid_ids) do
          {:ok, c} -> {:cont, {:ok, [c | acc]}}
          {:error, _} = e -> {:halt, e}
        end
      end)

    with {:ok, rev} <- reduced, do: {:ok, Enum.reverse(rev)}
  end

  defp normalize_connections(_, _), do: {:error, :connections_not_a_list}

  defp normalize_conn(raw, valid_ids) when is_map(raw) do
    from = raw |> get(["from", :from, "source", :source]) |> to_s() |> sanitize_ident_or_nil()
    to = raw |> get(["to", :to, "target", :target]) |> to_s() |> sanitize_ident_or_nil()

    cond do
      is_nil(from) ->
        {:error, {:edge_missing_from, raw}}

      is_nil(to) ->
        {:error, {:edge_missing_to, raw}}

      not MapSet.member?(valid_ids, from) ->
        {:error, {:edge_unknown_node, from}}

      not MapSet.member?(valid_ids, to) ->
        {:error, {:edge_unknown_node, to}}

      true ->
        {:ok,
         %{
           from: from,
           to: to,
           condition: edge_attr(raw, ["condition", :condition]),
           label: edge_attr(raw, ["label", :label])
         }}
    end
  end

  defp normalize_conn(_, _), do: {:error, :edge_not_a_map}

  defp edge_attr(raw, keys) do
    case to_s(get(raw, keys)) do
      v when v in [nil, ""] -> nil
      v -> v
    end
  end

  # --- primitives -------------------------------------------------------------

  defp get(map, keys), do: Enum.find_value(keys, fn k -> Map.get(map, k) end)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  # Collapse a free-text value onto a single line for use inside a // comment
  # (no quote-escaping needed — comments run to end-of-line).
  defp comment_clean(v) do
    (to_s(v) || "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp to_s(nil), do: nil
  defp to_s(true), do: "true"
  defp to_s(false), do: "false"
  defp to_s(v) when is_binary(v), do: v
  defp to_s(v) when is_number(v), do: to_string(v)
  defp to_s(v) when is_atom(v), do: Atom.to_string(v)
  defp to_s(v), do: inspect(v)

  # DOT-safe quoting: escape backslashes, then quotes; collapse internal
  # whitespace/newlines so a multi-line node prompt stays on one logical line.
  defp escape(v) do
    (to_s(v) || "")
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace(~r/\s*\n\s*/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp sanitize_ident(nil), do: "n"

  defp sanitize_ident(s) when is_binary(s) do
    cleaned =
      s
      |> String.trim()
      |> String.replace(~r/[^A-Za-z0-9_]+/, "_")
      |> String.trim("_")

    cond do
      cleaned == "" -> "n"
      String.match?(cleaned, ~r/^[0-9]/) -> "n_" <> cleaned
      true -> cleaned
    end
  end

  defp sanitize_ident_or_nil(nil), do: nil
  defp sanitize_ident_or_nil(""), do: nil
  defp sanitize_ident_or_nil(s), do: sanitize_ident(s)
end
