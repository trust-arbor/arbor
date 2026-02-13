defmodule Arbor.Orchestrator.UnifiedLLM.Client do
  @moduledoc """
  Minimal unified-llm client scaffold with provider routing and middleware.
  """

  alias Arbor.Orchestrator.UnifiedLLM.{
    AbortError,
    ConfigurationError,
    Message,
    Request,
    RequestTimeoutError,
    Response,
    Retry,
    StreamEvent,
    Tool,
    ToolCallValidator,
    ToolError
  }

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.{
    Anthropic,
    Gemini,
    LMStudio,
    Ollama,
    OpenAI,
    OpenRouter,
    XAI,
    Zai,
    ZaiCodingPlan
  }

  alias Arbor.Orchestrator.ToolHooks

  @default_client_key {__MODULE__, :default_client}

  # Mapping between our adapter string IDs and LLMDB atom provider IDs.
  # Only providers where the names differ need entries.
  @llmdb_provider_map %{
    "openai" => :openai,
    "anthropic" => :anthropic,
    "gemini" => :google,
    "zai" => :zai,
    "zai_coding_plan" => :zai_coding_plan,
    "openrouter" => :openrouter,
    "xai" => :xai,
    "lm_studio" => :lmstudio,
    "ollama" => :ollama_cloud
  }

  @llmdb_provider_reverse_map Map.new(@llmdb_provider_map, fn {k, v} -> {v, k} end)

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
      Keyword.get(opts, :default_provider, System.get_env("UNIFIED_LLM_DEFAULT_PROVIDER"))

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
        case Map.get(@llmdb_provider_map, provider_filter) do
          nil -> Keyword.put(llmdb_opts, :scope, :none)
          llmdb_id -> Keyword.put(llmdb_opts, :scope, llmdb_id)
        end
      else
        # Prefer providers we have adapters for
        prefer =
          client.adapters
          |> Map.keys()
          |> Enum.flat_map(fn name ->
            case Map.get(@llmdb_provider_map, name) do
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
            adapter_name =
              Map.get(@llmdb_provider_reverse_map, llmdb_provider, to_string(llmdb_provider))

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
  def complete(%__MODULE__{} = client, %Request{} = request, opts \\ []) do
    with {:ok, adapter} <- resolve_adapter(client, request) do
      base = fn req -> adapter.complete(req, opts) end

      wrapped =
        Enum.reduce(Enum.reverse(client.middleware), base, fn mw, acc ->
          fn req -> mw.(req, acc) end
        end)

      wrapped.(request)
    end
  end

  @spec stream(t(), Request.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(%__MODULE__{} = client, %Request{} = request, opts \\ []) do
    with {:ok, adapter} <- resolve_adapter(client, request),
         :ok <- ensure_stream_supported(adapter) do
      base = fn req -> normalize_stream(adapter.stream(req, opts)) end

      wrapped =
        Enum.reduce(Enum.reverse(client.stream_middleware), base, fn mw, acc ->
          fn req -> mw.(req, acc) end
        end)

      wrapped.(request)
    end
  end

  defp ensure_stream_supported(adapter) do
    if function_exported?(adapter, :stream, 2),
      do: :ok,
      else: {:error, {:stream_not_supported, adapter}}
  end

  defp normalize_stream({:ok, enumerable}), do: {:ok, enumerable}
  defp normalize_stream({:error, _reason} = error), do: error
  defp normalize_stream(enumerable), do: {:ok, enumerable}

  @spec collect_stream(Enumerable.t()) :: {:ok, Response.t()} | {:error, term()}
  def collect_stream(events) do
    result =
      Enum.reduce(events, %{text: "", finish_reason: :other, warnings: []}, fn event, acc ->
        case normalize_event(event) do
          %StreamEvent{type: :delta, data: %{"text" => chunk}} ->
            %{acc | text: acc.text <> to_string(chunk)}

          %StreamEvent{type: :delta, data: %{text: chunk}} ->
            %{acc | text: acc.text <> to_string(chunk)}

          %StreamEvent{type: :finish, data: data} ->
            %{acc | finish_reason: Map.get(data, :reason, Map.get(data, "reason", :stop))}

          %StreamEvent{type: :error, data: data} ->
            %{acc | warnings: acc.warnings ++ [inspect(data)]}

          _ ->
            acc
        end
      end)

    {:ok,
     %Response{text: result.text, finish_reason: result.finish_reason, warnings: result.warnings}}
  rescue
    exception -> {:error, exception}
  end

  defp normalize_event(%StreamEvent{} = event), do: event
  defp normalize_event(%{type: type, data: data}), do: %StreamEvent{type: type, data: data}
  defp normalize_event(_), do: %StreamEvent{type: :error, data: %{reason: :invalid_stream_event}}

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
      do_generate_with_tools(client, request, tools, on_step, max_steps, parallel, opts)
    end
  end

  defp do_generate_with_tools(client, request, tools, on_step, max_steps, parallel, opts) do
    with :ok <- ensure_not_aborted(opts) do
      retry_opts = Keyword.get(opts, :retry, [])

      complete_result =
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
              end,
              sleep_fn: Keyword.get(opts, :sleep_fn, fn ms -> Process.sleep(ms) end)
            ],
            retry_opts
          )
        )

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
              tool_messages = execute_tool_calls(tool_calls, tools, parallel, on_step, opts)

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
                opts
              )
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp complete_with_step_timeout(client, request, opts) do
    case Keyword.get(opts, :max_step_timeout_ms) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        task = Task.async(fn -> complete(client, request, opts) end)

        try do
          Task.await(task, timeout_ms)
        catch
          :exit, {:timeout, _} ->
            Task.shutdown(task, :brutal_kill)
            {:error, RequestTimeoutError.exception(timeout_ms: timeout_ms)}
        end

      _ ->
        complete(client, request, opts)
    end
  end

  defp execute_tool_calls(tool_calls, tools, parallel, on_step, opts) do
    runner = fn call -> execute_tool_call(call, tools, on_step, opts) end

    if parallel and length(tool_calls) > 1 do
      tool_calls
      |> Task.async_stream(runner, timeout: 30_000, ordered: true)
      |> Enum.map(fn
        {:ok, message} ->
          message

        {:exit, reason} ->
          Message.new(:tool, "tool failed: #{inspect(reason)}", %{"status" => "error"})
      end)
    else
      Enum.map(tool_calls, runner)
    end
  end

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

    pre_result = ToolHooks.run(:pre, hook_for(hooks, :pre), pre_payload, opts)
    emit_step(on_step, Map.merge(%{type: :tool_hook_pre, tool: name, id: id}, pre_result))

    output =
      cond do
        pre_result.decision == :skip ->
          %{
            "status" => "skipped",
            "error" => pre_result.reason || "tool call skipped by pre-hook",
            "type" => :hook_skipped
          }

        true ->
          execute_tool_after_pre(name, id, arguments, tools, on_step)
      end

    post_payload = %{
      phase: "post",
      tool_name: name,
      tool_call_id: id,
      arguments: arguments,
      result: output
    }

    post_result = ToolHooks.run(:post, hook_for(hooks, :post), post_payload, opts)
    emit_step(on_step, Map.merge(%{type: :tool_hook_post, tool: name, id: id}, post_result))

    Message.new(:tool, Jason.encode!(output), %{"tool_call_id" => id, "name" => name})
  end

  defp execute_tool_after_pre(name, id, arguments, tools, on_step) do
    case Enum.find(tools, &(&1.name == name)) do
      nil ->
        tool_error = %ToolError{
          message: "Unknown tool",
          type: :unknown_tool,
          tool_name: to_string(name),
          tool_call_id: to_string(id),
          retryable: false,
          details: %{"name" => name}
        }

        result = %{
          "status" => "error",
          "error" => Exception.message(tool_error),
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
                  tool_call_id: to_string(id),
                  retryable: false,
                  details: %{"reason" => inspect(reason)}
                }

                %{
                  "status" => "error",
                  "error" => Exception.message(tool_error),
                  "type" => tool_error.type
                }

              map when is_map(map) ->
                %{"status" => "ok", "result" => map}

              other ->
                %{"status" => "ok", "result" => %{"value" => inspect(other)}}
            end
          rescue
            exception ->
              tool_error = %ToolError{
                message: "Tool raised exception",
                type: :execution_failed,
                tool_name: tool.name,
                tool_call_id: to_string(id),
                retryable: false,
                details: %{"exception" => Exception.message(exception)}
              }

              %{
                "status" => "error",
                "error" => Exception.message(tool_error),
                "type" => tool_error.type
              }
          end

        emit_step(on_step, %{type: :tool_result, tool: name, status: output["status"], id: id})
        output

      %Tool{} ->
        tool_error = %ToolError{
          message: "Tool has no execute handler",
          type: :invalid_tool_call,
          tool_name: to_string(name),
          tool_call_id: to_string(id),
          retryable: false,
          details: %{"name" => name}
        }

        result = %{
          "status" => "error",
          "error" => Exception.message(tool_error),
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

  defp emit_step(callback, payload) when is_function(callback, 1), do: callback.(payload)
  defp emit_step(_, _), do: :ok

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
    case Map.get(adapters, provider) do
      nil -> {:error, {:unknown_provider, provider}}
      adapter -> {:ok, adapter}
    end
  end

  defp resolve_adapter(%__MODULE__{default_provider: default_provider} = client, %Request{
         provider: nil,
         model: model
       }) do
    cond do
      is_binary(default_provider) and default_provider != "" ->
        resolve_adapter(client, %Request{provider: default_provider, model: model})

      true ->
        with {:ok, provider} <- infer_provider(model) do
          {:error, {:provider_not_explicit, provider}}
        end
    end
  end

  defp infer_provider(model) when is_binary(model) do
    cond do
      String.starts_with?(model, "gpt") -> {:ok, "openai"}
      String.starts_with?(model, "claude") -> {:ok, "anthropic"}
      String.starts_with?(model, "gemini") -> {:ok, "gemini"}
      true -> {:error, :provider_inference_failed}
    end
  end

  defp env_provider_keys do
    [
      {"openai", System.get_env("OPENAI_API_KEY")},
      {"anthropic", System.get_env("ANTHROPIC_API_KEY")},
      {"gemini", System.get_env("GEMINI_API_KEY")},
      {"zai", System.get_env("ZAI_API_KEY")},
      {"zai_coding_plan", System.get_env("ZAI_CODING_PLAN_API_KEY")},
      {"openrouter", System.get_env("OPENROUTER_API_KEY")},
      {"xai", System.get_env("XAI_API_KEY")}
    ]
    |> Enum.filter(fn {_provider, value} -> is_binary(value) and value != "" end)
  end

  defp discover_env_adapters(opts) do
    api_adapters =
      env_provider_keys()
      |> Enum.reduce(%{}, fn {provider, _value}, acc ->
        adapter =
          case provider do
            "openai" -> OpenAI
            "anthropic" -> Anthropic
            "gemini" -> Gemini
            "zai" -> Zai
            "zai_coding_plan" -> ZaiCodingPlan
            "openrouter" -> OpenRouter
            "xai" -> XAI
            _ -> nil
          end

        if adapter, do: Map.put(acc, provider, adapter), else: acc
      end)

    adapters =
      if Keyword.get(opts, :discover_cli, true) do
        api_adapters
        |> maybe_add_claude_cli()
        |> maybe_add_arborcli()
      else
        api_adapters
      end

    if Keyword.get(opts, :discover_local, true) do
      adapters
      |> maybe_add_local("lm_studio", LMStudio)
      |> maybe_add_local("ollama", Ollama)
    else
      adapters
    end
  end

  defp maybe_add_claude_cli(adapters) do
    cli_mod = Arbor.Orchestrator.UnifiedLLM.Adapters.ClaudeCli

    if cli_mod.available?() do
      Map.put(adapters, "claude_cli", cli_mod)
    else
      adapters
    end
  end

  defp maybe_add_arborcli(adapters) do
    arborcli_mod = Arbor.Orchestrator.UnifiedLLM.Adapters.Arborcli

    if Code.ensure_loaded?(arborcli_mod) and arborcli_mod.available?() do
      Map.put(adapters, "arborcli", arborcli_mod)
    else
      adapters
    end
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
      case Map.get(@llmdb_provider_map, provider) do
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
        case Map.get(@llmdb_provider_map, name) do
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
          case Map.get(@llmdb_provider_map, name) do
            nil ->
              nil

            llmdb_id ->
              case llmdb_model(llmdb_id, model_id) do
                {:ok, model} -> {:ok, model_to_map(model)}
                _ -> nil
              end
          end
        end)

      result || {:error, :model_not_found}
    else
      {:error, :model_not_found}
    end
  end

  defp model_to_map(%{__struct__: _} = model) do
    %{
      id: model.id,
      name: model.name,
      family: model.family || get_in(Map.get(model, :extra, nil) || %{}, [:family]),
      provider: to_string(Map.get(@llmdb_provider_reverse_map, model.provider, model.provider)),
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

  defp maybe_add_local(adapters, name, module) do
    if module.available?() do
      Map.put(adapters, name, module)
    else
      adapters
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: to_string(value)
end
