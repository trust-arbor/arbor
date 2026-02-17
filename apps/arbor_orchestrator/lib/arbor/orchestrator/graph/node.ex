defmodule Arbor.Orchestrator.Graph.Node do
  @moduledoc false

  @type t :: %__MODULE__{
          id: String.t(),
          attrs: map(),
          # Typed fields populated from attrs via from_attrs/2
          shape: String.t() | nil,
          type: String.t() | nil,
          prompt: String.t() | nil,
          label: String.t() | nil,
          goal_gate: boolean(),
          max_retries: non_neg_integer() | nil,
          retry_target: String.t() | nil,
          fallback_retry_target: String.t() | nil,
          timeout: String.t() | nil,
          llm_model: String.t() | nil,
          llm_provider: String.t() | nil,
          reasoning_effort: String.t() | nil,
          allow_partial: boolean(),
          content_hash: String.t() | nil,
          fidelity: String.t() | nil,
          class: String.t() | nil,
          fan_out: boolean(),
          simulate: String.t() | nil
        }

  defstruct id: "",
            attrs: %{},
            shape: nil,
            type: nil,
            prompt: nil,
            label: nil,
            goal_gate: false,
            max_retries: nil,
            retry_target: nil,
            fallback_retry_target: nil,
            timeout: nil,
            llm_model: nil,
            llm_provider: nil,
            reasoning_effort: nil,
            allow_partial: false,
            content_hash: nil,
            fidelity: nil,
            class: nil,
            fan_out: false,
            simulate: nil

  @known_attrs ~w(shape type prompt label goal_gate max_retries retry_target
    fallback_retry_target timeout llm_model llm_provider reasoning_effort
    allow_partial content_hash fidelity class fan_out simulate)

  @doc "List of attribute keys that have typed struct fields."
  @spec known_attrs() :: [String.t()]
  def known_attrs, do: @known_attrs

  @doc "Populate typed fields from the attrs map."
  @spec from_attrs(String.t(), map()) :: t()
  def from_attrs(id, attrs) when is_map(attrs) do
    %__MODULE__{
      id: id,
      attrs: attrs,
      shape: Map.get(attrs, "shape"),
      type: Map.get(attrs, "type"),
      prompt: Map.get(attrs, "prompt"),
      label: Map.get(attrs, "label"),
      goal_gate: truthy?(Map.get(attrs, "goal_gate", false)),
      max_retries: parse_max_retries(Map.get(attrs, "max_retries")),
      retry_target: Map.get(attrs, "retry_target"),
      fallback_retry_target: Map.get(attrs, "fallback_retry_target"),
      timeout: Map.get(attrs, "timeout"),
      llm_model: Map.get(attrs, "llm_model"),
      llm_provider: Map.get(attrs, "llm_provider"),
      reasoning_effort: Map.get(attrs, "reasoning_effort"),
      allow_partial: truthy?(Map.get(attrs, "allow_partial", false)),
      content_hash: Map.get(attrs, "content_hash"),
      fidelity: Map.get(attrs, "fidelity"),
      class: Map.get(attrs, "class"),
      fan_out: truthy?(Map.get(attrs, "fan_out", false)),
      simulate: Map.get(attrs, "simulate")
    }
  end

  @doc "Returns true if this node can be skipped (start, exit, or conditional shapes)."
  @spec skippable?(t()) :: boolean()
  def skippable?(%__MODULE__{} = node) do
    shape = node.shape || Map.get(node.attrs, "shape")
    shape in ["Mdiamond", "Msquare", "diamond"]
  end

  @doc "Compute a SHA-256 content hash of this node's sorted attrs."
  @spec content_hash(t()) :: String.t()
  def content_hash(%__MODULE__{id: id, attrs: attrs}) do
    sorted_attrs = attrs |> Enum.sort() |> :erlang.term_to_binary()
    payload = :erlang.term_to_binary({id, sorted_attrs})
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  @doc "Returns true if this node has external side effects."
  @spec side_effecting?(t()) :: boolean()
  def side_effecting?(%__MODULE__{} = node) do
    node_type = node.type || Map.get(node.attrs, "type")

    node_type in [
      "shell",
      "tool",
      "file.write",
      "file.delete",
      "pipeline.run",
      "consensus.decide"
    ]
  end

  @spec attr(t(), String.t() | atom(), term()) :: term()
  def attr(node, key, default \\ nil)

  def attr(%__MODULE__{attrs: attrs}, key, default) when is_atom(key) do
    attr(%__MODULE__{attrs: attrs}, Atom.to_string(key), default)
  end

  def attr(%__MODULE__{attrs: attrs}, key, default) when is_binary(key) do
    Map.get(attrs, key, default)
  end

  # -- Private helpers --

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  defp parse_max_retries(nil), do: nil

  defp parse_max_retries(val) when is_integer(val), do: val

  defp parse_max_retries(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_max_retries(_), do: nil
end
