defmodule Arbor.Orchestrator.AgentLoop.LoopTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.AgentLoop.{Config, Event, Loop}
  alias Arbor.Orchestrator.UnifiedLLM.{Client, Request, Response}

  test "completes on final model response" do
    model_client = fn _session -> %{type: :final, content: "done"} end

    assert {:ok, session} = Loop.run(model_client: model_client)
    assert session.status == :completed
    assert session.result.content == "done"
  end

  test "executes tool calls and emits events" do
    parent = self()

    on_event = fn %Event{type: type} -> send(parent, {:event, type}) end

    model_client = fn session ->
      if session.turn == 0 do
        %{
          type: :tool_call,
          assistant_content: "calling tool",
          tool_calls: [%{id: "1", name: "grep"}]
        }
      else
        %{type: :final, content: "done"}
      end
    end

    tool_executor = fn _call -> %{content: "tool result"} end

    assert {:ok, session} =
             Loop.run(
               model_client: model_client,
               tool_executor: tool_executor,
               on_event: on_event
             )

    assert session.status == :completed
    assert Enum.any?(session.messages, &(&1.role == :tool))

    assert_receive {:event, :tool_calls_requested}
    assert_receive {:event, :tool_call_completed}
  end

  test "fails on repeated loop detection" do
    model_client = fn _session ->
      %{type: :tool_call, assistant_content: "same", tool_calls: [%{id: "1", name: "noop"}]}
    end

    tool_executor = fn _call -> %{content: "ok"} end

    assert {:error, :loop_detected, session} =
             Loop.run(
               model_client: model_client,
               tool_executor: tool_executor,
               config: %Config{max_turns: 10, loop_detection_window: 3}
             )

    assert session.status == :failed

    assert Enum.any?(
             session.messages,
             &(&1.role == :assistant and get_in(&1, [:metadata, :steering]) == true)
           )
  end

  test "enforces max_tool_rounds limit" do
    model_client = fn _session ->
      %{type: :tool_call, assistant_content: "loop", tool_calls: [%{id: "1", name: "noop"}]}
    end

    tool_executor = fn _call -> %{content: "ok"} end

    assert {:error, :max_tool_rounds_exceeded, session} =
             Loop.run(
               model_client: model_client,
               tool_executor: tool_executor,
               config: %Config{max_turns: 10, max_tool_rounds: 2, loop_detection_window: 50}
             )

    assert session.status == :failed
    assert session.result.reason == :max_tool_rounds_exceeded
  end

  test "abort signal stops the loop between rounds" do
    abort_state = :atomics.new(1, [])
    :atomics.put(abort_state, 1, 0)

    model_client = fn _session ->
      %{type: :tool_call, assistant_content: "call", tool_calls: [%{id: "1", name: "noop"}]}
    end

    tool_executor = fn _call ->
      :atomics.put(abort_state, 1, 1)
      %{content: "ok"}
    end

    assert {:error, :aborted, session} =
             Loop.run(
               model_client: model_client,
               tool_executor: tool_executor,
               config: %Config{max_turns: 10, max_tool_rounds: 10, loop_detection_window: 50},
               abort?: fn -> :atomics.get(abort_state, 1) == 1 end
             )

    assert session.status == :failed
    assert session.result.reason == :aborted
  end

  defmodule AgentLoopAdapter do
    @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

    @impl true
    def provider, do: "test"

    @impl true
    def complete(%Request{} = request, _opts) do
      has_tool_result =
        Enum.any?(request.messages, fn msg ->
          msg.role == :tool
        end)

      if has_tool_result do
        {:ok, %Response{text: "done", raw: %{type: :final, content: "done"}}}
      else
        {:ok,
         %Response{
           text: "calling tool",
           raw: %{
             type: :tool_call,
             assistant_content: "calling tool",
             tool_calls: [%{id: "1", name: "grep"}]
           }
         }}
      end
    end
  end

  test "runs via unified-llm client and provider profile" do
    client = Client.new() |> Client.register_adapter(AgentLoopAdapter)
    tool_executor = fn _call -> %{content: "tool result"} end

    assert {:ok, session} =
             Loop.run(
               llm_client: client,
               llm_provider: "test",
               llm_model: "demo-model",
               provider_profile: Arbor.Orchestrator.AgentLoop.ProviderProfiles.Default,
               tool_executor: tool_executor
             )

    assert session.status == :completed
    assert session.result.content == "done"
    assert Enum.any?(session.messages, &(&1.role == :tool))
  end

  test "unknown tool call returns error result instead of crashing the loop" do
    model_client = fn session ->
      if session.turn == 0 do
        %{
          type: :tool_call,
          assistant_content: "call unknown",
          tool_calls: [%{id: "1", name: "missing_tool"}]
        }
      else
        %{type: :final, content: "recovered"}
      end
    end

    assert {:ok, session} =
             Loop.run(
               model_client: model_client,
               tool_executor: nil
             )

    assert session.status == :completed

    assert Enum.any?(session.messages, fn msg ->
             msg.role == :tool and get_in(msg, [:metadata, :is_error]) == true
           end)
  end

  test "tool arguments are validated against schema in tool_registry" do
    model_client = fn session ->
      if session.turn == 0 do
        %{
          type: :tool_call,
          assistant_content: "bad args",
          tool_calls: [
            %{id: "1", name: "shell", arguments: ~s({"timeout_ms": 1000})}
          ]
        }
      else
        %{type: :final, content: "done"}
      end
    end

    tool_registry = %{
      "shell" => %{
        parameters: %{
          "type" => "object",
          "properties" => %{
            "command" => %{"type" => "string"},
            "timeout_ms" => %{"type" => "integer"}
          },
          "required" => ["command"]
        },
        execute: fn _args -> %{"ok" => true} end
      }
    }

    assert {:ok, session} =
             Loop.run(
               model_client: model_client,
               tool_executor: nil,
               tool_registry: tool_registry
             )

    assert Enum.any?(session.messages, fn msg ->
             msg.role == :tool and get_in(msg, [:metadata, :is_error]) == true
           end)
  end

  test "tool execution errors are captured as error results" do
    model_client = fn session ->
      if session.turn == 0 do
        %{
          type: :tool_call,
          assistant_content: "call",
          tool_calls: [%{id: "1", name: "explode", arguments: %{}}]
        }
      else
        %{type: :final, content: "done"}
      end
    end

    tool_registry = %{
      "explode" => %{
        execute: fn _ -> raise "boom" end
      }
    }

    assert {:ok, session} =
             Loop.run(
               model_client: model_client,
               tool_executor: nil,
               tool_registry: tool_registry
             )

    assert Enum.any?(session.messages, fn msg ->
             msg.role == :tool and get_in(msg, [:metadata, :is_error]) == true
           end)
  end

  test "parallel tool execution runs concurrently when enabled" do
    model_client = fn session ->
      if session.turn == 0 do
        %{
          type: :tool_call,
          assistant_content: "parallel",
          tool_calls: [
            %{id: "1", name: "slow_a", arguments: %{}},
            %{id: "2", name: "slow_b", arguments: %{}}
          ]
        }
      else
        %{type: :final, content: "done"}
      end
    end

    tool_registry = %{
      "slow_a" => %{
        execute: fn _ ->
          Process.sleep(80)
          %{"ok" => "a"}
        end
      },
      "slow_b" => %{
        execute: fn _ ->
          Process.sleep(80)
          %{"ok" => "b"}
        end
      }
    }

    start = System.monotonic_time(:millisecond)

    assert {:ok, _session} =
             Loop.run(
               model_client: model_client,
               tool_executor: nil,
               tool_registry: tool_registry,
               parallel_tool_execution: true,
               config: %Config{max_turns: 10, max_tool_rounds: 5, loop_detection_window: 10}
             )

    elapsed = System.monotonic_time(:millisecond) - start
    assert elapsed < 150
  end

  test "event lifecycle is bracketed by session_start/session_end and includes assistant/tool canonical events" do
    parent = self()

    on_event = fn %Event{} = event -> send(parent, {:event, event.type, event.data}) end

    model_client = fn session ->
      if session.turn == 0 do
        %{
          type: :tool_call,
          assistant_content: "using tool",
          tool_calls: [%{id: "1", name: "echo", arguments: %{"x" => 1}}]
        }
      else
        %{type: :final, content: "done"}
      end
    end

    tool_registry = %{
      "echo" => %{execute: fn args -> %{"echo" => args} end}
    }

    assert {:ok, _session} =
             Loop.run(
               model_client: model_client,
               tool_executor: nil,
               tool_registry: tool_registry,
               on_event: on_event
             )

    assert_receive {:event, :session_start, _}
    assert_receive {:event, :assistant_text_start, _}
    assert_receive {:event, :assistant_text_end, %{text: "using tool"}}
    assert_receive {:event, :tool_call_start, _}
    assert_receive {:event, :tool_call_end, %{full_output: full_output}}
    assert is_binary(full_output)
    assert_receive {:event, :session_end, %{status: :completed}}
  end
end
