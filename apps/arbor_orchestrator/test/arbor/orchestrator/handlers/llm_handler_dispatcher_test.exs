defmodule Arbor.Orchestrator.Handlers.LlmHandlerDispatcherTest do
  @moduledoc """
  Pin that `LlmHandler.call_llm_direct` now routes through the
  `Arbor.LLM.Dispatcher` behaviour (Phase 4+ B2) instead of calling
  `Arbor.LLM.Client.complete` directly.

  Drives execution through the public `LlmHandler.execute/4` with
  `simulate="false"` so the real call path fires, but installs a
  recording dispatcher via Application env so no network call happens
  and the request + opts handed to dispatch are observable.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.Handlers.LlmHandler

  defmodule RecordingDispatcher do
    @moduledoc false
    @behaviour Arbor.LLM.Dispatcher

    def start_link do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def calls, do: Agent.get(__MODULE__, & &1) |> Enum.reverse()

    @impl true
    def dispatch(request, opts) do
      Agent.update(__MODULE__, fn calls -> [{request, opts} | calls] end)

      {:ok,
       %Arbor.LLM.Response{
         text: "from RecordingDispatcher",
         finish_reason: :stop,
         usage: %{input_tokens: 10, output_tokens: 5}
       }}
    end
  end

  setup do
    {:ok, _} = RecordingDispatcher.start_link()
    Application.put_env(:arbor_orchestrator, :llm_dispatcher, RecordingDispatcher)

    on_exit(fn ->
      Application.delete_env(:arbor_orchestrator, :llm_dispatcher)
    end)

    :ok
  end

  defp build_node(attrs) do
    %{
      id: "test-node",
      attrs: Map.merge(%{"simulate" => "false", "prompt" => "hi there"}, attrs)
    }
  end

  defp build_graph, do: %{attrs: %{"goal" => "test goal"}}

  defp build_context do
    Arbor.Orchestrator.Engine.Context.new(%{
      "session.llm_provider" => "anthropic",
      "session.llm_model" => "claude-opus-4-6",
      "session.llm_runtime" => :arbor
    })
  end

  describe "call_llm_direct path → Dispatcher" do
    test "non-tools, non-streaming call invokes Dispatcher.dispatch" do
      outcome = LlmHandler.execute(build_node(%{}), build_context(), build_graph(), [])

      assert outcome.status == :success

      assert [{%Arbor.LLM.Request{} = request, opts}] = RecordingDispatcher.calls()
      assert request.provider == "anthropic"
      assert request.model == "claude-opus-4-6"
      assert request.runtime == :arbor

      # Client is threaded through opts so Runtime.Arbor can use it
      assert Keyword.has_key?(opts, :client)

      # No streaming callbacks for the non-streaming path
      refute Keyword.has_key?(opts, :callbacks)
    end

    test "streaming on_stream → Dispatcher receives :callbacks map" do
      pid = self()
      on_stream = fn event -> send(pid, {:stream_event, event}) end

      outcome =
        LlmHandler.execute(
          build_node(%{}),
          build_context(),
          build_graph(),
          on_stream: on_stream
        )

      assert outcome.status == :success

      assert [{_request, opts}] = RecordingDispatcher.calls()
      callbacks = Keyword.fetch!(opts, :callbacks)

      # Bridge produces a callbacks map with all 4 keys so RuntimeArbor
      # can dispatch any stream event back into the legacy on_stream shape.
      assert Map.has_key?(callbacks, :on_text_delta)
      assert Map.has_key?(callbacks, :on_thinking_delta)
      assert Map.has_key?(callbacks, :on_tool_call)
      assert Map.has_key?(callbacks, :on_usage)
    end

    test "on_text_delta callback synthesizes a %StreamEvent{} for legacy on_stream" do
      pid = self()
      on_stream = fn event -> send(pid, {:stream_event, event}) end

      _outcome =
        LlmHandler.execute(
          build_node(%{}),
          build_context(),
          build_graph(),
          on_stream: on_stream
        )

      assert [{_request, opts}] = RecordingDispatcher.calls()
      callbacks = Keyword.fetch!(opts, :callbacks)

      callbacks.on_text_delta.("hello world")

      assert_receive {:stream_event, %Arbor.LLM.StreamEvent{type: :delta, data: data}}, 100
      assert data["text"] == "hello world"
    end
  end

  describe "policy.fallback_chain from session context (Phase 4+ B3)" do
    test "empty session.llm_fallback_chain → policy.fallback_chain is []" do
      _outcome = LlmHandler.execute(build_node(%{}), build_context(), build_graph(), [])

      assert [{_request, opts}] = RecordingDispatcher.calls()
      policy = Keyword.fetch!(opts, :policy)
      assert policy.fallback_chain == []
    end

    test "session.llm_fallback_chain populates policy.fallback_chain" do
      chain = [%{runtime: :acp}, %{model: "claude-sonnet-4-6"}]

      context =
        Arbor.Orchestrator.Engine.Context.new(%{
          "session.llm_provider" => "anthropic",
          "session.llm_model" => "claude-opus-4-6",
          "session.llm_runtime" => :arbor,
          "session.llm_fallback_chain" => chain
        })

      _outcome = LlmHandler.execute(build_node(%{}), context, build_graph(), [])

      assert [{_request, opts}] = RecordingDispatcher.calls()
      policy = Keyword.fetch!(opts, :policy)
      assert policy.fallback_chain == chain
    end

    test "fallback chain flows on the streaming path too" do
      chain = [%{provider: :openai}]

      context =
        Arbor.Orchestrator.Engine.Context.new(%{
          "session.llm_provider" => "anthropic",
          "session.llm_model" => "claude-opus-4-6",
          "session.llm_runtime" => :arbor,
          "session.llm_fallback_chain" => chain
        })

      _outcome =
        LlmHandler.execute(build_node(%{}), context, build_graph(), on_stream: fn _ -> :ok end)

      assert [{_request, opts}] = RecordingDispatcher.calls()
      policy = Keyword.fetch!(opts, :policy)
      assert policy.fallback_chain == chain
    end
  end
end
