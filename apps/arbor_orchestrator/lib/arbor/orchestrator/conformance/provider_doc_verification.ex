defmodule Arbor.Orchestrator.Conformance.ProviderDocVerification do
  @moduledoc """
  Tracks explicit verification passes against official provider documentation
  for Unified LLM rows marked as implemented in the conformance matrix.
  """

  @sdk_sources [
    "apps/arbor_orchestrator/specs/provider_docs/openai_responses_from_openai_node_sdk_2026-02-09.md",
    "apps/arbor_orchestrator/specs/provider_docs/anthropic_messages_from_typescript_sdk_2026-02-09.md",
    "apps/arbor_orchestrator/specs/provider_docs/google_generate_content_from_js_genai_sdk_2026-02-09.md"
  ]

  @verified %{
    "8.1" => %{
      checked_on: ~D[2026-02-09],
      sources:
        [
          "https://platform.openai.com/docs/api-reference/responses/create",
          "https://docs.claude.com/en/api/messages",
          "https://ai.google.dev/api/generate-content"
        ] ++ @sdk_sources,
      notes:
        "Core client/provider resolution remains compatible with native provider API usage and auth flow expectations."
    },
    "8.3" => %{
      checked_on: ~D[2026-02-09],
      sources:
        [
          "https://platform.openai.com/docs/api-reference/responses/create",
          "https://docs.claude.com/en/api/messages",
          "https://ai.google.dev/api/generate-content"
        ] ++ @sdk_sources,
      notes:
        "Content-part model aligns with text/image/tool/thinking structures across providers; minor provider quirks are tracked in partial rows."
    },
    "8.2" => %{
      checked_on: ~D[2026-02-09],
      sources:
        [
          "https://platform.openai.com/docs/api-reference/responses/create",
          "https://docs.claude.com/en/api/messages",
          "https://ai.google.dev/api/generate-content"
        ] ++ @sdk_sources,
      notes:
        "Provider adapters use native APIs, support complete/stream paths, provider options, beta headers, role translation, and error mapping."
    },
    "4.2" => %{
      checked_on: ~D[2026-02-09],
      sources:
        [
          "https://platform.openai.com/docs/api-reference/responses-streaming",
          "https://docs.claude.com/en/api/messages-streaming",
          "https://ai.google.dev/api/generate-content#method:-models.streamgeneratecontent"
        ] ++ @sdk_sources,
      notes:
        "Adapter stream paths now emit normalized stream events for all providers; translation remains intentionally minimal while 8.2 stays partial."
    },
    "8.5" => %{
      checked_on: ~D[2026-02-09],
      sources:
        [
          "https://platform.openai.com/docs/guides/reasoning",
          "https://docs.claude.com/en/docs/build-with-claude/extended-thinking",
          "https://ai.google.dev/gemini-api/docs/thinking"
        ] ++ @sdk_sources,
      notes:
        "Reasoning-token usage is mapped for OpenAI/Gemini and represented via thinking content parts for Anthropic with estimation."
    },
    "8.8" => %{
      checked_on: ~D[2026-02-09],
      sources:
        [
          "https://platform.openai.com/docs/guides/error-codes",
          "https://docs.claude.com/en/api/errors",
          "https://ai.google.dev/gemini-api/docs/troubleshooting"
        ] ++ @sdk_sources,
      notes:
        "Provider errors map retryability and retry-after; retry utility honors retry-after limits and low-level complete/stream avoid automatic retries."
    },
    "8.7" => %{
      checked_on: ~D[2026-02-09],
      sources:
        [
          "https://platform.openai.com/docs/guides/function-calling",
          "https://docs.claude.com/en/docs/build-with-claude/tool-use",
          "https://ai.google.dev/gemini-api/docs/function-calling"
        ] ++ @sdk_sources,
      notes:
        "Tool loop supports active/passive behavior, bounded rounds, parallel batching, unknown tool error results, and provider-specific tool result translation."
    },
    "8.4" => %{
      checked_on: ~D[2026-02-09],
      sources:
        [
          "https://platform.openai.com/docs/api-reference/responses/create",
          "https://docs.claude.com/en/api/messages",
          "https://ai.google.dev/api/generate-content"
        ] ++ @sdk_sources,
      notes:
        "High-level generation now covers prompt/messages normalization, complete+stream+stream_object paths, schema-backed object parsing, timeout/abort controls, multi-step streaming tool continuity, and initial stream-setup retries without retrying partial streams."
    }
  }

  @spec all() :: %{String.t() => map()}
  def all, do: @verified

  @spec get(String.t()) :: map() | nil
  def get(id), do: Map.get(@verified, id)
end
