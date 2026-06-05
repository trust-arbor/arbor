defmodule Arbor.LLM.Response do
  @moduledoc false

  alias Arbor.LLM.ContentPart

  @type finish_reason :: :stop | :length | :tool_calls | :content_filter | :error | :other

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
          raw: map() | nil
        }

  defstruct text: "",
            reasoning_content: nil,
            thinking: nil,
            session_id: nil,
            finish_reason: :stop,
            content_parts: [],
            usage: %{},
            warnings: [],
            raw: nil
end
