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
  affect the node's behavior based on its type.
  """
  @spec compute(Node.t(), Context.t()) :: String.t()
  def compute(%Node{} = node, %Context{} = context) do
    node_type = node.type || Map.get(node.attrs, "type", "")

    extra_keys = Map.get(@type_context_keys, node_type, [])
    context_keys = @base_context_keys ++ extra_keys

    context_slice =
      context_keys
      |> Enum.map(fn key -> {key, Context.get(context, key)} end)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.sort()

    payload = :erlang.term_to_binary({node.id, node.attrs, context_slice})
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  @doc """
  Determine if a node can be skipped based on content hash match.

  A node can be skipped only when:
  1. The computed hash matches the stored hash
  2. The handler's idempotency class is `:idempotent` or `:read_only`
  3. The node is not side-effecting (based on Node.side_effecting?/1)
  """
  @spec can_skip?(Node.t(), String.t(), String.t(), module()) :: boolean()
  def can_skip?(%Node{} = node, computed_hash, stored_hash, handler_module) do
    hash_match = computed_hash == stored_hash

    idempotency = Handler.idempotency_of(handler_module)
    safe_class = idempotency in [:idempotent, :read_only]

    not_side_effecting = not Node.side_effecting?(node)

    hash_match and safe_class and not_side_effecting
  end
end
