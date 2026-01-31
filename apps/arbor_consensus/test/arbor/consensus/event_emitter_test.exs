defmodule Arbor.Consensus.EventEmitterTest do
  # Cannot be async since tests modify Application.env
  use ExUnit.Case, async: false

  alias Arbor.Consensus.EventEmitter
  alias Arbor.Contracts.Consensus.Events
  alias Arbor.Persistence.EventLog.ETS

  setup do
    # Create a unique ETS table for this test
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    table_name = :"test_events_#{System.unique_integer([:positive])}"
    {:ok, _pid} = ETS.start_link(name: table_name)

    # Store original config
    original = Application.get_env(:arbor_consensus, :event_log)

    # Set test config
    Application.put_env(:arbor_consensus, :event_log, {ETS, name: table_name})

    on_exit(fn ->
      # Restore original config
      if original do
        Application.put_env(:arbor_consensus, :event_log, original)
      else
        Application.delete_env(:arbor_consensus, :event_log)
      end
    end)

    %{table: table_name}
  end

  describe "emit/2" do
    test "emits ProposalSubmitted event", %{table: table} do
      event =
        Events.ProposalSubmitted.new(%{
          proposal_id: "prop_123",
          proposer: "agent_1",
          change_type: :code_modification,
          description: "Add caching"
        })

      assert :ok = EventEmitter.emit(event)

      # Verify event was persisted
      {:ok, events} = ETS.read_stream("arbor:consensus", name: table)
      assert length(events) == 1
      assert hd(events).type == "proposal.submitted"
    end

    test "emits event with correlation_id" do
      event =
        Events.ProposalSubmitted.new(%{
          proposal_id: "prop_456",
          proposer: "agent_2",
          change_type: :documentation_change,
          description: "Update README"
        })

      assert :ok = EventEmitter.emit(event, correlation_id: "corr_789")
    end

    test "returns :ok when no event_log configured" do
      Application.delete_env(:arbor_consensus, :event_log)

      event =
        Events.CoordinatorStarted.new(%{
          coordinator_id: "coord_1",
          config: %{}
        })

      assert :ok = EventEmitter.emit(event)
    end
  end

  describe "convenience emitters" do
    test "coordinator_started/3", %{table: table} do
      assert :ok = EventEmitter.coordinator_started("coord_1", %{size: 7})

      {:ok, events} = ETS.read_stream("arbor:consensus", name: table)
      assert length(events) == 1
      assert hd(events).type == "coordinator.started"
    end

    test "proposal_submitted/2", %{table: table} do
      proposal = %{
        id: "prop_1",
        proposer: "agent_1",
        change_type: :code_modification,
        description: "Fix bug",
        target_layer: 1,
        target_module: "Foo.Bar",
        metadata: %{}
      }

      assert :ok = EventEmitter.proposal_submitted(proposal)

      {:ok, events} = ETS.read_stream("arbor:consensus", name: table)
      assert length(events) == 1
      assert hd(events).type == "proposal.submitted"
    end

    test "evaluation_started/5", %{table: table} do
      assert :ok =
               EventEmitter.evaluation_started(
                 "prop_1",
                 [:security, :stability],
                 7,
                 5
               )

      {:ok, events} = ETS.read_stream("arbor:consensus", name: table)
      assert length(events) == 1
      assert hd(events).type == "evaluation.started"
    end

    test "evaluation_completed/2", %{table: table} do
      evaluation = %{
        proposal_id: "prop_1",
        id: "eval_1",
        perspective: :security,
        vote: :approve,
        confidence: 0.9,
        risk_score: 0.1,
        benefit_score: 0.8,
        concerns: [],
        recommendations: [],
        reasoning: "Looks safe"
      }

      assert :ok = EventEmitter.evaluation_completed(evaluation)

      {:ok, events} = ETS.read_stream("arbor:consensus", name: table)
      assert length(events) == 1
      assert hd(events).type == "evaluation.completed"
    end

    test "decision_rendered/2", %{table: table} do
      decision = %{
        proposal_id: "prop_1",
        id: "dec_1",
        decision: :approved,
        approve_count: 5,
        reject_count: 1,
        abstain_count: 1,
        required_quorum: 5,
        quorum_met: true,
        primary_concerns: [],
        average_confidence: 0.85
      }

      assert :ok = EventEmitter.decision_rendered(decision)

      {:ok, events} = ETS.read_stream("arbor:consensus", name: table)
      assert length(events) == 1
      assert hd(events).type == "decision.rendered"
    end

    test "proposal_executed/4", %{table: table} do
      {:ok, before} = ETS.read_stream("arbor:consensus", name: table)
      before_count = length(before)

      assert :ok = EventEmitter.proposal_executed("prop_1", :success, "Applied changes")

      {:ok, events} = ETS.read_stream("arbor:consensus", name: table)
      assert length(events) == before_count + 1
      assert List.last(events).type == "proposal.executed"
    end

    test "proposal_deadlocked/4", %{table: table} do
      {:ok, before} = ETS.read_stream("arbor:consensus", name: table)
      before_count = length(before)

      assert :ok = EventEmitter.proposal_deadlocked("prop_1", :no_quorum, "Only 3/5 voted")

      {:ok, events} = ETS.read_stream("arbor:consensus", name: table)
      assert length(events) == before_count + 1
      assert List.last(events).type == "proposal.deadlocked"
    end
  end

  describe "enabled?/0" do
    test "returns true when event_log is configured" do
      assert EventEmitter.enabled?() == true
    end

    test "returns false when no event_log configured" do
      Application.delete_env(:arbor_consensus, :event_log)
      assert EventEmitter.enabled?() == false
    end
  end

  describe "stream_id/0" do
    test "returns configured stream name" do
      assert EventEmitter.stream_id() == "arbor:consensus"
    end
  end

  describe "emit_all/2" do
    test "emits multiple events atomically", %{table: table} do
      events = [
        Events.ProposalSubmitted.new(%{
          proposal_id: "prop_batch_1",
          proposer: "agent_1",
          change_type: :code_modification,
          description: "Batch 1"
        }),
        Events.ProposalSubmitted.new(%{
          proposal_id: "prop_batch_2",
          proposer: "agent_2",
          change_type: :test_change,
          description: "Batch 2"
        })
      ]

      assert :ok = EventEmitter.emit_all(events)

      {:ok, stored} = ETS.read_stream("arbor:consensus", name: table)
      assert length(stored) >= 2
    end

    test "returns :ok when no event_log configured" do
      Application.delete_env(:arbor_consensus, :event_log)

      events = [
        Events.CoordinatorStarted.new(%{
          coordinator_id: "coord_1",
          config: %{}
        })
      ]

      assert :ok = EventEmitter.emit_all(events)
    end

    test "passes metadata and correlation options", %{table: table} do
      events = [
        Events.ProposalSubmitted.new(%{
          proposal_id: "prop_meta",
          proposer: "agent_meta",
          change_type: :code_modification,
          description: "With meta"
        })
      ]

      assert :ok =
               EventEmitter.emit_all(events,
                 correlation_id: "corr_batch",
                 metadata: %{batch: true}
               )

      {:ok, stored} = ETS.read_stream("arbor:consensus", name: table)
      assert stored != []
    end
  end

  describe "evaluation_failed/4" do
    test "emits evaluation failed event", %{table: table} do
      assert :ok =
               EventEmitter.evaluation_failed(
                 "prop_fail",
                 :security,
                 :timeout
               )

      {:ok, events} = ETS.read_stream("arbor:consensus", name: table)
      assert Enum.any?(events, &(&1.type == "evaluation.failed"))
    end
  end

  describe "recovery events" do
    test "recovery_started/3 emits event", %{table: table} do
      assert :ok = EventEmitter.recovery_started("coord_recovery", 42)

      {:ok, events} = ETS.read_stream("arbor:consensus", name: table)
      assert Enum.any?(events, &(&1.type == "recovery.started"))
    end

    test "recovery_completed/3 emits event", %{table: table} do
      stats = %{
        proposals_recovered: 5,
        decisions_recovered: 3,
        interrupted_count: 1,
        events_replayed: 42
      }

      assert :ok = EventEmitter.recovery_completed("coord_recovery", stats)

      {:ok, events} = ETS.read_stream("arbor:consensus", name: table)
      assert Enum.any?(events, &(&1.type == "recovery.completed"))
    end
  end

  describe "coordinator_started/3 with recovered_from" do
    test "emits event with recovered_from position", %{table: table} do
      assert :ok =
               EventEmitter.coordinator_started("coord_2", %{size: 7},
                 recovered_from: 100
               )

      {:ok, events} = ETS.read_stream("arbor:consensus", name: table)
      assert events != []
    end
  end
end
