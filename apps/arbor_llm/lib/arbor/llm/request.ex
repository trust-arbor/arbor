defmodule Arbor.LLM.Request do
  @moduledoc false

  alias Arbor.LLM.Message

  @type t :: %__MODULE__{
          provider: String.t() | nil,
          model: String.t(),
          messages: [Message.t()],
          tools: [map()],
          tool_choice: String.t() | map() | nil,
          max_tokens: integer() | nil,
          temperature: float() | nil,
          top_p: float() | nil,
          reasoning_effort: String.t() | nil,
          receive_timeout: pos_integer() | nil,
          provider_options: map(),
          runtime: atom()
        }

  defstruct provider: nil,
            model: "",
            messages: [],
            tools: [],
            tool_choice: nil,
            max_tokens: nil,
            temperature: nil,
            top_p: nil,
            reasoning_effort: nil,
            # nil → use req_llm default (30s for openai-compatible providers).
            # Required for slower local models or long tool-use turns; the
            # default cuts off well-formed responses that haven't streamed
            # yet from cold/large quants.
            receive_timeout: nil,
            provider_options: %{},
            # Runtime axis — :arbor (in-BEAM HTTP via req_llm) or :acp
            # (subprocess CLI via AcpPool). Arbor.AI.Runtime.Registry
            # dispatches to the corresponding adapter module. Defaults to
            # :arbor so existing call sites continue to flow through the
            # BEAM-native path unchanged. New consumers (Dispatch.dispatch,
            # the /runtime slash command, ChatLive after the dropdown
            # removal) set this explicitly. See .arbor/decisions/
            # 2026-06-04-slash-commands-for-runtime-config.md for context.
            runtime: :arbor
end
