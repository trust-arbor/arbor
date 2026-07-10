defmodule Arbor.Orchestrator.Engine.ContentHash do
  @moduledoc """
  Content-based skip logic for pipeline nodes.

  Computes a SHA-256 hash of a node's attributes and relevant context slice.
  On resume, if the hash matches and the node is safe to skip, the engine
  can bypass re-execution.
  """

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.Handler

  @base_context_keys ~w(graph.goal graph.label workdir)
  @type_context_keys %{
    "codergen" => ~w(last_response),
    "file.read" => ~w(workdir),
    "file.write" => ~w(workdir last_response),
    "conditional" => ~w(outcome preferred_label)
  }

  @doc """
  Compute a SHA-256 content hash for a node and its relevant context slice.

  The hash covers the node's id, attrs, and a slice of context keys that
  affect the node's behavior. The slice is the union of:

    1. `@base_context_keys` — always included (graph.goal, label, workdir).
    2. `@type_context_keys` — static legacy per-handler keys.
    3. **Dynamic per-node dependencies** — extracted from this node's attrs:
       * `transform` → `source_key` value
       * `exec` → CSV from `context_keys` + any `prompt_context_key` / `source_key`
       * `compute` → `prompt_context_key`, `system_prompt_context_key`, `messages_context_key`
       * `gate` with `predicate="expression"` → context refs parsed from `expression`
       * `read` / `write` → `source_key`
       * `transform` templates → every `{ctx.KEY}` reference in `expression` or `prompt`

    Without (3), nodes that read different context values across loop
    iterations (e.g. a transform with `source_key=foo` where `foo` changes
    iteration-to-iteration) compute the same hash and get content-hash-
    skipped — silently keeping their stale cached output instead of
    producing fresh output for the new input.
  """
  @spec compute(Node.t(), Context.t()) :: String.t()
  def compute(%Node{} = node, %Context{} = context) do
    node_type = node.type || Map.get(node.attrs, "type", "")

    extra_keys = Map.get(@type_context_keys, node_type, [])
    dynamic_keys = dynamic_dependency_keys(node)
    context_keys = @base_context_keys ++ extra_keys ++ dynamic_keys

    context_slice =
      context_keys
      |> Enum.uniq()
      |> Enum.map(fn key -> {key, Context.get(context, key)} end)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.sort()

    payload = :erlang.term_to_binary({node.id, node.attrs, context_slice})
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  # Extract the context keys this specific node will actually read from,
  # based on its attrs. Each entry returns a flat list of key names.
  defp dynamic_dependency_keys(%Node{attrs: attrs}) do
    type = Map.get(attrs, "type", "")

    case type do
      "transform" ->
        [Map.get(attrs, "source_key", "last_response")] ++ template_context_refs(attrs)

      "exec" ->
        from_context_keys =
          case Map.get(attrs, "context_keys") do
            nil ->
              []

            csv ->
              csv |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
          end

        from_action_key =
          case Map.get(attrs, "action_key") do
            nil -> []
            v when is_binary(v) -> [v]
            _ -> []
          end

        from_context_keys ++ from_action_key

      "compute" ->
        [
          Map.get(attrs, "prompt_context_key"),
          Map.get(attrs, "system_prompt_context_key"),
          Map.get(attrs, "messages_context_key")
        ]
        |> Enum.reject(&is_nil/1)

      "gate" ->
        case Map.get(attrs, "predicate") do
          "expression" ->
            attrs
            |> Map.get("expression", "")
            |> extract_expression_refs()

          _ ->
            []
        end

      "read" ->
        case Map.get(attrs, "source_key") do
          nil -> []
          v -> [v]
        end

      "write" ->
        case Map.get(attrs, "source_key") do
          nil -> ["last_response"]
          v -> [v]
        end

      _ ->
        []
    end
  end

  # Gate expressions like `expression="context.foo.bar"` reference one or
  # more context keys. The condition parser supports `=`, `!=`, `>=`, `<=`,
  # `>`, `<`, `~`, and `&&` composition. Conservative extraction: pull
  # every `context.<dotted>` and bare-identifier reference and strip the
  # `context.` prefix.
  defp extract_expression_refs(expression) when is_binary(expression) do
    expression
    |> String.split("&&")
    |> Enum.flat_map(fn clause ->
      clause
      |> String.split(~r/\s*(!=|>=|<=|=|>|<|~)\s*/, parts: 2)
      |> List.first()
      |> to_string()
      |> String.trim()
      |> case do
        "" -> []
        ref -> [String.replace_prefix(ref, "context.", "")]
      end
    end)
  end

  defp extract_expression_refs(_), do: []

  # Transform templates read every `{ctx.KEY}` placeholder in addition to their
  # `source_key`. Keep the extracted keys sorted and unique so the hash input is
  # stable regardless of placeholder order or duplication.
  defp template_context_refs(attrs) do
    attrs
    |> Map.take(["expression", "prompt"])
    |> Map.values()
    |> Enum.flat_map(&extract_template_refs/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp extract_template_refs(text) when is_binary(text) do
    for [key] <- Regex.scan(~r/\{ctx\.([a-zA-Z0-9_.-]+)\}/, text, capture: :all_but_first),
        do: key
  end

  defp extract_template_refs(_), do: []

  @doc """
  Determine if a node can be skipped based on content hash match.

  Accepts an optional `cached_outcome` (5th arg). When provided, `:idempotent_with_key`
  nodes are only skipped if the cached outcome was successful — failed outcomes
  should be re-executed since the handler may produce different results.

  `:side_effecting` handlers are NEVER skipped — they use the WAL pattern instead.
  """
  @spec can_skip?(Node.t(), String.t(), String.t(), module(), map() | nil) :: boolean()
  def can_skip?(node, computed_hash, stored_hash, handler_module, cached_outcome \\ nil)

  def can_skip?(%Node{} = node, computed_hash, stored_hash, handler_module, cached_outcome) do
    hash_match = computed_hash == stored_hash

    idempotency = Handler.idempotency_of(handler_module)

    safe_class =
      case idempotency do
        class when class in [:idempotent, :read_only] ->
          not Node.side_effecting?(node)

        :idempotent_with_key ->
          # Only skip if the cached outcome was successful — re-execute on failure
          # since the handler may produce different results on retry
          cached_outcome != nil and cached_outcome.status in [:success, :partial_success]

        _ ->
          false
      end

    hash_match and safe_class
  end
end
