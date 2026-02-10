defmodule Arbor.Orchestrator.UnifiedLLM.Request do
  @moduledoc false

  alias Arbor.Orchestrator.UnifiedLLM.Message

  @type t :: %__MODULE__{
          provider: String.t() | nil,
          model: String.t(),
          messages: [Message.t()],
          tools: [map()],
          tool_choice: String.t() | nil,
          max_tokens: integer() | nil,
          temperature: float() | nil,
          reasoning_effort: String.t() | nil,
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
            provider_options: %{}
end
