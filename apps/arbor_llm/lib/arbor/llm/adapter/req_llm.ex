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

  @impl true
  @spec embed(texts :: [String.t()], model :: String.t(), opts :: keyword()) ::
          {:ok,
           %{embeddings: [[float()]], model: String.t(), usage: map(), dimensions: pos_integer()}}
          | {:error, term()}
  def embed(texts, model, opts) when is_list(texts) and is_binary(model) do
    arbor_provider = Keyword.get(opts, :provider) || infer_provider_for_embedding(model)

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
          {:ok, Atom.to_string(atom) <> ":" <> model}
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

    base =
      []
      |> maybe_put(:temperature, request.temperature)
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
    |> maybe_merge(:provider_options, Keyword.get(opts, :provider_options))
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
      # Default production pipeline: just call req_llm. Tests override
      # via app config to insert Replay, Record, StalenessWarn, etc.
      Arbor.LLM.Plugs.Dispatch
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

  # Error translation moved to `Arbor.LLM.Plugs.Dispatch` (Session 8,
  # plug pipeline refactor). Adapter no longer catches dispatch
  # exceptions directly — the Dispatch plug handles them and stamps
  # `{:error, ProviderError | RequestTimeoutError}` on the call's
  # result field.
end
