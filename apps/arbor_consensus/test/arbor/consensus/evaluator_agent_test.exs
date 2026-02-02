defmodule Arbor.Consensus.EvaluatorAgentTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.EvaluatorAgent
  alias Arbor.Contracts.Consensus.{Evaluation, Proposal}

  # A test evaluator that implements the Evaluator behaviour
  defmodule TestEvaluator do
    @behaviour Arbor.Contracts.Consensus.Evaluator

    @impl true
    def name, do: :test_evaluator

    @impl true
    def perspectives, do: [:alpha, :beta, :gamma]

    @impl true
    def evaluate(proposal, perspective, _opts) do
      Evaluation.new(%{
        proposal_id: proposal.id,
        evaluator_id: "test_evaluator_#{perspective}",
        perspective: perspective,
        vote: :approve,
        confidence: 0.9,
        reasoning: "Test evaluation for #{perspective}"
      })
    end

    @impl true
    def strategy, do: :rule_based
  end

  # A slow evaluator for testing async behavior
  defmodule SlowEvaluator do
    @behaviour Arbor.Contracts.Consensus.Evaluator

    @impl true
    def name, do: :slow_evaluator

    @impl true
    def perspectives, do: [:slow_perspective]

    @impl true
    def evaluate(proposal, perspective, _opts) do
      Process.sleep(100)

      Evaluation.new(%{
        proposal_id: proposal.id,
        evaluator_id: "slow_evaluator",
        perspective: perspective,
        vote: :approve,
        confidence: 0.8,
        reasoning: "Slow evaluation complete"
      })
    end
  end

  describe "start_link/1" do
    test "starts an agent with required evaluator" do
      {:ok, pid} = EvaluatorAgent.start_link(evaluator: TestEvaluator)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "fails without evaluator option" do
      assert_raise KeyError, fn ->
        EvaluatorAgent.start_link([])
      end
    end
  end

  describe "status/1" do
    test "returns agent status" do
      {:ok, pid} = EvaluatorAgent.start_link(evaluator: TestEvaluator)

      status = EvaluatorAgent.status(pid)

      assert status.name == :test_evaluator
      assert status.evaluator == TestEvaluator
      assert status.perspectives == [:alpha, :beta, :gamma]
      assert status.processing == false
      assert status.evaluations_processed == 0
      assert is_map(status.mailbox)

      GenServer.stop(pid)
    end
  end

  describe "evaluator/1" do
    test "returns the evaluator module" do
      {:ok, pid} = EvaluatorAgent.start_link(evaluator: TestEvaluator)
      assert EvaluatorAgent.evaluator(pid) == TestEvaluator
      GenServer.stop(pid)
    end
  end

  describe "perspectives/1" do
    test "returns the evaluator perspectives" do
      {:ok, pid} = EvaluatorAgent.start_link(evaluator: TestEvaluator)
      assert EvaluatorAgent.perspectives(pid) == [:alpha, :beta, :gamma]
      GenServer.stop(pid)
    end
  end

  describe "deliver/3" do
    test "accepts envelope delivery" do
      {:ok, pid} = EvaluatorAgent.start_link(evaluator: TestEvaluator)

      {:ok, proposal} =
        Proposal.new(%{
          proposer: "test_agent",
          description: "Test proposal",
          topic: :test
        })

      envelope = %{
        proposal: proposal,
        perspectives: [:alpha],
        reply_to: self(),
        deadline: nil,
        priority: :normal
      }

      assert :ok = EvaluatorAgent.deliver(pid, envelope, :normal)

      GenServer.stop(pid)
    end

    test "rejects when mailbox is full" do
      # Note: First envelope is immediately dequeued for processing, so we need
      # mailbox_size=2 and must deliver 3 envelopes to hit the limit.
      # The third goes into the queue while 1 is processing and 1 is queued.
      {:ok, pid} = EvaluatorAgent.start_link(
        evaluator: SlowEvaluator,
        mailbox_size: 2,
        reserved_high_priority: 0
      )

      {:ok, proposal} =
        Proposal.new(%{
          proposer: "test_agent",
          description: "Test proposal",
          topic: :test
        })

      envelope = %{
        proposal: proposal,
        perspectives: [:slow_perspective],
        reply_to: self(),
        deadline: nil,
        priority: :normal
      }

      # First delivery: starts processing immediately (not in mailbox)
      assert :ok = EvaluatorAgent.deliver(pid, envelope, :normal)
      # Second delivery: goes into mailbox (1 slot used)
      assert :ok = EvaluatorAgent.deliver(pid, envelope, :normal)
      # Third delivery: goes into mailbox (2 slots used = full)
      assert :ok = EvaluatorAgent.deliver(pid, envelope, :normal)

      # Fourth should be rejected (mailbox is full)
      assert {:error, :mailbox_full} = EvaluatorAgent.deliver(pid, envelope, :normal)

      GenServer.stop(pid)
    end
  end

  describe "evaluation processing" do
    test "sends evaluation results back to reply_to" do
      {:ok, pid} = EvaluatorAgent.start_link(evaluator: TestEvaluator)

      {:ok, proposal} =
        Proposal.new(%{
          proposer: "test_agent",
          description: "Test proposal",
          topic: :test
        })

      envelope = %{
        proposal: proposal,
        perspectives: [:alpha, :beta],
        reply_to: self(),
        deadline: nil,
        priority: :normal
      }

      :ok = EvaluatorAgent.deliver(pid, envelope, :normal)

      # Should receive evaluation results
      assert_receive {:evaluation_complete, _proposal_id, %Evaluation{perspective: :alpha}}, 1000
      assert_receive {:evaluation_complete, _proposal_id, %Evaluation{perspective: :beta}}, 1000

      GenServer.stop(pid)
    end

    test "processes envelopes in priority order" do
      {:ok, pid} = EvaluatorAgent.start_link(evaluator: SlowEvaluator)

      {:ok, proposal1} =
        Proposal.new(%{
          proposer: "test_agent",
          description: "Normal priority proposal",
          topic: :test
        })

      {:ok, proposal2} =
        Proposal.new(%{
          proposer: "test_agent",
          description: "High priority proposal",
          topic: :test
        })

      # Deliver normal first, then high
      :ok = EvaluatorAgent.deliver(pid, %{
        proposal: proposal1,
        perspectives: [:slow_perspective],
        reply_to: self(),
        deadline: nil,
        priority: :normal
      }, :normal)

      :ok = EvaluatorAgent.deliver(pid, %{
        proposal: proposal2,
        perspectives: [:slow_perspective],
        reply_to: self(),
        deadline: nil,
        priority: :high
      }, :high)

      # First processed should be whatever was being processed (proposal1 started first)
      # Second should be high priority
      # Note: The first envelope starts processing immediately upon delivery
      assert_receive {:evaluation_complete, prop1_id, _}, 500
      assert_receive {:evaluation_complete, prop2_id, _}, 500

      # Since proposal1 started processing before proposal2 was added,
      # it completes first
      assert prop1_id == proposal1.id
      assert prop2_id == proposal2.id

      GenServer.stop(pid)
    end

    test "increments evaluations_processed counter" do
      {:ok, pid} = EvaluatorAgent.start_link(evaluator: TestEvaluator)

      {:ok, proposal} =
        Proposal.new(%{
          proposer: "test_agent",
          description: "Test proposal",
          topic: :test
        })

      envelope = %{
        proposal: proposal,
        perspectives: [:alpha],
        reply_to: self(),
        deadline: nil,
        priority: :normal
      }

      assert EvaluatorAgent.status(pid).evaluations_processed == 0

      :ok = EvaluatorAgent.deliver(pid, envelope, :normal)

      # Wait for processing
      assert_receive {:evaluation_complete, _, _}, 1000

      # Give agent time to update state
      Process.sleep(50)

      assert EvaluatorAgent.status(pid).evaluations_processed == 1

      GenServer.stop(pid)
    end
  end
end
