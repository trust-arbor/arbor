defmodule Arbor.Agent.Executor.ActionCatalogSecurityRegressionTest do
  @moduledoc """
  Exercises the trusted runtime Executor ingress with real held capabilities,
  Actions authorization and Memory proposals. This lookup repair does not add
  authenticated human intent admission or change the existing test identity mode.
  The observer delegates every pre-dispatch decision to Security; it cannot
  manufacture an allow. The index uses a local deterministic provider; no LLM
  or external database is used.
  """

  use ExUnit.Case, async: false

  alias Arbor.Actions

  alias Arbor.Actions.MemoryReview.{
    AcceptSuggestion,
    RejectSuggestion,
    ReviewQueue,
    ReviewSuggestions
  }

  alias Arbor.Agent.Executor
  alias Arbor.Agent.Executor.ActionDispatch
  alias Arbor.Contracts.Memory.Intent
  alias Arbor.Memory
  alias Arbor.Security

  @moduletag :fast
  @moduletag :integration
  @moduletag :security_regression

  defmodule ObservingAuthorizer do
    alias Arbor.Security

    def authorize(agent_id, resource, action, opts) do
      result = Security.authorize(agent_id, resource, action, opts)
      observer = Application.fetch_env!(:arbor_agent, :action_catalog_test_observer)
      send(observer, {:executor_authorized, agent_id, resource, result})
      result
    end
  end

  defmodule EmptyCatalog do
    def name_to_module(_name), do: {:error, :unknown_action}
  end

  defmodule LocalEmbedding do
    alias Arbor.Contracts.Persistence.VectorRecord

    def embed(_content) do
      {:ok,
       %{
         embedding: List.duplicate(0.5, VectorRecord.dimensions()),
         dimensions: VectorRecord.dimensions(),
         provider: "fixture",
         model: "executor-catalog"
       }}
    end
  end

  setup do
    settings = [
      actions_module: Actions,
      executor_authorizer: ObservingAuthorizer,
      action_catalog_test_observer: self()
    ]

    previous =
      Map.new(settings, fn {key, _value} -> {key, Application.fetch_env(:arbor_agent, key)} end)

    for {key, value} <- settings, do: Application.put_env(:arbor_agent, key, value)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, original} -> Application.put_env(:arbor_agent, key, original)
          :error -> Application.delete_env(:arbor_agent, key)
        end
      end
    end)

    :ok
  end

  test "existing public Actions catalog owns MemoryReview aliases and capability resources" do
    for {names, module, uri} <- action_cases(), name <- names do
      assert {:ok, ^module} = Actions.name_to_module(to_string(name))
      assert Actions.canonical_uri_for(module, %{}) == uri
    end
  end

  test "security regression: Agent resolution follows the existing public catalog" do
    for {names, module, _uri} <- action_cases(), name <- names do
      assert {:ok, ^module} = ActionDispatch.resolve_action_module(name)

      assert ActionDispatch.canonical_action_name(name) ==
               {:ok, ActionDispatch.module_to_dotted_name(module)}
    end
  end

  test "public Executor lists real proposal IDs for tool names and canonical aliases" do
    agent_id = init_agent()
    grant(agent_id, "arbor://memory/read")
    proposal = propose(agent_id, "Use explicit evidence when reviewing a suggestion")
    start_executor(agent_id)

    for name <- review_names() do
      percept = execute(agent_id, name)
      assert_authorized(agent_id, "arbor://memory/read")
      assert percept.outcome == :success
      assert %{"suggestions" => [suggestion], "count" => 1} = percept.data
      assert suggestion["id"] == proposal.id
      assert suggestion["content"] == proposal.content
      assert {:ok, %{status: :pending}} = Memory.get_proposal(agent_id, proposal.id)
    end
  end

  test "public Executor accepts listed IDs through the actual MemoryReview action" do
    for name <- accept_names() do
      # Isolate aliases from graph-level text dedup after the previous accept.
      # The atom and string tool name intentionally interpolate identically.
      agent_id = init_agent()
      grant(agent_id, "arbor://memory/read")
      grant(agent_id, "arbor://memory/write")
      start_executor(agent_id)
      proposal = propose(agent_id, "Accepted through #{name}")
      review = execute(agent_id, :memory_review_suggestions)
      assert_authorized(agent_id, "arbor://memory/read")
      assert %{"suggestions" => [%{"id" => id}]} = review.data
      assert id == proposal.id

      percept = execute(agent_id, name, %{suggestion_id: id})
      assert_authorized(agent_id, "arbor://memory/write")
      assert percept.outcome == :success
      assert %{"suggestion_id" => ^id, "node_id" => node_id, "accepted" => true} = percept.data
      assert {:ok, %{status: :accepted}} = Memory.get_proposal(agent_id, id)
      assert {:ok, graph} = Memory.export_knowledge_graph(agent_id)
      assert %{content: content, type: :insight} = Map.fetch!(graph.nodes, node_id)
      assert content == proposal.content
    end
  end

  test "security regression: a foreign ID and params cannot redirect the Executor principal" do
    agent_id = init_agent()
    foreign_id = init_agent()
    grant(agent_id, "arbor://memory/read")
    grant(agent_id, "arbor://memory/write")
    own = propose(agent_id, "The executor's own suggestion")
    foreign = propose(foreign_id, "Another agent's suggestion")
    assert {:ok, before_graph} = Memory.export_knowledge_graph(agent_id)
    assert {:ok, foreign_graph} = Memory.export_knowledge_graph(foreign_id)
    start_executor(agent_id)

    review = execute(agent_id, "memory_review.review_suggestions", %{agent_id: foreign_id})
    assert_authorized(agent_id, "arbor://memory/read")
    assert %{"suggestions" => [%{"id" => own_id}], "count" => 1} = review.data
    assert own_id == own.id

    for action <- [:memory_accept_suggestion, "memory_review.reject_suggestion"],
        id <- [foreign.id, "prop_missing_catalog_fixture"] do
      percept = execute(agent_id, action, %{suggestion_id: id, agent_id: foreign_id})
      assert_authorized(agent_id, "arbor://memory/write")
      assert percept.outcome == :failure
      assert percept.error == "not_found"
    end

    assert {:ok, %{status: :pending}} = Memory.get_proposal(agent_id, own.id)
    assert {:ok, %{status: :pending}} = Memory.get_proposal(foreign_id, foreign.id)
    assert {:ok, ^before_graph} = Memory.export_knowledge_graph(agent_id)
    assert {:ok, ^foreign_graph} = Memory.export_knowledge_graph(foreign_id)
  end

  test "public Executor rejects listed IDs without adding knowledge" do
    agent_id = init_agent()
    grant(agent_id, "arbor://memory/read")
    grant(agent_id, "arbor://memory/write")
    start_executor(agent_id)
    assert {:ok, before_graph} = Memory.export_knowledge_graph(agent_id)

    for name <- [:memory_reject_suggestion, "memory_review.reject_suggestion"] do
      proposal = propose(agent_id, "Rejected through #{name}")
      review = execute(agent_id, :memory_review_suggestions)
      assert_authorized(agent_id, "arbor://memory/read")
      assert %{"suggestions" => [%{"id" => id}]} = review.data
      assert id == proposal.id

      percept = execute(agent_id, name, %{suggestion_id: id})
      assert_authorized(agent_id, "arbor://memory/write")
      assert percept.outcome == :success
      assert %{"suggestion_id" => ^id, "rejected" => true} = percept.data
      assert {:ok, %{status: :rejected}} = Memory.get_proposal(agent_id, id)
      assert {:ok, ^before_graph} = Memory.export_knowledge_graph(agent_id)
    end
  end

  test "security regression: revocation blocks acceptance at the actual memory-write resource" do
    agent_id = init_agent()
    grant(agent_id, "arbor://memory/read")
    write_cap = grant(agent_id, "arbor://memory/write")
    proposal = propose(agent_id, "A revoked writer must leave this pending")
    start_executor(agent_id)

    assert %{outcome: :success, data: %{"suggestions" => [%{"id" => id}]}} =
             execute(agent_id, :memory_review_suggestions)

    assert_authorized(agent_id, "arbor://memory/read")
    assert id == proposal.id
    assert :ok = Security.revoke(write_cap.id)
    assert {:ok, before_graph} = Memory.export_knowledge_graph(agent_id)

    percept = execute(agent_id, :memory_accept_suggestion, %{suggestion_id: id})
    assert_receive {:executor_authorized, ^agent_id, "arbor://memory/write", {:error, _}}
    assert percept.outcome == :blocked
    assert {:ok, %{status: :pending}} = Memory.get_proposal(agent_id, id)
    assert {:ok, ^before_graph} = Memory.export_knowledge_graph(agent_id)
  end

  test "security regression: catalog dispatch retains the Actions private-write and capability gates" do
    agent_id = init_agent()
    read_cap = grant(agent_id, "arbor://memory/read")
    grant(agent_id, "arbor://memory/write")
    proposal = propose(agent_id, "Catalog lookup does not authorize a private write")
    context = %{memory_write_policy: :deny}

    assert {:ok, %{suggestions: [%{id: id}]}} =
             ActionDispatch.dispatch(:memory_review_suggestions, %{}, agent_id, context)

    assert id == proposal.id

    assert {:error, :private_turn_memory_write_denied} =
             ActionDispatch.dispatch(
               :memory_accept_suggestion,
               %{suggestion_id: id, memory_write_policy: nil},
               agent_id,
               context
             )

    assert :ok = Security.revoke(read_cap.id)

    assert {:error, {:unauthorized, :memory_review_suggestions}} =
             ActionDispatch.dispatch(:memory_review_suggestions, %{}, agent_id, context)

    assert {:ok, %{status: :pending}} = Memory.get_proposal(agent_id, id)
  end

  test "legacy convention fallback and inline proposal status remain available" do
    Application.put_env(:arbor_agent, :actions_module, EmptyCatalog)
    assert {:ok, Arbor.Actions.File.Read} = ActionDispatch.resolve_action_module(:file_read)
    assert {:ok, "proposal.status"} = ActionDispatch.canonical_action_name(:proposal_status)
    assert {:error, :missing_proposal_id} = ActionDispatch.dispatch(:proposal_status, %{})
    assert :error = ActionDispatch.resolve_action_module("catalog_fixture_unknown_action")
  end

  defp action_cases do
    [
      {review_names(), ReviewSuggestions, "arbor://memory/read"},
      {accept_names(), AcceptSuggestion, "arbor://memory/write"},
      {[:memory_review_queue, "memory_review.review_queue"], ReviewQueue, "arbor://memory/write"},
      {[:memory_reject_suggestion, "memory_review.reject_suggestion"], RejectSuggestion,
       "arbor://memory/write"}
    ]
  end

  defp review_names do
    [
      :memory_review_suggestions,
      "memory_review_suggestions",
      "memory_review.review_suggestions",
      "memory_review_review_suggestions"
    ]
  end

  defp accept_names do
    [
      :memory_accept_suggestion,
      "memory_accept_suggestion",
      "memory_review.accept_suggestion"
    ]
  end

  defp init_agent do
    agent_id = "agent_executor_catalog_#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             Memory.init_for_agent(agent_id,
               embedding_provider: LocalEmbedding,
               auto_embed: false
             )

    assert is_pid(pid)
    on_exit(fn -> assert :ok = Memory.cleanup_for_agent(agent_id) end)
    agent_id
  end

  defp grant(agent_id, resource) do
    assert {:ok, capability} = Security.grant(principal: agent_id, resource: resource)
    on_exit(fn -> Security.revoke(capability.id) end)
    capability
  end

  defp propose(agent_id, content) do
    assert {:ok, %{status: :pending} = proposal} =
             Memory.create_proposal(agent_id, :insight, %{content: content, confidence: 0.7})

    proposal
  end

  defp start_executor(agent_id) do
    assert {:ok, _pid} = Executor.start(agent_id)
    on_exit(fn -> assert :ok = Executor.stop(agent_id) end)
  end

  defp execute(agent_id, action, params \\ %{}) do
    intent = Intent.new(:act, action: action, params: params)
    assert :ok = Executor.execute(agent_id, intent)
    # Same-sender GenServer ordering waits for the real synchronous dispatch.
    assert {:ok, _status} = Executor.status(agent_id)
    assert {:ok, percept} = Memory.get_percept_for_intent(agent_id, intent.id)
    percept
  end

  defp assert_authorized(agent_id, resource) do
    assert_receive {:executor_authorized, ^agent_id, ^resource, {:ok, :authorized}}
  end
end
