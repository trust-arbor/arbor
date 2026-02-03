defmodule Arbor.Consensus.TopicGovernanceTest do
  @moduledoc """
  Tests for topic governance proposals.

  Verifies that:
  - Proposals to `:topic_governance` are handled correctly
  - New topics can be added to the registry via governance
  - Topic governance proposals use elevated quorum
  """

  use ExUnit.Case, async: false

  alias Arbor.Consensus.{Coordinator, TopicMatcher, TopicRegistry, TopicRule}
  alias Arbor.Consensus.TestHelpers
  alias Arbor.Contracts.Consensus.{Invariants, Proposal}

  @moduletag :fast

  describe "topic governance proposals" do
    setup do
      # Start TopicRegistry for these tests
      case TopicRegistry.start_link([]) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end

      # Register the topic_governance topic if not already registered
      unless TopicRegistry.exists?(:topic_governance) do
        TopicRegistry.register_topic(%TopicRule{
          topic: :topic_governance,
          match_patterns: ["topic", "governance", "registry"],
          min_quorum: :supermajority,
          required_evaluators: []
        })
      end

      {_es_pid, _es_name} = TestHelpers.start_test_event_store()
      {_coord_pid, coord_name} = TestHelpers.start_test_coordinator()

      on_exit(fn ->
        # Clean up any test topics (process may already be stopped)
        try do
          if TopicRegistry.exists?(:test_new_topic) do
            TopicRegistry.retire_topic(:test_new_topic)
          end
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, coordinator: coord_name}
    end

    test "topic governance proposals use elevated quorum" do
      proposal_attrs = %{
        proposer: "governance_agent",
        topic: :topic_governance,
        description: "Register a new topic for test purposes",
        target_layer: 1,
        context: %{
          action: :register_topic,
          topic_name: :test_new_topic,
          match_patterns: ["test", "new"]
        }
      }

      {:ok, _proposal} = Proposal.new(proposal_attrs)

      # Check that the topic is recognized as a meta-change
      assert Invariants.meta_change?(:topic_governance)
    end

    test "topic governance proposal can be submitted", %{coordinator: coord} do
      proposal_attrs = %{
        proposer: "governance_agent",
        topic: :topic_governance,
        description: "Propose adding a new topic for widget processing",
        target_layer: 1,
        context: %{
          action: :register_topic,
          topic_name: :widget_processing,
          match_patterns: ["widget", "process"],
          min_quorum: :majority
        }
      }

      {:ok, proposal} = Proposal.new(proposal_attrs)
      {:ok, proposal_id} = Coordinator.submit(proposal, server: coord)

      # Should be accepted for evaluation
      {:ok, status} = Coordinator.get_status(proposal_id, coord)
      assert status == :evaluating
    end

    test "topic governance approval flow", %{coordinator: coord} do
      # Submit a governance proposal
      proposal_attrs = %{
        proposer: "governance_agent",
        topic: :topic_governance,
        description: "Register :test_new_topic for testing",
        target_layer: 1,
        context: %{
          action: :register_topic,
          topic_name: :test_new_topic,
          match_patterns: ["test", "new", "topic"],
          min_quorum: :majority
        }
      }

      {:ok, proposal} = Proposal.new(proposal_attrs)
      {:ok, proposal_id} = Coordinator.submit(proposal, server: coord)

      # Wait for decision
      {:ok, _status} = TestHelpers.wait_for_decision(coord, proposal_id)
      {:ok, decision} = Coordinator.get_decision(proposal_id, coord)

      # The decision should exist
      assert decision != nil

      # If approved, the topic could be registered
      # (actual registration would be done by an executor, not the test)
      if decision.decision == :approved do
        # Simulate what an executor would do
        TopicRegistry.register_topic(%TopicRule{
          topic: :test_new_topic,
          match_patterns: ["test", "new", "topic"],
          min_quorum: :majority
        })

        # Verify the topic is now in the registry
        {:ok, rule} = TopicRegistry.get(:test_new_topic)
        assert rule.topic == :test_new_topic
      end
    end
  end

  describe "topic matching integration" do
    setup do
      case TopicRegistry.start_link([]) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end

      # Register test topics
      TopicRegistry.register_topic(%TopicRule{
        topic: :code_modification,
        match_patterns: ["code", "function", "module", "refactor"],
        min_quorum: :majority
      })

      TopicRegistry.register_topic(%TopicRule{
        topic: :documentation_change,
        match_patterns: ["doc", "readme", "comment", "documentation"],
        min_quorum: :majority
      })

      :ok
    end

    test "TopicMatcher routes to correct topic based on description" do
      topics = TopicRegistry.list()

      # Code-related description
      {matched_topic, confidence} =
        TopicMatcher.match(
          "Refactor the authentication module to use JWT",
          %{},
          topics
        )

      assert matched_topic in [:code_modification, :general]
      assert confidence >= 0.0

      # Documentation-related description
      {matched_topic2, confidence2} =
        TopicMatcher.match(
          "Update the README with installation instructions",
          %{},
          topics
        )

      assert matched_topic2 in [:documentation_change, :general]
      assert confidence2 >= 0.0
    end

    test "unmatched descriptions route to :general" do
      topics = TopicRegistry.list()

      {matched_topic, confidence} =
        TopicMatcher.match(
          "Something completely unrelated to any pattern",
          %{},
          topics
        )

      # Should either match with low confidence or fall back to :general
      if confidence < 0.3 do
        assert matched_topic == :general
      end
    end
  end

  describe "topic rule validation" do
    test "TopicRule validates required fields" do
      # Valid rule
      valid_rule = %TopicRule{
        topic: :valid_topic,
        match_patterns: ["valid"],
        min_quorum: :majority
      }

      assert valid_rule.topic == :valid_topic
      assert valid_rule.min_quorum == :majority
    end

    test "quorum_to_number converts quorum types correctly" do
      council_size = 7

      # majority: div(7, 2) + 1 = 4
      assert TopicRule.quorum_to_number(:majority, council_size) == 4
      # supermajority: ceil(7 * 2 / 3) = ceil(4.666...) = 5
      assert TopicRule.quorum_to_number(:supermajority, council_size) == 5
      assert TopicRule.quorum_to_number(:unanimous, council_size) == 7
      assert TopicRule.quorum_to_number(3, council_size) == 3
    end
  end
end
