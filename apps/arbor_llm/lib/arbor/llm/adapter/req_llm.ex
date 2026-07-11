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

  ## Session 4 status

  This module reached capability parity with the per-provider adapters
  it will replace. **It is NOT yet wired into `Arbor.LLM.Client`
  routing** — the existing per-provider adapters still handle live
  traffic. The next session will:

    1. Teach `Client.discover_env_adapters/1` to map provider strings
       to this adapter as the default when no per-provider override
       is registered, and
    2. Delete the 11 cloud/local adapter modules and
       `openai_compatible.ex` from arbor_orchestrator.

  Until then, exercise this adapter directly:

      iex> req = %Arbor.LLM.Request{provider: "anthropic", model: "claude-3-5-sonnet", messages: [...]}
      iex> Arbor.LLM.Adapter.ReqLLM.complete(req, [])

  ## What this adapter handles

  | Concern | Where |
  |---|---|
  | Provider routing | model-spec string `provider:model` → req_llm provider registry |
  | HTTP, auth, retry, SSE parsing | req_llm |
  | `base_url:` override (Ollama, LM Studio, vLLM) | passed through `opts` |
  | `provider_options:` passthrough (`num_ctx`, `repeat_penalty`, etc.) | passed through `opts` |
  | Tool calls (encode + decode) | `translate_tools/1` + `extract_tool_call_parts/1` here |
  | Streaming (`stream/2`) | `ReqLLM.stream_text/3` + `translate_stream_chunk/1` |
  | Embeddings (`embed/3`) | `ReqLLM.Embedding.embed/3` |
  | `reasoning_content` field extraction | `Arbor.LLM.PostProcessors` |
  | Wrapped-JSON envelope extraction (gpt-oss-heretic et al) | `Arbor.LLM.PostProcessors` |
  | `Arbor.LLM.Request` ↔ `ReqLLM.Message` translation | `translate_messages/1` here |
  | `ReqLLM.Response` → `Arbor.LLM.Response` translation | `translate_response/2` here |

  Structured output (`Arbor.LLM.generate_object/1`) is built on top of
  `complete/2` at the facade layer, so it works for free.
  """

  @behaviour Arbor.LLM.ProviderAdapter

  alias Arbor.Contracts.AI.{Capabilities, RuntimeContract}
  alias Arbor.LLM.ContentPart
  alias Arbor.LLM.Message
  alias Arbor.LLM.PostProcessors
  alias Arbor.LLM.Call
  alias Arbor.LLM.Pipeline
  alias Arbor.LLM.ProviderRegistry
  alias Arbor.LLM.Request
  alias Arbor.LLM.Response

  @sentinel_provider "req_llm_generic"

  # ── Behaviour callbacks ─────────────────────────────────────────────

  @impl true
  def provider, do: @sentinel_provider

  @impl true
  def runtime_contract do
    # The generic adapter inherits whatever capabilities req_llm's
    # provider for the model_spec actually supports. We advertise the
    # union of what every provider req_llm currently knows about
    # supports — callers that need provider-specific capability checks
    # should consult `Arbor.LLM.ProviderCatalog` for the resolved
    # capability map per provider, not this aggregate.
    {:ok, contract} =
      RuntimeContract.new(
        provider: @sentinel_provider,
        display_name: "ReqLLM (generic)",
        type: :api,
        capabilities:
          Capabilities.new(
            streaming: true,
            tool_calls: true,
            thinking: true,
            vision: true,
            structured_output: true,
            embeddings: true
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
  @spec stream(Request.t(), keyword()) :: Enumerable.t() | {:error, term()}
  def stream(%Request{} = request, opts \\ []) do
    with {:ok, model_spec} <- build_model_spec(request),
         messages <- translate_messages(request.messages),
         req_opts <- build_req_opts(request, opts),
         {:ok, %ReqLLM.StreamResponse{stream: stream}} <-
           call_req_llm_stream(model_spec, messages, req_opts) do
      Stream.map(stream, &translate_stream_chunk/1)
    end
  end

  @doc """
  Stream tokens via `callback` AND return the fully-assembled response.

  The lazy `stream/2` path surfaces tool-call *names* but not their *arguments*
  (in streaming, ReqLLM emits the tool-call chunk without assembled args — they
  only land in `StreamResponse`'s reconstructed message). So a tool loop that
  streams would get empty-argument tool calls.

  `ReqLLM.StreamResponse.process_stream/2` consumes the stream exactly once,
  fires `on_result`/`on_thinking` for real-time deltas, and returns a complete
  `%ReqLLM.Response{}` whose `message.tool_calls` carry full arguments — which
  `translate_response/2` turns into proper tool_call content parts. `callback`
  receives `%Arbor.LLM.StreamEvent{}` values, matching the lazy-stream contract.
  """
  @spec complete_streaming(Request.t(), (Arbor.LLM.StreamEvent.t() -> any()), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def complete_streaming(%Request{} = request, callback, opts \\ [])
      when is_function(callback, 1) do
    # Accumulate the thinking deltas: ReqLLM's process_stream forwards them to
    # on_thinking but does NOT retain the full chain-of-thought on the assembled
    # response (streaming captured only the first fragment, e.g. "Thinking"),
    # whereas the non-streaming path returns it in full. Collect via the mailbox
    # (process_stream is synchronous, so all deltas have arrived by the time it
    # returns) and restore the full reasoning below.
    collector = self()

    with {:ok, model_spec} <- build_model_spec(request),
         messages <- translate_messages(request.messages),
         req_opts <- build_req_opts(request, opts),
         {:ok, %ReqLLM.StreamResponse{} = stream_response} <-
           call_req_llm_stream(model_spec, messages, req_opts),
         {:ok, %ReqLLM.Response{} = resp} <-
           ReqLLM.StreamResponse.process_stream(stream_response,
             on_result: fn text ->
               callback.(%Arbor.LLM.StreamEvent{type: :delta, data: %{text: text}})
             end,
             on_thinking: fn text ->
               send(collector, {:arbor_reasoning_delta, text})
               callback.(%Arbor.LLM.StreamEvent{type: :delta, data: %{thinking: text}})
             end
           ) do
      reasoning = flush_reasoning_deltas([])
      translated = translate_response(resp, request)

      translated =
        if String.length(reasoning) > String.length(translated.reasoning_content || "") do
          %{translated | reasoning_content: reasoning}
        else
          translated
        end

      {:ok, translated}
    end
  end

  # Drain accumulated thinking deltas from the mailbox (all present once
  # process_stream has returned). Unique tag so it can't collide with other
  # messages in the calling process.
  defp flush_reasoning_deltas(acc) do
    receive do
      {:arbor_reasoning_delta, text} -> flush_reasoning_deltas([text | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("")
    end
  end

  @impl true
  @spec embed(texts :: [String.t()], model :: String.t(), opts :: keyword()) ::
          {:ok,
           %{embeddings: [[float()]], model: String.t(), usage: map(), dimensions: pos_integer()}}
          | {:error, term()}
  def embed(texts, model, opts) when is_list(texts) and is_binary(model) do
    arbor_provider = resolve_embed_provider(opts, model)

    cond do
      arbor_provider == nil ->
        {:error, {:invalid_request, :missing_provider_for_embedding}}

      texts == [] ->
        {:error, {:invalid_request, :empty_input}}

      true ->
        # Same struct-vs-string split as build_model_spec/1 — local
        # LMs bypass the catalog because operator-pulled embedding
        # models like `nomic-embed-text` aren't in llm_db.
        case build_embed_model_spec(arbor_provider, model) do
          {:ok, model_spec} ->
            do_embed(arbor_provider, model_spec, texts, opts)

          {:error, _} = err ->
            err
        end
    end
  end

  # Normalize the embed provider to its canonical arbor_llm string (e.g. the
  # `:lmstudio` atom from the arbor_ai option format → "lm_studio") BEFORE it
  # flows to `ProviderRegistry` / `default_base_url_for/1`, which are binary-only.
  # The generate_text path normalizes at its dispatch boundary; the embed path
  # read `opts[:provider]` raw, so an atom provider crashed
  # `default_base_url_for/1` with a FunctionClauseError — flooding the log on
  # every memory embed. `nil` stays `nil` so the missing-provider branch fires.
  defp resolve_embed_provider(opts, model) do
    case Keyword.get(opts, :provider) || infer_provider_for_embedding(model) do
      nil -> nil
      provider -> ProviderRegistry.normalize(provider)
    end
  end

  defp build_embed_model_spec(arbor_provider, model) do
    if ProviderRegistry.local?(arbor_provider) do
      build_local_model_struct(arbor_provider, model)
    else
      atom = ProviderRegistry.req_llm_atom(arbor_provider) || String.to_atom(arbor_provider)
      {:ok, Atom.to_string(atom) <> ":" <> model}
    end
  end

  defp do_embed(arbor_provider, model_spec, texts, opts) do
    req_opts = build_embed_opts(arbor_provider, opts)

    case call_req_llm_embed(model_spec, texts, req_opts) do
      {:ok, embeddings, usage} when is_list(embeddings) ->
        {:ok,
         %{
           embeddings: embeddings,
           model: model_spec,
           usage: usage || %{},
           dimensions: dimensions_of(embeddings)
         }}

      {:error, _} = err ->
        err
    end
  end

  defp build_embed_opts(arbor_provider, opts) do
    # Same local-LM base_url defaulting as build_req_opts/2 — Ollama
    # serves embeddings at the OpenAI-compatible /v1/embeddings endpoint
    # so the openai-via-base_url-override routing applies identically.
    caller_base_url = Keyword.get(opts, :base_url)
    inferred_base_url = caller_base_url || default_base_url_for(arbor_provider)

    []
    |> maybe_merge(:base_url, inferred_base_url)
    |> maybe_merge(:api_key, local_api_key(arbor_provider, opts))
    |> maybe_merge(:provider_options, Keyword.get(opts, :provider_options))
    |> maybe_merge(:dimensions, Keyword.get(opts, :dimensions))
  end

  defp call_req_llm_embed(%LLMDB.Model{} = model, texts, opts) do
    run_pipeline(:embed_local, {model, texts, opts})
  end

  defp call_req_llm_embed(model_spec, texts, opts) when is_binary(model_spec) do
    run_pipeline(:embed_cloud, {model_spec, texts, opts})
  end

  defp dimensions_of([first | _]) when is_list(first), do: length(first)
  defp dimensions_of(_), do: 0

  # The embedding endpoint requires a provider, but `Arbor.LLM.Request`
  # isn't used here (the ProviderAdapter behaviour passes texts + model
  # directly). For OpenAI-compatible local servers, callers should pass
  # `provider:` in opts; for cloud providers, the model_id often
  # encodes the provider (e.g. `voyage-large-2`) — leave that to a
  # future improvement and require explicit `provider:` for now.
  defp infer_provider_for_embedding(_model), do: nil

  defp call_req_llm_stream(model_spec, messages, opts) do
    run_pipeline(:stream, {model_spec, messages, opts})
  end

  # ── Streaming translation ──────────────────────────────────────────

  @doc """
  Translate a single `%ReqLLM.StreamChunk{}` into an
  `%Arbor.LLM.StreamEvent{}`. Public for testability.
  """
  @spec translate_stream_chunk(ReqLLM.StreamChunk.t()) :: Arbor.LLM.StreamEvent.t()
  def translate_stream_chunk(%ReqLLM.StreamChunk{} = chunk) do
    case chunk.type do
      :content ->
        %Arbor.LLM.StreamEvent{type: :delta, data: %{text: chunk.text || ""}}

      :thinking ->
        %Arbor.LLM.StreamEvent{type: :delta, data: %{thinking: chunk.text || ""}}

      :tool_call ->
        %Arbor.LLM.StreamEvent{
          type: :tool_call,
          data: %{name: chunk.name, arguments: chunk.arguments || %{}}
        }

      :meta ->
        %Arbor.LLM.StreamEvent{type: :step_finish, data: chunk.metadata || %{}}

      _ ->
        %Arbor.LLM.StreamEvent{type: :delta, data: %{raw: chunk}}
    end
  end

  # ── Translation: Arbor → ReqLLM ─────────────────────────────────────

  @doc """
  Build the model_spec req_llm expects.

  For cloud providers we return a `"provider:model"` string, which
  triggers `ReqLLM.model/1`'s llm_db catalog lookup — that's how
  pricing and capability metadata get attached to the response. For
  local-LM Arbor providers (lm_studio, ollama) we construct an
  `LLMDB.Model` struct directly because llm_db's catalog doesn't know
  about arbitrary operator-pulled models like `nomic-embed-text` or
  `llama-3.2-3b`. Without the struct path, `ReqLLM.model("openai:nomic-embed-text")`
  returns `{:error, :not_found}` and dispatch fails before reaching
  the network.

  Public for testability — production code goes through `complete/2`.
  """
  @spec build_model_spec(Request.t()) :: {:ok, String.t() | LLMDB.Model.t()} | {:error, term()}
  def build_model_spec(%Request{provider: nil}),
    do: {:error, {:invalid_request, :missing_provider}}

  def build_model_spec(%Request{model: nil}),
    do: {:error, {:invalid_request, :missing_model}}

  def build_model_spec(%Request{provider: provider, model: model})
      when is_binary(provider) and is_binary(model) do
    if ProviderRegistry.local?(provider) do
      build_local_model_struct(provider, model)
    else
      case ProviderRegistry.req_llm_atom(provider) do
        nil ->
          # Unknown provider — pass through unchanged so an operator
          # can use a provider req_llm knows about that we haven't
          # mapped explicitly (e.g. amazon_bedrock, azure, groq).
          {:ok, provider <> ":" <> model}

        atom ->
          spec = Atom.to_string(atom) <> ":" <> model

          # The catalog lookup attaches pricing/capability metadata — but its
          # snapshot lags fresh releases, so a just-launched slug (e.g. a new
          # OpenRouter model) returns {:error, :not_found} and dispatch fails
          # before the network. Fall back to a bare struct (as local providers
          # do) so any provider-served model still runs; the response usage
          # carries the tokens/cost either way.
          case ReqLLM.model(spec) do
            {:ok, _} -> {:ok, spec}
            _ -> LLMDB.Model.new(%{id: model, model: model, provider: atom})
          end
      end
    end
  end

  defp build_local_model_struct(arbor_provider, model) do
    atom = ProviderRegistry.req_llm_atom(arbor_provider)

    # The schema requires `id`, `model`, and `provider`. Everything
    # else is nullish — that's what we want for local LMs since
    # llm_db has no pricing or capability metadata for them.
    LLMDB.Model.new(%{
      id: model,
      model: model,
      provider: atom
    })
  end

  @doc """
  Look up the default base_url for a local-LM Arbor provider.

  Returns the operator-configured value when set
  (`config :arbor_orchestrator, <provider>, base_url: ...`), the
  hardcoded default otherwise, or `nil` if the provider isn't a
  local-LM server. Public for testability.
  """
  @spec default_base_url_for(String.t()) :: String.t() | nil
  def default_base_url_for(provider) when is_binary(provider) do
    ProviderRegistry.default_base_url(provider)
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
        ReqLLM.Context.user(reqllm_user_content(content))

      :assistant ->
        translate_assistant_content(content)

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

        # ReqLLM message content must be a list of ContentPart structs (keyed by
        # :type), NOT raw strings — a bare string here raised "expected a map,
        # got: <string>" when encoding the tool-result turn. Wrap the (already
        # sanitized) tool-result text as a ReqLLM text part.
        %ReqLLM.Message{
          role: :tool,
          content: content |> List.wrap() |> Enum.map(&reqllm_text_part/1),
          tool_call_id: tool_call_id
        }
    end
  end

  # Only raw strings need wrapping (the tool-result text that raised "expected a
  # map"). Existing ContentPart structs / maps pass through unchanged, preserving
  # the prior List.wrap behavior for non-string content.
  defp reqllm_text_part(text) when is_binary(text), do: ReqLLM.Message.ContentPart.text(text)
  defp reqllm_text_part(other), do: other

  # A user message's content is either a plain string or a list of Arbor ContentPart
  # maps (multimodal). ReqLLM.Context.user takes the list as-is, so Arbor's kind-keyed
  # maps must be converted to ReqLLM's type-keyed ContentParts first — otherwise they
  # encode to empty content (a 400 "Input must have at least 1 token").
  defp reqllm_user_content(content) when is_binary(content), do: content
  defp reqllm_user_content(parts) when is_list(parts), do: Enum.map(parts, &reqllm_content_part/1)
  defp reqllm_user_content(other), do: other

  defp reqllm_content_part(text) when is_binary(text), do: ReqLLM.Message.ContentPart.text(text)
  defp reqllm_content_part(%ReqLLM.Message.ContentPart{} = p), do: p
  defp reqllm_content_part(%{kind: :text, text: t}), do: ReqLLM.Message.ContentPart.text(t)

  # Arbor's image_base64 stores ALREADY-base64 data; ReqLLM.image/2 base64-encodes
  # its input (expects raw bytes), which would double-encode. Build the data-URI
  # directly as an image_url so the base64 passes through untouched.
  defp reqllm_content_part(%{kind: :image, data: data, media_type: mt}) when is_binary(data),
    do: ReqLLM.Message.ContentPart.image_url("data:#{mt || "image/png"};base64,#{data}")

  defp reqllm_content_part(%{kind: :image, url: url}) when is_binary(url),
    do: ReqLLM.Message.ContentPart.image_url(url)

  defp reqllm_content_part(other), do: other

  # An assistant message is either plain text (from history) OR a list of Arbor
  # content parts (build_assistant_message emits `%{kind: :text}` +
  # `%{kind: :tool_call}` maps for the tool-use continuation). ReqLLM has NO
  # tool_call CONTENT part — tool calls live in the Message's `:tool_calls`
  # field — and ReqLLM content parts are keyed by `:type`, so handing Arbor's
  # `:kind`-keyed maps to `Context.assistant/1` as raw content raised
  # `KeyError :type` on the continuation turn (the text part has no `:type`).
  # Convert: text parts → the content string, tool_call parts → `:tool_calls`.
  defp translate_assistant_content(content) when is_binary(content),
    do: ReqLLM.Context.assistant(content)

  defp translate_assistant_content(parts) when is_list(parts) do
    text =
      parts
      |> Enum.filter(&(Map.get(&1, :kind) == :text))
      |> Enum.map_join("", &(Map.get(&1, :text) || ""))

    tool_calls =
      parts
      |> Enum.filter(&(Map.get(&1, :kind) == :tool_call))
      |> Enum.map(fn tc ->
        {Map.get(tc, :name), Map.get(tc, :arguments), [id: Map.get(tc, :id)]}
      end)

    ReqLLM.Context.assistant(text, tool_calls: tool_calls)
  end

  defp translate_assistant_content(other), do: ReqLLM.Context.assistant(other)

  @doc """
  Build the keyword opts req_llm accepts.

  We forward the standard generation knobs (temperature, max_tokens,
  reasoning_effort), the translated tools list, and any caller-supplied
  `base_url:` / `provider_options:` overrides. Public for testability.
  """
  @spec build_req_opts(Request.t(), keyword()) :: keyword()
  def build_req_opts(%Request{} = request, opts) do
    request_provider_opts =
      case request.provider_options do
        m when is_map(m) and map_size(m) > 0 -> Map.to_list(m)
        _ -> nil
      end

    # kimi k2.x-code/thinking models LOCK sampling params to fixed values and ERROR on any
    # custom value (Moonshot docs). Omit temperature/top_p so the model uses its own defaults.
    # Minimal per-model policy — only kimi behaves this way, so no general seam is warranted.
    {temperature, top_p} =
      if kimi_params_locked?(request.model),
        do: {nil, nil},
        else: {request.temperature, request.top_p}

    base =
      []
      |> maybe_put(:temperature, temperature)
      |> maybe_put(:top_p, top_p)
      |> maybe_put(:max_tokens, request.max_tokens)
      |> maybe_put(:reasoning_effort, request.reasoning_effort)
      |> maybe_put(:receive_timeout, request.receive_timeout)
      |> maybe_put(:provider_options, request_provider_opts)
      |> maybe_put(:tools, translate_tools(request.tools))
      |> maybe_put(:tool_choice, translate_tool_choice(request.tool_choice))

    # Caller-supplied base_url wins. Otherwise, if the request is for a
    # local-LM Arbor provider (lm_studio / ollama), inject the
    # configured default so req_llm's openai provider points at
    # localhost instead of api.openai.com.
    caller_base_url = Keyword.get(opts, :base_url)
    inferred_base_url = caller_base_url || default_base_url_for(request.provider)

    base
    |> maybe_merge(:base_url, inferred_base_url)
    |> maybe_merge(:api_key, local_api_key(request.provider, opts))
    |> maybe_merge(:req_http_options, local_req_http_options(request.provider, opts))
    |> maybe_merge(:provider_options, Keyword.get(opts, :provider_options))
    |> maybe_merge(:max_response_bytes, Keyword.get(opts, :max_response_bytes))
  end

  # Disable req's transient-retry for local-LM providers. Retrying a slow
  # local server (e.g. a loaded homelab Ollama) just multiplies a
  # receive_timeout-bounded wait by the retry count, so a 30s timeout can
  # silently become 90s+. req_llm exposes req's knobs under
  # :req_http_options. A caller-supplied value always wins. Returns nil
  # for cloud providers (keep req's default backoff for flaky cloud APIs).
  defp local_req_http_options(provider, opts) do
    cond do
      Keyword.has_key?(opts, :req_http_options) -> Keyword.get(opts, :req_http_options)
      is_binary(provider) and ProviderRegistry.local?(provider) -> [retry: false]
      true -> nil
    end
  end

  # Local-LM servers (Ollama, LM Studio) need no real auth, but req_llm's
  # OpenAI-compatible provider — which we route these through — refuses to
  # dispatch without an :api_key / OPENAI_API_KEY. Inject a harmless
  # placeholder so the call reaches the local base_url. Caller-supplied
  # keys always win. Returns nil for cloud providers (req_llm resolves
  # their real key from the env).
  defp local_api_key(provider, opts) do
    cond do
      Keyword.get(opts, :api_key) -> Keyword.get(opts, :api_key)
      is_binary(provider) and ProviderRegistry.local?(provider) -> "arbor-local"
      true -> nil
    end
  end

  @doc """
  Translate Arbor tool maps (OpenAI nested format) into the
  `%ReqLLM.Tool{}` struct list req_llm expects.

  req_llm's per-provider `prepare_request` calls
  `ReqLLM.Tool.to_schema/2` to convert each struct to provider-specific
  shape (Anthropic input_schema, OpenAI function definition, etc.) —
  passing raw maps bypasses that conversion and breaks tool use for
  every provider except OpenAI chat-completions.

  Callbacks are stubbed: req_llm never invokes them in the
  request → response flow (tool execution happens upstream in our
  `ToolLoop`), so a no-op `fn _ -> {:ok, %{}} end` keeps `Tool.new/1`
  validation happy without affecting behavior. Public for testability.
  """
  @spec translate_tools([map()] | nil) :: [ReqLLM.Tool.t()] | nil
  def translate_tools(nil), do: nil
  def translate_tools([]), do: nil

  def translate_tools(tools) when is_list(tools) do
    tools
    |> Enum.map(&translate_tool/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      list -> list
    end
  end

  defp translate_tool(%{"type" => "function", "function" => function}) when is_map(function) do
    name = function["name"]
    description = function["description"] || ""
    params = function["parameters"] || %{"type" => "object", "properties" => %{}}

    case ReqLLM.Tool.new(
           name: name,
           description: description,
           parameter_schema: params,
           callback: fn _args -> {:ok, %{}} end
         ) do
      {:ok, tool} -> tool
      {:error, _reason} -> nil
    end
  end

  defp translate_tool(_), do: nil

  @doc """
  Translate Arbor's `tool_choice` value to what req_llm's providers
  accept.

  req_llm's openai provider only handles map-shape `tool_choice` — the
  OpenAI-spec strings (`"auto"`, `"none"`, `"required"`) reach
  `translate_tool_choice_format/1` and crash with `BadMapError`. We
  handle them at this boundary:

    * `"auto"` (the default behavior) → `nil` (omit; providers default
      to auto when tools are present, so this is a no-op semantically).
    * `"none"` / `"required"` → `nil` (omit; the caller wanting these
      semantics should clear `tools` or pin to a specific tool
      respectively, both of which the prompt + tool list already
      handle without `tool_choice`).
    * Map shape (e.g. `%{type: "tool", name: "foo"}` or
      OpenAI's `%{"type" => "function", "function" => %{"name" => "foo"}}`)
      → pass through.

  Public for testability.
  """
  @spec translate_tool_choice(String.t() | atom() | map() | nil) :: map() | nil
  def translate_tool_choice(nil), do: nil
  def translate_tool_choice(""), do: nil
  def translate_tool_choice("auto"), do: nil
  def translate_tool_choice(:auto), do: nil
  def translate_tool_choice("none"), do: nil
  def translate_tool_choice(:none), do: nil
  def translate_tool_choice("required"), do: nil
  def translate_tool_choice(:required), do: nil
  def translate_tool_choice(%{} = map), do: map
  def translate_tool_choice(_), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # kimi k2.x (k2.5 / k2.6 / k2.7-code) fix temperature/top_p/penalties and reject any custom
  # value. Kept deliberately narrow — only kimi behaves this way.
  defp kimi_params_locked?(model) when is_binary(model), do: model =~ ~r/kimi-k2/i
  defp kimi_params_locked?(_), do: false

  defp maybe_merge(opts, _key, nil), do: opts
  defp maybe_merge(opts, key, value), do: Keyword.put(opts, key, value)

  # ── Dispatch ────────────────────────────────────────────────────────

  defp call_req_llm(model_spec, messages, opts) do
    run_pipeline(:complete, {model_spec, messages, opts})
  end

  # Single entry point for all four dispatch operations. Each call
  # threads through the configured pipeline, falling through to
  # Plugs.Dispatch (which calls the appropriate req_llm function) if
  # no upstream plug short-circuited. The pipeline is configurable
  # so tests can swap in record-only, replay-only, or transparent
  # variants without touching the adapter.
  defp run_pipeline(operation, request) do
    operation
    |> Call.new(request)
    |> Pipeline.through(pipeline())
    |> Map.fetch!(:result)
  end

  defp pipeline do
    Application.get_env(:arbor_llm, :pipeline, [
      # Default production pipeline:
      #   1. Dispatch — call req_llm and stamp the result.
      #   2. RateLimitBackoff — on HTTP 429 / rate-limit errors, sleep
      #      for retry-after (or exponential backoff) and re-invoke
      #      Dispatch up to N times before bubbling up. Composes with
      #      Dispatch.dispatch/2's fallback chain: backoff handles
      #      "same path, wait a moment" and fallback handles "this
      #      path is exhausted, try a different one."
      #
      # Tests override via app config to insert Replay, Record,
      # StalenessWarn, etc.
      Arbor.LLM.Plugs.ResponseLimit,
      Arbor.LLM.Plugs.Dispatch,
      Arbor.LLM.Plugs.RateLimitBackoff
    ])
  end

  # ── Translation: ReqLLM → Arbor ─────────────────────────────────────

  @doc """
  Translate a successful `ReqLLM.Response` into `Arbor.LLM.Response`.

  The `content_parts` field is built in three layers:

    1. **Tool calls** (if any) from `response.message.tool_calls` are
       promoted to `kind: :tool_call` parts. These flow to the
       orchestrator's `ToolLoop`, which dispatches them.
    2. **Text content** runs through `PostProcessors.parse_structured/1`
       so any provider's response benefits from reasoning_content
       extraction and wrapped-JSON envelope handling.
    3. Tool-call parts come first when present (matches how the
       openai_compatible adapter today orders them); text parts append.

  Public for testability.
  """
  @spec translate_response(ReqLLM.Response.t(), Request.t()) :: Response.t()
  def translate_response(%ReqLLM.Response{} = req_response, %Request{} = _request) do
    text = ReqLLM.Response.text(req_response) || ""
    reasoning_content = extract_reasoning_text(req_response)
    finish_reason = translate_finish_reason(req_response.finish_reason)

    msg_for_post = %{
      "content" => text,
      "reasoning_content" => reasoning_content,
      "reasoning" => nil
    }

    text_parts =
      case PostProcessors.parse_structured(msg_for_post) do
        nil -> [ContentPart.text(text)]
        parts -> parts
      end

    tool_call_parts = extract_tool_call_parts(req_response)

    content_parts = tool_call_parts ++ text_parts

    %Response{
      text: text,
      # Expose chain-of-thought content to downstream consumers. Hidden by
      # default in most rendering paths but available when the UX wants
      # transparency — and critically, NOT silently dropped, which masks
      # reasoning-model responses where final-content tokens got cut off
      # mid-CoT (gemma-4-e4b-it surfaced this on 2026-06-02).
      reasoning_content: reasoning_content,
      finish_reason: finish_reason,
      content_parts: content_parts,
      usage: translate_usage(req_response.usage),
      warnings: [],
      raw: %{req_llm_response: req_response}
    }
  end

  defp extract_tool_call_parts(%ReqLLM.Response{message: nil}), do: []

  defp extract_tool_call_parts(%ReqLLM.Response{message: %ReqLLM.Message{tool_calls: nil}}),
    do: []

  defp extract_tool_call_parts(%ReqLLM.Response{message: %ReqLLM.Message{tool_calls: []}}), do: []

  defp extract_tool_call_parts(%ReqLLM.Response{
         message: %ReqLLM.Message{tool_calls: calls}
       })
       when is_list(calls) do
    Enum.map(calls, &translate_tool_call/1)
  end

  defp translate_tool_call(%ReqLLM.ToolCall{id: id, function: function}) when is_map(function) do
    name = function["name"] || function[:name] || ""
    arguments = function["arguments"] || function[:arguments] || %{}
    ContentPart.tool_call(id, name, arguments)
  end

  # ReqLLM provider may also emit ToolCall-shaped maps directly for
  # protocols where the strict struct doesn't fit (e.g. some
  # OpenAI-compat streaming flows). Handle the loose shape too so a
  # provider quirk doesn't lose tool calls.
  defp translate_tool_call(%{} = call) do
    id = call[:id] || call["id"] || ""
    function = call[:function] || call["function"] || %{}
    name = function[:name] || function["name"] || ""
    arguments = function[:arguments] || function["arguments"] || %{}
    ContentPart.tool_call(id, name, arguments)
  end

  defp translate_tool_call(_), do: nil

  defp extract_reasoning_text(%ReqLLM.Response{message: nil}), do: nil

  defp extract_reasoning_text(%ReqLLM.Response{message: %ReqLLM.Message{} = msg}) do
    # Two upstream paths for chain-of-thought content, depending on the
    # provider's ReqLLM adapter:
    #
    # 1. `message.reasoning_details` — a list of structured
    #    `ReasoningDetails`. Used by providers that surface reasoning
    #    as a separate top-level field (some OpenAI o-series paths,
    #    certain Anthropic flows).
    #
    # 2. `message.content` parts with `type: :thinking` — used by
    #    Ollama for reasoning models like kimi-k2.6:cloud and the
    #    gemma-3-it thinking variants. Pre-fix, this path was silently
    #    dropped — `reasoning_content` ended up nil even though the
    #    model HAD emitted reasoning. Worse, when a reasoning model
    #    exhausted its budget mid-CoT and produced no final `:text`
    #    part, `text` came back "" with no signal as to why.
    #
    # Combine both sources; nil if neither yields text.
    reasoning_from_details(msg) || reasoning_from_thinking_parts(msg)
  end

  defp extract_reasoning_text(_), do: nil

  defp reasoning_from_details(%ReqLLM.Message{reasoning_details: nil}), do: nil

  defp reasoning_from_details(%ReqLLM.Message{reasoning_details: details})
       when is_list(details) do
    details
    |> Enum.map(fn %ReqLLM.Message.ReasoningDetails{text: text} -> text end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> nil_if_blank()
  end

  defp reasoning_from_details(_), do: nil

  defp reasoning_from_thinking_parts(%ReqLLM.Message{content: nil}), do: nil

  defp reasoning_from_thinking_parts(%ReqLLM.Message{content: parts}) when is_list(parts) do
    parts
    |> Enum.filter(fn
      %ReqLLM.Message.ContentPart{type: :thinking} -> true
      _ -> false
    end)
    |> Enum.map(& &1.text)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> nil_if_blank()
  end

  defp reasoning_from_thinking_parts(_), do: nil

  defp nil_if_blank(""), do: nil
  defp nil_if_blank(s) when is_binary(s), do: s

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

  # Error translation moved to `Arbor.LLM.Plugs.Dispatch` (Session 8,
  # plug pipeline refactor). Adapter no longer catches dispatch
  # exceptions directly — the Dispatch plug handles them and stamps
  # `{:error, ProviderError | RequestTimeoutError}` on the call's
  # result field.
end
