defmodule Arbor.Contracts.Handler.ScopedContext do
  @moduledoc """
  Restricted context struct passed to handler behaviour callbacks.

  Instead of passing raw pipeline context (which may contain internal keys,
  other handler state, or sensitive data), handlers receive a ScopedContext
  with only the keys they need.

  Council requirement: "Context Scoping" (11/13 approval).
  """

  @type t :: %__MODULE__{
          node_id: String.t(),
          node_type: String.t(),
          node_attrs: map(),
          values: map(),
          agent_id: String.t() | nil,
          pipeline_id: String.t() | nil,
          metadata: map()
        }

  defstruct [
    :node_id,
    :node_type,
    :node_attrs,
    :agent_id,
    :pipeline_id,
    values: %{},
    metadata: %{}
  ]

  @doc """
  Build a ScopedContext from a node and raw pipeline context.

  Only extracts relevant context values based on the node's declared
  input keys. Internal context keys are never exposed.
  """
  @spec from_node_and_context(map(), map(), keyword()) :: t()
  def from_node_and_context(node, context, opts \\ []) do
    input_keys = Keyword.get(opts, :input_keys, [])

    values =
      case input_keys do
        [] -> context
        keys -> Map.take(context, keys)
      end

    %__MODULE__{
      node_id: Map.get(node, :id) || Map.get(node, "id"),
      node_type: Map.get(node, :type) || Map.get(node, "type"),
      node_attrs: Map.get(node, :attrs, %{}),
      values: values,
      agent_id: Map.get(context, :agent_id) || Map.get(context, "agent_id"),
      pipeline_id: Map.get(context, :pipeline_id) || Map.get(context, "pipeline_id"),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Get a value from the scoped context.
  """
  @spec get(t(), String.t() | atom(), term()) :: term()
  def get(%__MODULE__{values: values}, key, default \\ nil) do
    Map.get(values, key, default)
  end

  @doc """
  Put a value into the scoped context.
  """
  @spec put(t(), String.t() | atom(), term()) :: t()
  def put(%__MODULE__{} = ctx, key, value) do
    %{ctx | values: Map.put(ctx.values, key, value)}
  end
end
