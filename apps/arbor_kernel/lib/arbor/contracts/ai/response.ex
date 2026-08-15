defmodule Arbor.Contracts.AI.Response do
  @moduledoc """
  TypedStruct for AI/LLM response envelope.

  Represents a complete, validated response from an LLM provider. Captures all
  data needed for routing decisions, billing reconciliation, taint tracking,
  performance monitoring, and audit.

  ## Taint Levels

  - `:public` — No sensitive data in prompt or response
  - `:internal` — Internal data, response may contain internal context
  - `:sensitive` — PII or credentials may be present
  - `:restricted` — Highest classification, on-premise only

  ## Usage

      {:ok, resp} = Response.new(
        request_id: "req_abc123",
        content: "Hello! How can I help?",
        model: "claude-sonnet-4-20250514",
        provider: "anthropic",
        usage: %{input_tokens: 10, output_tokens: 25}
      )

      Response.text?(resp)          # => true
      Response.tool_call?(resp)     # => false
      Response.total_tokens(resp)   # => 35
  """

  use TypedStruct

  @valid_taint_levels [:public, :internal, :sensitive, :restricted]

  @derive {Jason.Encoder, except: []}
  typedstruct enforce: true do
    @typedoc "A validated AI/LLM response envelope"

    field(:request_id, String.t())
    field(:content, String.t() | nil, enforce: false)
    field(:tool_calls, [map()], default: [])
    field(:thinking, String.t() | nil, enforce: false)
    field(:usage, map())
    field(:model, String.t())
    field(:provider, String.t())
    field(:taint_level, :public | :internal | :sensitive | :restricted, default: :public)
    field(:latency_ms, non_neg_integer() | nil, enforce: false)
    field(:metadata, map(), default: %{})
  end

  @doc """
  Create a new AI response with validation.

  Accepts keyword list or map. Validates that required fields are present
  and that `usage` contains `:input_tokens` and `:output_tokens`.

  ## Required Fields

  - `:request_id` — Correlates response to its originating request
  - `:model` — LLM model that generated the response
  - `:provider` — Provider that served the request
  - `:usage` — Token usage map with `:input_tokens` and `:output_tokens`

  ## Optional Fields

  - `:content` — Text content of the response
  - `:tool_calls` — Tool call requests from the model (default: `[]`)
  - `:thinking` — Model thinking/reasoning blocks
  - `:taint_level` — Data classification (default: `:public`)
  - `:latency_ms` — End-to-end latency in milliseconds
  - `:metadata` — Additional metadata (default: `%{}`)

  ## Examples

      {:ok, resp} = Response.new(
        request_id: "req_abc123",
        content: "Hello!",
        model: "claude-sonnet-4-20250514",
        provider: "anthropic",
        usage: %{input_tokens: 10, output_tokens: 5}
      )

      {:error, {:missing_required_field, :usage}} = Response.new(
        request_id: "req_abc123",
        model: "gpt-4",
        provider: "openai"
      )

      {:error, {:invalid_usage, :missing_token_counts}} = Response.new(
        request_id: "req_abc123",
        model: "gpt-4",
        provider: "openai",
        usage: %{total: 100}
      )
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    attrs |> Map.new() |> new()
  end

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_required(attrs, [:request_id, :model, :provider, :usage]),
         :ok <- validate_usage(get_attr(attrs, :usage)),
         :ok <- validate_taint_level(get_attr(attrs, :taint_level)),
         :ok <- validate_latency_ms(get_attr(attrs, :latency_ms)),
         :ok <- validate_tool_calls(get_attr(attrs, :tool_calls)) do
      response = %__MODULE__{
        request_id: get_attr(attrs, :request_id),
        content: get_attr(attrs, :content),
        tool_calls: get_attr(attrs, :tool_calls) || [],
        thinking: get_attr(attrs, :thinking),
        usage: get_attr(attrs, :usage),
        model: get_attr(attrs, :model),
        provider: get_attr(attrs, :provider),
        taint_level: get_attr(attrs, :taint_level) || :public,
        latency_ms: get_attr(attrs, :latency_ms),
        metadata: get_attr(attrs, :metadata) || %{}
      }

      {:ok, response}
    end
  end

  # ============================================================================
  # Public — Query Functions
  # ============================================================================

  @doc """
  Returns `true` if the response contains non-empty text content.

  ## Examples

      iex> {:ok, resp} = Arbor.Contracts.AI.Response.new(
      ...>   request_id: "req_1", content: "Hello",
      ...>   model: "m", provider: "p", usage: %{input_tokens: 1, output_tokens: 1}
      ...> )
      iex> Arbor.Contracts.AI.Response.text?(resp)
      true

      iex> {:ok, resp} = Arbor.Contracts.AI.Response.new(
      ...>   request_id: "req_2", content: nil,
      ...>   model: "m", provider: "p", usage: %{input_tokens: 1, output_tokens: 1}
      ...> )
      iex> Arbor.Contracts.AI.Response.text?(resp)
      false
  """
  @spec text?(t()) :: boolean()
  def text?(%__MODULE__{content: content}) do
    is_binary(content) and content != ""
  end

  @doc """
  Returns `true` if the response contains tool calls.

  ## Examples

      iex> {:ok, resp} = Arbor.Contracts.AI.Response.new(
      ...>   request_id: "req_1", tool_calls: [%{name: "search", input: %{q: "elixir"}}],
      ...>   model: "m", provider: "p", usage: %{input_tokens: 1, output_tokens: 1}
      ...> )
      iex> Arbor.Contracts.AI.Response.tool_call?(resp)
      true

      iex> {:ok, resp} = Arbor.Contracts.AI.Response.new(
      ...>   request_id: "req_2",
      ...>   model: "m", provider: "p", usage: %{input_tokens: 1, output_tokens: 1}
      ...> )
      iex> Arbor.Contracts.AI.Response.tool_call?(resp)
      false
  """
  @spec tool_call?(t()) :: boolean()
  def tool_call?(%__MODULE__{tool_calls: tool_calls}) do
    is_list(tool_calls) and tool_calls != []
  end

  @doc """
  Returns the total token count (input + output) from the response usage.

  ## Examples

      iex> {:ok, resp} = Arbor.Contracts.AI.Response.new(
      ...>   request_id: "req_1", model: "m", provider: "p",
      ...>   usage: %{input_tokens: 100, output_tokens: 50}
      ...> )
      iex> Arbor.Contracts.AI.Response.total_tokens(resp)
      150
  """
  @spec total_tokens(t()) :: non_neg_integer()
  def total_tokens(%__MODULE__{usage: usage}) do
    Map.get(usage, :input_tokens, 0) + Map.get(usage, :output_tokens, 0)
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

  defp validate_usage(nil), do: {:error, {:missing_required_field, :usage}}

  defp validate_usage(usage) when is_map(usage) do
    has_input = Map.has_key?(usage, :input_tokens) or Map.has_key?(usage, "input_tokens")
    has_output = Map.has_key?(usage, :output_tokens) or Map.has_key?(usage, "output_tokens")

    if has_input and has_output do
      :ok
    else
      {:error, {:invalid_usage, :missing_token_counts}}
    end
  end

  defp validate_usage(_), do: {:error, {:invalid_usage, :not_a_map}}

  defp validate_taint_level(nil), do: :ok

  defp validate_taint_level(level) when level in @valid_taint_levels, do: :ok

  defp validate_taint_level(level), do: {:error, {:invalid_taint_level, level}}

  defp validate_latency_ms(nil), do: :ok

  defp validate_latency_ms(ms) when is_integer(ms) and ms >= 0, do: :ok

  defp validate_latency_ms(ms), do: {:error, {:invalid_latency_ms, ms}}

  defp validate_tool_calls(nil), do: :ok

  defp validate_tool_calls(calls) when is_list(calls) do
    if Enum.all?(calls, &is_map/1) do
      :ok
    else
      {:error, {:invalid_tool_calls, :not_all_maps}}
    end
  end

  defp validate_tool_calls(_), do: {:error, {:invalid_tool_calls, :not_a_list}}

  # ============================================================================
  # Private — Helpers
  # ============================================================================

  # Supports both atom and string keys in attrs map
  defp get_attr(attrs, key) when is_atom(key) do
    case Map.get(attrs, key) do
      nil -> Map.get(attrs, Atom.to_string(key))
      value -> value
    end
  end
end
