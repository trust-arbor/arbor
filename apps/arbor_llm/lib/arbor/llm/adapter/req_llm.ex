defmodule Arbor.LLM.Adapter.ReqLLM do
  @moduledoc """
  Generic LLM adapter that delegates transport to the upstream
  `req_llm` library.

  Replaces — eventually, in Session 4 — the 12 per-provider HTTP
  adapter modules under `Arbor.Orchestrator.UnifiedLLM.Adapters.*`.
  Provider routing happens inside req_llm via the model-spec string
  (`"anthropic:claude-3-5-sonnet"`, `"openai:gpt-4o"`,
  `"openai:llama-3.2-3b-instruct"` with `base_url:` override for
  local LMs), so a single adapter module covers everything req_llm
  knows about — currently 19 providers including Bedrock, Vertex,
  Azure, OpenRouter, the cloud usuals, and OpenAI-compatible
  endpoints behind `base_url`.

  ## Session 3 status

  This module ships as a standalone, fully-tested adapter that
  implements the `Arbor.LLM.ProviderAdapter` behaviour. **It is NOT
  yet wired into `Arbor.LLM.Client` routing** — the existing
  per-provider adapters still handle live traffic. Session 4 will:

    1. Teach `Client.discover_env_adapters/1` to map provider strings
       to this adapter as the default when no per-provider override
       is registered, and
    2. Delete the 11 cloud/local adapter modules and
       `openai_compatible.ex` from arbor_orchestrator.

  Until then, you can exercise this adapter directly:

      iex> req = %Arbor.LLM.Request{provider: "anthropic", model: "claude-3-5-sonnet", messages: [...]}
      iex> Arbor.LLM.Adapter.ReqLLM.complete(req, [])

  ## What this adapter handles

  | Concern | Where |
  |---|---|
  | Provider routing | model-spec string `provider:model` → req_llm provider registry |
  | HTTP, auth, retry, SSE parsing | req_llm |
  | `base_url:` override (Ollama, LM Studio, vLLM) | passed through `opts` |
  | `provider_options:` passthrough (`num_ctx`, `repeat_penalty`, etc.) | passed through `opts` |
  | `reasoning_content` field extraction | `Arbor.LLM.PostProcessors` |
  | Wrapped-JSON envelope extraction (gpt-oss-heretic et al) | `Arbor.LLM.PostProcessors` |
  | `Arbor.LLM.Request` ↔ `ReqLLM.Message` translation | `translate_messages/1` here |
  | `ReqLLM.Response` → `Arbor.LLM.Response` translation | `translate_response/2` here |

  ## Streaming and embeddings

  Streaming and embeddings are stubbed `{:error, :not_implemented}`
  in Session 3 — they land in a follow-up session alongside the
  per-provider-adapter deletion. The existing per-provider adapters
  continue to serve streaming and embedding requests until then.
  """

  @behaviour Arbor.LLM.ProviderAdapter

  alias Arbor.Contracts.AI.{Capabilities, RuntimeContract}
  alias Arbor.LLM.ContentPart
  alias Arbor.LLM.Message
  alias Arbor.LLM.PostProcessors
  alias Arbor.LLM.ProviderError
  alias Arbor.LLM.Request
  alias Arbor.LLM.RequestTimeoutError
  alias Arbor.LLM.Response

  @sentinel_provider "req_llm_generic"

  # ── Behaviour callbacks ─────────────────────────────────────────────

  @impl true
  def provider, do: @sentinel_provider

  @impl true
  def runtime_contract do
    {:ok, contract} =
      RuntimeContract.new(
        provider: @sentinel_provider,
        display_name: "ReqLLM (generic)",
        type: :api,
        capabilities:
          Capabilities.new(
            streaming: false,
            tool_calls: false,
            thinking: true,
            vision: false
          )
      )

    contract
  end

  @impl true
  @spec complete(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def complete(%Request{} = request, opts \\ []) do
    with {:ok, model_spec} <- build_model_spec(request),
         messages <- translate_messages(request.messages),
         req_opts <- build_req_opts(request, opts),
         {:ok, %ReqLLM.Response{} = resp} <- call_req_llm(model_spec, messages, req_opts) do
      {:ok, translate_response(resp, request)}
    end
  end

  @impl true
  def stream(%Request{} = _request, _opts), do: {:error, :not_implemented}

  @impl true
  def embed(_texts, _model, _opts), do: {:error, :not_implemented}

  # ── Translation: Arbor → ReqLLM ─────────────────────────────────────

  @doc """
  Build the `"provider:model"` string req_llm expects.

  Public for testability — production code goes through `complete/2`.
  """
  @spec build_model_spec(Request.t()) :: {:ok, String.t()} | {:error, term()}
  def build_model_spec(%Request{provider: nil}),
    do: {:error, {:invalid_request, :missing_provider}}

  def build_model_spec(%Request{model: nil}),
    do: {:error, {:invalid_request, :missing_model}}

  def build_model_spec(%Request{provider: provider, model: model})
      when is_binary(provider) and is_binary(model) do
    {:ok, provider <> ":" <> model}
  end

  @doc """
  Translate Arbor `Message` structs into req_llm-shaped messages.

  req_llm's `generate_text/3` accepts a list of `%ReqLLM.Message{}`
  structs (or, equivalently, the `Context.user/assistant/system/tool`
  helpers). For text-only content we go through the helpers — they
  normalize `String.t() | [ContentPart.t()]` content for us. For
  structured content (already a list of parts), we pass the list
  straight through.

  Public for testability.
  """
  @spec translate_messages([Message.t()]) :: [ReqLLM.Message.t()]
  def translate_messages(messages) when is_list(messages) do
    Enum.map(messages, &translate_message/1)
  end

  defp translate_message(%Message{role: role, content: content} = msg) do
    case role do
      :user ->
        ReqLLM.Context.user(content)

      :assistant ->
        ReqLLM.Context.assistant(content)

      :system ->
        ReqLLM.Context.system(content)

      :developer ->
        ReqLLM.Context.system(content)

      :tool ->
        # ReqLLM.Context doesn't expose a tool/1 helper; the tool_call_id
        # lives in the Arbor message metadata. Build the ReqLLM.Message
        # struct directly so we preserve it for the provider's
        # tool-response shape.
        tool_call_id =
          Map.get(msg.metadata, "tool_call_id") || Map.get(msg.metadata, :tool_call_id)

        %ReqLLM.Message{
          role: :tool,
          content: List.wrap(content),
          tool_call_id: tool_call_id
        }
    end
  end

  @doc """
  Build the keyword opts req_llm accepts.

  We forward the standard generation knobs and any caller-supplied
  `base_url:` / `provider_options:` overrides. Public for testability.
  """
  @spec build_req_opts(Request.t(), keyword()) :: keyword()
  def build_req_opts(%Request{} = request, opts) do
    request_provider_opts =
      case request.provider_options do
        m when is_map(m) and map_size(m) > 0 -> Map.to_list(m)
        _ -> nil
      end

    base =
      []
      |> maybe_put(:temperature, request.temperature)
      |> maybe_put(:max_tokens, request.max_tokens)
      |> maybe_put(:reasoning_effort, request.reasoning_effort)
      |> maybe_put(:provider_options, request_provider_opts)

    base
    |> maybe_merge(:base_url, Keyword.get(opts, :base_url))
    |> maybe_merge(:provider_options, Keyword.get(opts, :provider_options))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_merge(opts, _key, nil), do: opts
  defp maybe_merge(opts, key, value), do: Keyword.put(opts, key, value)

  # ── Dispatch ────────────────────────────────────────────────────────

  defp call_req_llm(model_spec, messages, opts) do
    ReqLLM.generate_text(model_spec, messages, opts)
  rescue
    e -> {:error, translate_exception(e)}
  catch
    :exit, reason -> {:error, translate_exit(reason)}
  end

  # ── Translation: ReqLLM → Arbor ─────────────────────────────────────

  @doc """
  Translate a successful `ReqLLM.Response` into `Arbor.LLM.Response`.

  Runs `PostProcessors.parse_structured/1` against the assistant
  message so any provider's response benefits from reasoning_content
  extraction and wrapped-JSON envelope handling. Public for
  testability.
  """
  @spec translate_response(ReqLLM.Response.t(), Request.t()) :: Response.t()
  def translate_response(%ReqLLM.Response{} = req_response, %Request{} = _request) do
    text = ReqLLM.Response.text(req_response) || ""
    finish_reason = translate_finish_reason(req_response.finish_reason)

    msg_for_post = %{
      "content" => text,
      "reasoning_content" => extract_reasoning_text(req_response),
      "reasoning" => nil
    }

    content_parts =
      case PostProcessors.parse_structured(msg_for_post) do
        nil -> [ContentPart.text(text)]
        parts -> parts
      end

    %Response{
      text: text,
      finish_reason: finish_reason,
      content_parts: content_parts,
      usage: translate_usage(req_response.usage),
      warnings: [],
      raw: %{req_llm_response: req_response}
    }
  end

  defp extract_reasoning_text(%ReqLLM.Response{message: nil}), do: nil

  defp extract_reasoning_text(%ReqLLM.Response{message: %ReqLLM.Message{reasoning_details: nil}}),
    do: nil

  defp extract_reasoning_text(%ReqLLM.Response{
         message: %ReqLLM.Message{reasoning_details: details}
       })
       when is_list(details) do
    details
    |> Enum.map(fn %ReqLLM.Message.ReasoningDetails{text: text} -> text end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> case do
      "" -> nil
      joined -> joined
    end
  end

  defp extract_reasoning_text(_), do: nil

  defp translate_finish_reason(nil), do: :stop
  defp translate_finish_reason(:stop), do: :stop
  defp translate_finish_reason(:length), do: :length
  defp translate_finish_reason(:tool_calls), do: :tool_calls
  defp translate_finish_reason(:content_filter), do: :content_filter
  defp translate_finish_reason(:error), do: :error
  defp translate_finish_reason(_), do: :other

  defp translate_usage(nil), do: %{}

  defp translate_usage(usage) when is_map(usage) do
    # ReqLLM.Usage canonical keys: input_tokens, output_tokens, total_tokens.
    # Forward as-is plus map to Arbor's historical aliases.
    Map.merge(usage, %{
      input_tokens: Map.get(usage, :input_tokens),
      output_tokens: Map.get(usage, :output_tokens),
      total_tokens: Map.get(usage, :total_tokens)
    })
  end

  # ── Error translation ──────────────────────────────────────────────

  defp translate_exception(%{__struct__: mod} = e)
       when mod in [ReqLLM.Error.API.Request, ReqLLM.Error.API.Response] do
    status = Map.get(e, :status)

    ProviderError.exception(
      message: Exception.message(e),
      status: status,
      retryable: retryable_status?(status),
      details: %{source: :req_llm, raw: inspect(e)}
    )
  end

  defp translate_exception(e) do
    ProviderError.exception(
      message: Exception.message(e),
      retryable: false,
      details: %{source: :req_llm, raw: inspect(e)}
    )
  end

  defp translate_exit({:timeout, _}) do
    RequestTimeoutError.exception(message: "request timed out")
  end

  defp translate_exit(reason) do
    ProviderError.exception(
      message: "request exited: " <> inspect(reason),
      retryable: false,
      details: %{source: :req_llm, raw: inspect(reason)}
    )
  end

  defp retryable_status?(status) when status in [408, 429, 500, 502, 503, 504], do: true
  defp retryable_status?(_), do: false
end
