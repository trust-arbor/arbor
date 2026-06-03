defmodule Arbor.LLM.Request do
  @moduledoc false

  alias Arbor.LLM.Message

  @type t :: %__MODULE__{
          provider: String.t() | nil,
          model: String.t(),
          messages: [Message.t()],
          tools: [map()],
          tool_choice: String.t() | nil,
          max_tokens: integer() | nil,
          temperature: float() | nil,
          reasoning_effort: String.t() | nil,
          receive_timeout: pos_integer() | nil,
          provider_options: map()
        }

  defstruct provider: nil,
            model: "",
            messages: [],
            tools: [],
            tool_choice: nil,
            max_tokens: nil,
            temperature: nil,
            reasoning_effort: nil,
            # nil → use req_llm default (30s for openai-compatible providers).
            # Required for slower local models or long tool-use turns; the
            # default cuts off well-formed responses that haven't streamed
            # yet from cold/large quants.
            receive_timeout: nil,
            provider_options: %{}
end
