defmodule Arbor.LLM.Conformance84Test do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.LLM

  alias Arbor.LLM.AbortError

  alias Arbor.LLM.Client

  alias Arbor.LLM.Message

  alias Arbor.LLM.NoObjectGeneratedError

  alias Arbor.LLM.ProviderError

  alias Arbor.LLM.Request

  alias Arbor.LLM.RequestTimeoutError

  alias Arbor.LLM.Response

  alias Arbor.LLM.StreamEvent

  alias Arbor.LLM.Tool

  defmodule Adapter do
    @behaviour Arbor.LLM.ProviderAdapter

    @impl true
    def provider, do: "conformance-84"

    @impl true
    def complete(%Request{} = request, _opts) do
      if request.model == "slow-model" do
        Process.sleep(40)
      end

      has_prompt_message = Enum.any?(request.messages, &(&1.role == :user))

      if request.model == "json-model" do
        {:ok, %Response{text: ~s({"ok":true}), finish_reason: :stop, raw: %{}}}
      else
        {:ok,
         %Response{
           text: if(has_prompt_message, do: "ok", else: "missing"),
           finish_reason: :stop,
           raw: %{}
         }}
      end
    end

    @impl true
    def stream(%Request{} = request, _opts) do
      if request.model == "slow-stream" do
        Process.sleep(40)
      end

      cond do
        request.model == "json-stream-model" ->
          [
            %StreamEvent{type: :start, data: %{}},
            %StreamEvent{type: :delta, data: %{"text" => "{\"ok\":"}},
            %StreamEvent{type: :delta, data: %{"text" => "true}"}},
            %StreamEvent{type: :finish, data: %{"reason" => :stop}}
          ]

        request.model == "bad-json-stream-model" ->
          [
            %StreamEvent{type: :start, data: %{}},
            %StreamEvent{type: :delta, data: %{"text" => "{\"ok\":"}},
            %StreamEvent{type: :finish, data: %{"reason" => :stop}}
          ]

        request.model == "slow-event-stream" ->
          Stream.resource(
            fn -> 0 end,
            fn
              0 ->
                {[%StreamEvent{type: :start, data: %{}}], 1}

              1 ->
                Process.sleep(40)
                {[%StreamEvent{type: :delta, data: %{"text" => "hi"}}], 2}

              2 ->
                Process.sleep(40)
                {[%StreamEvent{type: :finish, data: %{"reason" => :stop}}], 3}

              _ ->
                {:halt, 3}
            end,
            fn _ -> :ok end
          )

        true ->
          [
            %StreamEvent{type: :start, data: %{}},
            %StreamEvent{type: :delta, data: %{"text" => "hi"}},
            %StreamEvent{type: :finish, data: %{"reason" => :stop}}
          ]
      end
    end
  end

  defmodule ToolLoopAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    @impl true
    def provider, do: "conformance-84-tool-loop"

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
    @behaviour Arbor.LLM.ProviderAdapter

    @impl true
    def provider, do: "conformance-84-slow-tool-loop"

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
    @behaviour Arbor.LLM.ProviderAdapter

    @impl true
    def provider, do: "conformance-84-stream-tool-loop"

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

  defmodule StreamMixedToolLoopAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    @impl true
    def provider, do: "conformance-84-stream-mixed-tool-loop"

    @impl true
    def complete(_request, _opts), do: {:error, :not_supported}

    @impl true
    def stream(%Request{} = request, _opts) do
      if Enum.any?(request.messages, &(&1.role == :tool)) do
        [
          %StreamEvent{type: :start, data: %{}},
          %StreamEvent{type: :delta, data: %{"text" => "mixed-done"}},
          %StreamEvent{type: :finish, data: %{"reason" => :stop}}
        ]
      else
        [
          %StreamEvent{type: :start, data: %{}},
          %StreamEvent{
            type: :tool_call,
            data: %{"id" => "c1", "name" => "lookup_ok", "arguments" => %{"q" => "x"}}
          },
          %StreamEvent{
            type: :tool_call,
            data: %{"id" => "c2", "name" => "lookup_fail", "arguments" => %{"q" => "y"}}
          },
          %StreamEvent{type: :finish, data: %{"reason" => :tool_calls}}
        ]
      end
    end
  end

  defmodule RetryStreamAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    @impl true
    def provider, do: "conformance-84-retry-stream"

    @impl true
    def complete(_request, _opts), do: {:error, :not_supported}

    @impl true
    def stream(%Request{} = _request, opts) do
      counter = Keyword.fetch!(opts, :retry_counter)

      case :atomics.add_get(counter, 1, 1) do
        1 ->
          {:error,
           ProviderError.exception(
             message: "transient stream setup failure",
             provider: "conformance-84-retry-stream",
             status: 503,
             retryable: true
           )}

        _ ->
          [
            %StreamEvent{type: :start, data: %{}},
            %StreamEvent{type: :delta, data: %{"text" => "recovered"}},
            %StreamEvent{type: :finish, data: %{"reason" => :stop}}
          ]
      end
    end
  end

  test "8.4 generate works with prompt and messages and rejects both together" do
    client = Client.new(default_provider: "conformance-84") |> Client.register_adapter(Adapter)

    assert {:ok, _} =
             LLM.generate(
               client: client,
               model: "demo",
               prompt: "hello"
             )

    assert {:ok, _} =
             LLM.generate(
               client: client,
               model: "demo",
               messages: [Message.new(:user, "hello")]
             )

    assert {:error, :prompt_and_messages_mutually_exclusive} =
             LLM.generate(
               client: client,
               model: "demo",
               prompt: "a",
               messages: [Message.new(:user, "b")]
             )
  end

  test "8.4 stream emits start/delta/finish and text collects" do
    client = Client.new(default_provider: "conformance-84") |> Client.register_adapter(Adapter)

    assert {:ok, stream} =
             LLM.stream(client: client, model: "demo", prompt: "hello")

    assert [%StreamEvent{type: :start}, %StreamEvent{type: :delta}, %StreamEvent{type: :finish}] =
             Enum.to_list(stream)
  end

  test "8.4 generate_object parses valid object and returns NoObjectGeneratedError on failure" do
    client = Client.new(default_provider: "conformance-84") |> Client.register_adapter(Adapter)

    assert {:ok, %{"ok" => true}} =
             LLM.generate_object(
               client: client,
               model: "json-model",
               prompt: "hello"
             )

    assert {:error, %NoObjectGeneratedError{}} =
             LLM.generate_object(
               client: client,
               model: "demo",
               prompt: "hello"
             )
  end

  test "8.4 generate_object validates against schema and fails on mismatch" do
    client = Client.new(default_provider: "conformance-84") |> Client.register_adapter(Adapter)

    schema = %{
      "type" => "object",
      "properties" => %{
        "ok" => %{"type" => "boolean"}
      },
      "required" => ["ok"]
    }

    assert {:ok, %{"ok" => true}} =
             LLM.generate_object(
               client: client,
               model: "json-model",
               prompt: "hello",
               schema: schema
             )

    assert {:error, %NoObjectGeneratedError{reason: {:schema_property_invalid, "ok", _}}} =
             LLM.generate_object(
               client: client,
               model: "json-model",
               prompt: "hello",
               schema: %{
                 "type" => "object",
                 "properties" => %{"ok" => %{"type" => "string"}},
                 "required" => ["ok"]
               }
             )
  end

  test "8.4 stream_object emits parsed object updates and validates final output" do
    client = Client.new(default_provider: "conformance-84") |> Client.register_adapter(Adapter)

    assert {:ok, object_stream} =
             LLM.stream_object(
               client: client,
               model: "json-stream-model",
               prompt: "hello",
               schema: %{
                 "type" => "object",
                 "properties" => %{"ok" => %{"type" => "boolean"}},
                 "required" => ["ok"]
               }
             )

    assert [%{"ok" => true}] = Enum.to_list(object_stream)
  end

  test "8.4 stream_object raises NoObjectGeneratedError for invalid final JSON" do
    client = Client.new(default_provider: "conformance-84") |> Client.register_adapter(Adapter)

    assert {:ok, object_stream} =
             LLM.stream_object(
               client: client,
               model: "bad-json-stream-model",
               prompt: "hello"
             )

    assert_raise NoObjectGeneratedError, fn -> Enum.to_list(object_stream) end
  end

  test "8.4 timeout controls return RequestTimeoutError for slow calls" do
    client = Client.new(default_provider: "conformance-84") |> Client.register_adapter(Adapter)

    assert {:error, %RequestTimeoutError{timeout_ms: 5}} =
             LLM.generate(
               client: client,
               model: "slow-model",
               prompt: "hello",
               timeout_ms: 5
             )

    assert {:error, %RequestTimeoutError{timeout_ms: 5}} =
             LLM.stream(
               client: client,
               model: "slow-stream",
               prompt: "hello",
               timeout_ms: 5
             )
  end

  test "8.4 stream read timeout raises RequestTimeoutError during consumption" do
    client = Client.new(default_provider: "conformance-84") |> Client.register_adapter(Adapter)

    assert {:ok, stream} =
             LLM.stream(
               client: client,
               model: "slow-event-stream",
               prompt: "hello",
               stream_read_timeout_ms: 5
             )

    assert_raise RequestTimeoutError, fn -> Enum.to_list(stream) end
  end

  test "8.4 abort preflight returns AbortError" do
    client = Client.new(default_provider: "conformance-84") |> Client.register_adapter(Adapter)

    assert {:error, %AbortError{}} =
             LLM.generate(
               client: client,
               model: "demo",
               prompt: "hello",
               abort?: true
             )

    assert {:error, %AbortError{}} =
             LLM.stream(
               client: client,
               model: "demo",
               prompt: "hello",
               abort?: fn -> true end
             )
  end

  test "8.4 stream abort signal raises AbortError during consumption" do
    client = Client.new(default_provider: "conformance-84") |> Client.register_adapter(Adapter)
    abort_state = :atomics.new(1, [])
    :atomics.put(abort_state, 1, 0)

    assert {:ok, stream} =
             LLM.stream(
               client: client,
               model: "slow-event-stream",
               prompt: "hello",
               abort?: fn -> :atomics.get(abort_state, 1) == 1 end
             )

    assert_raise AbortError, fn ->
      Enum.reduce(stream, 0, fn _event, idx ->
        if idx == 0, do: :atomics.put(abort_state, 1, 1)
        idx + 1
      end)
    end
  end

  test "8.4 generate respects stop_when hook for tool loops" do
    client =
      Client.new(default_provider: "conformance-84-tool-loop")
      |> Client.register_adapter(ToolLoopAdapter)

    tool = %Tool{
      name: "lookup",
      execute: fn _ -> %{"ok" => true} end
    }

    assert {:ok, response} =
             LLM.generate(
               client: client,
               model: "demo",
               prompt: "hello",
               tools: [tool],
               stop_when: fn %{tool_calls: calls} -> calls != [] end
             )

    assert response.finish_reason == :tool_calls
  end

  test "8.4 generate tool loop checks abort signal between steps" do
    client =
      Client.new(default_provider: "conformance-84-tool-loop")
      |> Client.register_adapter(ToolLoopAdapter)

    abort_state = :atomics.new(1, [])
    :atomics.put(abort_state, 1, 0)

    tool = %Tool{
      name: "lookup",
      execute: fn _ -> %{"ok" => true} end
    }

    on_step = fn
      %{type: :llm_response} -> :atomics.put(abort_state, 1, 1)
      _ -> :ok
    end

    assert {:error, %AbortError{}} =
             LLM.generate(
               client: client,
               model: "demo",
               prompt: "hello",
               tools: [tool],
               max_tool_rounds: 2,
               on_step: on_step,
               abort?: fn -> :atomics.get(abort_state, 1) == 1 end
             )
  end

  test "8.4 generate supports per-step timeout on tool loops" do
    client =
      Client.new(default_provider: "conformance-84-slow-tool-loop")
      |> Client.register_adapter(SlowToolLoopAdapter)

    tool = %Tool{
      name: "lookup",
      execute: fn _ -> %{"ok" => true} end
    }

    assert {:error, %RequestTimeoutError{timeout_ms: 5}} =
             LLM.generate(
               client: client,
               model: "demo",
               prompt: "hello",
               tools: [tool],
               max_tool_rounds: 1,
               max_step_timeout_ms: 5,
               retry: [max_retries: 0]
             )
  end

  test "8.4 stream with active tools continues across tool rounds" do
    client =
      Client.new(default_provider: "conformance-84-stream-tool-loop")
      |> Client.register_adapter(StreamToolLoopAdapter)

    tool = %Tool{
      name: "lookup",
      execute: fn _ -> %{"ok" => true} end
    }

    assert {:ok, stream} =
             LLM.stream(
               client: client,
               model: "demo",
               prompt: "hello",
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

  test "8.4 stream sends mixed tool success/failure results and still continues" do
    client =
      Client.new(default_provider: "conformance-84-stream-mixed-tool-loop")
      |> Client.register_adapter(StreamMixedToolLoopAdapter)

    ok_tool = %Tool{
      name: "lookup_ok",
      execute: fn _ -> %{"ok" => true} end
    }

    fail_tool = %Tool{
      name: "lookup_fail",
      execute: fn _ -> {:error, :boom} end
    }

    assert {:ok, stream} =
             LLM.stream(
               client: client,
               model: "demo",
               prompt: "hello",
               tools: [ok_tool, fail_tool],
               max_tool_rounds: 2
             )

    events = Enum.to_list(stream)

    assert Enum.any?(
             events,
             &match?(
               %StreamEvent{type: :tool_result, data: %{"id" => "c1", "status" => "ok"}},
               &1
             )
           )

    assert Enum.any?(
             events,
             &match?(
               %StreamEvent{type: :tool_result, data: %{"id" => "c2", "status" => "error"}},
               &1
             )
           )

    assert Enum.any?(
             events,
             &match?(%StreamEvent{type: :delta, data: %{"text" => "mixed-done"}}, &1)
           )

    assert match?(%StreamEvent{type: :finish, data: %{"reason" => :stop}}, List.last(events))
  end

  test "8.4 stream with max_tool_rounds zero does not auto-execute tools" do
    client =
      Client.new(default_provider: "conformance-84-stream-tool-loop")
      |> Client.register_adapter(StreamToolLoopAdapter)

    tool = %Tool{
      name: "lookup",
      execute: fn _ -> %{"ok" => true} end
    }

    assert {:ok, stream} =
             LLM.stream(
               client: client,
               model: "demo",
               prompt: "hello",
               tools: [tool],
               max_tool_rounds: 0
             )

    events = Enum.to_list(stream)
    assert Enum.any?(events, &match?(%StreamEvent{type: :tool_call}, &1))
    refute Enum.any?(events, &match?(%StreamEvent{type: :tool_result}, &1))
    refute Enum.any?(events, &match?(%StreamEvent{type: :step_finish}, &1))

    assert match?(
             %StreamEvent{type: :finish, data: %{"reason" => :tool_calls}},
             List.last(events)
           )
  end

  test "8.4 stream retries initial setup failures when retry policy allows" do
    counter = :atomics.new(1, [])

    client =
      Client.new(default_provider: "conformance-84-retry-stream")
      |> Client.register_adapter(RetryStreamAdapter)

    assert {:ok, stream} =
             LLM.stream(
               client: client,
               model: "demo",
               prompt: "hello",
               client_opts: [retry_counter: counter],
               retry: [max_retries: 1, initial_delay_ms: 0],
               sleep_fn: fn _ -> :ok end
             )

    assert Enum.any?(
             stream,
             &match?(%StreamEvent{type: :delta, data: %{"text" => "recovered"}}, &1)
           )

    assert :atomics.get(counter, 1) == 2
  end

  test "8.4 stream tool loop honors abort between steps" do
    client =
      Client.new(default_provider: "conformance-84-stream-tool-loop")
      |> Client.register_adapter(StreamToolLoopAdapter)

    abort_state = :atomics.new(1, [])
    :atomics.put(abort_state, 1, 0)

    tool = %Tool{
      name: "lookup",
      execute: fn _ -> %{"ok" => true} end
    }

    assert {:ok, stream} =
             LLM.stream(
               client: client,
               model: "demo",
               prompt: "hello",
               tools: [tool],
               max_tool_rounds: 2,
               abort?: fn -> :atomics.get(abort_state, 1) == 1 end
             )

    assert_raise AbortError, fn ->
      Enum.reduce(stream, 0, fn event, idx ->
        if match?(%StreamEvent{type: :step_finish}, event), do: :atomics.put(abort_state, 1, 1)
        idx + 1
      end)
    end
  end
end
