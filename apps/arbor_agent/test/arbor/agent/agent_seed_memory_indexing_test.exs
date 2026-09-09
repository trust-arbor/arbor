defmodule Arbor.Agent.AgentSeedMemoryIndexingTest do
  @moduledoc """
  Characterizes the existing AgentSeed conversation-indexing failure.

  This is not producer acceptance: DateTime normalization remains deferred until
  host writes have qualified ownership. Observe the real facade call and return,
  because conversation recall is deliberately excluded by M1a even when stored.
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

  test "producer characterization: finalize_query submits DateTime metadata and swallows its rejection",
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

    assert [
             {:call, {Memory, :index, [^agent_id, content, metadata]}},
             {:return_from, @index_mfa, {:error, {:invalid_legacy_embedding, :invalid_metadata}}}
           ] = events

    assert content == "Q: My preferred editor is Vim.\nA: I will remember that."
    assert %{type: :conversation, timestamp: %DateTime{}} = metadata
    assert finalized.memory_initialized
    assert finalized.responded_to_last_user_message
    assert {:ok, %{entry_count: 0}} = Memory.index_stats(agent_id)

    # Same observed producer payload, with only its timestamp made JSON-clean.
    # This proves the index can write; it does not enable the production writer
    # or treat an absent conversation recall as proof of failed indexing.
    control_metadata = Map.update!(metadata, :timestamp, &DateTime.to_iso8601/1)
    assert {:ok, entry_id} = Memory.index(agent_id, content, control_metadata)
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
