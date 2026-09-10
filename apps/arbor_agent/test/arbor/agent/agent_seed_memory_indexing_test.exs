defmodule Arbor.Agent.AgentSeedMemoryIndexingTest do
  @moduledoc """
  Direct host finalization cannot produce unowned semantic conversations.

  The previous writer attempted a write and swallowed DateTime metadata rejection.
  Explicit unavailability now removes that producer while retaining local effects.
  The ordinary Memory write control remains separate from host authorization.
  """

  use ExUnit.Case, async: false

  alias Arbor.Agent.AgentSeed
  alias Arbor.Memory

  @moduletag :fast
  @timeout 5_000
  @index_mfa {Memory, :index, 3}

  defmodule LocalEmbedding do
    @moduledoc false

    def embed(_text) do
      {:ok,
       %{
         embedding: List.duplicate(0.25, 768),
         dimensions: 768,
         model: "agent-seed-characterization",
         provider: :test
       }}
    end
  end

  setup do
    agent_id = "agent_seed_index_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    {:ok, index} =
      Memory.init_for_agent(agent_id,
        graph_enabled: false,
        backend: :ets,
        embedding_provider: LocalEmbedding
      )

    on_exit(fn ->
      assert :ok = Memory.cleanup_for_agent(agent_id)
      refute Process.alive?(index)
    end)

    %{agent_id: agent_id}
  end

  test "host finalization does not attempt automatic unowned conversation indexing",
       %{agent_id: agent_id} do
    assert {:ok, %{entry_count: 0}} = Memory.index_stats(agent_id)

    # Exercise the real indexing branch without unrelated working-memory,
    # context-window or tenth-query consolidation effects.
    state = %{
      id: agent_id,
      memory_initialized: true,
      working_memory: nil,
      context_window: nil,
      query_count: 0
    }

    {finalized, events} =
      observe_finalize_query("My preferred editor is Vim.", "I will remember that.", state)

    assert events == []

    assert AgentSeed.conversation_memory_status() == %{
             status: "unavailable",
             reason: "authenticated_session_required"
           }

    assert finalized.memory_initialized
    assert finalized.responded_to_last_user_message
    assert {:ok, %{entry_count: 0}} = Memory.index_stats(agent_id)

    # A functioning store is not authority for a direct host conversation write.
    assert {:ok, entry_id} = Memory.index(agent_id, "ordinary store control", %{type: :fact})
    assert is_binary(entry_id)
    assert {:ok, %{entry_count: 1}} = Memory.index_stats(agent_id)
  end

  defp observe_finalize_query(prompt, response, state) do
    Code.ensure_loaded!(Memory)
    session = :trace.session_create(__MODULE__, self(), [])
    run_ref = make_ref()

    task =
      Task.async(fn ->
        receive do
          {:run, ^run_ref} -> AgentSeed.finalize_query(prompt, response, state)
        end
      end)

    try do
      assert 1 =
               :trace.function(
                 session,
                 @index_mfa,
                 [{:_, [], [{:return_trace}, {:exception_trace}]}],
                 [:local]
               )

      assert 1 = :trace.process(session, task.pid, true, [:call])
      send(task.pid, {:run, run_ref})
      finalized = Task.await(task, @timeout)

      # A completed Task alone is not a trace-delivery barrier. Missing calls,
      # exception returns and additional calls all fail the exact event assertion.
      delivered_ref = :trace.delivered(session, :all)
      assert_receive {:trace_delivered, :all, ^delivered_ref}, @timeout

      {finalized, drain_trace_events(task.pid, [])}
    after
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      :trace.session_destroy(session)
    end
  end

  defp drain_trace_events(producer, events) do
    receive do
      {:trace, ^producer, :call, call} ->
        drain_trace_events(producer, [{:call, call} | events])

      {:trace, ^producer, :return_from, mfa, result} ->
        drain_trace_events(producer, [{:return_from, mfa, result} | events])

      {:trace, ^producer, :exception_from, mfa, reason} ->
        drain_trace_events(producer, [{:exception_from, mfa, reason} | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
