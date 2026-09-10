defmodule Arbor.Actions.PrivateTurnMemoryWriteSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions
  alias Arbor.Memory

  @moduletag :fast
  @moduletag :security_regression
  @denied {:error, :private_turn_memory_write_denied}
  @timeout 5_000
  @probe_resource "arbor://action/test/private-turn-memory-policy"

  defmodule LocalEmbedding do
    def embed(_text) do
      {:ok,
       %{
         embedding: List.duplicate(0.25, 768),
         dimensions: 768,
         model: "private-turn-memory-policy",
         provider: :test
       }}
    end
  end

  defmodule LocalReflection do
    def reflect(prompt, _context) do
      {:ok, %{analysis: prompt, insights: [], self_assessment: %{}}}
    end
  end

  # Same advertised name as a mutator; admission uses the resolved module.
  defmodule ReadProbe do
    use Jido.Action,
      name: "memory_remember",
      description: "Test-owned read-only action",
      schema: []

    def authorization_resource(_params),
      do: {:ok, "arbor://action/test/private-turn-memory-policy"}

    @impl true
    def run(_params, _context), do: {:ok, %{read: true}}
  end

  defmodule Elixir.Arbor.Actions.Memory.PrivateTurnUnreviewedTestAction do
    use Jido.Action,
      name: "private_turn_unreviewed_test_action",
      description: "A future memory action must be reviewed before private-turn use",
      schema: []

    def authorization_resource(_params),
      do: {:ok, "arbor://action/test/private-turn-memory-policy"}

    @impl true
    def run(_params, _context), do: {:ok, %{unreviewed_action_ran: true}}
  end

  setup do
    settings = [
      {:arbor_security, :policy_enforcer_enabled, false},
      {:arbor_trust, :policy_enforcer_enabled, false},
      {:arbor_security, :approval_guard_enabled, false},
      {:arbor_trust, :approval_guard_enabled, false},
      {:arbor_memory, :reflection_llm_module, LocalReflection}
    ]

    previous =
      Enum.map(settings, fn {app, key, value} ->
        old = Application.fetch_env(app, key)
        Application.put_env(app, key, value)
        {app, key, old}
      end)

    on_exit(fn ->
      Enum.each(previous, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)
    end)

    agent_id = "agent_private_memory_#{System.unique_integer([:positive])}"

    {:ok, _index} =
      Memory.init_for_agent(agent_id, backend: :ets, embedding_provider: LocalEmbedding)

    on_exit(fn -> assert :ok = Memory.cleanup_for_agent(agent_id) end)

    for resource <- [
          "arbor://memory/add_knowledge",
          "arbor://memory/write/#{agent_id}",
          "arbor://memory/recall",
          "arbor://memory/read/#{agent_id}",
          "arbor://memory/read",
          "arbor://orchestrator/execute",
          @probe_resource
        ] do
      assert {:ok, capability} = Arbor.Security.grant(principal: agent_id, resource: resource)
      on_exit(fn -> Arbor.Security.revoke(capability.id) end)
    end

    %{agent_id: agent_id, context: %{agent_id: agent_id, taint_policy: :permissive}}
  end

  test "security regression: private fact is refused before KG or index writes, with real absent and nil controls",
       %{agent_id: agent_id, context: context} do
    before_graph = Memory.knowledge_stats(agent_id)
    assert {:ok, %{entry_count: 0}} = Memory.index_stats(agent_id)
    params = %{content: "The private code is QUARTZ-41", type: "fact"}

    {result, calls} =
      observe_calls(
        fn ->
          Actions.authorize_and_execute(
            agent_id,
            Actions.Memory.Remember,
            params,
            Map.put(context, :memory_write_policy, :deny)
          )
        end,
        [
          {Actions.Memory.Remember, :run, 2},
          {Memory, :authorize_add_knowledge_with_outcome, 4},
          {Memory, :index, 3},
          {Arbor.Trust, :authorize, 4}
        ]
      )

    assert result == @denied
    assert calls == []
    assert Memory.knowledge_stats(agent_id) == before_graph
    assert {:ok, %{entry_count: 0}} = Memory.index_stats(agent_id)

    assert {:ok, %{stored: true, indexed: true}} =
             Actions.authorize_and_execute(agent_id, Actions.Memory.Remember, params, context)

    assert {:ok, %{stored: true, indexed: true}} =
             Actions.authorize_and_execute(
               agent_id,
               Actions.Memory.Remember,
               %{content: "The public control is AMBER-52", type: "fact"},
               Map.put(context, :memory_write_policy, nil)
             )

    assert {:ok, %{entry_count: 2}} = Memory.index_stats(agent_id)
    refute Memory.knowledge_stats(agent_id) == before_graph

    assert {:ok, %{results: results}} =
             Actions.authorize_and_execute(
               agent_id,
               Actions.Memory.Recall,
               %{query: "private code", limit: 10},
               context
             )

    assert Enum.any?(results, &(&1.content == params.content))
  end

  test "security regression: reflection cannot persist private prompt and absent policy still executes",
       %{agent_id: agent_id, context: context} do
    before_history = Memory.reflection_history(agent_id)
    params = %{prompt: "private reflection", include_stats: false}

    {result, calls} =
      observe_calls(
        fn ->
          Actions.authorize_and_execute(
            agent_id,
            Actions.Memory.Reflect,
            params,
            Map.put(context, :memory_write_policy, :deny)
          )
        end,
        [{Actions.Memory.Reflect, :run, 2}, {Memory, :reflect, 2}, {LocalReflection, :reflect, 2}]
      )

    assert result == @denied
    assert calls == []
    assert Memory.reflection_history(agent_id) == before_history

    assert {:ok, %{reflection: %{prompt: "private reflection"}}} =
             Actions.authorize_and_execute(agent_id, Actions.Memory.Reflect, params, context)

    assert {:ok, reflections} = Memory.reflection_history(agent_id)
    assert Enum.any?(reflections, &(&1.prompt == params.prompt))
  end

  test "security regression: private Session recall consumes precomputed data without generic query embedding",
       ctx do
    assert {:ok, _} = Memory.index(ctx.agent_id, "ordinary agent-wide recall control")
    context = Map.put(ctx.context, :allow_pipeline_internal, true)
    private = [%{id: "verified-private-row", content: "private precomputed recall"}]

    params = %{
      agent_id: ctx.agent_id,
      query: "private query must stay local",
      private_recalled_memories: private
    }

    {result, calls} =
      observe_calls(
        fn ->
          Actions.authorize_and_execute(
            ctx.agent_id,
            Actions.SessionMemory.Recall,
            params,
            Map.put(context, :memory_write_policy, :deny)
          )
        end,
        [{Memory, :recall, 2}, {Memory, :recall, 3}, {LocalEmbedding, :embed, 1}]
      )

    assert {:ok, %{recalled_memories: ^private}} = result
    assert calls == []

    assert {:ok, %{recalled_memories: ordinary}} =
             Actions.authorize_and_execute(
               ctx.agent_id,
               Actions.SessionMemory.Recall,
               params,
               context
             )

    assert Enum.any?(ordinary, &(&1.content == "ordinary agent-wide recall control"))
    refute Enum.any?(ordinary, &(&1.content == "private precomputed recall"))
  end

  test "security regression: missing private preflight never falls back to generic beliefs or query recall",
       ctx do
    context = Map.merge(ctx.context, %{allow_pipeline_internal: true, memory_write_policy: :deny})

    for type <- ["query", "beliefs", "goals", "intents"] do
      {result, calls} =
        observe_calls(
          fn ->
            Actions.authorize_and_execute(
              ctx.agent_id,
              Actions.SessionMemory.Recall,
              %{agent_id: ctx.agent_id, query: "private query", recall_type: type},
              context
            )
          end,
          [{Actions.SessionMemory, :bridge, 4}]
        )

      assert result == {:ok, %{recalled_memories: []}}
      assert calls == []
    end
  end

  test "security regression: generic semantic recall aliases cannot send private queries to an unqualified provider",
       ctx do
    specs =
      for name <- ["memory.recall", "memory_recall"],
          do: %{type: name, query: "private query sentinel", memory_write_policy: "allow"}

    {results, calls} =
      observe_calls(
        fn ->
          Actions.execute_batch(specs,
            agent_id: ctx.agent_id,
            context: Map.put(ctx.context, :memory_write_policy, :deny)
          )
        end,
        [
          {Actions.Memory.Recall, :run, 2},
          {Memory, :authorize_recall, 4},
          {Memory, :recall, 3},
          {LocalEmbedding, :embed, 1}
        ]
      )

    assert Enum.map(results, &elem(&1, 1)) ==
             List.duplicate({:error, :private_turn_memory_query_denied}, 2)

    assert calls == []

    assert {:ok, _} =
             Actions.authorize_and_execute(
               ctx.agent_id,
               Actions.Memory.LoadWorking,
               %{},
               Map.put(ctx.context, :memory_write_policy, :deny)
             )
  end

  test "security regression: system facade execution cannot bypass an inherited write restriction",
       %{agent_id: agent_id, context: context} do
    params = %{content: "private system-dispatched fact", type: "fact"}
    before_graph = Memory.knowledge_stats(agent_id)

    {result, calls} =
      observe_calls(
        fn ->
          Actions.execute_action(
            Actions.Memory.Remember,
            params,
            Map.put(context, :memory_write_policy, :deny)
          )
        end,
        [{Actions.Memory.Remember, :run, 2}, {Memory, :index, 3}]
      )

    assert result == @denied
    assert calls == []
    assert Memory.knowledge_stats(agent_id) == before_graph
    assert {:ok, %{entry_count: 0}} = Memory.index_stats(agent_id)

    assert {:ok, %{stored: true, indexed: true}} =
             Actions.execute_action(Actions.Memory.Remember, params, context)

    assert {:ok, %{entry_count: 1}} = Memory.index_stats(agent_id)
  end

  test "security regression: all memory mutators and uncontained launches are refused before action code",
       %{agent_id: agent_id, context: context} do
    modules = [
      Actions.Memory.Remember,
      Actions.Memory.Connect,
      Actions.Memory.Reflect,
      Actions.Memory.Index,
      Actions.Memory.Consolidate,
      Actions.Memory.SaveWorking,
      Actions.MemoryIdentity.AddInsight,
      Actions.MemoryCognitive.AdjustPreference,
      Actions.MemoryCognitive.PinMemory,
      Actions.MemoryCognitive.UnpinMemory,
      Actions.MemoryReview.ReviewQueue,
      Actions.MemoryReview.AcceptSuggestion,
      Actions.MemoryReview.RejectSuggestion,
      Actions.MemoryCode.StoreCode,
      Actions.MemoryCode.DeleteCode,
      Actions.Relationship.Save,
      Actions.Relationship.Moment,
      Actions.SessionMemory.Consolidate,
      Actions.SessionMemory.UpdateWorkingMemory,
      Actions.SessionMemory.BackgroundChecks,
      Actions.SessionGoals.UpdateGoals,
      Actions.SessionGoals.StoreDecompositions,
      Actions.SessionGoals.ProcessProposalDecisions,
      Actions.SessionGoals.StoreIdentity,
      Actions.SessionGoals.PruneStaleIntents,
      Actions.SessionExecution.RouteActions,
      Actions.SessionExecution.ExecuteActions,
      Actions.Skill.Activate,
      Actions.Skill.Deactivate,
      Actions.Agent.SpawnWorker,
      Actions.Pipeline.Run,
      Actions.Council.Consult,
      Actions.Council.ConsultOne,
      Actions.Council.ReviewChange,
      Actions.Acp.StartSession,
      Actions.Acp.SendMessage
    ]

    restricted = Map.put(context, :memory_write_policy, :deny)

    {results, calls} =
      observe_calls(
        fn ->
          Enum.map(modules, fn module ->
            Actions.authorize_and_execute(agent_id, module, %{}, restricted)
          end)
        end,
        Enum.map(modules, &{&1, :run, 2}) ++ [{Arbor.Trust, :authorize, 4}]
      )

    assert calls == []
    assert results == List.duplicate(@denied, length(modules))
  end

  test "security regression: aliases, batch arguments and advertised names cannot replace resolved policy",
       %{agent_id: agent_id, context: context} do
    restricted = Map.put(context, :memory_write_policy, :deny)

    for name <- ["memory_remember", "memory.remember"] do
      spec = %{
        "type" => name,
        "params" => %{
          "content" => "private batch fact",
          "type" => "fact",
          "memory_write_policy" => nil,
          "action_module" => "Arbor.Actions.Memory.Recall",
          "context" => %{"memory_write_policy" => nil}
        }
      }

      assert [{^spec, @denied}] =
               Actions.execute_batch([spec], agent_id: agent_id, context: restricted)
    end

    assert @denied =
             Actions.authorize_and_execute(
               agent_id,
               Actions.Memory.Remember,
               %{content: "private", type: "fact", memory_write_policy: nil},
               Map.put(restricted, "memory_write_policy", nil)
             )

    assert {:ok, %{read: true}} =
             Actions.authorize_and_execute(agent_id, ReadProbe, %{}, restricted)

    assert {:ok, %{entry_count: 0}} = Memory.index_stats(agent_id)
  end

  test "security regression: unknown policies fail closed even for read actions",
       %{agent_id: agent_id, context: context} do
    for invalid <- [:allow, false, true, "deny", [], %{}] do
      restricted = Map.put(context, :memory_write_policy, invalid)
      assert @denied = Actions.authorize_and_execute(agent_id, ReadProbe, %{}, restricted)
      assert @denied = Actions.execute_action(ReadProbe, %{}, restricted)
    end

    assert {:ok, %{read: true}} = Actions.authorize_and_execute(agent_id, ReadProbe, %{}, context)
  end

  test "security regression: future memory-family action defaults closed before any callback",
       %{agent_id: agent_id, context: context} do
    module = Elixir.Arbor.Actions.Memory.PrivateTurnUnreviewedTestAction

    {result, calls} =
      observe_calls(
        fn ->
          Actions.authorize_and_execute(
            agent_id,
            module,
            %{},
            Map.put(context, :memory_write_policy, :deny)
          )
        end,
        [{module, :authorization_resource, 1}, {module, :run, 2}]
      )

    assert result == @denied
    assert calls == []

    assert {:ok, %{unreviewed_action_ran: true}} =
             Actions.authorize_and_execute(agent_id, module, %{}, context)
  end

  test "security regression: private empty Session update succeeds without calling the Memory bridge",
       %{agent_id: agent_id, context: context} do
    restricted = Map.merge(context, %{memory_write_policy: :deny, allow_pipeline_internal: true})

    inputs = [
      %{agent_id: agent_id},
      %{agent_id: agent_id, turn_data: nil},
      %{agent_id: agent_id, turn_data: %{}},
      %{agent_id: agent_id, turn_data: %{memory_notes: []}},
      %{"agent_id" => agent_id, "turn_data" => %{"memory_notes" => nil}},
      %{"agent_id" => agent_id, "session.turn_data" => %{"session.memory_notes" => []}}
    ]

    {results, calls} =
      observe_calls(
        fn ->
          Enum.map(inputs, fn params ->
            Actions.authorize_and_execute(
              agent_id,
              Actions.SessionMemory.Update,
              params,
              restricted
            )
          end)
        end,
        [{Memory, :index_memory_notes, 2}]
      )

    assert results == List.duplicate({:ok, %{memory_updated: false}}, length(inputs))
    assert calls == []
  end

  test "security regression: nonempty, conflicting and malformed Session note aliases cannot write",
       %{agent_id: agent_id, context: context} do
    restricted = Map.merge(context, %{memory_write_policy: :deny, allow_pipeline_internal: true})

    turn_data = [
      %{memory_notes: ["private"]},
      %{"memory_notes" => ["private"]},
      %{"session.memory_notes" => ["private"]},
      %{"memory_notes" => [], memory_notes: ["shadowed private"]},
      %{memory_notes: "private"},
      %{memory_notes: false},
      %{memory_notes: %{}},
      false,
      "private",
      []
    ]

    params =
      for key <- [:turn_data, "turn_data", "session.turn_data"], data <- turn_data do
        Map.put(%{agent_id: agent_id}, key, data)
      end

    params =
      params ++
        [%{"turn_data" => %{memory_notes: ["private"]}, agent_id: agent_id, turn_data: %{}}]

    {results, calls} =
      observe_calls(
        fn ->
          Enum.map(params, fn input ->
            Actions.authorize_and_execute(
              agent_id,
              Actions.SessionMemory.Update,
              input,
              restricted
            )
          end)
        end,
        [{Actions.SessionMemory.Update, :run, 2}, {Memory, :index_memory_notes, 2}]
      )

    assert results == List.duplicate(@denied, length(params))
    assert calls == []
  end

  defp observe_calls(fun, mfas) do
    Enum.each(mfas, fn {module, _function, _arity} -> Code.ensure_loaded!(module) end)
    session = :trace.session_create(__MODULE__, self(), [])
    run_ref = make_ref()

    task =
      Task.async(fn ->
        receive do
          {:run, ^run_ref} ->
            try do
              fun.()
            rescue
              exception ->
                {:observed_action_exception, exception.__struct__, Exception.message(exception)}
            end
        end
      end)

    try do
      for mfa <- mfas do
        assert 1 = :trace.function(session, mfa, true, [:local])
      end

      assert 1 = :trace.process(session, task.pid, true, [:call])
      send(task.pid, {:run, run_ref})
      result = Task.await(task, @timeout)
      delivered = :trace.delivered(session, :all)
      assert_receive {:trace_delivered, :all, ^delivered}, @timeout
      {result, drain_calls(task.pid, [])}
    after
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
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
end
