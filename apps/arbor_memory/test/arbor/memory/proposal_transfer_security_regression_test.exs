defmodule Arbor.Memory.ProposalTransferSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope, TaintedValue}

  alias Arbor.Memory.{
    Events,
    GoalStore,
    GraphOps,
    IntentStore,
    KnowledgeGraph,
    KnowledgeGraphStore,
    Proposal
  }

  alias Arbor.Memory.Proposal.{Core, Store}
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag spec: "VOICE-17"

  setup do
    ensure_durable_store()
    agent_id = "prop_xfer_#{System.unique_integer([:positive])}"
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)
    assert :ok = GraphOps.save_graph(agent_id, graph)

    on_exit(fn ->
      _ = Proposal.delete_all(agent_id)
      _ = GoalStore.clear_goals(agent_id)
      _ = IntentStore.clear(agent_id)
    end)

    %{agent_id: agent_id}
  end

  test "security regression: every knowledge route transfers joined taint onto KG node", %{
    agent_id: agent_id
  } do
    require_candidate_transfer!()

    routes = [
      {:fact, :fact},
      {:insight, :insight},
      {:learning, :skill},
      {:pattern, :experience},
      {:preconscious, :experience},
      {:thought, :observation},
      {:concern, :observation},
      {:curiosity, :observation},
      {:cognitive_mode, :observation},
      {:identity, :trait}
    ]

    for {ptype, node_type} <- routes do
      taint = hostile_taint("route_#{ptype}")

      {:ok, p} =
        Proposal.create_tainted(agent_id, ptype, %{content: "content for #{ptype}"}, taint)

      assert {:ok, target_id} = Proposal.accept_tainted(agent_id, p.id, trusted_taint("accept"))
      assert is_binary(target_id)

      {:ok, graph} = GraphOps.get_graph(agent_id)
      {:ok, node} = KnowledgeGraph.get_node(graph, target_id)
      assert node.type == node_type

      assert {:ok, snapshot} = KnowledgeGraphStore.get_snapshot(agent_id)
      labelled = Map.fetch!(snapshot.nodes, target_id)
      assert labelled.label.taint.level == :hostile
      assert labelled.label.taint.sensitivity == :restricted
    end
  end

  test "security regression: goal route writes only GoalStore with joined taint", %{
    agent_id: agent_id
  } do
    require_candidate_transfer!()

    taint = hostile_taint("goal")
    before_count = graph_node_count(agent_id)

    {:ok, p} =
      Proposal.create_tainted(
        agent_id,
        :goal,
        %{
          content: "Ship proposal authority",
          metadata: %{goal_data: %{"priority" => "high"}}
        },
        taint
      )

    assert {:ok, goal_id} = Proposal.accept_tainted(agent_id, p.id, trusted_taint("a"))
    assert String.starts_with?(goal_id, "goal_prop_")

    assert {:ok, %TaintedValue{value: goal, taint: gt}, _} =
             GoalStore.get_goal_tainted(agent_id, goal_id)

    assert goal.description == "Ship proposal authority"
    assert gt.level == :hostile
    assert gt.sensitivity == :restricted

    # No knowledge-graph reference node for goal route
    assert graph_node_count(agent_id) == before_count
    refute_kg_reference(agent_id, goal_id)
    refute_kg_content(agent_id, "Ship proposal authority")
  end

  test "security regression: intent route writes only IntentStore with joined taint", %{
    agent_id: agent_id
  } do
    require_candidate_transfer!()

    taint = hostile_taint("intent")
    before_count = graph_node_count(agent_id)

    {:ok, p} =
      Proposal.create_tainted(
        agent_id,
        :intent,
        %{
          content: "Read config",
          metadata: %{decomposition: %{"capability" => "fs", "op" => "read", "target" => "/tmp"}}
        },
        taint
      )

    assert {:ok, intent_id} = Proposal.accept_tainted(agent_id, p.id, trusted_taint("a"))
    assert String.starts_with?(intent_id, "int_prop_")

    assert {:ok, items} = IntentStore.recent_intents_tainted(agent_id, limit: 20)
    match = Enum.find(items, fn {%TaintedValue{value: intent}, _} -> intent.id == intent_id end)
    assert match
    {%TaintedValue{taint: it}, _status} = match
    assert it.level == :hostile
    assert it.sensitivity == :restricted

    assert graph_node_count(agent_id) == before_count
    refute_kg_reference(agent_id, intent_id)
    refute_kg_content(agent_id, "Read config")
  end

  test "security regression: goal_update requires valid metadata", %{agent_id: agent_id} do
    require_candidate_transfer!()

    {:ok, goal} = GoalStore.add_goal_tainted(agent_id, "Existing", [], trusted_taint("g"))
    goal_id = goal.id

    {:ok, p} =
      Proposal.create(agent_id, :goal_update, %{
        content: "progress",
        metadata: %{update_data: %{"id" => goal_id, "progress" => 0.5}}
      })

    assert {:ok, ^goal_id} = Proposal.accept(agent_id, p.id)

    assert {:ok, %TaintedValue{taint: gt}, _} = GoalStore.get_goal_tainted(agent_id, goal_id)
    # raw accept joins missing_fallback; must not remain pure trusted public
    refute gt.level == :trusted and gt.sensitivity == :public

    {:ok, bad} =
      Proposal.create(agent_id, :goal_update, %{
        content: "missing id",
        metadata: %{update_data: %{}}
      })

    assert {:error, :invalid_request} = Proposal.accept(agent_id, bad.id)
    {:ok, still} = Proposal.get(agent_id, bad.id)
    assert still.status == :pending
  end

  test "security regression: retry accept is one target effect", %{agent_id: agent_id} do
    require_candidate_transfer!()

    {:ok, p} = Proposal.create(agent_id, :fact, %{content: "once only"})
    {:ok, t1} = Proposal.accept(agent_id, p.id)
    {:ok, t2} = Proposal.accept(agent_id, p.id)
    assert t1 == t2

    {:ok, graph} = GraphOps.get_graph(agent_id)

    matches =
      graph.nodes
      |> Map.values()
      |> Enum.filter(&(&1.content == "once only"))

    assert length(matches) == 1
  end

  test "security regression: in-flight lost-ack replay converges to one target", %{
    agent_id: agent_id
  } do
    require_candidate_transfer!()

    content = "lost ack replay content unique #{System.unique_integer([:positive])}"
    {:ok, p} = Proposal.create(agent_id, :fact, %{content: content})

    decision = TaintEnvelope.missing_fallback()

    # Real prepare: reserve fence + joined target-write taint.
    assert {:ok, {:ready, proposal, joined_taint, _joined_status, fence}} =
             GenServer.call(
               Store,
               {:prepare_accept, agent_id, p.id, decision, :legacy_unlabeled}
             )

    assert fence.phase == :in_flight
    assert is_binary(fence.operation_id)
    assert {:knowledge, node_data} = Core.transfer_plan(proposal)

    # Target write once with the reserved stable operation_id; omit complete (lost ack).
    assert {:ok, first_target} =
             GraphOps.add_knowledge_tainted(agent_id, node_data, joined_taint,
               operation_id: fence.operation_id
             )

    {:ok, mid} = Proposal.get(agent_id, p.id)
    assert mid.status == :pending

    # Public accept must replay the same op id, complete the fence, and converge.
    assert {:ok, target} = Proposal.accept(agent_id, p.id)
    assert target == first_target
    assert {:ok, ^target} = Proposal.accept(agent_id, p.id)

    {:ok, done} = Proposal.get(agent_id, p.id)
    assert done.status == :accepted

    {:ok, graph} = GraphOps.get_graph(agent_id)

    matches =
      graph.nodes
      |> Map.values()
      |> Enum.filter(&(&1.content == content))

    assert length(matches) == 1
    assert hd(matches).id == target

    assert {:ok, recent} = Events.get_recent(agent_id, 50)

    accepted =
      Enum.filter(recent, fn event ->
        to_string(event.type) == "proposal_accepted" and
          (event.data["proposal_id"] == p.id or event.data[:proposal_id] == p.id)
      end)

    assert length(accepted) == 1
  end

  test "security regression: failed transfer does not mark accepted or emit success path", %{
    agent_id: agent_id
  } do
    require_candidate_transfer!()

    test_pid = self()

    {:ok, sub_id} =
      Arbor.Signals.subscribe("memory.proposal_accepted", fn signal ->
        send(test_pid, {:proposal_accepted_signal, signal})
      end)

    on_exit(fn -> Arbor.Signals.unsubscribe(sub_id) end)

    {:ok, p} =
      Proposal.create(agent_id, :goal_update, %{
        content: "no target",
        metadata: %{update_data: %{}}
      })

    assert {:error, :invalid_request} = Proposal.accept(agent_id, p.id)
    {:ok, still} = Proposal.get(agent_id, p.id)
    assert still.status == :pending

    refute_receive {:proposal_accepted_signal, _}, 200

    assert {:ok, recent} = Events.get_recent(agent_id, 50)

    refute Enum.any?(recent, fn event ->
             to_string(event.type) == "proposal_accepted" and
               (event.data["proposal_id"] == p.id or event.data[:proposal_id] == p.id)
           end)
  end

  test "security regression: accept_all all-ok vs batch_incomplete shapes", %{agent_id: agent_id} do
    require_candidate_transfer!()

    batch_a =
      ("batch_a_" <> Integer.to_string(System.unique_integer([:positive])))
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    batch_b =
      ("batch_b_" <> Integer.to_string(System.unique_integer([:positive])))
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    {:ok, _} = Proposal.create(agent_id, :fact, %{content: batch_a})
    {:ok, _} = Proposal.create(agent_id, :fact, %{content: batch_b})
    assert {:ok, results} = Proposal.accept_all(agent_id)
    assert length(results) == 2
    assert Enum.all?(results, fn {id, target} -> is_binary(id) and is_binary(target) end)

    {:ok, ok_p} = Proposal.create(agent_id, :fact, %{content: "ok item"})
    {:ok, bad_p} = Proposal.create(agent_id, :goal_update, %{content: "bad", metadata: %{}})

    assert {:error, {:batch_incomplete, ordered}} = Proposal.accept_all(agent_id)
    assert length(ordered) == 2
    assert Enum.any?(ordered, fn {id, r} -> id == ok_p.id and match?({:ok, _}, r) end)
    assert Enum.any?(ordered, fn {id, r} -> id == bad_p.id and match?({:error, _}, r) end)

    {:ok, bad_still} = Proposal.get(agent_id, bad_p.id)
    assert bad_still.status == :pending
  end

  defp require_candidate_transfer! do
    unless Code.ensure_loaded?(Store) and function_exported?(Proposal, :create_tainted, 4) do
      flunk("candidate taint-preserving proposal transfer is required")
    end
  end

  defp graph_node_count(agent_id) do
    case GraphOps.get_graph(agent_id) do
      {:ok, graph} -> map_size(graph.nodes)
      {:error, reason} -> flunk("graph read failed: #{inspect(reason)}")
    end
  end

  defp refute_kg_reference(agent_id, domain_id) do
    case GraphOps.get_graph(agent_id) do
      {:ok, graph} ->
        refute Enum.any?(Map.values(graph.nodes), fn node ->
                 meta = Map.get(node, :metadata) || %{}

                 Map.get(meta, :domain_key) == domain_id or
                   Map.get(meta, "domain_key") == domain_id or
                   Map.get(meta, :proposal_id) == domain_id
               end)

      {:error, reason} ->
        flunk("graph read failed: #{inspect(reason)}")
    end
  end

  defp refute_kg_content(agent_id, content) do
    case GraphOps.get_graph(agent_id) do
      {:ok, graph} ->
        refute Enum.any?(Map.values(graph.nodes), &(&1.content == content))

      {:error, reason} ->
        flunk("graph read failed: #{inspect(reason)}")
    end
  end

  defp trusted_taint(source) do
    %Taint{
      level: :trusted,
      sensitivity: :public,
      sanitizations: 0,
      confidence: :verified,
      source: source,
      chain: []
    }
  end

  defp hostile_taint(source) do
    %Taint{
      level: :hostile,
      sensitivity: :restricted,
      sanitizations: 0,
      confidence: :unverified,
      source: source,
      chain: []
    }
  end

  defp ensure_durable_store do
    case Process.whereis(:arbor_memory_durable) do
      nil ->
        start_supervised!(
          {BufferedStore, name: :arbor_memory_durable, backend: nil, write_mode: :sync}
        )

      _ ->
        :ok
    end
  end
end
