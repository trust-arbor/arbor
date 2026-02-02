defmodule Arbor.Consensus.EvaluatorAgentMemoryTest do
  use ExUnit.Case, async: false

  alias Arbor.Consensus.EvaluatorAgent

  require Logger

  # ============================================================================
  # Test Memory Adapter using ETS for cross-process communication
  # ============================================================================

  defmodule TestMemoryAdapter do
    @moduledoc false
    @behaviour EvaluatorAgent.MemoryAdapter

    def setup_table do
      try do
        :ets.new(:memory_test_table, [:named_table, :public, :set])
      rescue
        ArgumentError -> :ets.delete_all_objects(:memory_test_table)
      end

      :ets.insert(:memory_test_table, {:recall_response, []})
      :ets.insert(:memory_test_table, {:recall_calls, []})
      :ets.insert(:memory_test_table, {:store_calls, []})
    end

    def set_recall_response(memories) do
      :ets.insert(:memory_test_table, {:recall_response, memories})
    end

    def get_recall_calls do
      case :ets.lookup(:memory_test_table, :recall_calls) do
        [{_, calls}] -> calls
        [] -> []
      end
    end

    def get_store_calls do
      case :ets.lookup(:memory_test_table, :store_calls) do
        [{_, calls}] -> calls
        [] -> []
      end
    end

    @impl true
    def recall(agent_id, query, opts) do
      # Record the call
      existing = get_recall_calls()
      :ets.insert(:memory_test_table, {:recall_calls, [{agent_id, query, opts} | existing]})

      # Return configured response
      case :ets.lookup(:memory_test_table, :recall_response) do
        [{_, memories}] -> {:ok, memories}
        [] -> {:ok, []}
      end
    end

    @impl true
    def store(agent_id, content, metadata) do
      # Record the call
      existing = get_store_calls()
      :ets.insert(:memory_test_table, {:store_calls, [{agent_id, content, metadata} | existing]})
      {:ok, "mem_#{System.unique_integer([:positive])}"}
    end
  end

  defmodule ErrorMemoryAdapter do
    @moduledoc false
    @behaviour EvaluatorAgent.MemoryAdapter

    @impl true
    def recall(_agent_id, _query, _opts) do
      {:error, :storage_unavailable}
    end

    @impl true
    def store(_agent_id, _content, _metadata) do
      {:error, :storage_unavailable}
    end
  end

  defmodule CrashingMemoryAdapter do
    @moduledoc false
    @behaviour EvaluatorAgent.MemoryAdapter

    @impl true
    def recall(_agent_id, _query, _opts) do
      raise "Memory system crashed!"
    end

    @impl true
    def store(_agent_id, _content, _metadata) do
      raise "Memory system crashed!"
    end
  end

  # ============================================================================
  # Test Evaluator
  # ============================================================================

  defmodule MemoryAwareEvaluator do
    @moduledoc false
    @behaviour Arbor.Contracts.Consensus.Evaluator

    @impl true
    def name, do: :memory_test_evaluator

    @impl true
    def perspectives, do: [:test_perspective]

    @impl true
    def evaluate(proposal, perspective, opts) do
      # Record that opts were passed (for memory_context verification)
      try do
        existing = :ets.lookup(:memory_test_table, :evaluate_opts)

        prev =
          case existing do
            [{_, list}] -> list
            [] -> []
          end

        :ets.insert(:memory_test_table, {:evaluate_opts, [{proposal.id, opts} | prev]})
      rescue
        ArgumentError -> :ok
      end

      evaluation = %Arbor.Contracts.Consensus.Evaluation{
        id: "eval_#{System.unique_integer([:positive])}",
        proposal_id: proposal.id,
        evaluator_id: "memory_test_evaluator",
        perspective: perspective,
        vote: :approve,
        confidence: 0.9,
        reasoning: "Test approval",
        risk_score: 0.1,
        benefit_score: 0.8,
        concerns: [],
        recommendations: [],
        created_at: DateTime.utc_now(),
        sealed: true
      }

      {:ok, evaluation}
    end
  end

  # ============================================================================
  # Test helpers
  # ============================================================================

  setup do
    TestMemoryAdapter.setup_table()
    :ok
  end

  defp build_test_proposal(overrides \\ %{}) do
    defaults = %{
      id: "prop_#{System.unique_integer([:positive])}",
      proposer: "test_agent",
      topic: :code_modification,
      mode: :decision,
      description: "Test proposal for memory integration",
      target_layer: 4,
      context: %{},
      metadata: %{},
      status: :evaluating,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    struct!(Arbor.Contracts.Consensus.Proposal, Map.merge(defaults, overrides))
  end

  defp build_envelope(proposal, opts \\ []) do
    %{
      proposal: proposal,
      perspectives: Keyword.get(opts, :perspectives, [:test_perspective]),
      reply_to: Keyword.get(opts, :reply_to, self()),
      deadline: Keyword.get(opts, :deadline, nil),
      priority: Keyword.get(opts, :priority, :normal)
    }
  end

  defp get_evaluate_opts do
    case :ets.lookup(:memory_test_table, :evaluate_opts) do
      [{_, list}] -> list
      [] -> []
    end
  end

  # ============================================================================
  # Tests: Agent without memory adapter (backward compatibility)
  # ============================================================================

  describe "without memory adapter" do
    test "agent starts and processes normally" do
      {:ok, pid} = EvaluatorAgent.start_link(evaluator: MemoryAwareEvaluator)

      proposal = build_test_proposal()
      envelope = build_envelope(proposal)

      assert :ok = EvaluatorAgent.deliver(pid, envelope)

      assert_receive {:evaluation_complete, _, _evaluation}, 5_000

      status = EvaluatorAgent.status(pid)
      assert status.memory_adapter == nil

      GenServer.stop(pid)
    end

    test "evaluator receives empty opts when no memory adapter" do
      {:ok, pid} = EvaluatorAgent.start_link(evaluator: MemoryAwareEvaluator)

      proposal = build_test_proposal()
      envelope = build_envelope(proposal)

      EvaluatorAgent.deliver(pid, envelope)

      assert_receive {:evaluation_complete, _, _}, 5_000

      # Check what opts were passed to evaluate
      opts_log = get_evaluate_opts()
      assert opts_log != []
      {_id, opts} = hd(opts_log)
      assert opts == []

      GenServer.stop(pid)
    end
  end

  # ============================================================================
  # Tests: Agent with memory adapter
  # ============================================================================

  describe "with memory adapter" do
    test "status includes memory adapter" do
      {:ok, pid} =
        EvaluatorAgent.start_link(
          evaluator: MemoryAwareEvaluator,
          memory_adapter: TestMemoryAdapter
        )

      status = EvaluatorAgent.status(pid)
      assert status.memory_adapter == TestMemoryAdapter

      GenServer.stop(pid)
    end

    test "recall is called before evaluation" do
      {:ok, pid} =
        EvaluatorAgent.start_link(
          evaluator: MemoryAwareEvaluator,
          memory_adapter: TestMemoryAdapter
        )

      proposal = build_test_proposal(%{description: "Test security assessment"})
      envelope = build_envelope(proposal)

      EvaluatorAgent.deliver(pid, envelope)

      assert_receive {:evaluation_complete, _, _}, 5_000

      # Check recall was called via ETS
      recall_calls = TestMemoryAdapter.get_recall_calls()
      assert recall_calls != []
      {_agent_id, query, _opts} = hd(recall_calls)
      assert query == "Test security assessment"

      GenServer.stop(pid)
    end

    test "memory context is passed to evaluator when memories exist" do
      TestMemoryAdapter.set_recall_response([
        %{content: "Previous proposal about security", metadata: %{}}
      ])

      {:ok, pid} =
        EvaluatorAgent.start_link(
          evaluator: MemoryAwareEvaluator,
          memory_adapter: TestMemoryAdapter
        )

      proposal = build_test_proposal()
      envelope = build_envelope(proposal)

      EvaluatorAgent.deliver(pid, envelope)

      assert_receive {:evaluation_complete, _, _}, 5_000

      # Check that evaluate was called with memory_context in opts
      opts_log = get_evaluate_opts()
      assert opts_log != []
      {_id, opts} = hd(opts_log)
      assert Keyword.has_key?(opts, :memory_context)
      memories = Keyword.get(opts, :memory_context)
      assert length(memories) == 1

      GenServer.stop(pid)
    end

    test "store is called after evaluation" do
      {:ok, pid} =
        EvaluatorAgent.start_link(
          evaluator: MemoryAwareEvaluator,
          memory_adapter: TestMemoryAdapter
        )

      proposal = build_test_proposal(%{description: "Important security update"})
      envelope = build_envelope(proposal)

      EvaluatorAgent.deliver(pid, envelope)

      assert_receive {:evaluation_complete, _, _}, 5_000

      # Store is called asynchronously — wait a bit
      Process.sleep(200)

      store_calls = TestMemoryAdapter.get_store_calls()
      assert store_calls != []
      {_agent_id, content, metadata} = hd(store_calls)
      assert content =~ "Important security update"
      assert metadata.type == "evaluation_outcome"

      GenServer.stop(pid)
    end

    test "handles memory recall errors gracefully" do
      {:ok, pid} =
        EvaluatorAgent.start_link(
          evaluator: MemoryAwareEvaluator,
          memory_adapter: ErrorMemoryAdapter
        )

      proposal = build_test_proposal()
      envelope = build_envelope(proposal)

      assert :ok = EvaluatorAgent.deliver(pid, envelope)

      # Should still complete evaluation despite memory error
      assert_receive {:evaluation_complete, _, _evaluation}, 5_000

      GenServer.stop(pid)
    end

    test "handles memory recall crashes gracefully" do
      {:ok, pid} =
        EvaluatorAgent.start_link(
          evaluator: MemoryAwareEvaluator,
          memory_adapter: CrashingMemoryAdapter
        )

      proposal = build_test_proposal()
      envelope = build_envelope(proposal)

      assert :ok = EvaluatorAgent.deliver(pid, envelope)

      # Should still complete evaluation despite memory crash
      assert_receive {:evaluation_complete, _, _evaluation}, 5_000

      GenServer.stop(pid)
    end
  end

  # ============================================================================
  # Tests: MemoryAdapter behaviour
  # ============================================================================

  describe "MemoryAdapter behaviour" do
    test "TestMemoryAdapter implements the behaviour" do
      assert function_exported?(TestMemoryAdapter, :recall, 3)
      assert function_exported?(TestMemoryAdapter, :store, 3)
    end

    test "ErrorMemoryAdapter implements the behaviour" do
      assert function_exported?(ErrorMemoryAdapter, :recall, 3)
      assert function_exported?(ErrorMemoryAdapter, :store, 3)
    end
  end

  # ============================================================================
  # Tests: Multiple deliveries with memory
  # ============================================================================

  describe "multiple deliveries with memory" do
    test "agent processes multiple proposals sequentially" do
      {:ok, pid} =
        EvaluatorAgent.start_link(
          evaluator: MemoryAwareEvaluator,
          memory_adapter: TestMemoryAdapter
        )

      p1 = build_test_proposal(%{description: "First proposal"})
      p2 = build_test_proposal(%{description: "Second proposal"})

      EvaluatorAgent.deliver(pid, build_envelope(p1))
      EvaluatorAgent.deliver(pid, build_envelope(p2))

      assert_receive {:evaluation_complete, _, _}, 5_000
      assert_receive {:evaluation_complete, _, _}, 5_000

      status = EvaluatorAgent.status(pid)
      assert status.evaluations_processed == 2

      GenServer.stop(pid)
    end
  end
end
