defmodule Arbor.Orchestrator.IR.TypedNode do
  @moduledoc """
  A typed intermediate representation of a pipeline node.

  Created by compiling an untyped `Graph.Node` via the IR compiler.
  Contains resolved handler type, module, capabilities, data classification,
  and validated attribute types.
  """

  alias Arbor.Orchestrator.IR.HandlerSchema

  @type data_class :: :public | :internal | :sensitive | :secret

  @type t :: %__MODULE__{
          id: String.t(),
          handler_type: String.t(),
          handler_module: module() | nil,
          attrs: map(),
          schema: HandlerSchema.t(),
          capabilities_required: [String.t()],
          data_classification: data_class(),
          idempotency: atom(),
          resource_bounds: resource_bounds(),
          schema_errors: [{:error | :warning, String.t()}]
        }

  @type resource_bounds :: %{
          max_retries: non_neg_integer() | nil,
          timeout_ms: non_neg_integer() | nil,
          max_tokens: non_neg_integer() | nil
        }

  defstruct id: "",
            handler_type: "codergen",
            handler_module: nil,
            attrs: %{},
            schema: %HandlerSchema{},
            capabilities_required: [],
            data_classification: :public,
            idempotency: :side_effecting,
            resource_bounds: %{max_retries: nil, timeout_ms: nil, max_tokens: nil},
            schema_errors: []

  @doc "Returns true if this node has side effects."
  @spec side_effecting?(t()) :: boolean()
  def side_effecting?(%__MODULE__{idempotency: class}),
    do: class == :side_effecting

  @doc "Returns true if this node requires the given capability."
  @spec requires_capability?(t(), String.t()) :: boolean()
  def requires_capability?(%__MODULE__{capabilities_required: caps}, capability),
    do: capability in caps

  @doc "Returns true if this node has schema validation errors."
  @spec has_errors?(t()) :: boolean()
  def has_errors?(%__MODULE__{schema_errors: errors}),
    do: Enum.any?(errors, fn {severity, _} -> severity == :error end)
end
