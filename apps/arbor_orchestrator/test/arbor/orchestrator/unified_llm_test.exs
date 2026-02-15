defmodule Arbor.Orchestrator.UnifiedLLMTest do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.UnifiedLLM.{
    Client,
    ConfigurationError,
    Message,
    Request,
    RequestTimeoutError,
    Response,
    StreamEvent,
    Tool
  }

  defmodule TestAdapter do
    @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

    @impl true
    def provider, do: "test"

    @impl true
    def complete(%Request{} = request, _opts) do
      {:ok,
       %Response{
         text: "ok:" <> request.model,
         finish_reason: :stop,
         usage: %{input_tokens: 1, output_tokens: 1}
       }}
    end

    @impl true
    def stream(%Request{} = request, _opts) do
      events = [
        %StreamEvent{type: :start, data: %{model: request.model}},
        %StreamEvent{type: :delta, data: %{text: "hello "}},
        %StreamEvent{type: :delta, data: %{text: "world"}},
        %StreamEvent{type: :finish, data: %{reason: :stop}}
      ]

      events
    end
  end

  defmodule ToolLoopAdapter do
    @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

    @impl true
    def provider, do: "tool-loop"

    @impl true
    def complete(%Request{} = request, _opts) do
      has_tool_result =
        Enum.any?(request.messages, fn msg ->
          msg.role == :tool
        end)

      if has_tool_result do
        {:ok, %Response{text: "final answer", finish_reason: :stop, raw: %{}}}
      else
        {:ok,
         %Response{
           text: "need tools",
           finish_reason: :tool_calls,
           raw: %{
             "tool_calls" => [
               %{"id" => "1", "name" => "lookup", "arguments" => %{"k" => "a"}},
               %{"id" => "2", "name" => "lookup", "arguments" => %{"k" => "b"}}
             ]
           }
         }}
      end
    end
  end

  defmodule RetryAdapter do
    @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

    @impl true
    def provider, do: "retry-adapter"

    @impl true
    def complete(_request, opts) do
      parent = Keyword.fetch!(opts, :parent)
      send(parent, :adapter_called)

      case Process.get(:retry_adapter_calls, 0) do
        0 ->
          Process.put(:retry_adapter_calls, 1)

          {:error,
           Arbor.Orchestrator.UnifiedLLM.ProviderError.exception(
             message: "transient",
             provider: "retry-adapter",
             retryable: true
           )}

        _ ->
          {:ok, %Response{text: "ok-after-retry", raw: %{}}}
      end
    end
  end

  defmodule StepTimeoutAdapter do
    @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

    @impl true
    def provider, do: "step-timeout-adapter"

    @impl true
    def complete(_request, opts) do
      parent = Keyword.fetch!(opts, :parent)
      send(parent, :step_timeout_adapter_called)
      Process.sleep(40)
      {:ok, %Response{text: "late", finish_reason: :stop, raw: %{}}}
    end
  end

  defmodule TimeoutThenSuccessAdapter do
    @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

    @impl true
    def provider, do: "timeout-then-success-adapter"

    @impl true
    def complete(_request, opts) do
      parent = Keyword.fetch!(opts, :parent)
      send(parent, :timeout_then_success_called)

      table = :timeout_then_success_counter

      count =
        if :ets.whereis(table) == :undefined do
          1
        else
          :ets.update_counter(table, :count, {2, 1}, {:count, 0})
        end

      case count do
        1 ->
          Process.sleep(40)
          {:ok, %Response{text: "late", finish_reason: :stop, raw: %{}}}

        _ ->
          {:ok, %Response{text: "ok-after-timeout-retry", finish_reason: :stop, raw: %{}}}
      end
    end
  end

  test "routes requests to registered adapter" do
    client = Client.new() |> Client.register_adapter(TestAdapter)

    request = %Request{
      provider: "test",
      model: "demo-1",
      messages: [Message.new(:user, "hello")]
    }

    assert {:ok, response} = Client.complete(client, request)
    assert response.text == "ok:demo-1"
  end

  test "returns error for unknown provider" do
    client = Client.new()
    request = %Request{provider: "missing", model: "m", messages: []}

    assert {:error, {:unknown_provider, "missing"}} = Client.complete(client, request)
  end

  test "uses default provider when request provider is omitted" do
    client =
      Client.new(default_provider: "test")
      |> Client.register_adapter(TestAdapter)

    request = %Request{provider: nil, model: "demo", messages: []}

    assert {:ok, response} = Client.complete(client, request)
    assert response.text == "ok:demo"
  end

  test "from_env raises when no default provider and no provider keys are configured" do
    with_env(
      %{
        "UNIFIED_LLM_DEFAULT_PROVIDER" => nil,
        "OPENAI_API_KEY" => nil,
        "ANTHROPIC_API_KEY" => nil,
        "GEMINI_API_KEY" => nil,
        "ZAI_API_KEY" => nil,
        "ZAI_CODING_PLAN_API_KEY" => nil,
        "OPENROUTER_API_KEY" => nil,
        "XAI_API_KEY" => nil
      },
      fn ->
        assert_raise ConfigurationError, fn ->
          Client.from_env(discover_cli: false, discover_local: false)
        end
      end
    )
  end

  test "from_env sets default provider from environment" do
    with_env(
      %{
        "UNIFIED_LLM_DEFAULT_PROVIDER" => "test",
        "OPENAI_API_KEY" => nil,
        "ANTHROPIC_API_KEY" => nil,
        "GEMINI_API_KEY" => nil,
        "ZAI_API_KEY" => nil,
        "ZAI_CODING_PLAN_API_KEY" => nil,
        "OPENROUTER_API_KEY" => nil,
        "XAI_API_KEY" => nil
      },
      fn ->
        client = Client.from_env(discover_local: false)
        assert client.default_provider == "test"
      end
    )
  end

  test "from_env auto-discovers adapters from provider api keys" do
    with_env(
      %{
        "UNIFIED_LLM_DEFAULT_PROVIDER" => nil,
        "OPENAI_API_KEY" => "sk-live",
        "ANTHROPIC_API_KEY" => nil,
        "GEMINI_API_KEY" => nil,
        "ZAI_API_KEY" => nil,
        "ZAI_CODING_PLAN_API_KEY" => nil,
        "OPENROUTER_API_KEY" => nil,
        "XAI_API_KEY" => nil
      },
      fn ->
        client = Client.from_env(discover_cli: false, discover_local: false)
        assert client.default_provider == "openai"
        assert Map.has_key?(client.adapters, "openai")
      end
    )
  end

  test "default client can be set and retrieved" do
    :ok = Client.clear_default_client()
    on_exit(fn -> Client.clear_default_client() end)

    client = Client.new(default_provider: "test")
    assert :ok = Client.set_default_client(client)
    assert %Client{default_provider: "test"} = Client.default_client()
  end

  test "list_models and get_model_info expose model catalog" do
    # With explicit catalog (non-LLMDB mode)
    catalog = %{
      "test" => [
        %{id: "gpt-5", family: "gpt-5", modalities: [:text, :tools]},
        %{id: "gpt-5-mini", family: "gpt-5", modalities: [:text, :tools]}
      ]
    }

    client = Client.new(model_catalog: catalog)
    models = Client.list_models(client)

    assert Enum.any?(models, &(&1.id == "gpt-5"))
    assert {:ok, info} = Client.get_model_info(client, "gpt-5")
    assert info.family == "gpt-5"
    assert {:error, :model_not_found} = Client.get_model_info(client, "missing-model")
  end

  test "list_models queries LLMDB when catalog is :llmdb" do
    # Register an adapter so LLMDB knows which providers to query
    client =
      Client.new()
      |> Client.register_adapter(Arbor.Orchestrator.UnifiedLLM.Adapters.XAI)

    models = Client.list_models(client, provider: "xai")
    assert length(models) > 0
    assert Enum.any?(models, &(&1.id == "grok-4-1-fast"))

    # Each model has the expected fields from LLMDB
    model = Enum.find(models, &(&1.id == "grok-4-1-fast"))
    assert model.provider == "xai"
    assert is_map(model.capabilities)
    assert is_map(model.cost)
  end

  test "get_model_info queries LLMDB for registered providers" do
    client =
      Client.new()
      |> Client.register_adapter(Arbor.Orchestrator.UnifiedLLM.Adapters.XAI)

    assert {:ok, info} = Client.get_model_info(client, "grok-4-1-fast")
    assert info.id == "grok-4-1-fast"
    assert info.provider == "xai"
    assert {:error, :model_not_found} = Client.get_model_info(client, "nonexistent-model-xyz")
  end

  test "select_model finds best model matching capabilities" do
    client =
      Client.new()
      |> Client.register_adapter(Arbor.Orchestrator.UnifiedLLM.Adapters.XAI)

    assert {:ok, result} = Client.select_model(client, require: [chat: true], provider: "xai")
    assert result.provider == "xai"
    assert is_binary(result.model)
    assert result.info != nil
  end

  test "select_model returns error for unmapped provider" do
    client = Client.new()
    assert {:error, :no_matching_model} = Client.select_model(client, provider: "nonexistent")
  end

  test "middleware wraps adapter call" do
    middleware = fn req, next ->
      req = %{req | model: req.model <> "-mw"}
      next.(req)
    end

    client = Client.new(middleware: [middleware]) |> Client.register_adapter(TestAdapter)
    request = %Request{provider: "test", model: "demo", messages: []}

    assert {:ok, response} = Client.complete(client, request)
    assert response.text == "ok:demo-mw"
  end

  test "streams events through adapter and collects response" do
    client = Client.new() |> Client.register_adapter(TestAdapter)
    request = %Request{provider: "test", model: "stream-demo", messages: []}

    assert {:ok, stream} = Client.stream(client, request)
    assert {:ok, response} = Client.collect_stream(stream)
    assert response.text == "hello world"
    assert response.finish_reason == :stop
  end

  test "stream middleware wraps stream request" do
    stream_middleware = fn req, next ->
      req = %{req | model: req.model <> "-mw"}
      next.(req)
    end

    client =
      Client.new(stream_middleware: [stream_middleware])
      |> Client.register_adapter(TestAdapter)

    request = %Request{provider: "test", model: "s", messages: []}

    assert {:ok, stream} = Client.stream(client, request)
    assert {:ok, response} = Client.collect_stream(stream)
    assert response.text == "hello world"
  end

  test "generate_with_tools performs tool-call loop to completion" do
    client = Client.new() |> Client.register_adapter(ToolLoopAdapter)

    request = %Request{
      provider: "tool-loop",
      model: "demo",
      messages: [Message.new(:user, "find values")]
    }

    tool =
      %Tool{
        name: "lookup",
        execute: fn %{"k" => key} -> %{"value" => "v:" <> key} end
      }

    assert {:ok, response} = Client.generate_with_tools(client, request, [tool], max_steps: 4)
    assert response.text == "final answer"
  end

  test "generate_with_tools supports parallel tool execution" do
    client = Client.new() |> Client.register_adapter(ToolLoopAdapter)

    request = %Request{
      provider: "tool-loop",
      model: "demo",
      messages: [Message.new(:user, "parallel")]
    }

    parent = self()

    tool =
      %Tool{
        name: "lookup",
        execute: fn args ->
          send(parent, {:tool_executed, args["k"]})
          %{ok: true}
        end
      }

    assert {:ok, _response} =
             Client.generate_with_tools(client, request, [tool],
               max_steps: 4,
               parallel_tool_execution: true
             )

    assert_receive {:tool_executed, "a"}
    assert_receive {:tool_executed, "b"}
  end

  test "generate_with_tools can repair invalid tool calls before execution" do
    client = Client.new() |> Client.register_adapter(ToolLoopAdapter)

    request = %Request{
      provider: "tool-loop",
      model: "demo",
      messages: [Message.new(:user, "repair tool call")]
    }

    tool =
      %Tool{
        name: "lookup",
        execute: fn %{"k" => _key} -> %{ok: true} end
      }

    validate_tool_call = fn _call, _tools -> {:error, :invalid_arguments} end

    repair_tool_call = fn call, _reason, _tools ->
      {:ok, Map.put(call, "arguments", %{"k" => "repaired"})}
    end

    assert {:ok, response} =
             Client.generate_with_tools(client, request, [tool],
               validate_tool_call: validate_tool_call,
               repair_tool_call: repair_tool_call
             )

    assert response.text == "final answer"
  end

  test "generate_with_tools retries llm step with retry policy" do
    Process.delete(:retry_adapter_calls)
    client = Client.new() |> Client.register_adapter(RetryAdapter)
    request = %Request{provider: "retry-adapter", model: "demo", messages: []}
    parent = self()

    assert {:ok, response} =
             Client.generate_with_tools(client, request, [],
               retry: [max_retries: 2, initial_delay_ms: 1],
               sleep_fn: fn _ -> :ok end,
               parent: parent
             )

    assert response.text == "ok-after-retry"
    assert_receive :adapter_called
    assert_receive :adapter_called
  end

  test "tool pre-hook can skip tool execution" do
    client = Client.new() |> Client.register_adapter(ToolLoopAdapter)

    request = %Request{
      provider: "tool-loop",
      model: "demo",
      messages: [Message.new(:user, "skip hook")]
    }

    parent = self()

    tool =
      %Tool{
        name: "lookup",
        execute: fn _args ->
          send(parent, :tool_executed)
          %{ok: true}
        end
      }

    pre = fn _payload -> :skip end

    assert {:ok, response} =
             Client.generate_with_tools(client, request, [tool], tool_hooks: %{pre: pre})

    assert response.text == "final answer"
    refute_receive :tool_executed
  end

  test "tool post-hook failure is emitted and does not fail run" do
    client = Client.new() |> Client.register_adapter(ToolLoopAdapter)

    request = %Request{
      provider: "tool-loop",
      model: "demo",
      messages: [Message.new(:user, "post hook")]
    }

    parent = self()

    on_step = fn event -> send(parent, {:step, event}) end
    post = fn _payload -> {:error, :audit_sink_down} end

    tool = %Tool{name: "lookup", execute: fn _args -> %{ok: true} end}

    assert {:ok, response} =
             Client.generate_with_tools(client, request, [tool],
               tool_hooks: %{post: post},
               on_step: on_step
             )

    assert response.text == "final answer"
    assert_receive {:step, %{type: :tool_hook_post, status: :error}}
  end

  test "generate_with_tools returns RequestTimeoutError when a step exceeds max_step_timeout_ms" do
    client = Client.new() |> Client.register_adapter(StepTimeoutAdapter)
    request = %Request{provider: "step-timeout-adapter", model: "demo", messages: []}

    assert {:error, %RequestTimeoutError{timeout_ms: 5}} =
             Client.generate_with_tools(client, request, [],
               max_steps: 2,
               max_step_timeout_ms: 5,
               retry: [max_retries: 0],
               parent: self()
             )

    assert_receive :step_timeout_adapter_called
  end

  test "generate_with_tools retries step timeout and can recover" do
    if :ets.whereis(:timeout_then_success_counter) != :undefined do
      :ets.delete(:timeout_then_success_counter)
    end

    :ets.new(:timeout_then_success_counter, [:named_table, :public])

    client = Client.new() |> Client.register_adapter(TimeoutThenSuccessAdapter)
    request = %Request{provider: "timeout-then-success-adapter", model: "demo", messages: []}

    assert {:ok, response} =
             Client.generate_with_tools(client, request, [],
               max_steps: 2,
               max_step_timeout_ms: 20,
               retry: [max_retries: 1, initial_delay_ms: 1],
               sleep_fn: fn _ -> :ok end,
               parent: self()
             )

    assert response.text == "ok-after-timeout-retry"
    assert_receive :timeout_then_success_called
    assert_receive :timeout_then_success_called
  end

  defp with_env(changes, fun) do
    previous =
      Enum.map(changes, fn {key, _value} ->
        {key, System.get_env(key)}
      end)

    Enum.each(changes, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
