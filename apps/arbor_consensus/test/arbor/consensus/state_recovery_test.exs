defmodule Arbor.Consensus.StateRecoveryTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.StateRecovery
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.ETS

  setup do
    # Create a unique ETS table for this test
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    table_name = :"test_recovery_#{System.unique_integer([:positive])}"
    {:ok, _pid} = ETS.start_link(name: table_name)

    %{table: table_name}
  end

  describe "rebuild_from_events/1" do
    test "returns empty state when no events", %{table: table} do
      {:ok, state} = StateRecovery.rebuild_from_events({ETS, name: table})

      assert state.proposals == %{}
      assert state.decisions == %{}
      assert state.interrupted == []
      assert state.events_replayed == 0
    end

    test "returns empty state when event_log is nil" do
      {:ok, state} = StateRecovery.rebuild_from_events(nil)

      assert state.proposals == %{}
      assert state.decisions == %{}
      assert state.interrupted == []
    end

    test "recovers proposal from ProposalSubmitted event", %{table: table} do
      # Emit a ProposalSubmitted event
      event = create_persistence_event("proposal.submitted", %{
        proposal_id: "prop_1",
        proposer: "agent_1",
        change_type: "code_modification",
        description: "Add caching",
        target_layer: 1,
        target_module: "Foo.Bar",
        metadata: %{}
      })

      {:ok, _} = ETS.append("arbor:consensus", event, name: table)

      # Rebuild state
      {:ok, state} = StateRecovery.rebuild_from_events({ETS, name: table})

      assert map_size(state.proposals) == 1
      assert state.proposals["prop_1"].status == :submitted
      assert state.proposals["prop_1"].proposer == "agent_1"
      assert state.events_replayed == 1
    end

    test "recovers evaluation in progress", %{table: table} do
      # Emit ProposalSubmitted
      {:ok, _} =
        ETS.append(
          "arbor:consensus",
          create_persistence_event("proposal.submitted", %{
            proposal_id: "prop_1",
            proposer: "agent_1",
            change_type: "code_modification",
            description: "Add caching"
          }),
          name: table
        )

      # Emit EvaluationStarted
      {:ok, _} =
        ETS.append(
          "arbor:consensus",
          create_persistence_event("evaluation.started", %{
            proposal_id: "prop_1",
            perspectives: ["security", "stability", "capability"],
            council_size: 3,
            required_quorum: 2
          }),
          name: table
        )

      {:ok, state} = StateRecovery.rebuild_from_events({ETS, name: table})

      assert state.proposals["prop_1"].status == :evaluating
      assert state.proposals["prop_1"].perspectives == ["security", "stability", "capability"]
      # Since no decision rendered, this is interrupted
      assert length(state.interrupted) == 1
      assert hd(state.interrupted).proposal_id == "prop_1"
    end

    test "recovers completed evaluations", %{table: table} do
      # Setup: submitted -> started -> 2 evaluations completed
      events = [
        create_persistence_event("proposal.submitted", %{
          proposal_id: "prop_1",
          proposer: "agent_1",
          change_type: "code_modification",
          description: "Add caching"
        }),
        create_persistence_event("evaluation.started", %{
          proposal_id: "prop_1",
          perspectives: ["security", "stability"],
          council_size: 2,
          required_quorum: 2
        }),
        create_persistence_event("evaluation.completed", %{
          proposal_id: "prop_1",
          evaluation_id: "eval_1",
          perspective: "security",
          vote: "approve",
          confidence: 0.9
        })
      ]

      for event <- events do
        {:ok, _} = ETS.append("arbor:consensus", event, name: table)
      end

      {:ok, state} = StateRecovery.rebuild_from_events({ETS, name: table})

      proposal = state.proposals["prop_1"]
      assert map_size(proposal.completed_evaluations) == 1
      assert Map.has_key?(proposal.completed_evaluations, :security)

      # Still interrupted since stability hasn't completed
      assert length(state.interrupted) == 1
      interrupted = hd(state.interrupted)
      # Perspectives may be atoms or strings depending on deserialization
      missing = Enum.map(interrupted.missing_perspectives, &to_string/1)
      completed = Enum.map(interrupted.completed_perspectives, &to_string/1)
      assert "stability" in missing
      refute "stability" in completed
    end

    test "recovers decision", %{table: table} do
      events = [
        create_persistence_event("proposal.submitted", %{
          proposal_id: "prop_1",
          proposer: "agent_1",
          change_type: "code_modification",
          description: "Add caching"
        }),
        create_persistence_event("decision.rendered", %{
          proposal_id: "prop_1",
          decision_id: "dec_1",
          decision: "approved",
          approve_count: 5,
          reject_count: 1,
          abstain_count: 1,
          required_quorum: 5,
          quorum_met: true,
          primary_concerns: [],
          average_confidence: 0.85
        })
      ]

      for event <- events do
        {:ok, _} = ETS.append("arbor:consensus", event, name: table)
      end

      {:ok, state} = StateRecovery.rebuild_from_events({ETS, name: table})

      assert state.proposals["prop_1"].status == :decided
      assert map_size(state.decisions) == 1
      assert state.decisions["prop_1"].decision == :approved
      assert state.interrupted == []
    end

    test "recovers deadlocked proposal", %{table: table} do
      events = [
        create_persistence_event("proposal.submitted", %{
          proposal_id: "prop_1",
          proposer: "agent_1",
          change_type: "code_modification",
          description: "Add caching"
        }),
        create_persistence_event("proposal.deadlocked", %{
          proposal_id: "prop_1",
          reason: "no_quorum",
          details: "Only 3/5 voted"
        })
      ]

      for event <- events do
        {:ok, _} = ETS.append("arbor:consensus", event, name: table)
      end

      {:ok, state} = StateRecovery.rebuild_from_events({ETS, name: table})

      assert state.proposals["prop_1"].status == :deadlocked
      assert state.interrupted == []
    end

    test "tracks last event position", %{table: table} do
      events = [
        create_persistence_event("proposal.submitted", %{
          proposal_id: "prop_1",
          proposer: "agent_1",
          change_type: "code_modification",
          description: "Add caching"
        }),
        create_persistence_event("proposal.submitted", %{
          proposal_id: "prop_2",
          proposer: "agent_2",
          change_type: "documentation_change",
          description: "Update docs"
        })
      ]

      for event <- events do
        {:ok, _} = ETS.append("arbor:consensus", event, name: table)
      end

      {:ok, state} = StateRecovery.rebuild_from_events({ETS, name: table})

      assert state.events_replayed == 2
      # Position depends on ETS implementation
      assert state.last_position >= 0
    end
  end

  describe "detect_interrupted/1" do
    test "detects evaluations without decisions" do
      state = %{
        proposals: %{
          "prop_1" => %{
            status: :evaluating,
            perspectives: [:security, :stability],
            completed_evaluations: %{security: %{}}
          },
          "prop_2" => %{
            status: :decided,
            perspectives: [:security],
            completed_evaluations: %{security: %{}}
          }
        },
        decisions: %{},
        interrupted: [],
        last_position: 0,
        events_replayed: 0
      }

      interrupted = StateRecovery.detect_interrupted(state)

      assert length(interrupted) == 1
      assert hd(interrupted).proposal_id == "prop_1"
      assert hd(interrupted).missing_perspectives == [:stability]
    end
  end

  describe "recovery with ProposalExecuted event" do
    test "marks proposal as executed", %{table: table} do
      events = [
        create_persistence_event("proposal.submitted", %{
          proposal_id: "prop_exec",
          proposer: "agent_1",
          change_type: "code_modification",
          description: "Executed proposal"
        }),
        create_persistence_event("decision.rendered", %{
          proposal_id: "prop_exec",
          decision_id: "dec_1",
          decision: "approved",
          approve_count: 5,
          reject_count: 1,
          abstain_count: 0,
          required_quorum: 5,
          quorum_met: true,
          primary_concerns: [],
          average_confidence: 0.9
        }),
        create_persistence_event("proposal.executed", %{
          proposal_id: "prop_exec",
          result: "success",
          details: "Applied changes"
        })
      ]

      for event <- events do
        {:ok, _} = ETS.append("arbor:consensus", event, name: table)
      end

      {:ok, state} = StateRecovery.rebuild_from_events({ETS, name: table})
      assert state.proposals["prop_exec"].status == :executed
    end
  end

  describe "recovery with EvaluationFailed event" do
    test "tracks failed evaluation as completed with error", %{table: table} do
      events = [
        create_persistence_event("proposal.submitted", %{
          proposal_id: "prop_fail",
          proposer: "agent_1",
          change_type: "code_modification",
          description: "Failed evaluation"
        }),
        create_persistence_event("evaluation.started", %{
          proposal_id: "prop_fail",
          perspectives: ["security", "stability"],
          council_size: 2,
          required_quorum: 2
        }),
        create_persistence_event("evaluation.failed", %{
          proposal_id: "prop_fail",
          perspective: "security",
          reason: "timeout"
        })
      ]

      for event <- events do
        {:ok, _} = ETS.append("arbor:consensus", event, name: table)
      end

      {:ok, state} = StateRecovery.rebuild_from_events({ETS, name: table})

      proposal = state.proposals["prop_fail"]
      assert map_size(proposal.completed_evaluations) == 1
      failed = proposal.completed_evaluations[:security]
      assert failed.vote == :error
      assert failed.reason == :timeout
    end
  end

  describe "recovery with coordinator lifecycle events" do
    test "handles CoordinatorStarted event", %{table: table} do
      events = [
        create_persistence_event("coordinator.started", %{
          coordinator_id: "coord_1",
          config: %{council_size: 7}
        }),
        create_persistence_event("proposal.submitted", %{
          proposal_id: "prop_after_start",
          proposer: "agent_1",
          change_type: "code_modification",
          description: "After coordinator start"
        })
      ]

      for event <- events do
        {:ok, _} = ETS.append("arbor:consensus", event, name: table)
      end

      {:ok, state} = StateRecovery.rebuild_from_events({ETS, name: table})
      assert state.events_replayed == 2
      assert Map.has_key?(state.proposals, "prop_after_start")
    end

    test "handles RecoveryStarted event", %{table: table} do
      event = create_persistence_event("recovery.started", %{
        coordinator_id: "coord_1",
        from_position: 0
      })

      {:ok, _} = ETS.append("arbor:consensus", event, name: table)
      {:ok, state} = StateRecovery.rebuild_from_events({ETS, name: table})
      assert state.events_replayed == 1
    end

    test "handles RecoveryCompleted event", %{table: table} do
      event = create_persistence_event("recovery.completed", %{
        coordinator_id: "coord_1",
        proposals_recovered: 3,
        decisions_recovered: 1,
        interrupted_count: 1,
        events_replayed: 5
      })

      {:ok, _} = ETS.append("arbor:consensus", event, name: table)
      {:ok, state} = StateRecovery.rebuild_from_events({ETS, name: table})
      assert state.events_replayed == 1
    end
  end

  describe "apply_event/2 with unknown event type" do
    test "skips unknown event types gracefully" do
      state = %{
        proposals: %{},
        decisions: %{},
        interrupted: [],
        last_position: 0,
        events_replayed: 0
      }

      # Event with completely unknown type
      event = create_persistence_event("unknown.event.type", %{some: "data"})
      result = StateRecovery.apply_event(event, state)

      # State should be unchanged
      assert result.proposals == %{}
      assert result.decisions == %{}
    end
  end

  describe "event for unknown proposal" do
    test "handles evaluation.started for non-existent proposal", %{table: table} do
      # No ProposalSubmitted, just EvaluationStarted
      event = create_persistence_event("evaluation.started", %{
        proposal_id: "nonexistent_prop",
        perspectives: ["security"],
        council_size: 1,
        required_quorum: 1
      })

      {:ok, _} = ETS.append("arbor:consensus", event, name: table)
      {:ok, state} = StateRecovery.rebuild_from_events({ETS, name: table})

      # Proposal shouldn't exist since we never submitted it
      refute Map.has_key?(state.proposals, "nonexistent_prop")
    end
  end

  # Helper to create persistence events
  defp create_persistence_event(type, data) do
    Event.new("arbor:consensus", type, data,
      timestamp: DateTime.utc_now()
    )
  end
end
