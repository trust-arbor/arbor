defmodule Arbor.Contracts.AI.Request do
  @moduledoc """
  TypedStruct for AI/LLM request envelope.

  Represents a complete, validated request to an LLM provider. Captures all
  parameters needed for routing, billing, taint tracking, and audit.

  ## Taint Levels

  - `:public` — No sensitive data, safe for any provider
  - `:internal` — Internal data, prefer local/trusted providers
  - `:sensitive` — PII or credentials, requires encrypted transport
  - `:restricted` — Highest classification, on-premise only

  ## Billing Classes

  - `:free` — Route only to free-tier providers
  - `:paid` — Route only to paid providers
  - `:any` — No billing constraint

  ## Usage

      {:ok, req} = Request.new(
        model: "claude-sonnet-4-20250514",
        messages: [%{role: "user", content: "Hello"}],
        agent_id: "agent_abc123",
        system_prompt: "You are a helpful assistant.",
        taint_level: :internal
      )
  """

  use TypedStruct

  @valid_taint_levels [:public, :internal, :sensitive, :restricted]
  @valid_billing_classes [:free, :paid, :any]

  @derive {Jason.Encoder, except: []}
  typedstruct enforce: true do
    @typedoc "A validated AI/LLM request envelope"

    field(:request_id, String.t())
    field(:parent_request_id, String.t() | nil, enforce: false)
    field(:model, String.t())
    field(:messages, [map()])
    field(:tools, [map()], default: [])
    field(:system_prompt, String.t() | nil, enforce: false)
    field(:temperature, float() | nil, enforce: false)
    field(:max_tokens, pos_integer() | nil, enforce: false)
    field(:max_input_tokens, pos_integer() | nil, enforce: false)
    field(:taint_level, :public | :internal | :sensitive | :restricted, default: :public)
    field(:cache_control, map() | nil, enforce: false)
    field(:billing_class, :free | :paid | :any, default: :any)
    field(:streaming, boolean(), default: false)
    field(:agent_id, String.t())
    field(:metadata, map(), default: %{})
  end

  @doc """
  Create a new AI request with validation.

  Accepts keyword list or map. Generates `request_id` automatically.

  ## Required Fields

  - `:model` — LLM model identifier
  - `:messages` — List of message maps (each with at least `:role` and `:content`)
  - `:agent_id` — ID of the requesting agent

  ## Optional Fields

  - `:parent_request_id` — For tracing request chains (retries, sub-requests)
  - `:tools` — Tool definitions available to the model (default: `[]`)
  - `:system_prompt` — System-level instructions
  - `:temperature` — Sampling temperature
  - `:max_tokens` — Maximum output tokens
  - `:max_input_tokens` — Maximum input context tokens
  - `:taint_level` — Data classification (default: `:public`)
  - `:cache_control` — Provider-specific cache hints
  - `:billing_class` — Cost routing constraint (default: `:any`)
  - `:streaming` — Whether to stream the response (default: `false`)
  - `:metadata` — Additional metadata

  ## Examples

      {:ok, req} = Request.new(
        model: "claude-sonnet-4-20250514",
        messages: [%{role: "user", content: "Hello"}],
        agent_id: "agent_abc123"
      )

      {:error, {:invalid_taint_level, :bogus}} = Request.new(
        model: "gpt-4",
        messages: [%{role: "user", content: "Hello"}],
        agent_id: "agent_abc123",
        taint_level: :bogus
      )
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    attrs |> Map.new() |> new()
  end

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_required(attrs, [:model, :messages, :agent_id]),
         :ok <- validate_messages(attrs[:messages] || attrs["messages"]),
         :ok <- validate_taint_level(attrs[:taint_level]),
         :ok <- validate_billing_class(attrs[:billing_class]),
         :ok <- validate_temperature(attrs[:temperature]),
         :ok <- validate_max_tokens(attrs[:max_tokens]),
         :ok <- validate_max_input_tokens(attrs[:max_input_tokens]) do
      request = %__MODULE__{
        request_id: get_attr(attrs, :request_id) || generate_request_id(),
        parent_request_id: get_attr(attrs, :parent_request_id),
        model: get_attr(attrs, :model),
        messages: get_attr(attrs, :messages),
        tools: get_attr(attrs, :tools) || [],
        system_prompt: get_attr(attrs, :system_prompt),
        temperature: get_attr(attrs, :temperature),
        max_tokens: get_attr(attrs, :max_tokens),
        max_input_tokens: get_attr(attrs, :max_input_tokens),
        taint_level: get_attr(attrs, :taint_level) || :public,
        cache_control: get_attr(attrs, :cache_control),
        billing_class: get_attr(attrs, :billing_class) || :any,
        streaming: get_attr(attrs, :streaming) || false,
        agent_id: get_attr(attrs, :agent_id),
        metadata: get_attr(attrs, :metadata) || %{}
      }

      {:ok, request}
    end
  end

  # ============================================================================
  # Private — Validation
  # ============================================================================

  defp validate_required(attrs, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      if get_attr(attrs, key) do
        {:cont, :ok}
      else
        {:halt, {:error, {:missing_required_field, key}}}
      end
    end)
  end

  defp validate_messages(nil), do: :ok
  defp validate_messages([]), do: {:error, {:invalid_messages, :empty}}

  defp validate_messages(messages) when is_list(messages) do
    if Enum.all?(messages, &is_map/1) do
      :ok
    else
      {:error, {:invalid_messages, :not_all_maps}}
    end
  end

  defp validate_messages(_), do: {:error, {:invalid_messages, :not_a_list}}

  defp validate_taint_level(nil), do: :ok

  defp validate_taint_level(level) when level in @valid_taint_levels, do: :ok

  defp validate_taint_level(level), do: {:error, {:invalid_taint_level, level}}

  defp validate_billing_class(nil), do: :ok

  defp validate_billing_class(class) when class in @valid_billing_classes, do: :ok

  defp validate_billing_class(class), do: {:error, {:invalid_billing_class, class}}

  defp validate_temperature(nil), do: :ok

  defp validate_temperature(t) when is_float(t) or is_integer(t) do
    if t >= 0.0 and t <= 2.0 do
      :ok
    else
      {:error, {:invalid_temperature, t}}
    end
  end

  defp validate_temperature(t), do: {:error, {:invalid_temperature, t}}

  defp validate_max_tokens(nil), do: :ok

  defp validate_max_tokens(n) when is_integer(n) and n > 0, do: :ok

  defp validate_max_tokens(n), do: {:error, {:invalid_max_tokens, n}}

  defp validate_max_input_tokens(nil), do: :ok

  defp validate_max_input_tokens(n) when is_integer(n) and n > 0, do: :ok

  defp validate_max_input_tokens(n), do: {:error, {:invalid_max_input_tokens, n}}

  # ============================================================================
  # Private — Helpers
  # ============================================================================

  defp generate_request_id do
    "req_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  # Supports both atom and string keys in attrs map
  defp get_attr(attrs, key) when is_atom(key) do
    case Map.get(attrs, key) do
      nil -> Map.get(attrs, Atom.to_string(key))
      value -> value
    end
  end
end
