defmodule Arbor.Orchestrator.Graph.Node do
  @moduledoc false

  alias Arbor.Orchestrator.IR.HandlerSchema

  @type data_class :: :public | :internal | :sensitive | :secret

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
          timeout_ms: non_neg_integer() | nil,
          llm_model: String.t() | nil,
          llm_provider: String.t() | nil,
          reasoning_effort: String.t() | nil,
          allow_partial: boolean(),
          content_hash: String.t() | nil,
          fidelity: String.t() | nil,
          class: String.t() | nil,
          fan_out: boolean(),
          simulate: String.t() | nil,
          # IR compilation fields (nil/empty until Compiler.compile/1 enriches them)
          handler_module: module() | nil,
          handler_schema: HandlerSchema.t() | nil,
          capabilities_required: [String.t()],
          data_classification: data_class() | nil,
          idempotency: atom() | nil,
          schema_errors: [{:error | :warning, String.t()}]
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
            timeout_ms: nil,
            llm_model: nil,
            llm_provider: nil,
            reasoning_effort: nil,
            allow_partial: false,
            content_hash: nil,
            fidelity: nil,
            class: nil,
            fan_out: false,
            simulate: nil,
            handler_module: nil,
            handler_schema: nil,
            capabilities_required: [],
            data_classification: nil,
            idempotency: nil,
            schema_errors: []

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
      shape: Map.get(attrs, "shape", "box"),
      type: Map.get(attrs, "type"),
      prompt: Map.get(attrs, "prompt"),
      label: Map.get(attrs, "label", id),
      goal_gate: truthy?(Map.get(attrs, "goal_gate", false)),
      max_retries: parse_max_retries(Map.get(attrs, "max_retries")),
      retry_target: Map.get(attrs, "retry_target"),
      fallback_retry_target: Map.get(attrs, "fallback_retry_target"),
      timeout: Map.get(attrs, "timeout"),
      timeout_ms: parse_timeout_ms(Map.get(attrs, "timeout")),
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
  def side_effecting?(%__MODULE__{idempotency: :side_effecting}), do: true

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

  @doc "Returns true if this node requires the given capability."
  @spec requires_capability?(t(), String.t()) :: boolean()
  def requires_capability?(%__MODULE__{capabilities_required: caps}, capability),
    do: capability in caps

  @doc "Returns true if this node has schema validation errors (severity :error)."
  @spec has_schema_errors?(t()) :: boolean()
  def has_schema_errors?(%__MODULE__{schema_errors: errors}),
    do: Enum.any?(errors, fn {severity, _} -> severity == :error end)

  @doc "Returns true if this node has been enriched by the IR compiler."
  @spec compiled?(t()) :: boolean()
  def compiled?(%__MODULE__{handler_module: nil}), do: false
  def compiled?(%__MODULE__{}), do: true

  @doc "Split the comma-separated class string into a list."
  @spec classes(t()) :: [String.t()]
  def classes(%__MODULE__{} = node) do
    case node.class || Map.get(node.attrs, "class") do
      nil -> []
      "" -> []
      str when is_binary(str) -> str |> String.split(",") |> Enum.map(&String.trim/1)
    end
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

  defp parse_timeout_ms(nil), do: nil

  defp parse_timeout_ms(val) when is_binary(val) do
    case Regex.run(~r/^(\d+(?:\.\d+)?)\s*(ms|s|m|h)$/, val) do
      [_, num, "ms"] -> parse_number(num) |> trunc()
      [_, num, "s"] -> (parse_number(num) * 1_000) |> trunc()
      [_, num, "m"] -> (parse_number(num) * 60_000) |> trunc()
      [_, num, "h"] -> (parse_number(num) * 3_600_000) |> trunc()
      _ -> nil
    end
  end

  defp parse_timeout_ms(_), do: nil

  defp parse_number(str) do
    case Float.parse(str) do
      {f, ""} -> f
      _ -> 0.0
    end
  end
end
