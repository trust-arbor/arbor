defmodule Arbor.Actions.MemorySuggestionReviewTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions
  alias Arbor.Actions.MemoryReview.{AcceptSuggestion, RejectSuggestion, ReviewSuggestions}
  alias Arbor.Memory

  @moduletag :fast
  @moduletag :integration

  setup do
    agent_id = init_agent("review")
    foreign_agent_id = init_agent("foreign")

    for resource <- ["arbor://memory/read", "arbor://memory/write"] do
      assert {:ok, capability} = Arbor.Security.grant(principal: agent_id, resource: resource)
      on_exit(fn -> Arbor.Security.revoke(capability.id) end)
    end

    %{agent_id: agent_id, foreign_agent_id: foreign_agent_id, context: %{agent_id: agent_id}}
  end

  test "listed suggestion IDs round-trip through public accept and reject", %{
    agent_id: agent_id,
    context: context
  } do
    accepted = propose(agent_id, :insight, "Explain decisions with concise examples")
    rejected = propose(agent_id, :insight, "Investigate conflicting evidence before proceeding")

    assert {:ok, %{suggestions: suggestions, count: 2}} =
             dispatch(agent_id, ReviewSuggestions, %{}, context)

    assert MapSet.new(Enum.map(suggestions, & &1.id)) == MapSet.new([accepted.id, rejected.id])
    accepted_id = Enum.find(suggestions, &(&1.content == accepted.content)).id
    rejected_id = Enum.find(suggestions, &(&1.content == rejected.content)).id

    assert {:ok, %{suggestion_id: ^accepted_id, node_id: node_id, accepted: true}} =
             dispatch(agent_id, AcceptSuggestion, %{suggestion_id: accepted_id}, context)

    assert {:ok, %{status: :accepted}} = Memory.get_proposal(agent_id, accepted_id)
    assert {:ok, graph_after_accept} = Memory.export_knowledge_graph(agent_id)
    assert %{content: content, type: :insight} = Map.fetch!(graph_after_accept.nodes, node_id)
    assert content == accepted.content

    assert {:ok, %{suggestion_id: ^rejected_id, rejected: true}} =
             dispatch(agent_id, RejectSuggestion, %{suggestion_id: rejected_id}, context)

    assert {:ok, %{status: :rejected}} = Memory.get_proposal(agent_id, rejected_id)
    assert {:ok, ^graph_after_accept} = Memory.export_knowledge_graph(agent_id)

    assert {:ok, %{suggestions: [], count: 0}} =
             dispatch(agent_id, ReviewSuggestions, %{}, context)
  end

  test "repeated bounded listing keeps IDs stable and leaves the queue and graph unchanged", %{
    agent_id: agent_id,
    foreign_agent_id: foreign_agent_id,
    context: context
  } do
    first = propose(agent_id, :insight, "Prefer explicit assumptions")
    second = propose(agent_id, :insight, "Check failure paths during code review")
    propose(agent_id, :fact, "The launch date is September ninth")
    deferred = propose(agent_id, :insight, "Research unfamiliar libraries before choosing one")
    assert :ok = Memory.defer_proposal(agent_id, deferred.id)
    propose(foreign_agent_id, :insight, "A different agent prefers detailed progress reports")
    before = snapshot(agent_id)
    foreign_before = snapshot(foreign_agent_id)

    assert {:ok, %{suggestions: suggestions, count: 2} = listed} =
             dispatch(agent_id, ReviewSuggestions, %{}, context)

    assert MapSet.new(Enum.map(suggestions, & &1.id)) == MapSet.new([first.id, second.id])
    assert Enum.all?(suggestions, &(&1.type == :insight and is_binary(&1.id)))

    for _ <- 1..3 do
      assert {:ok, ^listed} = dispatch(agent_id, ReviewSuggestions, %{}, context)
    end

    assert {:ok, %{suggestions: [limited], count: 1}} =
             dispatch(agent_id, ReviewSuggestions, %{limit: 1}, context)

    assert limited in suggestions

    assert {:ok, %{suggestions: [], count: 0}} =
             dispatch(agent_id, ReviewSuggestions, %{limit: 0}, context)

    assert snapshot(agent_id) == before
    assert snapshot(foreign_agent_id) == foreign_before
    assert {:ok, %{status: :deferred}} = Memory.get_proposal(agent_id, deferred.id)
  end

  test "security regression: missing and foreign IDs cannot mutate either agent's proposals or graph",
       %{agent_id: agent_id, foreign_agent_id: foreign_agent_id, context: context} do
    own = propose(agent_id, :insight, "Use reproducible experiments")
    foreign = propose(foreign_agent_id, :insight, "Reserve mornings for focused work")
    before = snapshot(agent_id)
    foreign_before = snapshot(foreign_agent_id)

    for action <- [AcceptSuggestion, RejectSuggestion],
        id <- ["prop_missing_suggestion", foreign.id] do
      assert {:error, :not_found} =
               dispatch(
                 agent_id,
                 action,
                 %{suggestion_id: id, agent_id: foreign_agent_id},
                 context
               )
    end

    assert snapshot(agent_id) == before
    assert snapshot(foreign_agent_id) == foreign_before
    assert {:ok, %{status: :pending}} = Memory.get_proposal(agent_id, own.id)
    assert {:ok, %{status: :pending}} = Memory.get_proposal(foreign_agent_id, foreign.id)
  end

  test "security regression: a private turn can list stable IDs but cannot decide them", %{
    agent_id: agent_id,
    context: context
  } do
    proposal = propose(agent_id, :insight, "State uncertainty when evidence is incomplete")
    restricted = Map.put(context, :memory_write_policy, :deny)
    before = snapshot(agent_id)

    assert {:ok, %{suggestions: [suggestion], count: 1}} =
             dispatch(agent_id, ReviewSuggestions, %{}, restricted)

    assert suggestion.id == proposal.id

    for action <- [AcceptSuggestion, RejectSuggestion] do
      assert {:error, :private_turn_memory_write_denied} =
               dispatch(
                 agent_id,
                 action,
                 %{suggestion_id: suggestion.id, memory_write_policy: nil},
                 restricted
               )
    end

    assert snapshot(agent_id) == before
    assert {:ok, %{status: :pending}} = Memory.get_proposal(agent_id, suggestion.id)

    assert {:ok, %{accepted: true}} =
             dispatch(agent_id, AcceptSuggestion, %{suggestion_id: suggestion.id}, context)
  end

  test "proposal listing errors are reported instead of an empty successful review", %{
    agent_id: agent_id,
    context: context
  } do
    before = snapshot(agent_id)

    assert {:error, :limit_exceeded} =
             dispatch(agent_id, ReviewSuggestions, %{limit: 10_001}, context)

    assert snapshot(agent_id) == before
  end

  test "public tool discovery and name resolution expose the queued suggestion reader" do
    assert ReviewSuggestions in Actions.exposed_actions()
    assert Enum.any?(Actions.all_tools(), &(&1[:name] == "memory_review_suggestions"))

    for name <- ["memory_review_suggestions", "memory_review.review_suggestions"] do
      assert {:ok, ReviewSuggestions} = Actions.name_to_module(name)
    end
  end

  test "security regression: read-only authority cannot approve a queued suggestion" do
    agent_id = init_agent("reader")
    assert {:ok, cap} = Arbor.Security.grant(principal: agent_id, resource: "arbor://memory/read")
    on_exit(fn -> Arbor.Security.revoke(cap.id) end)
    context = %{agent_id: agent_id}
    proposal = propose(agent_id, :insight, "read-only proposal fixture")
    before = snapshot(agent_id)

    assert {:ok, %{suggestions: [%{id: id}]}} =
             dispatch(agent_id, ReviewSuggestions, %{}, context)

    assert id == proposal.id

    for action <- [AcceptSuggestion, RejectSuggestion] do
      assert {:error, _reason} =
               dispatch(agent_id, action, %{suggestion_id: id}, context)
    end

    assert snapshot(agent_id) == before
  end

  defp init_agent(label) do
    agent_id = "agent_suggestion_#{label}_#{System.unique_integer([:positive])}"
    assert {:ok, nil} = Memory.init_for_agent(agent_id, index_enabled: false, auto_embed: false)
    on_exit(fn -> assert :ok = Memory.cleanup_for_agent(agent_id) end)
    agent_id
  end

  defp propose(agent_id, type, content) do
    assert {:ok, %{id: id} = proposal} =
             Memory.create_proposal(agent_id, type, %{content: content, confidence: 0.7})

    assert is_binary(id)
    proposal
  end

  defp dispatch(agent_id, action, params, context) do
    Actions.authorize_and_execute(agent_id, action, params, context)
  end

  defp snapshot(agent_id) do
    assert {:ok, proposals} = Memory.get_proposals(agent_id)
    stats = Memory.proposal_stats(agent_id)
    assert is_map(stats)
    assert {:ok, graph} = Memory.export_knowledge_graph(agent_id)
    %{proposals: proposals, stats: stats, graph: graph}
  end
end
