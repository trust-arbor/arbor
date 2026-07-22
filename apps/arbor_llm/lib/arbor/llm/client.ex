defmodule Arbor.LLM.Client do
  @moduledoc """
  Minimal unified-llm client scaffold with provider routing and middleware.
  """

  # ToolHooks lives in arbor_orchestrator (which depends on arbor_llm).
  # Compile-time alias would create a cycle. We hold it as a module
  # attribute and dispatch via apply/3 — the variable indirection hides
  # the module from compile-time analysis so no warning fires (per the
  # arbor "Cross-library calls use runtime indirection" pattern).
  @tool_hooks_mod Arbor.Orchestrator.ToolHooks

  alias Arbor.LLM.AbortError

  alias Arbor.LLM.Boundary

  alias Arbor.LLM.ConfigurationError

  alias Arbor.LLM.ContentPart

  alias Arbor.LLM.Deadline

  alias Arbor.LLM.Message

  alias Arbor.LLM.OwnedStream

  alias Arbor.LLM.Request

  alias Arbor.LLM.ResponseBudget

  alias Arbor.LLM.RequestTimeoutError

  alias Arbor.LLM.Response

  alias Arbor.LLM.Retry

  alias Arbor.LLM.StreamEvent

  alias Arbor.LLM.Tool

  alias Arbor.LLM.ToolCallValidator

  alias Arbor.LLM.ToolError

  alias Arbor.LLM.ToolResultBudget

  # ── Adapter routing ──────────────────────────────────────────────────
  #
  # The generic `Arbor.LLM.Adapter.ReqLLM` handles every API + local-LM
  # provider through req_llm transport. ACP is a separate Claude Code
  # CLI subprocess runtime, not an LLM transport — it has its own
  # adapter in arbor_ai. The Session 5 `use_generic_llm_adapter` flag
  # was removed in Session 6 after the soak verified the cutover; the
  # rollback path it gated no longer exists.
  @generic_adapter Arbor.LLM.Adapter.ReqLLM

  # ACP adapter lives in arbor_ai (which depends on arbor_llm) — held
  # as Module.concat atom-list to hide the cross-app reference from
  # compile-time analysis.
  @acp_adapter Module.concat([:Arbor, :AI, :LLM, :Adapter, :Acp])

  alias Arbor.LLM.ProviderRegistry

  @default_client_key {__MODULE__, :default_client}

  # Local-LM providers map to llm_db catalog atoms that don't follow
  # the Arbor-name-equals-atom convention:
  #
  #   - "lm_studio" → :lmstudio: llm_db drops the underscore.
  #
  #   - "ollama" → :ollama_cloud: llm_db has one Ollama atom and chose
  #     that name. It IS the right catalog for the Arbor `"ollama"`
  #     provider despite the confusing label — Ollama Inc maintains a
  #     single official model catalog that covers everything a local
  #     `ollama serve` daemon can serve, including locally-pulled
  #     models, cloud-proxy models (the `:cloud`-suffixed ones the
  #     daemon proxies to Ollama Cloud), and bridge pulls. There's no
  #     separate `:ollama` (local-only) atom in llm_db.
  #
  # For cloud providers Arbor's names match req_llm's atoms after the
  # Session 6.6 rename, so we just round-trip via
  # `String.to_existing_atom/1` rather than maintaining tautological
  # entries.
  @llmdb_provider_overrides %{
    "lm_studio" => :lmstudio,
    "ollama" => :ollama_cloud
  }

  @llmdb_provider_reverse_overrides Map.new(@llmdb_provider_overrides, fn {k, v} ->
                                      {v, k}
                                    end)

  @type complete_middleware ::
          (Request.t(), (Request.t() -> {:ok, Response.t()} | {:error, term()}) ->
             {:ok, Response.t()} | {:error, term()})

  @type stream_middleware ::
          (Request.t(), (Request.t() -> {:ok, Enumerable.t()} | {:error, term()}) ->
             {:ok, Enumerable.t()} | {:error, term()})

  @type t :: %__MODULE__{
          adapters: %{String.t() => module()},
          default_provider: String.t() | nil,
          model_catalog: :llmdb | %{String.t() => [map()]},
          middleware: [complete_middleware()],
          stream_middleware: [stream_middleware()]
        }

  defstruct adapters: %{},
            default_provider: nil,
            model_catalog: :llmdb,
            middleware: [],
            stream_middleware: []

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      adapters: Keyword.get(opts, :adapters, %{}),
      default_provider: Keyword.get(opts, :default_provider),
      model_catalog: Keyword.get(opts, :model_catalog, :llmdb),
      middleware: Keyword.get(opts, :middleware, []),
      stream_middleware: Keyword.get(opts, :stream_middleware, [])
    }
  end

  @spec from_env(keyword()) :: t()
  def from_env(opts \\ []) do
    discovered_adapters = discover_env_adapters(opts)
    adapters = Map.merge(discovered_adapters, Keyword.get(opts, :adapters, %{}))

    configured_default =
      Keyword.get(
        opts,
        :default_provider,
        System.get_env("UNIFIED_LLM_DEFAULT_PROVIDER") ||
          Application.get_env(:arbor_llm, :default_provider)
      )

    default_provider =
      cond do
        configured_default not in [nil, ""] ->
          blank_to_nil(configured_default)

        map_size(adapters) > 0 ->
          adapters
          |> Map.keys()
          |> Enum.sort()
          |> List.first()

        true ->
          nil
      end

    catalog = Keyword.get(opts, :model_catalog, :llmdb)

    if default_provider in [nil, ""] and adapters == %{} do
      raise ConfigurationError,
        message:
          "No provider configured. Set UNIFIED_LLM_DEFAULT_PROVIDER or pass adapters/default_provider."
    else
      new(
        adapters: adapters,
        default_provider: default_provider,
        model_catalog: catalog,
        middleware: Keyword.get(opts, :middleware, []),
        stream_middleware: Keyword.get(opts, :stream_middleware, [])
      )
    end
  end

  @spec set_default_client(t()) :: :ok
  def set_default_client(%__MODULE__{} = client) do
    :persistent_term.put(@default_client_key, client)
    :ok
  end

  @spec default_client(keyword()) :: t()
  def default_client(opts \\ []) do
    case :persistent_term.get(@default_client_key, nil) do
      %__MODULE__{} = client ->
        client

      _ ->
        client = from_env(opts)
        :ok = set_default_client(client)
        client
    end
  end

  @spec clear_default_client() :: :ok
  def clear_default_client do
    :persistent_term.erase(@default_client_key)
    :ok
  end

  @spec list_models(t(), keyword()) :: [map()]
  def list_models(%__MODULE__{} = client, opts \\ []) do
    provider = Keyword.get(opts, :provider)

    case client.model_catalog do
      :llmdb ->
        list_models_from_llmdb(provider, Map.keys(client.adapters))

      catalog when is_map(catalog) ->
        if is_binary(provider) do
          Map.get(catalog, provider, [])
        else
          catalog |> Map.values() |> List.flatten()
        end
    end
  end

  @spec get_model_info(t(), String.t()) :: {:ok, map()} | {:error, :model_not_found}
  def get_model_info(%__MODULE__{} = client, model_id) when is_binary(model_id) do
    case client.model_catalog do
      :llmdb ->
        get_model_from_llmdb(model_id, Map.keys(client.adapters))

      _catalog ->
        case Enum.find(list_models(client), &(&1.id == model_id)) do
          nil -> {:error, :model_not_found}
          model -> {:ok, model}
        end
    end
  end

  @doc """
  Select the best model matching capability requirements.

  Uses LLMDB's capability-based selection when available. Options:

      Client.select_model(client,
        require: [chat: true, tools: true],
        provider: "xai"
      )

  Returns `{:ok, %{provider: "xai", model: "grok-4-1-fast", info: %LLMDB.Model{}}}` or
  `{:error, :no_matching_model}`.
  """
  @spec select_model(t(), keyword()) :: {:ok, map()} | {:error, :no_matching_model}
  def select_model(%__MODULE__{} = client, opts \\ []) do
    provider_filter = Keyword.get(opts, :provider)
    require = Keyword.get(opts, :require, chat: true)
    forbid = Keyword.get(opts, :forbid, [])

    llmdb_opts = [require: require, forbid: forbid]

    llmdb_opts =
      if is_binary(provider_filter) do
        case arbor_to_llmdb_atom(provider_filter) do
          nil -> Keyword.put(llmdb_opts, :scope, :none)
          llmdb_id -> Keyword.put(llmdb_opts, :scope, llmdb_id)
        end
      else
        # Prefer providers we have adapters for
        prefer =
          client.adapters
          |> Map.keys()
          |> Enum.flat_map(fn name ->
            case arbor_to_llmdb_atom(name) do
              nil -> []
              id -> [id]
            end
          end)

        if prefer != [], do: Keyword.put(llmdb_opts, :prefer, prefer), else: llmdb_opts
      end

    cond do
      Keyword.get(llmdb_opts, :scope) == :none ->
        {:error, :no_matching_model}

      not llmdb_available?() ->
        {:error, :no_matching_model}

      true ->
        case llmdb_select(llmdb_opts) do
          {:ok, {llmdb_provider, model_id}} ->
            adapter_name = llmdb_atom_to_arbor(llmdb_provider)

            info =
              case llmdb_model(llmdb_provider, model_id) do
                {:ok, model} -> model
                _ -> nil
              end

            {:ok, %{provider: adapter_name, model: model_id, info: info}}

          _ ->
            {:error, :no_matching_model}
        end
    end
  end

  @spec register_adapter(t(), module()) :: t()
  def register_adapter(%__MODULE__{} = client, module) do
    provider = module.provider()
    %{client | adapters: Map.put(client.adapters, provider, module)}
  end

  @spec complete(t(), Request.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def complete(client, request, opts \\ [])

  def complete(%__MODULE__{} = client, %Request{} = request, opts) do
    with {:ok, opts, _timeout} <- normalize_client_deadline(opts, request.receive_timeout),
         {:ok, receipt} <- Deadline.receipt(opts) do
      Deadline.run(
        fn ->
          with {:ok, adapter} <- resolve_adapter(client, request) do
            base = fn req -> adapter.complete(req, opts) end

            wrapped =
              Enum.reduce(Enum.reverse(client.middleware), base, fn mw, acc ->
                fn req -> mw.(req, acc) end
              end)

            Boundary.completion(wrapped.(request), opts)
          end
        end,
        receipt,
        RequestTimeoutError.exception(timeout_ms: receipt.timeout_ms)
      )
    end
  end

  def complete(_client, _request, _opts), do: {:error, :invalid_completion_request}

  @spec stream(t(), Request.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(client, request, opts \\ [])

  def stream(%__MODULE__{} = client, %Request{} = request, opts) do
    with {:ok, opts, _timeout} <- normalize_client_deadline(opts, request.receive_timeout),
         {:ok, receipt} <- Deadline.receipt(opts) do
      Deadline.run(
        fn ->
          with {:ok, adapter} <- resolve_adapter(client, request),
               :ok <- ensure_stream_supported(adapter),
               {:ok, tracker} <- Boundary.stream_tracker(opts),
               {:ok, max_events} <- Boundary.stream_event_limit(opts) do
            base = fn req -> normalize_stream(adapter.stream(req, opts)) end

            wrapped =
              Enum.reduce(Enum.reverse(client.stream_middleware), base, fn mw, acc ->
                fn req -> mw.(req, acc) end
              end)

            with {:ok, source} <- wrapped.(request),
                 true <-
                   not match?(%OwnedStream{}, source) or
                     {:error, :owned_stream_nesting_forbidden},
                 {:ok, owned} <-
                   OwnedStream.new(track_stream_source(source, tracker, max_events, opts),
                     deadline_ms: receipt.deadline_ms,
                     timeout_ms: receipt.timeout_ms,
                     validator: fn event -> {:ok, event} end
                   ) do
              {:ok, owned}
            end
          end
        end,
        receipt,
        RequestTimeoutError.exception(timeout_ms: receipt.timeout_ms)
      )
    end
  end

  def stream(_client, _request, _opts), do: {:error, :invalid_stream_request}

  @doc """
  Stream tokens to `callback` and return the fully-assembled response.

  Unlike `stream/3` (a lazy chunk stream whose tool-call chunks lack assembled
  arguments), this returns a complete `%Response{}` with tool calls + arguments
  intact, while still delivering real-time deltas via `callback`
  (`%Arbor.LLM.StreamEvent{}`). Falls back with `{:error, {:stream_not_supported,
  adapter}}` if the adapter can't stream-and-assemble.
  """
  @spec complete_streaming(t(), Request.t(), (Arbor.LLM.StreamEvent.t() -> any()), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def complete_streaming(client, request, callback, opts \\ [])

  def complete_streaming(%__MODULE__{} = client, %Request{} = request, callback, opts)
      when is_function(callback, 1) do
    with {:ok, opts, _timeout} <- normalize_client_deadline(opts, request.receive_timeout),
         {:ok, receipt} <- Deadline.receipt(opts) do
      Deadline.run(
        fn ->
          with {:ok, adapter} <- resolve_adapter(client, request) do
            if adapter_exports?(adapter, :complete_streaming, 3) do
              with {:ok, tracker} <- Boundary.stream_tracker(opts),
                   {:ok, max_events} <- Boundary.stream_event_limit(opts) do
                event_counter = :atomics.new(1, [])

                guarded_callback = fn event ->
                  if :atomics.add_get(event_counter, 1, 1) <= max_events do
                    case Boundary.track_stream_event(tracker, event, opts) do
                      {:ok, normalized} -> callback.(normalized)
                      {:error, reason} -> throw({:invalid_stream_callback_event, reason})
                    end
                  else
                    throw(
                      {:invalid_stream_callback_event,
                       {:stream_limit_exceeded, :events, max_events}}
                    )
                  end
                end

                try do
                  adapter.complete_streaming(request, guarded_callback, opts)
                  |> Boundary.completion(opts)
                catch
                  :throw, {:invalid_stream_callback_event, reason} -> {:error, reason}
                end
              end
            else
              {:error, {:stream_not_supported, adapter}}
            end
          end
        end,
        receipt,
        RequestTimeoutError.exception(timeout_ms: receipt.timeout_ms)
      )
    end
  end

  def complete_streaming(_client, _request, _callback, _opts),
    do: {:error, :invalid_streaming_completion_request}

  @doc """
  Generate embeddings for a list of texts using the specified provider.

  Resolves the adapter from the request's provider and delegates to the
  adapter's `embed/3` callback. Returns `{:error, :embed_not_supported}`
  if the adapter doesn't implement embeddings.

  ## Options

  - `:provider` — provider string (required, used to resolve adapter)
  - `:model` — embedding model string (required)
  - `:dimensions` — requested embedding dimensions (optional)
  - `:timeout` — request timeout in ms (optional)
  """
  @spec embed(t(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def embed(client, provider, model, opts \\ [])

  def embed(%__MODULE__{} = client, provider, model, opts)
      when is_binary(provider) and is_binary(model) do
    with {:ok, opts, _timeout} <- Deadline.normalize_options(opts, 30_000),
         {:ok, receipt} <- Deadline.receipt(opts) do
      Deadline.run(
        fn ->
          with {:ok, texts} <- embed_texts_option(opts),
               [text | _rest] <- texts do
            do_embed_batch(client, provider, model, [text], opts)
          else
            {:error, _reason} = error -> error
            _ -> {:error, :embedding_texts_required}
          end
        end,
        receipt,
        RequestTimeoutError.exception(timeout_ms: receipt.timeout_ms)
      )
    end
  end

  def embed(_client, _provider, _model, _opts), do: {:error, :invalid_embedding_request}

  @doc """
  Generate embeddings for multiple texts in a batch.

  Same as `embed/4` but takes a list of texts directly.
  """
  @spec embed_batch(t(), String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def embed_batch(client, provider, model, texts, opts \\ [])

  def embed_batch(%__MODULE__{} = client, provider, model, texts, opts)
      when is_binary(provider) and is_binary(model) do
    with {:ok, opts, _timeout} <- Deadline.normalize_options(opts, 30_000),
         {:ok, receipt} <- Deadline.receipt(opts) do
      Deadline.run(
        fn -> do_embed_batch(client, provider, model, texts, opts) end,
        receipt,
        RequestTimeoutError.exception(timeout_ms: receipt.timeout_ms)
      )
    end
  end

  def embed_batch(_client, _provider, _model, _texts, _opts),
    do: {:error, :invalid_embedding_request}

  defp do_embed_batch(client, provider, model, texts, opts) do
    canonical = ProviderRegistry.normalize(provider)

    with :ok <- Boundary.embedding_inputs(texts),
         {:ok, adapter} <- resolve_embedding_adapter(client, canonical, provider),
         true <-
           adapter_exports?(adapter, :embed, 3) or {:error, {:embed_not_supported, provider}},
         adapter_opts = safe_put_new(opts, :provider, canonical),
         options when is_list(options) <- adapter_opts,
         result <- adapter.embed(texts, model, options),
         {:ok, indexed, usage} <-
           Boundary.embedding_response_with_indices(elem_or_result(result), length(texts)) do
      embeddings = Enum.map(indexed, & &1.embedding)

      {:ok,
       %{
         association_version: 1,
         embeddings: embeddings,
         indexed_embeddings: indexed,
         model: model,
         provider: canonical,
         usage: usage,
         dimensions: embeddings |> List.first([]) |> length()
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_embedding_adapter_options}
    end
  end

  defp resolve_embedding_adapter(client, canonical, original) do
    case Map.get(client.adapters, canonical) do
      nil -> {:error, {:unknown_provider, original}}
      adapter -> {:ok, adapter}
    end
  end

  defp elem_or_result({:ok, result}), do: result
  defp elem_or_result({:error, _reason} = error), do: error
  defp elem_or_result(other), do: other

  defp normalize_client_deadline(opts, fallback) do
    Deadline.normalize_transport_options(opts, fallback)
  end

  defp embed_texts_option(opts) do
    case safe_keyword_get(opts, :texts, [""]) do
      {:ok, texts} ->
        case Boundary.embedding_inputs(texts) do
          :ok -> {:ok, texts}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp safe_put_new(opts, key, value) do
    case safe_keyword_get(opts, key, :__arbor_missing__) do
      {:ok, :__arbor_missing__} -> [{key, value} | opts]
      {:ok, _existing} -> opts
      {:error, _reason} = error -> error
    end
  end

  defp safe_keyword_get([], _key, default), do: {:ok, default}
  defp safe_keyword_get([{key, value} | _rest], key, _default), do: {:ok, value}

  defp safe_keyword_get([{key, _value} | rest], wanted, default) when is_atom(key),
    do: safe_keyword_get(rest, wanted, default)

  defp safe_keyword_get(_improper, _key, _default), do: {:error, :keyword_options_required}

  defp ensure_stream_supported(adapter) do
    if adapter_exports?(adapter, :stream, 2),
      do: :ok,
      else: {:error, {:stream_not_supported, adapter}}
  end

  defp adapter_exports?(adapter, function, arity) when is_atom(adapter) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, function, arity)
  end

  defp normalize_stream({:ok, enumerable}), do: {:ok, enumerable}
  defp normalize_stream({:error, _reason} = error), do: error
  defp normalize_stream(enumerable), do: {:ok, enumerable}

  defp track_stream_source(source, tracker, max_events, opts) do
    Stream.transform(source, 0, fn event, count ->
      next = count + 1

      if next > max_events do
        raise Arbor.LLM.StreamError,
          reason: {:stream_limit_exceeded, :events, max_events}
      end

      case Boundary.track_stream_event(tracker, event, opts) do
        {:ok, normalized} -> {[normalized], next}
        {:error, reason} -> raise Arbor.LLM.StreamError, reason: reason
      end
    end)
  end

  @spec collect_stream(Enumerable.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def collect_stream(events, opts \\ []) do
    with {:ok, tracker} <- Boundary.stream_tracker(opts),
         {:ok, max_events} <- Boundary.stream_event_limit(opts) do
      do_collect_stream(events, opts, tracker, max_events)
    end
  end

  defp do_collect_stream(events, opts, tracker, max_events) do
    result =
      Enum.reduce_while(
        events,
        %{
          text_chunks: [],
          text_bytes: 0,
          event_count: 0,
          term_bytes: 0,
          term_nodes: 0,
          term_map_keys: 0,
          term_list_items: 0,
          finish_reason: :other,
          warnings: [],
          warning_count: 0,
          tool_calls: [],
          tool_call_count: 0,
          usage: nil
        },
        fn event, acc ->
          event_count = acc.event_count + 1

          if event_count > max_events do
            {:halt, {:error, {:stream_limit_exceeded, :events, max_events}}}
          else
            with {:ok, event} <- Boundary.track_stream_event(tracker, event, opts) do
              case event do
                %StreamEvent{type: :delta, data: %{"text" => chunk}} ->
                  collect_text_chunk(chunk, acc)

                %StreamEvent{type: :delta, data: %{text: chunk}} ->
                  collect_text_chunk(chunk, acc)

                %StreamEvent{type: :tool_call, data: data}
                when is_map(data) and acc.tool_call_count < 10_000 ->
                  with {:ok, measurements} <- preflight_stream_tool_call(data),
                       {:ok, acc} <- account_retained_measurements(acc, measurements),
                       {:ok, part} <- build_stream_tool_call(data) do
                    {:cont,
                     %{
                       acc
                       | tool_calls: [part | acc.tool_calls],
                         tool_call_count: acc.tool_call_count + 1
                     }}
                  else
                    {:error, reason} ->
                      {:halt, {:error, reason}}
                  end

                %StreamEvent{type: :tool_call} ->
                  {:halt, {:error, {:stream_limit_exceeded, :tool_calls, 10_000}}}

                %StreamEvent{type: :finish, data: data} when is_map(data) ->
                  case bounded_finish_fields(data) do
                    {:ok, reason, usage} ->
                      {:cont,
                       %{
                         acc
                         | finish_reason: reason,
                           usage: usage || acc.usage
                       }}

                    {:error, reason} ->
                      {:halt, {:error, reason}}
                  end

                %StreamEvent{type: :error, data: data} when acc.warning_count < 1_000 ->
                  warning = Arbor.LLM.ExternalTerm.inspect(data)

                  {:cont,
                   %{
                     acc
                     | warnings: [warning | acc.warnings],
                       warning_count: acc.warning_count + 1
                   }}

                %StreamEvent{type: :error} ->
                  {:halt, {:error, {:stream_limit_exceeded, :warnings, 1_000}}}

                _ ->
                  {:cont, acc}
              end
            else
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end
        end
      )

    with %{} = result <- result do
      text = result.text_chunks |> Enum.reverse() |> IO.iodata_to_binary()
      tool_calls = Enum.reverse(result.tool_calls)
      warnings = Enum.reverse(result.warnings)
      text_parts = if text != "", do: [ContentPart.text(text)], else: []
      content_parts = text_parts ++ tool_calls

      finish_reason =
        cond do
          tool_calls != [] and result.finish_reason == :other -> :tool_calls
          true -> result.finish_reason
        end

      response = %Response{
        text: text,
        finish_reason: finish_reason,
        content_parts: content_parts,
        warnings: warnings,
        usage: result.usage || %{}
      }

      Boundary.completion({:ok, response}, opts)
    else
      {:error, _reason} = error -> error
    end
  rescue
    exception -> {:error, exception}
  end

  defp collect_text_chunk(chunk, acc) when is_binary(chunk) do
    bytes = acc.text_bytes + byte_size(chunk)

    if bytes <= 16_777_216,
      do: {:cont, %{acc | text_chunks: [chunk | acc.text_chunks], text_bytes: bytes}},
      else: {:halt, {:error, {:stream_limit_exceeded, :text_bytes, 16_777_216}}}
  end

  defp collect_text_chunk(_chunk, _acc), do: {:halt, {:error, :binary_stream_text_required}}

  defp account_retained_measurements(acc, nil), do: {:ok, acc}

  defp account_retained_measurements(acc, measurements) do
    bytes = acc.term_bytes + Map.get(measurements, :bytes, 0)
    nodes = acc.term_nodes + Map.get(measurements, :nodes, 0)
    map_keys = acc.term_map_keys + Map.get(measurements, :map_keys, 0)
    list_items = acc.term_list_items + Map.get(measurements, :list_items, 0)

    cond do
      bytes > 16_777_216 ->
        {:error, {:stream_limit_exceeded, :retained_bytes, 16_777_216}}

      nodes > 100_000 ->
        {:error, {:stream_limit_exceeded, :retained_nodes, 100_000}}

      map_keys > 10_000 ->
        {:error, {:stream_limit_exceeded, :retained_map_keys, 10_000}}

      list_items > 100_000 ->
        {:error, {:stream_limit_exceeded, :retained_list_items, 100_000}}

      true ->
        {:ok,
         %{
           acc
           | term_bytes: bytes,
             term_nodes: nodes,
             term_map_keys: map_keys,
             term_list_items: list_items
         }}
    end
  end

  defp preflight_stream_tool_call(data) do
    case data[:arguments] || data["arguments"] || %{} do
      arguments when is_binary(arguments) ->
        case ResponseBudget.preflight_json(arguments, tool_argument_limits()) do
          {:ok, measurements} -> {:ok, measurements}
          {:error, reason} -> {:error, {:invalid_tool_arguments, reason}}
        end

      arguments when is_map(arguments) ->
        {:ok, nil}

      _arguments ->
        {:error, :tool_arguments_must_be_map_or_json}
    end
  end

  defp build_stream_tool_call(data) do
    id = data[:id] || data["id"] || ""
    name = data[:name] || data["name"] || ""
    arguments = data[:arguments] || data["arguments"] || %{}

    with :ok <- bounded_tool_string(id, :id, 512, true),
         :ok <- bounded_tool_string(name, :name, 512, false),
         {:ok, arguments} <- decode_tool_args(arguments) do
      {:ok, ContentPart.tool_call(id, name, arguments)}
    end
  end

  defp bounded_tool_string(value, _field, maximum, allow_empty?)
       when is_binary(value) and byte_size(value) <= maximum do
    cond do
      not String.valid?(value) -> {:error, :valid_utf8_required}
      value == "" and not allow_empty? -> {:error, :non_empty_tool_name_required}
      true -> :ok
    end
  end

  defp bounded_tool_string(_value, field, maximum, _allow_empty?),
    do: {:error, {:invalid_tool_call_field, field, {:bounded_string_required, maximum}}}

  defp bounded_finish_fields(data) do
    reason = Map.get(data, :reason, Map.get(data, "reason", :stop))
    usage = Map.get(data, :usage, Map.get(data, "usage"))

    with :ok <- validate_finish_reason(reason),
         :ok <- validate_finish_usage(usage) do
      {:ok, reason, usage}
    end
  end

  defp validate_finish_reason(reason) when is_atom(reason), do: :ok

  defp validate_finish_reason(reason) when is_binary(reason) and byte_size(reason) <= 64 do
    if String.valid?(reason), do: :ok, else: {:error, :invalid_finish_reason}
  end

  defp validate_finish_reason(_reason), do: {:error, :invalid_finish_reason}

  defp validate_finish_usage(nil), do: :ok

  defp validate_finish_usage(usage) when is_map(usage) do
    Arbor.LLM.ResponseBudget.validate(usage,
      max_bytes: 1_048_576,
      max_nodes: 10_000,
      max_depth: 16,
      max_map_keys: 2_000,
      max_list_items: 10_000
    )
  end

  defp validate_finish_usage(_usage), do: {:error, :invalid_finish_usage}

  defp decode_tool_args(args) when is_binary(args) do
    case ResponseBudget.decode_json(args, tool_argument_limits()) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, :tool_arguments_must_be_map}
      {:error, reason} -> {:error, {:invalid_tool_arguments, reason}}
    end
  end

  defp decode_tool_args(args) when is_map(args) do
    case ResponseBudget.validate(args, tool_argument_limits()) do
      :ok -> {:ok, args}
      {:error, reason} -> {:error, {:invalid_tool_arguments, reason}}
    end
  end

  defp decode_tool_args(_args), do: {:error, :tool_arguments_must_be_map_or_json}

  defp tool_argument_limits do
    [
      max_bytes: 1_048_576,
      max_nodes: 10_000,
      max_depth: 32,
      max_map_keys: 2_000,
      max_list_items: 10_000
    ]
  end

  @spec generate_with_tools(t(), Request.t(), [Tool.t()], keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def generate_with_tools(%__MODULE__{} = client, %Request{} = request, tools, opts \\ []) do
    max_steps = Keyword.get(opts, :max_tool_rounds, Keyword.get(opts, :max_steps, 8))
    parallel = Keyword.get(opts, :parallel_tool_execution, true)
    on_step = Keyword.get(opts, :on_step)

    request =
      %{request | tools: Enum.map(tools, &Tool.as_definition/1)}

    if max_steps <= 0 do
      complete(client, request, opts)
    else
      do_generate_with_tools(
        client,
        request,
        tools,
        on_step,
        max_steps,
        parallel,
        opts,
        ToolResultBudget.new()
      )
    end
  end

  defp do_generate_with_tools(
         client,
         request,
         tools,
         on_step,
         max_steps,
         parallel,
         opts,
         tool_result_budget
       ) do
    with :ok <- ensure_not_aborted(opts) do
      retry_opts = Keyword.get(opts, :retry, [])

      # Retry only provider generation. Tool calls run after this boundary and
      # must not be repeated as part of a provider retry.
      complete_result =
        with {:ok, receipt} <- Deadline.receipt(opts) do
          Deadline.run(
            fn ->
              Retry.execute(
                fn -> complete_with_step_timeout(client, request, opts) end,
                Keyword.merge(
                  [
                    on_retry: fn reason, meta ->
                      emit_step(on_step, %{
                        type: :llm_retrying,
                        reason: reason,
                        attempt: meta.attempt,
                        delay_ms: meta.delay_ms
                      })

                      # Emit structured retry signal for observability
                      emit_retry_signal(reason, meta, request)
                    end,
                    sleep_fn: Keyword.get(opts, :sleep_fn, fn ms -> Process.sleep(ms) end)
                  ],
                  retry_opts
                )
              )
            end,
            receipt,
            RequestTimeoutError.exception(timeout_ms: receipt.timeout_ms)
          )
        end

      case complete_result do
        {:ok, %Response{} = response} ->
          tool_calls = extract_tool_calls(response)
          stop_when = Keyword.get(opts, :stop_when)

          emit_step(on_step, %{
            type: :llm_response,
            response: response,
            tool_call_count: length(tool_calls)
          })

          cond do
            tool_calls == [] ->
              {:ok, response}

            max_steps <= 0 ->
              {:ok, response}

            is_function(stop_when, 1) and
                stop_when.(%{
                  response: response,
                  tool_calls: tool_calls,
                  remaining_rounds: max_steps
                }) ->
              {:ok, response}

            not should_auto_execute_tool_calls?(tool_calls, tools) ->
              {:ok, response}

            true ->
              with {:ok, tool_messages, next_budget} <-
                     execute_tool_calls(
                       tool_calls,
                       tools,
                       parallel,
                       on_step,
                       opts,
                       tool_result_budget
                     ) do
                updated_messages =
                  request.messages ++
                    [Message.new(:assistant, response.text, %{"tool_calls" => tool_calls})] ++
                    tool_messages

                next_request = %{request | messages: updated_messages}

                do_generate_with_tools(
                  client,
                  next_request,
                  tools,
                  on_step,
                  max_steps - 1,
                  parallel,
                  opts,
                  next_budget
                )
              end
          end

        {:error, reason} ->
          # Emit retry-exhausted signal when all retries have failed
          emit_retry_exhausted_signal(reason, request)
          {:error, reason}
      end
    end
  end

  defp complete_with_step_timeout(client, request, opts) do
    if option_present?(opts, :max_step_timeout_ms) do
      case Deadline.select(opts, [:max_step_timeout_ms], 30_000, 900_000) do
        {:ok, timeout_ms} ->
          with {:ok, receipt} <- Deadline.receipt(timeout_ms: timeout_ms) do
            Deadline.run(
              fn -> complete(client, request, opts) end,
              receipt,
              RequestTimeoutError.exception(timeout_ms: receipt.timeout_ms)
            )
          end

        {:error, _reason} = error ->
          error
      end
    else
      complete(client, request, opts)
    end
  end

  defp option_present?(opts, wanted) do
    Enum.any?(opts, fn
      {key, _value} when is_atom(key) -> key == wanted
      _invalid -> false
    end)
  end

  defp execute_tool_calls(tool_calls, tools, parallel, on_step, opts, aggregate) do
    runner = fn call -> execute_tool_call(call, tools, on_step, opts) end

    results =
      if parallel and length(tool_calls) > 1 do
        tool_calls
        |> Task.async_stream(runner, timeout: 30_000, ordered: true)
        |> Enum.map(fn
          {:ok, result} ->
            result

          {:exit, _reason} ->
            {%{"status" => "error", "error" => "tool execution failed"}, nil, nil}
        end)
      else
        Enum.map(tool_calls, runner)
      end

    encode_tool_results(results, aggregate, [])
  end

  defp encode_tool_results([], aggregate, messages),
    do: {:ok, Enum.reverse(messages), aggregate}

  defp encode_tool_results([{output, id, name} | rest], aggregate, messages) do
    with {:ok, encoded, next} <- ToolResultBudget.encode(output, aggregate) do
      message = Message.new(:tool, encoded, %{"tool_call_id" => id, "name" => name})
      encode_tool_results(rest, next, [message | messages])
    end
  end

  defp encode_tool_results(_invalid, _aggregate, _messages),
    do: {:error, :invalid_tool_execution_result}

  defp execute_tool_call(call, tools, on_step, opts) do
    validate_fun = Keyword.get(opts, :validate_tool_call, &ToolCallValidator.validate/2)

    call =
      case validate_fun.(call, tools) do
        :ok ->
          call

        {:error, reason} ->
          case ToolCallValidator.maybe_repair(call, reason, tools, opts) do
            {:ok, repaired} ->
              repaired

            :drop ->
              %{
                "id" => Map.get(call, "id") || Map.get(call, :id),
                "name" => "__dropped__",
                "arguments" => %{}
              }

            {:error, _} ->
              %{
                "id" => Map.get(call, "id") || Map.get(call, :id),
                "name" => "__invalid__",
                "arguments" => %{},
                "error" => reason
              }
          end
      end

    id = Map.get(call, "id") || Map.get(call, :id)
    name = Map.get(call, "name") || Map.get(call, :name)
    arguments = Map.get(call, "arguments") || Map.get(call, :arguments) || %{}
    hooks = Keyword.get(opts, :tool_hooks, %{})

    pre_payload = %{
      phase: "pre",
      tool_name: name,
      tool_call_id: id,
      arguments: arguments
    }

    hooks_mod = @tool_hooks_mod
    pre_result = safe_hook(hooks_mod, :pre, hook_for(hooks, :pre), pre_payload, opts)
    emit_step(on_step, Map.merge(%{type: :tool_hook_pre, tool: name, id: id}, pre_result))

    output =
      if pre_result.decision == :skip do
        %{
          "status" => "skipped",
          "error" => pre_result.reason || "tool call skipped by pre-hook",
          "type" => :hook_skipped
        }
      else
        execute_tool_after_pre(name, id, arguments, tools, on_step)
      end

    post_payload = %{
      phase: "post",
      tool_name: name,
      tool_call_id: id,
      arguments: arguments,
      result: output
    }

    post_result = safe_hook(hooks_mod, :post, hook_for(hooks, :post), post_payload, opts)
    emit_step(on_step, Map.merge(%{type: :tool_hook_post, tool: name, id: id}, post_result))

    {output, id, name}
  end

  defp execute_tool_after_pre(name, id, arguments, tools, on_step) do
    case Enum.find(tools, &(&1.name == name)) do
      nil ->
        tool_error = %ToolError{
          message: "Unknown tool",
          type: :unknown_tool,
          tool_name: external_identifier(name),
          tool_call_id: external_identifier(id),
          retryable: false,
          details: %{"name" => name}
        }

        result = %{
          "status" => "error",
          "error" => Arbor.LLM.ExternalTerm.exception_message(tool_error),
          "type" => tool_error.type,
          "name" => name
        }

        emit_step(on_step, %{type: :tool_result, tool: name, status: :error, id: id})
        result

      %Tool{execute: execute} = tool when is_function(execute, 1) ->
        output =
          try do
            case execute.(arguments) do
              {:ok, map} when is_map(map) ->
                %{"status" => "ok", "result" => map}

              {:error, reason} ->
                tool_error = %ToolError{
                  message: "Tool execution failed",
                  type: :execution_failed,
                  tool_name: tool.name,
                  tool_call_id: external_identifier(id),
                  retryable: false,
                  details: %{"reason" => Arbor.LLM.ExternalTerm.inspect(reason)}
                }

                %{
                  "status" => "error",
                  "error" => Arbor.LLM.ExternalTerm.exception_message(tool_error),
                  "type" => tool_error.type
                }

              map when is_map(map) ->
                %{"status" => "ok", "result" => map}

              other ->
                %{"status" => "ok", "result" => other}
            end
          rescue
            exception ->
              tool_error = %ToolError{
                message: "Tool raised exception",
                type: :execution_failed,
                tool_name: tool.name,
                tool_call_id: external_identifier(id),
                retryable: false,
                details: %{"exception" => Arbor.LLM.ExternalTerm.exception_message(exception)}
              }

              %{
                "status" => "error",
                "error" => Arbor.LLM.ExternalTerm.exception_message(tool_error),
                "type" => tool_error.type
              }
          catch
            kind, reason ->
              %{
                "status" => "error",
                "error" => "tool callback #{kind}: " <> Arbor.LLM.ExternalTerm.inspect(reason),
                "type" => :execution_failed
              }
          end

        emit_step(on_step, %{type: :tool_result, tool: name, status: output["status"], id: id})
        output

      %Tool{} ->
        tool_error = %ToolError{
          message: "Tool has no execute handler",
          type: :invalid_tool_call,
          tool_name: external_identifier(name),
          tool_call_id: external_identifier(id),
          retryable: false,
          details: %{"name" => name}
        }

        result = %{
          "status" => "error",
          "error" => Arbor.LLM.ExternalTerm.exception_message(tool_error),
          "type" => tool_error.type,
          "name" => name
        }

        emit_step(on_step, %{type: :tool_result, tool: name, status: :error, id: id})
        result
    end
  end

  defp should_auto_execute_tool_calls?(tool_calls, tools) do
    Enum.any?(tool_calls, fn call ->
      name = Map.get(call, "name") || Map.get(call, :name)

      case Enum.find(tools, &(&1.name == name)) do
        %Tool{execute: execute} when is_function(execute, 1) -> true
        %Tool{execute: nil} -> false
        nil -> true
      end
    end)
  end

  defp hook_for(hooks, key) when is_map(hooks),
    do: Map.get(hooks, key) || Map.get(hooks, to_string(key))

  defp hook_for(hooks, key) when is_list(hooks), do: Keyword.get(hooks, key)
  defp hook_for(_, _), do: nil

  defp extract_tool_calls(%Response{raw: raw}) when is_map(raw) do
    calls = Map.get(raw, "tool_calls") || Map.get(raw, :tool_calls) || []
    if is_list(calls), do: calls, else: []
  end

  defp extract_tool_calls(_), do: []

  defp safe_hook(module, phase, hook, payload, opts) do
    apply(module, :run, [phase, hook, payload, opts])
  rescue
    exception ->
      %{decision: :continue, reason: Arbor.LLM.ExternalTerm.exception_message(exception)}
  catch
    kind, reason ->
      %{decision: :continue, reason: "#{kind}: " <> Arbor.LLM.ExternalTerm.inspect(reason)}
  end

  defp emit_step(callback, payload) when is_function(callback, 1) do
    callback.(payload)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp emit_step(_, _), do: :ok

  defp external_identifier(value) when is_binary(value) and byte_size(value) <= 512,
    do: String.replace_invalid(value, "")

  defp external_identifier(value) when is_atom(value), do: Atom.to_string(value)
  defp external_identifier(value), do: Arbor.LLM.ExternalTerm.inspect(value)

  defp ensure_not_aborted(opts) do
    abort =
      case Keyword.get(opts, :abort?) do
        fun when is_function(fun, 0) -> fun.()
        value -> value
      end

    if abort do
      {:error, AbortError.exception([])}
    else
      :ok
    end
  end

  defp resolve_adapter(%__MODULE__{adapters: adapters}, %Request{provider: provider})
       when is_binary(provider) do
    # Fold provider-name spellings (e.g. "lmstudio" → "lm_studio") onto
    # the canonical name adapters are registered under.
    canonical = ProviderRegistry.normalize(provider)

    case Map.get(adapters, canonical) do
      nil -> {:error, {:unknown_provider, provider}}
      adapter -> {:ok, adapter}
    end
  end

  defp resolve_adapter(%__MODULE__{default_provider: default_provider} = client, %Request{
         provider: nil,
         model: model
       }) do
    if is_binary(default_provider) and default_provider != "" do
      resolve_adapter(client, %Request{provider: default_provider, model: model})
    else
      with {:ok, provider} <- infer_provider(model) do
        {:error, {:provider_not_explicit, provider}}
      end
    end
  end

  defp infer_provider(model) when is_binary(model) do
    cond do
      String.starts_with?(model, "gpt") -> {:ok, "openai"}
      String.starts_with?(model, "claude") -> {:ok, "anthropic"}
      String.starts_with?(model, "gemini") -> {:ok, "google"}
      true -> {:error, :provider_inference_failed}
    end
  end

  # Enumerate cloud providers from ProviderRegistry, look up each
  # provider's env-key via its req_llm module's `default_env_key/0`,
  # and keep only providers whose key is set. The provider list, env
  # var names, and value-presence check all flow from req_llm — Arbor
  # doesn't carry its own hardcoded copy.
  defp env_provider_keys do
    for provider <- ProviderRegistry.list_cloud(),
        ProviderRegistry.env_available?(provider),
        do: {provider, :present}
  end

  defp maybe_put_oauth(adapters, provider_key, oauth_provider) do
    if Arbor.LLM.OAuth.configured?(oauth_provider) do
      Map.put(adapters, provider_key, Arbor.LLM.Adapter.OAuthResponses)
    else
      adapters
    end
  end

  defp discover_env_adapters(opts) do
    api_adapters =
      env_provider_keys()
      |> Enum.reduce(%{}, fn {provider, _value}, acc ->
        Map.put(acc, provider, @generic_adapter)
      end)

    adapters = api_adapters

    # Subscription-OAuth adapters (raw model on a flat subscription instead of an API key).
    # Registered only for a validated Arbor-owned credential envelope. Discovery never refreshes,
    # reads CLI credentials, or treats a legacy/raw store as ready.
    adapters =
      if Keyword.get(opts, :discover_oauth, true) do
        adapters
        |> maybe_put_oauth("openai_oauth", :openai)
        |> maybe_put_oauth("xai_oauth", :xai)
      else
        adapters
      end

    default_discover_local =
      Application.get_env(:arbor_orchestrator, :discover_local_providers, true)

    adapters =
      if Keyword.get(opts, :discover_local, default_discover_local) do
        # Owned LM Studio adapter (direct /v1/chat/completions with full sampling in the body).
        # Opt-in provider name; ReqLLM still serves plain "lm_studio" until this is proven.
        # Only registered when local discovery is enabled so discover_local: false cannot
        # silently select it as the default provider.
        adapters = Map.put(adapters, "lm_studio_owned", Arbor.LLM.Adapter.LmStudio)

        Enum.reduce(ProviderRegistry.list_local(), adapters, fn provider, acc ->
          maybe_add_local_provider(acc, provider)
        end)
      else
        adapters
      end

    if Keyword.get(opts, :discover_acp, true) do
      maybe_add_acp(adapters, "acp", @acp_adapter)
    else
      adapters
    end
  end

  defp maybe_add_acp(adapters, name, mod) do
    if mod.available?() do
      Map.put(adapters, name, mod)
    else
      adapters
    end
  rescue
    _ -> adapters
  catch
    :exit, _ -> adapters
  end

  # --- LLMDB Integration ---
  # LLMDB is a transitive dep (via req_llm) — use apply/3 to avoid compile warnings.

  @llmdb_module LLMDB

  defp llmdb_available? do
    Code.ensure_loaded?(@llmdb_module)
  end

  defp llmdb_models(provider_id) do
    apply(@llmdb_module, :models, [provider_id])
  end

  defp llmdb_model(provider_id, model_id) do
    apply(@llmdb_module, :model, [provider_id, model_id])
  end

  defp llmdb_select(opts) do
    apply(@llmdb_module, :select, [opts])
  end

  defp list_models_from_llmdb(provider, _adapter_keys) when is_binary(provider) do
    if llmdb_available?() do
      case arbor_to_llmdb_atom(provider) do
        nil -> []
        llmdb_id -> llmdb_models(llmdb_id) |> Enum.map(&model_to_map/1)
      end
    else
      []
    end
  end

  defp list_models_from_llmdb(nil, adapter_keys) do
    if llmdb_available?() do
      adapter_keys
      |> Enum.flat_map(fn name ->
        case arbor_to_llmdb_atom(name) do
          nil -> []
          llmdb_id -> llmdb_models(llmdb_id) |> Enum.map(&model_to_map/1)
        end
      end)
    else
      []
    end
  end

  defp get_model_from_llmdb(model_id, adapter_keys) do
    if llmdb_available?() do
      result =
        Enum.find_value(adapter_keys, fn name ->
          case arbor_to_llmdb_atom(name) do
            nil -> nil
            llmdb_id -> lookup_llmdb_model(llmdb_id, model_id)
          end
        end)

      result || {:error, :model_not_found}
    else
      {:error, :model_not_found}
    end
  end

  # Map an Arbor provider string to the atom llm_db's catalog uses for
  # that provider. Cloud providers' Arbor names match req_llm's atoms
  # (after the Session 6.6 rename), and llm_db reuses req_llm's atoms,
  # so `String.to_existing_atom/1` works for them. Local-LM providers
  # use Arbor-only names that differ from llm_db's catalog atoms — the
  # overrides table handles them.
  defp arbor_to_llmdb_atom(provider) when is_binary(provider) do
    canonical = ProviderRegistry.normalize(provider)

    case Map.fetch(@llmdb_provider_overrides, canonical) do
      {:ok, atom} -> atom
      :error -> String.to_existing_atom(canonical)
    end
  rescue
    ArgumentError -> nil
  end

  defp llmdb_atom_to_arbor(atom) when is_atom(atom) do
    case Map.fetch(@llmdb_provider_reverse_overrides, atom) do
      {:ok, name} -> name
      :error -> Atom.to_string(atom)
    end
  end

  defp lookup_llmdb_model(llmdb_id, model_id) do
    case llmdb_model(llmdb_id, model_id) do
      {:ok, model} -> {:ok, model_to_map(model)}
      _ -> nil
    end
  end

  defp model_to_map(%{__struct__: _} = model) do
    %{
      id: model.id,
      name: model.name,
      family: model.family || get_in(Map.get(model, :extra, nil) || %{}, [:family]),
      provider: llmdb_atom_to_arbor(model.provider),
      capabilities: model.capabilities,
      modalities: model.modalities,
      cost: model.cost,
      limits: model.limits,
      deprecated: model.deprecated,
      knowledge: model.knowledge,
      release_date: model.release_date,
      aliases: model.aliases || []
    }
  end

  defp model_to_map(map) when is_map(map), do: map

  # HTTP probe for local-LM availability. We GET <base_url>/models
  # (where base_url comes from ProviderRegistry, honouring operator
  # config overrides) and register the generic adapter when the
  # server responds 2xx.
  defp maybe_add_local_provider(adapters, provider) do
    case ProviderRegistry.default_base_url(provider) do
      nil ->
        adapters

      base_url ->
        if probe_local_provider(provider, base_url) do
          Map.put(adapters, provider, @generic_adapter)
        else
          adapters
        end
    end
  end

  defp probe_local_provider(provider, base_url) do
    case Arbor.LLM.Preflight.loaded_models(provider, base_url, timeout_ms: 2_000) do
      {:ok, _models} -> true
      {:error, _reason} -> false
    end
  rescue
    _ -> false
  catch
    _kind, _reason -> false
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: to_string(value)

  # ── Structured Error Signals ──────────────────────────────────────

  defp emit_retry_signal(reason, meta, request) do
    llm_error_mod = Arbor.AI.LLMError
    signals_mod = Arbor.Signals

    if Code.ensure_loaded?(llm_error_mod) and function_exported?(llm_error_mod, :classify, 1) and
         Code.ensure_loaded?(signals_mod) and function_exported?(signals_mod, :durable_emit, 3) do
      error_info = apply(llm_error_mod, :classify, [reason])

      apply(signals_mod, :durable_emit, [
        :ai,
        :llm_retry,
        Map.merge(error_info, %{
          attempt: meta.attempt,
          delay_ms: meta.delay_ms,
          provider: request.provider,
          model: request.model
        })
      ])
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp emit_retry_exhausted_signal(reason, request) do
    llm_error_mod = Arbor.AI.LLMError
    signals_mod = Arbor.Signals

    if Code.ensure_loaded?(llm_error_mod) and function_exported?(llm_error_mod, :classify, 1) and
         Code.ensure_loaded?(signals_mod) and function_exported?(signals_mod, :durable_emit, 3) do
      error_info = apply(llm_error_mod, :classify, [reason])

      apply(signals_mod, :durable_emit, [
        :ai,
        :llm_retries_exhausted,
        Map.merge(error_info, %{
          provider: request.provider,
          model: request.model
        })
      ])
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
