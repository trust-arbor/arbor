defmodule Arbor.LLM.Response do
  @moduledoc false

  alias Arbor.LLM.ContentPart

  @type finish_reason :: :stop | :length | :tool_calls | :content_filter | :error | :other

  defmodule ProviderReceipt do
    @moduledoc false

    @max_token_count 1_000_000_000
    @fields [:backend, :reported_model, :usage]
    @usage_fields [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :cached_tokens,
      :cache_write_tokens,
      :reasoning_tokens
    ]

    @enforce_keys [:backend, :reported_model, :usage]
    defstruct [:backend, :reported_model, :usage]

    @type backend :: :openai | :xai
    @type t :: %__MODULE__{
            backend: backend(),
            reported_model: String.t() | nil,
            usage: map()
          }

    @spec new(map()) :: {:ok, t()} | {:error, atom()}
    def new(attrs) when is_map(attrs) do
      with :ok <- validate_fields(attrs),
           :ok <- validate_backend(attrs.backend),
           :ok <- validate_model(attrs.reported_model),
           {:ok, usage} <- canonical_usage(attrs.usage) do
        {:ok,
         %__MODULE__{
           backend: attrs.backend,
           reported_model: attrs.reported_model,
           usage: usage
         }}
      end
    end

    def new(_attrs), do: {:error, :invalid_provider_receipt}

    @spec revalidate(t()) :: {:ok, t()} | {:error, atom()}
    def revalidate(%__MODULE__{} = receipt) do
      receipt
      |> Map.from_struct()
      |> new()
    end

    def revalidate(_receipt), do: {:error, :invalid_provider_receipt}

    defp validate_fields(attrs) do
      keys = Map.keys(attrs)

      if length(keys) == length(@fields) and Enum.all?(keys, &(&1 in @fields)),
        do: :ok,
        else: {:error, :invalid_provider_receipt_fields}
    end

    defp validate_backend(backend) when backend in [:openai, :xai], do: :ok
    defp validate_backend(_backend), do: {:error, :invalid_provider_receipt_backend}

    defp validate_model(nil), do: :ok

    defp validate_model(model)
         when is_binary(model) and byte_size(model) <= 512 do
      if String.valid?(model) and String.trim(model) == model and model != "" and
           not String.match?(model, ~r/[\x00-\x1F\x7F]/),
         do: :ok,
         else: {:error, :invalid_provider_receipt_model}
    end

    defp validate_model(_model), do: {:error, :invalid_provider_receipt_model}

    defp canonical_usage(usage) when is_map(usage) and not is_struct(usage) do
      keys = Map.keys(usage)

      cond do
        not Enum.all?(keys, &(&1 in @usage_fields)) ->
          {:error, :invalid_provider_receipt_usage_keys}

        map_size(usage) == 0 ->
          {:ok, %{}}

        not Enum.all?([:input_tokens, :output_tokens, :total_tokens], &Map.has_key?(usage, &1)) ->
          {:error, :incomplete_provider_receipt_usage}

        not Enum.all?(Map.values(usage), &valid_token_count?/1) ->
          {:error, :invalid_provider_receipt_usage_value}

        usage.input_tokens + usage.output_tokens != usage.total_tokens ->
          {:error, :inconsistent_provider_receipt_usage_total}

        Map.has_key?(usage, :cached_tokens) and usage.cached_tokens > usage.input_tokens ->
          {:error, :inconsistent_provider_receipt_cached_tokens}

        Map.has_key?(usage, :cache_write_tokens) and
            usage.cache_write_tokens > usage.input_tokens ->
          {:error, :inconsistent_provider_receipt_cache_write_tokens}

        Map.has_key?(usage, :reasoning_tokens) and
            usage.reasoning_tokens > usage.output_tokens ->
          {:error, :inconsistent_provider_receipt_reasoning_tokens}

        true ->
          {:ok, usage}
      end
    end

    defp canonical_usage(_usage), do: {:error, :invalid_provider_receipt_usage}

    defp valid_token_count?(value),
      do: is_integer(value) and value >= 0 and value <= @max_token_count
  end

  @typedoc """
  Claude-style extended-thinking block. Carries the model's reasoning
  text plus a cryptographic signature when the provider supplies one
  (the Claude API signs thinking blocks so they can be replayed in
  subsequent turns without re-incurring the thinking cost). Populated
  by adapters that surface structured thinking — currently
  `Arbor.AI.Runtime.Acp` when the Claude CLI emits thinking via ACP
  stream events. For prose-style reasoning (gemma/deepseek/o-series),
  use `:reasoning_content` instead.
  """
  @type thinking_block :: %{
          required(:text) => String.t(),
          optional(:signature) => String.t() | nil
        }

  @type t :: %__MODULE__{
          text: String.t(),
          # Reasoning content from chain-of-thought / thinking-tuned models
          # (gemma reasoning variants, deepseek-r1, openai o-series, etc.).
          # Populated when the provider returns it as a distinct field; nil
          # for non-reasoning models or providers that don't expose it.
          # Consumers can render this inline for transparency or hide it
          # depending on the UX — but it must not be silently dropped at the
          # adapter layer, or reasoning-only responses (final content hit
          # max_tokens before the answer began) look empty.
          reasoning_content: String.t() | nil,
          # Claude-style structured thinking blocks. Distinct from
          # :reasoning_content because Claude's blocks carry per-block
          # cryptographic signatures (used for replay across turns) and
          # arrive as a list, not a single string. Populated by the
          # :acp runtime when the Claude CLI emits thinking; nil for
          # everything else.
          thinking: [thinking_block()] | nil,
          # Provider's session handle when one is durably exposed. The
          # :acp runtime populates this from the ACP prompt response's
          # `sessionId` field, letting callers correlate responses with
          # the underlying Claude SDK session (audit, telemetry,
          # caller-driven --resume). nil for runtimes / providers
          # without a session concept.
          session_id: String.t() | nil,
          finish_reason: finish_reason(),
          content_parts: [ContentPart.part()],
          usage: map(),
          warnings: [String.t()],
          raw: map() | nil,
          provider_receipt: ProviderReceipt.t() | nil
        }

  defstruct text: "",
            reasoning_content: nil,
            thinking: nil,
            session_id: nil,
            finish_reason: :stop,
            content_parts: [],
            usage: %{},
            warnings: [],
            raw: nil,
            provider_receipt: nil
end
