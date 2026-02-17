defmodule Arbor.Orchestrator.UnifiedLLM.HighLevelApiTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.UnifiedLLM
  alias Arbor.Orchestrator.UnifiedLLM.{
    AbortError,
    Client,
    Message,
    NoObjectGeneratedError,
    Request,
    RequestTimeoutError,
    Response,
    StreamEvent,
    Tool
  }

  defmodule HighLevelAdapter do
    @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

    @impl true
    def provider, do: "high-level-test"

    @impl true
    def complete(%Request{} = request, _opts) do
      if request.model == "error-model" do
        {:error, :provider_failed}
      else
        if request.model == "slow-model" do
          Process.sleep(40)
        end

        text =
          request.messages
          |> Enum.map_join("|", fn msg ->
            "#{msg.role}:#{Message.text(msg)}"
          end)

        if request.model == "json-model" do
          {:ok, %Response{text: ~s({"ok":true}), finish_reason: :stop, raw: %{}}}
        else
          {:ok, %Response{text: text, finish_reason: :stop, raw: %{}}}
        end
      end
    end

    @impl true
    def stream(%Request{} = request, _opts) do
      if request.model == "slow-stream" do
        Process.sleep(40)
      end

      if request.model == "json-stream-model" do
        [
          %StreamEvent{type: :start, data: %{}},
          %StreamEvent{type: :delta, data: %{"text" => "{\"ok\":"}},
          %StreamEvent{type: :delta, data: %{"text" => "true}"}},
          %StreamEvent{type: :finish, data: %{"reason" => :stop}}
        ]
      else
        if request.model == "bad-json-stream-model" do
          [
            %StreamEvent{type: :start, data: %{}},
            %StreamEvent{type: :delta, data: %{"text" => "{\"ok\":"}},
            %StreamEvent{type: :finish, data: %{"reason" => :stop}}
          ]
        else
          if request.model == "slow-event-stream" do
            Stream.resource(
              fn -> 0 end,
              fn
                0 ->
                  {[%StreamEvent{type: :start, data: %{}}], 1}

                1 ->
                  Process.sleep(40)
                  {[%StreamEvent{type: :delta, data: %{"text" => "hello"}}], 2}

                2 ->
                  Process.sleep(40)
                  {[%StreamEvent{type: :finish, data: %{"reason" => :stop}}], 3}

                _ ->
                  {:halt, 3}
              end,
              fn _ -> :ok end
            )
          else
            [
              %StreamEvent{type: :start, data: %{}},
              %StreamEvent{type: :delta, data: %{"text" => "hello"}},
              %StreamEvent{type: :finish, data: %{"reason" => :stop}}
            ]
          end
        end
      end
    end
  end

  defmodule ToolLoopAdapter do
    @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

    @impl true
    def provider, do: "tool-loop-high-level"

    @impl true
    def complete(%Request{} = request, _opts) do
      if Enum.any?(request.messages, &(&1.role == :tool)) do
        {:ok, %Response{text: "done", finish_reason: :stop, raw: %{}}}
      else
        {:ok,
         %Response{
           text: "need tool",
           finish_reason: :tool_calls,
           raw: %{"tool_calls" => [%{"id" => "1", "name" => "lookup", "arguments" => %{}}]}
         }}
      end
    end
  end

  defmodule SlowToolLoopAdapter do
    @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

    @impl true
    def provider, do: "slow-tool-loop-high-level"

    @impl true
    def complete(%Request{} = request, _opts) do
      if Enum.any?(request.messages, &(&1.role == :tool)) do
        {:ok, %Response{text: "done", finish_reason: :stop, raw: %{}}}
      else
        Process.sleep(40)

        {:ok,
         %Response{
           text: "need tool",
           finish_reason: :tool_calls,
           raw: %{"tool_calls" => [%{"id" => "1", "name" => "lookup", "arguments" => %{}}]}
         }}
      end
    end
  end

  defmodule StreamToolLoopAdapter do
    @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

    @impl true
    def provider, do: "stream-tool-loop-high-level"

    @impl true
    def complete(_request, _opts), do: {:error, :not_supported}

    @impl true
    def stream(%Request{} = request, opts) do
      if parent = opts[:parent],
        do: send(parent, {:stream_call, Enum.map(request.messages, & &1.role)})

      if Enum.any?(request.messages, &(&1.role == :tool)) do
        [
          %StreamEvent{type: :start, data: %{}},
          %StreamEvent{type: :delta, data: %{"text" => "done"}},
          %StreamEvent{type: :finish, data: %{"reason" => :stop}}
        ]
      else
        [
          %StreamEvent{type: :start, data: %{}},
          %StreamEvent{
            type: :tool_call,
            data: %{"id" => "c1", "name" => "lookup", "arguments" => %{"q" => "x"}}
          },
          %StreamEvent{type: :finish, data: %{"reason" => :tool_calls}}
        ]
      end
    end
  end

  test "generate accepts prompt" do
    client =
      Client.new(default_provider: "high-level-test") |> Client.register_adapter(HighLevelAdapter)

    assert {:ok, response} =
             UnifiedLLM.generate(
               client: client,
               model: "demo",
               prompt: "hi"
             )

    assert response.text =~ "user:hi"
  end

  test "generate accepts messages with optional system" do
    client =
      Client.new(default_provider: "high-level-test") |> Client.register_adapter(HighLevelAdapter)

    messages = [Message.new(:user, "hello")]

    assert {:ok, response} =
             UnifiedLLM.generate(
               client: client,
               model: "demo",
               system: "rules",
               messages: messages
             )

    assert response.text =~ "system:rules"
    assert response.text =~ "user:hello"
  end

  test "generate rejects both prompt and messages" do
    client =
      Client.new(default_provider: "high-level-test") |> Client.register_adapter(HighLevelAdapter)

    assert {:error, :prompt_and_messages_mutually_exclusive} =
             UnifiedLLM.generate(
               client: client,
               model: "demo",
               prompt: "x",
               messages: [Message.new(:user, "y")]
             )
  end

  test "stream returns enumerable stream events" do
    client =
      Client.new(default_provider: "high-level-test") |> Client.register_adapter(HighLevelAdapter)

    assert {:ok, stream} =
             UnifiedLLM.stream(
               client: client,
               model: "demo",
               prompt: "hi"
             )

    assert Enum.any?(stream, &match?(%StreamEvent{type: :delta}, &1))
  end

  test "generate_object parses json object and validates with callback" do
    client =
      Client.new(default_provider: "high-level-test") |> Client.register_adapter(HighLevelAdapter)

    assert {:ok, %{"ok" => true}} =
             UnifiedLLM.generate_object(
               client: client,
               model: "json-model",
               prompt: "hi",
               validate_object: fn %{"ok" => true} -> :ok end
             )
  end

  test "generate_object validates with schema and reports NoObjectGeneratedError on schema failure" do
    client =
      Client.new(default_provider: "high-level-test") |> Client.register_adapter(HighLevelAdapter)

    assert {:ok, %{"ok" => true}} =
             UnifiedLLM.generate_object(
               client: client,
               model: "json-model",
               prompt: "hi",
               schema: %{
                 "type" => "object",
                 "properties" => %{"ok" => %{"type" => "boolean"}},
                 "required" => ["ok"]
               }
             )

    assert {:error, %NoObjectGeneratedError{reason: {:schema_property_invalid, "ok", _}}} =
             UnifiedLLM.generate_object(
               client: client,
               model: "json-model",
               prompt: "hi",
               schema: %{
                 "type" => "object",
                 "properties" => %{"ok" => %{"type" => "integer"}},
                 "required" => ["ok"]
               }
             )
  end

  test "stream_object emits parsed object updates and validates final output" do
    client =
      Client.new(default_provider: "high-level-test") |> Client.register_adapter(HighLevelAdapter)

    assert {:ok, object_stream} =
             UnifiedLLM.stream_object(
               client: client,
               model: "json-stream-model",
               prompt: "hi",
               schema: %{
                 "type" => "object",
                 "properties" => %{"ok" => %{"type" => "boolean"}},
                 "required" => ["ok"]
               }
             )

    assert [%{"ok" => true}] = Enum.to_list(object_stream)
  end

  test "stream_object raises NoObjectGeneratedError when final output is invalid" do
    client =
      Client.new(default_provider: "high-level-test") |> Client.register_adapter(HighLevelAdapter)

    assert {:ok, object_stream} =
             UnifiedLLM.stream_object(
               client: client,
               model: "bad-json-stream-model",
               prompt: "hi"
             )

    assert_raise NoObjectGeneratedError, fn -> Enum.to_list(object_stream) end
  end

  test "generate_object returns NoObjectGeneratedError on invalid json output" do
    client =
      Client.new(default_provider: "high-level-test") |> Client.register_adapter(HighLevelAdapter)

    assert {:error, %NoObjectGeneratedError{reason: :no_object_generated}} =
             UnifiedLLM.generate_object(
               client: client,
               model: "demo",
               prompt: "hi"
             )
  end

  test "generate can run tool loop through high-level API" do
    client = Client.new(default_provider: "tool-loop-high-level")

    client = Client.register_adapter(client, ToolLoopAdapter)
    tool = %Tool{name: "lookup", execute: fn _ -> %{"ok" => true} end}

    assert {:ok, response} =
             UnifiedLLM.generate(
               client: client,
               model: "demo",
               prompt: "run",
               tools: [tool],
               max_tool_rounds: 2
             )

    assert response.text == "done"
  end

  test "generate with stop_when halts before tool execution loop continues" do
    client = Client.new(default_provider: "tool-loop-high-level")
    client = Client.register_adapter(client, ToolLoopAdapter)

    parent = self()

    tool =
      %Tool{
        name: "lookup",
        execute: fn _ ->
          send(parent, :tool_executed)
          %{"ok" => true}
        end
      }

    stop_when = fn %{tool_calls: tool_calls} -> tool_calls != [] end

    assert {:ok, response} =
             UnifiedLLM.generate(
               client: client,
               model: "demo",
               prompt: "run",
               tools: [tool],
               max_tool_rounds: 2,
               stop_when: stop_when
             )

    assert response.finish_reason == :tool_calls
    refute_receive :tool_executed
  end

  test "generate returns RequestTimeoutError when timeout_ms is exceeded" do
    client =
      Client.new(default_provider: "high-level-test") |> Client.register_adapter(HighLevelAdapter)

    assert {:error, %RequestTimeoutError{timeout_ms: 5}} =
             UnifiedLLM.generate(
               client: client,
               model: "slow-model",
               prompt: "hi",
               timeout_ms: 5
             )
  end

  test "stream returns RequestTimeoutError when timeout_ms is exceeded before connection" do
    client =
      Client.new(default_provider: "high-level-test") |> Client.register_adapter(HighLevelAdapter)

    assert {:error, %RequestTimeoutError{timeout_ms: 5}} =
             UnifiedLLM.stream(
               client: client,
               model: "slow-stream",
               prompt: "hi",
               timeout_ms: 5
             )
  end

  test "stream raises RequestTimeoutError when stream_read_timeout_ms is exceeded mid-stream" do
    client =
      Client.new(default_provider: "high-level-test") |> Client.register_adapter(HighLevelAdapter)

    assert {:ok, stream} =
             UnifiedLLM.stream(
               client: client,
               model: "slow-event-stream",
               prompt: "hi",
               stream_read_timeout_ms: 5
             )

    assert_raise RequestTimeoutError, fn -> Enum.to_list(stream) end
  end

  test "generate and stream return AbortError when abort preflight is true" do
    client =
      Client.new(default_provider: "high-level-test") |> Client.register_adapter(HighLevelAdapter)

    assert {:error, %AbortError{}} =
             UnifiedLLM.generate(
               client: client,
               model: "demo",
               prompt: "hi",
               abort?: true
             )

    assert {:error, %AbortError{}} =
             UnifiedLLM.stream(
               client: client,
               model: "demo",
               prompt: "hi",
               abort?: fn -> true end
             )
  end

  test "stream raises AbortError when abort signal triggers after stream starts" do
    client =
      Client.new(default_provider: "high-level-test") |> Client.register_adapter(HighLevelAdapter)

    abort_state = :atomics.new(1, [])
    :atomics.put(abort_state, 1, 0)

    assert {:ok, stream} =
             UnifiedLLM.stream(
               client: client,
               model: "slow-event-stream",
               prompt: "hi",
               abort?: fn -> :atomics.get(abort_state, 1) == 1 end
             )

    assert_raise AbortError, fn ->
      Enum.reduce(stream, 0, fn _event, idx ->
        if idx == 0, do: :atomics.put(abort_state, 1, 1)
        idx + 1
      end)
    end
  end

  test "generate_object preserves upstream generation errors" do
    client =
      Client.new(default_provider: "high-level-test") |> Client.register_adapter(HighLevelAdapter)

    assert {:error, :provider_failed} =
             UnifiedLLM.generate_object(
               client: client,
               model: "error-model",
               prompt: "hi"
             )
  end

  test "generate with tools supports per-step timeout and timeout retry recovery" do
    Process.delete(:timeout_then_success_calls)
    client = Client.new(default_provider: "slow-tool-loop-high-level")
    client = Client.register_adapter(client, SlowToolLoopAdapter)

    tool = %Tool{name: "lookup", execute: fn _ -> %{"ok" => true} end}

    assert {:error, %RequestTimeoutError{timeout_ms: 5}} =
             UnifiedLLM.generate(
               client: client,
               model: "demo",
               prompt: "run",
               tools: [tool],
               max_tool_rounds: 1,
               max_step_timeout_ms: 5,
               retry: [max_retries: 0]
             )
  end

  test "stream with active tools continues across tool rounds" do
    client = Client.new(default_provider: "stream-tool-loop-high-level")
    client = Client.register_adapter(client, StreamToolLoopAdapter)
    tool = %Tool{name: "lookup", execute: fn _ -> %{"ok" => true} end}

    assert {:ok, stream} =
             UnifiedLLM.stream(
               client: client,
               model: "demo",
               prompt: "run",
               tools: [tool],
               max_tool_rounds: 2,
               client_opts: [parent: self()]
             )

    events = Enum.to_list(stream)
    assert_receive {:stream_call, [:user]}
    assert_receive {:stream_call, roles}
    assert Enum.member?(roles, :tool)

    assert Enum.any?(events, &match?(%StreamEvent{type: :tool_call}, &1))
    assert Enum.any?(events, &match?(%StreamEvent{type: :tool_result}, &1))
    assert Enum.any?(events, &match?(%StreamEvent{type: :step_finish}, &1))
    assert Enum.any?(events, &match?(%StreamEvent{type: :delta, data: %{"text" => "done"}}, &1))
    assert match?(%StreamEvent{type: :finish, data: %{"reason" => :stop}}, List.last(events))
  end
end
