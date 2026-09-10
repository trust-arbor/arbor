defmodule Arbor.Agent.HostMemoryOwnershipTest do
  @moduledoc """
  Host-boundary regressions for redundant Session memory work and explicit
  unavailable direct-host conversation writes. Real host processes and public
  query/stream APIs run against deterministic provider/runtime/Session fixtures.
  These tests do not qualify private prompt context or host working-memory ownership.
  """

  use ExUnit.Case, async: false

  alias Arbor.Agent.{APIAgent, AgentSeed, Claude, SessionManager}
  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.LLM.Client
  alias Arbor.Memory
  alias Arbor.Memory.WorkingMemory

  @moduletag :fast
  @moduletag :integration
  @memory_calls [
    {Memory, :recall, 3},
    {Memory, :index, 3},
    {Memory, :save_working_memory, 2},
    {Memory, :should_consolidate?, 1}
  ]

  defmodule LocalEmbedding do
    @moduledoc false
    def embed(text) do
      send(Arbor.Agent.HostMemoryOwnershipTest, {:embedding_called, text})

      {:ok,
       %{
         embedding: [1.0 | List.duplicate(0.0, 767)],
         dimensions: 768,
         model: "host-test",
         provider: :test
       }}
    end
  end

  defmodule Adapter do
    @moduledoc false
    @behaviour Arbor.LLM.ProviderAdapter
    alias Arbor.LLM.{ContentPart, Response}
    def provider, do: "openai"

    def complete(request, _opts) do
      send(Arbor.Agent.HostMemoryOwnershipTest, {:provider_request, request})

      {:ok,
       %Response{
         text: "host answer",
         finish_reason: :stop,
         content_parts: [ContentPart.text("host answer")],
         raw: %{},
         usage: %{input_tokens: 1, output_tokens: 2, total_tokens: 3}
       }}
    end

    def complete_streaming(request, _callback, opts), do: complete(request, opts)
  end

  defmodule Runtime do
    @moduledoc false
    @behaviour Arbor.AI.Runtime
    alias Arbor.Contracts.AI.RuntimeProfile
    alias Arbor.LLM.{ContentPart, Response}

    def prepare(request, _opts), do: {:ok, request}

    def execute(request, _callback, _opts) do
      send(Arbor.Agent.HostMemoryOwnershipTest, {:runtime_request, request})

      {:ok,
       %Response{
         text: "host answer",
         finish_reason: :stop,
         content_parts: [ContentPart.text("host answer")],
         raw: %{},
         usage: %{input_tokens: 1, output_tokens: 2, total_tokens: 3}
       }}
    end

    def profile do
      {:ok, profile} =
        RuntimeProfile.new(%{
          runtime_id: :acp,
          display_name: "host fixture",
          owns_model_loop: false,
          owns_thread_history: false,
          supports_jido_actions: false,
          supports_action_hooks: false,
          supports_native_tools: false,
          runs_context_engine: false,
          exposes_compaction_data: false,
          unsupported_features: []
        })

      profile
    end
  end

  defmodule Session do
    @moduledoc false
    use GenServer
    def start_link(observer), do: GenServer.start_link(__MODULE__, observer)
    def init(observer), do: {:ok, observer}

    def handle_call({:send_message, message}, _from, observer) do
      send(observer, {:session_message, message})

      {:reply,
       {:ok,
        %{
          content: "session answer",
          usage: %{input_tokens: 2, output_tokens: 3},
          tool_history: []
        }}, observer}
    end
  end

  setup do
    true = Process.register(self(), __MODULE__)
    set_env(:arbor_agent, :context_persistence_enabled, false)
    set_env(:arbor_agent, :checkpoint_enabled, false)
    set_env(:arbor_agent, :timing_context_enabled, false)
    set_env(:arbor_ai, :runtime_registry, %{acp: Runtime})

    original_client = Client.default_client()

    client =
      Client.new(default_provider: "openai", model_catalog: %{})
      |> Client.register_adapter(Adapter)

    Client.set_default_client(client)
    on_exit(fn -> Client.set_default_client(original_client) end)

    agent_id = "agent_host_memory_#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             Memory.init_for_agent(agent_id,
               graph_enabled: false,
               backend: :ets,
               embedding_provider: LocalEmbedding
             )

    on_exit(fn -> Memory.cleanup_for_agent(agent_id) end)
    %{agent_id: agent_id}
  end

  test "Seed finalization retains timing, working memory, context and consolidation check without a semantic write",
       ctx do
    state = local_state(ctx.agent_id, 9)

    {finalized, calls} =
      traced(self(), fn -> AgentSeed.finalize_query("question", "answer", state) end)

    assert %DateTime{} = finalized.last_assistant_output_at
    assert finalized.responded_to_last_user_message
    assert finalized.working_memory.thought_count == 1

    assert Enum.map(finalized.context_window.entries, fn {:message, content, _at} -> content end) ==
             [
               "Human: question",
               "Assistant: answer"
             ]

    assert Enum.any?(calls, &match?({Memory, :save_working_memory, [_, _]}, &1))

    assert Enum.filter(calls, &match?({Memory, :should_consolidate?, _}, &1)) ==
             [{Memory, :should_consolidate?, [ctx.agent_id]}]

    refute Enum.any?(calls, &match?({Memory, :index, _}, &1))
    assert {:ok, %{entry_count: 0}} = Memory.index_stats(ctx.agent_id)
  end

  test "security regression: Seed recall false gates the read itself while retaining user timing",
       ctx do
    state = local_state(ctx.agent_id)

    {{prompt, [], prepared}, calls} =
      traced(self(), fn ->
        AgentSeed.prepare_query("question", state, recall_memories: false, enhance_prompt: false)
      end)

    assert prompt == "question"
    assert %DateTime{} = prepared.last_user_message_at
    refute prepared.responded_to_last_user_message
    assert calls == []
    refute_receive {:embedding_called, _}
  end

  test "public Session wrapper performs one Session call and retains default local effects without recall/index",
       ctx do
    host = start_host(APIAgent, ctx.agent_id, 9)
    session = start_supervised!({Session, self()})
    register_session(ctx.agent_id, session)
    message = UserMessage.from_string("wrapper question")

    {{:ok, response}, calls} =
      traced(host, fn -> APIAgent.query(host, message, recall_memories: true) end)

    assert_receive {:session_message, ^message}
    refute_receive {:session_message, _}
    assert response.text == "session answer"
    assert response.recalled_memories == []
    assert response.usage.output_tokens == 3
    assert {:ok, wm} = APIAgent.get_working_memory(host)
    assert wm.thought_count == 1
    state = :sys.get_state(host)
    assert state.query_count == 10
    assert state.responded_to_last_user_message
    assert %DateTime{} = state.last_user_message_at
    assert %DateTime{} = state.last_assistant_output_at
    assert length(state.context_window.entries) == 2
    assert Enum.any?(calls, &match?({Memory, :should_consolidate?, _}, &1))
    refute Enum.any?(calls, fn {_, name, _} -> name in [:recall, :index] end)
    refute_receive {:embedding_called, _}
  end

  test "Session wrapper legacy finalization false still suppresses working-memory/context/output-timing effects",
       ctx do
    host = start_host(APIAgent, ctx.agent_id, 9)
    session = start_supervised!({Session, self()})
    register_session(ctx.agent_id, session)
    before = :sys.get_state(host)

    {{:ok, response}, calls} =
      traced(host, fn -> APIAgent.query(host, "no finalization", index_response: false) end)

    assert response.text == "session answer"
    after_query = :sys.get_state(host)
    assert after_query.working_memory == before.working_memory
    assert after_query.context_window == before.context_window
    assert after_query.last_assistant_output_at == before.last_assistant_output_at
    assert after_query.query_count == 10
    assert %DateTime{} = after_query.last_user_message_at
    assert calls == []
  end

  test "public API direct query reports unavailable conversation memory and honors recall false",
       ctx do
    host = start_host(APIAgent, ctx.agent_id)

    {{:ok, response}, calls} =
      traced(host, fn -> APIAgent.query(host, "direct question", recall_memories: false) end)

    assert response.text == "host answer"
    assert response.conversation_memory == AgentSeed.conversation_memory_status()
    assert response.recalled_memories == []
    assert response.session_id == nil
    assert_receive {:provider_request, request}

    assert Enum.any?(
             request.messages,
             &(&1.role == :user and String.contains?(&1.content, "direct question"))
           )

    refute Enum.any?(calls, fn {_, name, _} -> name in [:recall, :index] end)
    assert {:ok, %{thought_count: 1}} = APIAgent.get_working_memory(host)
    assert length(:sys.get_state(host).context_window.entries) == 2
    refute_receive {:embedding_called, _}
  end

  for mode <- [:query, :stream] do
    test "public Claude #{mode} reports unavailable conversation memory with no recall/index",
         ctx do
      host = start_host(Claude, ctx.agent_id)
      observer = self()

      {{:ok, response}, calls} =
        traced(host, fn ->
          invoke_claude(unquote(mode), host, observer)
        end)

      assert response.text == "host answer"
      assert response.conversation_memory == AgentSeed.conversation_memory_status()
      assert response.recalled_memories == []
      assert_receive {:runtime_request, request}
      assert Enum.any?(request.messages, &(&1.role == :user and &1.content == "Claude question"))
      assert {:ok, %{thought_count: 1}} = Claude.get_working_memory(host)
      refute Enum.any?(calls, fn {_, name, _} -> name in [:recall, :index] end)
      refute_receive {:embedding_called, _}

      assert_claude_events(unquote(mode), response)
    end
  end

  defp invoke_claude(:query, host, _observer) do
    Claude.query(host, "Claude question", recall_memories: false, capture_thinking: false)
  end

  defp invoke_claude(:stream, host, observer) do
    Claude.stream(host, "Claude question", &send(observer, {:stream_event, &1}),
      recall_memories: false,
      capture_thinking: false
    )
  end

  defp assert_claude_events(:query, _response), do: :ok

  defp assert_claude_events(:stream, response) do
    assert_receive {:stream_event, {:text, "host answer"}}
    assert_receive {:stream_event, {:complete, completed}}
    assert completed.conversation_memory == response.conversation_memory
    refute_receive {:stream_event, {:memories, _}}
  end

  for host_module <- [APIAgent, Claude] do
    test "#{host_module} preserves deprecated index_response false local-effect suppression",
         ctx do
      host_module = unquote(host_module)
      host = start_host(host_module, ctx.agent_id)
      before = :sys.get_state(host)

      {{:ok, response}, calls} =
        traced(host, fn ->
          host_module.query(host, "disabled finalization",
            recall_memories: false,
            index_response: false,
            capture_thinking: false
          )
        end)

      assert response.conversation_memory == AgentSeed.conversation_memory_status()
      after_query = :sys.get_state(host)
      assert after_query.working_memory == before.working_memory
      assert after_query.context_window == before.context_window
      assert after_query.last_assistant_output_at == before.last_assistant_output_at
      assert calls == []
    end
  end

  defp local_state(agent_id, count \\ 0) do
    %{
      id: agent_id,
      memory_initialized: true,
      query_count: count,
      working_memory: WorkingMemory.new(agent_id, rebuild_from_signals: false),
      context_window: Memory.new_context_window(agent_id),
      last_user_message_at: nil,
      last_assistant_output_at: nil,
      responded_to_last_user_message: false
    }
  end

  defp start_host(module, agent_id, count \\ 0) do
    # The real host consumes an already-initialized, test-owned Memory fixture.
    # Avoid reinitializing unrelated graph/executor owners during host startup.
    opts = [id: agent_id, memory_enabled: false, skip_executor: true, capture_thinking: false]

    opts =
      if module == APIAgent, do: opts ++ [provider: :openai, model: "gpt-4o-mini"], else: opts

    pid = start_supervised!({module, opts})
    :sys.replace_state(pid, &Map.merge(&1, local_state(agent_id, count)))
    pid
  end

  defp register_session(agent_id, session) do
    owner_ets(fn -> :ets.insert(SessionManager, {agent_id, session}) end)
    on_exit(fn -> owner_ets(fn -> :ets.delete(SessionManager, agent_id) end) end)
  end

  defp owner_ets(fun) do
    :sys.replace_state(SessionManager, fn state ->
      fun.()
      state
    end)
  end

  defp traced(pid, fun) do
    if pid == self() do
      ref = make_ref()

      task =
        Task.async(fn ->
          receive do
            {:run, ^ref} -> fun.()
          end
        end)

      try do
        observe_calls(task.pid, fn ->
          send(task.pid, {:run, ref})
          Task.await(task, 5_000)
        end)
      after
        if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      end
    else
      observe_calls(pid, fun)
    end
  end

  defp observe_calls(pid, fun) do
    session = :trace.session_create(__MODULE__, self(), [])

    try do
      for mfa <- @memory_calls do
        assert 1 = :trace.function(session, mfa, [{:_, [], []}], [:local])
      end

      assert 1 = :trace.process(session, pid, true, [:call])
      result = fun.()
      delivered = :trace.delivered(session, :all)
      assert_receive {:trace_delivered, :all, ^delivered}, 5_000
      {result, drain_calls(pid, [])}
    after
      :trace.session_destroy(session)
    end
  end

  defp drain_calls(pid, calls) do
    receive do
      {:trace, ^pid, :call, call} -> drain_calls(pid, [call | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end

  defp set_env(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)
  end
end
