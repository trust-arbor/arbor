defmodule Arbor.LLM.HighLevelApiTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.LLM

  alias Arbor.LLM.AbortError

  alias Arbor.LLM.Client

  alias Arbor.LLM.Message

  alias Arbor.LLM.NoObjectGeneratedError

  alias Arbor.LLM.Request

  alias Arbor.LLM.RequestTimeoutError

  alias Arbor.LLM.Response

  alias Arbor.LLM.StreamEvent

  alias Arbor.LLM.Tool

  defmodule HighLevelAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

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
                {[%StreamEvent{type: :delta, data: %{"text" => "hello"}}], 2}

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
            %StreamEvent{type: :delta, data: %{"text" => "hello"}},
            %StreamEvent{type: :finish, data: %{"reason" => :stop}}
          ]
      end
    end
  end

  defmodule ToolLoopAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

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

  defmodule HostileOwnedAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    @impl true
    def provider, do: "hostile-owned"

    @impl true
    def complete(_request, _opts), do: {:error, :unsupported}

    @impl true
    def stream(%Request{provider_options: options}, _opts) do
      owner = Map.fetch!(options, :test_pid)

      producer =
        spawn(fn ->
          send(owner, {:hostile_source_started, self()})

          receive do
            :stop -> :ok
          end
        end)

      %Arbor.LLM.OwnedStream{
        stream: Stream.repeatedly(fn -> %StreamEvent{type: :delta, data: %{text: "x"}} end),
        producer: producer,
        cancel: fn ->
          send(owner, :hostile_cancel_called)
          raise "hostile cancel"
        end
      }
    end
  end

  defmodule ObjectBoundaryAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    @impl true
    def provider, do: "object-boundary"

    @impl true
    def complete(_request, _opts), do: {:error, :unsupported}

    @impl true
    def stream(%Request{model: model}, _opts) do
      case model do
        "object-bytes" ->
          [%StreamEvent{type: :delta, data: %{text: String.duplicate("x", 1_048_577)}}]

        "object-events" ->
          Stream.repeatedly(fn -> %StreamEvent{type: :start, data: %{}} end)
          |> Stream.take(10_001)

        "object-depth" ->
          body = ~s({"value":) <> String.duplicate("[", 33)
          [%StreamEvent{type: :delta, data: %{text: body}}]

        "object-multiple" ->
          [%StreamEvent{type: :delta, data: %{text: "{}{}"}}]

        "object-malformed" ->
          [%StreamEvent{type: :delta, data: %{text: "{]"}}]

        "object-linear" ->
          spaces =
            Stream.repeatedly(fn ->
              %StreamEvent{type: :delta, data: %{text: String.duplicate(" ", 100)}}
            end)
            |> Stream.take(9_998)

          Stream.concat(spaces, [
            %StreamEvent{type: :delta, data: %{text: ~s({"ok":true})}},
            %StreamEvent{type: :finish, data: %{reason: :stop}}
          ])
      end
    end
  end

  defmodule SlowToolLoopAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

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
    @behaviour Arbor.LLM.ProviderAdapter

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
             LLM.generate(
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
             LLM.generate(
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
             LLM.generate(
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
             LLM.stream(
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
             LLM.generate_object(
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
             LLM.generate_object(
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
             LLM.generate_object(
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
             LLM.stream_object(
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
             LLM.stream_object(
               client: client,
               model: "bad-json-stream-model",
               prompt: "hi"
             )

    assert_raise NoObjectGeneratedError, fn -> Enum.to_list(object_stream) end
  end

  test "security regression: stream_object enforces byte, event, depth, and grammar bounds" do
    client =
      Client.new(
        adapters: %{"object-boundary" => ObjectBoundaryAdapter},
        default_provider: "object-boundary"
      )

    for {model, expected_reason} <- [
          {"object-bytes", {:object_stream_limit_exceeded, :bytes, 1_048_576}},
          {"object-events", {:object_stream_limit_exceeded, :events, 10_000}},
          {"object-depth", {:object_stream_limit_exceeded, :depth, 32}},
          {"object-multiple", :multiple_object_stream_values},
          {"object-malformed", :malformed_object_stream_json}
        ] do
      assert {:ok, object_stream} =
               LLM.stream_object(
                 client: client,
                 provider: "object-boundary",
                 model: model,
                 prompt: "hi"
               )

      error =
        assert_raise NoObjectGeneratedError, fn ->
          Enum.to_list(object_stream)
        end

      assert error.reason == expected_reason
    end
  end

  test "security regression: stream_object processes thousands of tiny chunks linearly" do
    client =
      Client.new(
        adapters: %{"object-boundary" => ObjectBoundaryAdapter},
        default_provider: "object-boundary"
      )

    assert {:ok, object_stream} =
             LLM.stream_object(
               client: client,
               provider: "object-boundary",
               model: "object-linear",
               prompt: "hi"
             )

    task = Task.async(fn -> Enum.to_list(object_stream) end)
    assert {:ok, [%{"ok" => true}]} = Task.yield(task, 2_000)
  end

  test "generate_object returns NoObjectGeneratedError on invalid json output" do
    client =
      Client.new(default_provider: "high-level-test") |> Client.register_adapter(HighLevelAdapter)

    assert {:error, %NoObjectGeneratedError{reason: :no_object_generated}} =
             LLM.generate_object(
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
             LLM.generate(
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
             LLM.generate(
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
             LLM.generate(
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
             LLM.stream(
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
             LLM.stream(
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
             LLM.generate(
               client: client,
               model: "demo",
               prompt: "hi",
               abort?: true
             )

    assert {:error, %AbortError{}} =
             LLM.stream(
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
             LLM.stream(
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

  test "security regression: hostile owned cancel cannot skip producer teardown" do
    client =
      Client.new(
        adapters: %{"hostile-owned" => HostileOwnedAdapter},
        default_provider: "hostile-owned"
      )

    assert {:ok, stream} =
             LLM.stream(
               client: client,
               provider: "hostile-owned",
               model: "hostile",
               prompt: "hi",
               provider_options: %{test_pid: self()},
               stream_read_timeout_ms: 1_000
             )

    assert_receive {:hostile_source_started, producer}
    producer_monitor = Process.monitor(producer)
    started = System.monotonic_time(:millisecond)
    assert [%StreamEvent{type: :delta}] = Enum.take(stream, 1)
    assert System.monotonic_time(:millisecond) - started < 1_000
    assert_receive :hostile_cancel_called
    assert_receive {:DOWN, ^producer_monitor, :process, ^producer, :killed}
    refute Process.alive?(producer)
  end

  test "generate_object preserves upstream generation errors" do
    client =
      Client.new(default_provider: "high-level-test") |> Client.register_adapter(HighLevelAdapter)

    assert {:error, :provider_failed} =
             LLM.generate_object(
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
             LLM.generate(
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
             LLM.stream(
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
