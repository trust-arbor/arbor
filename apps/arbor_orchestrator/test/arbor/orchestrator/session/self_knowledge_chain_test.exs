defmodule Arbor.Orchestrator.Session.SelfKnowledgeChainTest do
  @moduledoc """
  Standalone SQLite proof of the production heartbeat DOT, model-output parser,
  Memory writes, and the following provider request. Uses the real Actions
  executor; only the provider response is deterministic. SQLite/BufferedStore
  reopen and exact-agent projection eviction prove storage reload in this BEAM,
  not whole-BEAM, node, or host restart. Identity admission remains asynchronous.
  """
  use ExUnit.Case, async: false

  alias Arbor.Actions
  alias Arbor.Actions.MemoryReview.{ReviewQueue, ReviewSuggestions}
  alias Arbor.LLM.{Client, ContentPart, Request, Response}
  alias Arbor.Memory
  alias Arbor.Orchestrator
  alias Arbor.Orchestrator.Session.Builders
  alias Arbor.Persistence
  alias Arbor.Persistence.{BufferedStore, QueryableStore, Repo}

  @moduletag :isolated_repo
  @moduletag :database
  @moduletag :sqlite
  @moduletag :integration
  @store :arbor_memory_durable
  @collection "model_output_chain_fixture"
  @heartbeat_path Path.expand("../../../../specs/pipelines/session/heartbeat.dot", __DIR__)
  @migrations_path Path.expand("../../../../../arbor_persistence/priv/repo/migrations", __DIR__)

  if Repo.__adapter__() != Ecto.Adapters.SQLite3 do
    @moduletag skip: "requires the compiled SQLite Repo adapter"
  end

  defmodule Probe do
    use Agent
    def start_link(parent), do: Agent.start_link(fn -> parent end, name: __MODULE__)
    def parent, do: Agent.get(__MODULE__, & &1)
  end

  defmodule CaptureProvider do
    @behaviour Arbor.LLM.ProviderAdapter
    @impl true
    def provider, do: "lm_studio"

    @impl true
    def complete(%Request{} = request, _opts) do
      send(Probe.parent(), {:provider_request, request, self()})

      receive do
        {:respond, body} ->
          text = Jason.encode!(body)

          {:ok,
           %Response{
             text: text,
             content_parts: [ContentPart.text(text)],
             finish_reason: :stop,
             usage: %{input_tokens: 1, output_tokens: 1},
             raw: %{}
           }}
      after
        5_000 -> {:error, :fixture_response_not_supplied}
      end
    end

    @impl true
    def complete_single_attempt(request, opts), do: complete(request, opts)
  end

  setup do
    assert System.get_env("ARBOR_TEST_MEMORY_AUTHORITY") == "external",
           "run this file alone with ARBOR_TEST_MEMORY_AUTHORITY=external"

    assert Process.whereis(@store) == nil, "fixture must own the memory authority"
    assert Process.whereis(Repo) == nil, "fixture must own its private SQLite Repo"

    root =
      Path.join(System.tmp_dir!(), "model-output-chain-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    repo_opts = [
      database: Path.join(root, "memory.sqlite3"),
      pool: DBConnection.ConnectionPool,
      pool_size: 2,
      busy_timeout: 5_000,
      journal_mode: :wal
    ]

    start_supervised!({Repo, repo_opts})
    assert [_ | _] = Ecto.Migrator.run(Repo, @migrations_path, :up, all: true, log: false)

    store_opts = [
      name: @store,
      backend: QueryableStore.Postgres,
      backend_opts: [repo: Repo],
      collection: @collection,
      write_mode: :sync,
      ack_mode: :backend
    ]

    start_supervised!({BufferedStore, store_opts})
    start_supervised!({Probe, self()})

    client =
      Client.new(default_provider: CaptureProvider.provider(), model_catalog: %{})
      |> Client.register_adapter(CaptureProvider)

    agent = init_agent("chain")
    existing_writers = writer_pids()

    grants =
      for resource <- [
            "arbor://orchestrator/execute/**",
            "arbor://memory/read",
            "arbor://memory/write",
            "arbor://action/session_goals/prune_stale_intents"
          ] do
        assert {:ok, cap} = Arbor.Security.grant(principal: agent, resource: resource)
        cap
      end

    on_exit(fn ->
      await_writers(existing_writers)
      Enum.each(grants, &Arbor.Security.revoke(&1.id))
      clear_projections(agent)
      File.rm_rf!(root)
    end)

    %{
      agent: agent,
      root: root,
      client: client,
      repo_opts: repo_opts,
      store_opts: store_opts,
      existing_writers: existing_writers,
      grants: grants
    }
  end

  test "two production DOT beats store valid later output and deliver reloaded insight to provider",
       ctx do
    first = start_beat(ctx)
    assert_receive {:provider_request, first_request, provider}, 5_000
    refute prompt_text(first_request) =~ "I can trace complete persistence flows"
    refute prompt_text(first_request) =~ "can_trace_complete_persistence"

    send(
      provider,
      {:respond,
       %{
         "identity_insights" => [
           %{"category" => "unknown-model-category", "content" => "invalid first item"},
           %{"category" => "trait", "content" => false},
           %{
             "category" => "capability",
             "content" => "I can trace complete persistence flows",
             "confidence" => 0.9
           }
         ],
         "memory_notes" => ["The fixture note survives storage reload"],
         "concerns" => ["Verify the actual destination"],
         "curiosity" => ["What consumes this value?"]
       }}
    )

    assert {:ok, first_result} = Task.await(first, 10_000)
    assert first_result.final_outcome.status == :success
    assert "store_identity" in first_result.completed_nodes
    assert "update_wm" in first_result.completed_nodes
    assert first_result.context["session.identity_admitted_count"] == 1
    assert first_result.context["session.identity_skipped_count"] == 2
    assert first_result.context["session.identity_error_count"] == 0
    assert first_result.context["session.identity_persistence"] == "unconfirmed"
    assert first_result.context["session.working_memory_result"]["applied_count"] == 3
    await_writers(ctx.existing_writers)

    assert {:ok, identity_record} = persisted("self_knowledge:#{ctx.agent}")
    assert Jason.encode!(identity_record.data) =~ "I can trace complete persistence flows"
    assert {:ok, wm_record} = persisted("working_memory:#{ctx.agent}")
    assert Jason.encode!(wm_record.data) =~ "The fixture note survives storage reload"
    reopen_storage(ctx)

    assert Memory.summarize_self_knowledge(Memory.get_self_knowledge(ctx.agent)) =~
             "can_trace_complete_persistence"

    second = start_beat(ctx)
    assert_receive {:provider_request, second_request, provider}, 5_000
    assert prompt_text(second_request) =~ "can_trace_complete_persistence"
    assert prompt_text(second_request) =~ "The fixture note survives storage reload"
    send(provider, {:respond, %{}})
    assert {:ok, second_result} = Task.await(second, 10_000)
    assert second_result.final_outcome.status == :success
    assert second_result.context["session.identity_admitted_count"] == 0
    assert second_result.context["session.identity_persistence"] == "not_requested"
    assert second_result.context["session.wm_updated"] == false
  end

  test "refused identity admission fails the production beat without reporting accepted output",
       ctx do
    beat = start_beat(ctx)
    assert_receive {:provider_request, _request, provider}, 5_000
    await_writers(ctx.existing_writers)
    # Exact test-agent admission closure is fault setup, not a domain assertion.
    assert {:ok, _fence} = Memory.MutationAdmission.drain(ctx.agent, timeout_ms: 1_000)

    send(
      provider,
      {:respond,
       %{
         "identity_insights" => [
           %{"category" => "capability", "content" => "must not be admitted"},
           %{"category" => "value", "content" => "must not be admitted either"}
         ]
       }}
    )

    assert {:ok, result} = Task.await(beat, 10_000)
    assert result.final_outcome.status == :fail
    assert result.final_outcome.failure_reason =~ "identity_store_failed"
    assert result.final_outcome.failure_reason =~ "identity_admitted_count: 0"
    assert result.final_outcome.failure_reason =~ "identity_error_count: 2"
    assert Memory.get_self_knowledge(ctx.agent) == nil
    assert {:error, :not_found} = persisted("self_knowledge:#{ctx.agent}")
  end

  test "public catalog proposal IDs reach ReviewQueue and accepted knowledge survives SQLite reopen",
       ctx do
    foreign = init_agent("foreign")
    on_exit(fn -> clear_projections(foreign) end)
    assert ReviewSuggestions in Actions.exposed_actions()
    assert Enum.any?(Actions.all_tools(), &(&1[:name] == "memory_review_suggestions"))
    assert {:ok, ReviewSuggestions} = Actions.name_to_module("memory_review_suggestions")
    assert {:ok, ReviewQueue} = Actions.name_to_module("memory_review.review_queue")

    assert {:ok, accepted} =
             Memory.create_proposal(ctx.agent, :insight, %{
               content: "accepted durable fixture",
               confidence: 0.8
             })

    assert {:ok, rejected} =
             Memory.create_proposal(ctx.agent, :insight, %{
               content: "rejected fixture",
               confidence: 0.8
             })

    assert {:ok, foreign_proposal} =
             Memory.create_proposal(foreign, :insight, %{
               content: "foreign fixture",
               confidence: 0.8
             })

    context = %{agent_id: ctx.agent}

    assert {:ok, %{suggestions: suggestions}} =
             Actions.authorize_and_execute(ctx.agent, ReviewSuggestions, %{}, context)

    assert MapSet.new(Enum.map(suggestions, & &1.id)) == MapSet.new([accepted.id, rejected.id])
    assert {:ok, before} = Memory.export_knowledge_graph(ctx.agent)
    assert {:ok, foreign_before} = Memory.export_knowledge_graph(foreign)

    for id <- ["proposal_missing_fixture", foreign_proposal.id],
        action <- ["approve", "reject"] do
      assert {:error, :not_found} =
               Actions.authorize_and_execute(
                 ctx.agent,
                 ReviewQueue,
                 %{action: action, item_id: id},
                 context
               )
    end

    assert {:error, :private_turn_memory_write_denied} =
             Actions.authorize_and_execute(
               ctx.agent,
               ReviewQueue,
               %{action: "approve", item_id: accepted.id},
               Map.put(context, :memory_write_policy, :deny)
             )

    assert {:ok, ^before} = Memory.export_knowledge_graph(ctx.agent)
    assert {:ok, ^foreign_before} = Memory.export_knowledge_graph(foreign)

    assert {:ok, %{approved: true}} =
             Actions.authorize_and_execute(
               ctx.agent,
               ReviewQueue,
               %{action: "approve", item_id: accepted.id},
               context
             )

    assert {:ok, %{rejected: true}} =
             Actions.authorize_and_execute(
               ctx.agent,
               ReviewQueue,
               %{action: "reject", item_id: rejected.id},
               context
             )

    assert {:ok, after_accept} = Memory.export_knowledge_graph(ctx.agent)
    assert Enum.any?(after_accept.nodes, fn {_id, node} -> node.content == accepted.content end)
    refute Enum.any?(after_accept.nodes, fn {_id, node} -> node.content == rejected.content end)
    assert {:ok, %{status: :accepted}} = Memory.get_proposal(ctx.agent, accepted.id)
    assert {:ok, %{status: :rejected}} = Memory.get_proposal(ctx.agent, rejected.id)

    assert {:ok, %{suggestions: []}} =
             Actions.authorize_and_execute(ctx.agent, ReviewSuggestions, %{}, context)

    assert {:ok, _record} = persisted("knowledge_graph:#{ctx.agent}")
    reopen_storage(ctx)
    assert {:ok, ^after_accept} = Memory.export_knowledge_graph(ctx.agent)
    assert {:ok, ^foreign_before} = Memory.export_knowledge_graph(foreign)
  end

  defp start_beat(ctx) do
    state = %{
      agent_id: ctx.agent,
      session_id: "heartbeat-#{ctx.agent}",
      turn_count: 1,
      config: %{"llm_provider" => "lmstudio", "llm_model" => "model-output-fixture"},
      heartbeat_beat_count: 10
    }

    values = Builders.build_heartbeat_values(state)

    Task.async(fn ->
      Orchestrator.run(File.read!(@heartbeat_path),
        agent_id: ctx.agent,
        execution_principal: ctx.agent,
        authorization: false,
        resumable: false,
        logs_root: ctx.root,
        llm_client: ctx.client,
        initial_values: values
      )
    end)
  end

  defp init_agent(label) do
    agent = "agent_#{label}_#{System.unique_integer([:positive])}"
    assert {:ok, nil} = Memory.init_for_agent(agent, index_enabled: false, auto_embed: false)
    agent
  end

  defp reopen_storage(ctx) do
    await_writers(ctx.existing_writers)
    assert :ok = stop_supervised(BufferedStore)
    assert :ok = stop_supervised(Repo)
    clear_projections(ctx.agent)
    start_supervised!({Repo, ctx.repo_opts})
    start_supervised!({BufferedStore, ctx.store_opts})
  end

  defp clear_projections(agent) do
    for table <- [:arbor_self_knowledge, :arbor_working_memory, :arbor_memory_graphs],
        :ets.whereis(table) != :undefined do
      :ets.delete(table, agent)
    end
  end

  defp persisted(key), do: Persistence.get(@collection, QueryableStore.Postgres, key, repo: Repo)

  defp prompt_text(request),
    do: Enum.map_join(request.messages, "\n", &inspect(&1.content, limit: :infinity))

  defp writer_pids do
    Memory.AsyncWriter.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_, pid, _, _} -> if is_pid(pid), do: [pid], else: [] end)
    |> MapSet.new()
  end

  defp await_writers(existing) do
    for pid <- MapSet.difference(writer_pids(), existing) do
      monitor = Process.monitor(pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 5_000
    end
  end
end
