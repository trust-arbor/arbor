defmodule Arbor.Consensus.CoordinatorQuorumSecurityRegressionTest do
  @moduledoc """
  Security regression for correlated-monitor quorum weakening
  (arxiv.org/abs/2610.29178, Exposure Check group P).

  A topic rule of `:unanimous` for a 5-seat council must require 5 votes.
  Silently capping that rule to simple majority (3 of 5) lets a correlated
  subset bind a decision the topic forbade.
  """

  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Consensus.{Coordinator, TopicRegistry, TopicRule}
  alias Arbor.Consensus.TestHelpers
  alias Arbor.Contracts.Consensus.{Evaluation, Proposal}

  defmodule FiveSeatUnanimousBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Consensus.Evaluator

    @impl Arbor.Contracts.Consensus.Evaluator
    def name, do: :five_seat_unanimous

    @impl Arbor.Contracts.Consensus.Evaluator
    def perspectives, do: [:security, :stability, :capability, :adversarial, :resource]

    @impl Arbor.Contracts.Consensus.Evaluator
    def strategy, do: :deterministic

    @impl Arbor.Contracts.Consensus.Evaluator
    def evaluate(proposal, perspective, opts) do
      vote =
        if perspective in [:security, :stability, :capability], do: :approve, else: :reject

      evaluator_id = Keyword.get(opts, :evaluator_id, "eval_#{perspective}_five_seat")

      {:ok, eval} =
        Evaluation.new(%{
          proposal_id: proposal.id,
          evaluator_id: evaluator_id,
          perspective: perspective,
          vote: vote,
          reasoning: "Five-seat unanimous security-regression vote",
          confidence: 0.9,
          risk_score: 0.2,
          benefit_score: 0.7
        })

      {:ok, Evaluation.seal(eval)}
    end
  end

  defmodule FiveSeatApproveAllBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Consensus.Evaluator

    @impl Arbor.Contracts.Consensus.Evaluator
    def name, do: :five_seat_approve_all

    @impl Arbor.Contracts.Consensus.Evaluator
    def perspectives, do: [:security, :stability, :capability, :adversarial, :resource]

    @impl Arbor.Contracts.Consensus.Evaluator
    def strategy, do: :deterministic

    @impl Arbor.Contracts.Consensus.Evaluator
    def evaluate(proposal, perspective, opts) do
      evaluator_id = Keyword.get(opts, :evaluator_id, "eval_#{perspective}_five_seat_all")

      {:ok, eval} =
        Evaluation.new(%{
          proposal_id: proposal.id,
          evaluator_id: evaluator_id,
          perspective: perspective,
          vote: :approve,
          reasoning: "Five-seat unanimous all-approve security-regression vote",
          confidence: 0.9,
          risk_score: 0.1,
          benefit_score: 0.9
        })

      {:ok, Evaluation.seal(eval)}
    end
  end

  defp register_unanimous_topic! do
    topic = :"unanimous_five_seat_#{System.unique_integer([:positive])}"

    {:ok, _rule} =
      TopicRegistry.register_topic(%TopicRule{
        topic: topic,
        min_quorum: :unanimous,
        required_evaluators: [],
        match_patterns: [Atom.to_string(topic)],
        allowed_modes: [:decision]
      })

    on_exit(fn ->
      try do
        TopicRegistry.retire_topic(topic)
      catch
        :exit, _ -> :ok
      end
    end)

    topic
  end

  defp start_coord(backend) do
    {_es_pid, _es_name} = TestHelpers.start_test_event_store()

    {_pid, coord} =
      TestHelpers.start_test_coordinator(
        evaluator_backend: backend,
        config: [evaluation_timeout_ms: 5_000]
      )

    coord
  end

  test "security regression: a unanimous rule with 5 seats needs 5 votes, not 3" do
    topic = register_unanimous_topic!()
    coord = start_coord(FiveSeatUnanimousBackend)

    {:ok, proposal} =
      Proposal.new(%{
        proposer: "agent_quorum_regression",
        topic: topic,
        description: "Unanimous five-seat quorum must not collapse to majority",
        target_layer: 4,
        context: %{new_code: "defmodule QuorumRegression do\nend"}
      })

    {:ok, proposal_id} = Coordinator.submit(proposal, server: coord)
    assert {:ok, status} = TestHelpers.wait_for_decision(coord, proposal_id)
    {:ok, decision} = Coordinator.get_decision(proposal_id, coord)

    assert decision.required_quorum == 5
    refute decision.required_quorum == 3
    assert decision.approve_count == 3
    assert decision.reject_count == 2
    assert status == :deadlock
    assert decision.decision == :deadlock
    refute decision.quorum_met
  end

  test "security regression: five matching votes satisfy the unanimous five-seat rule" do
    topic = register_unanimous_topic!()
    coord = start_coord(FiveSeatApproveAllBackend)

    {:ok, proposal} =
      Proposal.new(%{
        proposer: "agent_quorum_regression_all",
        topic: topic,
        description: "Unanimous five-seat quorum is met only by five votes",
        target_layer: 4,
        context: %{new_code: "defmodule QuorumRegressionAll do\nend"}
      })

    {:ok, proposal_id} = Coordinator.submit(proposal, server: coord)
    assert {:ok, :approved} = TestHelpers.wait_for_decision(coord, proposal_id)
    {:ok, decision} = Coordinator.get_decision(proposal_id, coord)

    assert decision.required_quorum == 5
    assert decision.approve_count == 5
    assert decision.decision == :approved
    assert decision.quorum_met
  end
end
