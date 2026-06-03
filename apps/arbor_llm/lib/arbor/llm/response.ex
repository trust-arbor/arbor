defmodule Arbor.LLM.Response do
  @moduledoc false

  alias Arbor.LLM.ContentPart

  @type finish_reason :: :stop | :length | :tool_calls | :content_filter | :error | :other

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
          finish_reason: finish_reason(),
          content_parts: [ContentPart.part()],
          usage: map(),
          warnings: [String.t()],
          raw: map() | nil
        }

  defstruct text: "",
            reasoning_content: nil,
            finish_reason: :stop,
            content_parts: [],
            usage: %{},
            warnings: [],
            raw: nil
end
