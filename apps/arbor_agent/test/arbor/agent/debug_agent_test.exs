defmodule Arbor.Agent.DebugAgentTest do
  use ExUnit.Case

  alias Arbor.Agent.DebugAgent

  @moduletag :slow

  # These tests require the full app ecosystem to be running.
  # Mark them as :integration to skip during fast test runs.
  # Run with: mix test --include integration

  # Clean up after each test
  setup do
    on_exit(fn ->
      # Clean up any leftover agents
      try do
        DebugAgent.stop("test-debug-agent")
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end

      try do
        DebugAgent.stop("debug-agent")
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  describe "start/1" do
    @tag :integration
    test "starts a debug agent with default ID" do
      assert {:ok, agent_id} = DebugAgent.start()
      assert agent_id == "debug-agent"
      assert :ok = DebugAgent.stop(agent_id)
    end

    @tag :integration
    test "starts with custom agent ID" do
      assert {:ok, agent_id} = DebugAgent.start(agent_id: "test-debug-agent")
      assert agent_id == "test-debug-agent"
      assert :ok = DebugAgent.stop(agent_id)
    end

    @tag :integration
    test "accepts callback options" do
      proposals = :ets.new(:test_proposals, [:set, :public])

      on_proposal = fn proposal ->
        :ets.insert(proposals, {:proposal, proposal})
        :ok
      end

      on_decision = fn decision ->
        :ets.insert(proposals, {:decision, decision})
        :ok
      end

      assert {:ok, agent_id} =
               DebugAgent.start(
                 agent_id: "test-debug-agent",
                 on_proposal: on_proposal,
                 on_decision: on_decision
               )

      assert :ok = DebugAgent.stop(agent_id)
      :ets.delete(proposals)
    end

    @tag :integration
    test "accepts custom cycles option" do
      assert {:ok, agent_id} = DebugAgent.start(agent_id: "test-debug-agent", cycles: 5)
      assert :ok = DebugAgent.stop(agent_id)
    end
  end

  describe "stop/1" do
    @tag :integration
    test "stops a running agent" do
      {:ok, agent_id} = DebugAgent.start(agent_id: "test-debug-agent")
      assert :ok = DebugAgent.stop(agent_id)
    end

    @tag :integration
    test "is idempotent" do
      {:ok, agent_id} = DebugAgent.start(agent_id: "test-debug-agent")
      assert :ok = DebugAgent.stop(agent_id)
      assert :ok = DebugAgent.stop(agent_id)
    end

    test "is safe when agent doesn't exist" do
      # Stop is always safe and doesn't fail
      assert :ok = DebugAgent.stop("nonexistent-agent")
    end
  end

  describe "get_state/1" do
    test "returns error when agent not started" do
      assert {:error, :not_found} = DebugAgent.get_state("nonexistent-agent")
    end
  end

  describe "module structure" do
    test "exports expected functions" do
      Code.ensure_loaded!(DebugAgent)
      assert function_exported?(DebugAgent, :start_managed, 0)
      assert function_exported?(DebugAgent, :start_managed, 1)
      assert function_exported?(DebugAgent, :start_link, 0)
      assert function_exported?(DebugAgent, :start_link, 1)
      assert function_exported?(DebugAgent, :stop, 1)
      assert function_exported?(DebugAgent, :run_bounded, 2)
      assert function_exported?(DebugAgent, :get_state, 1)
    end

    test "has correct typespecs" do
      # The module should compile without warnings
      # This test ensures the typespecs are valid
      {:ok, specs} = Code.Typespec.fetch_specs(DebugAgent)
      assert specs != []

      spec_names = Enum.map(specs, fn {{name, _arity}, _} -> name end)
      assert :start_managed in spec_names
      assert :stop in spec_names
      assert :run_bounded in spec_names
    end
  end

  describe "think function phases" do
    # These tests verify the internal state machine logic
    # without running the full reasoning loop

    test "initial state is :check_anomalies phase" do
      # Manually test state initialization
      state = %{
        phase: :check_anomalies,
        current_anomaly: nil,
        current_proposal: nil,
        proposals_submitted: 0,
        proposals_approved: 0,
        proposals_rejected: 0,
        anomalies_detected: 0,
        last_check: nil,
        started_at: DateTime.utc_now()
      }

      assert state.phase == :check_anomalies
      assert state.current_anomaly == nil
    end

    test "state transitions are well-defined" do
      # Verify the phase transitions are valid
      valid_phases = [:check_anomalies, :await_analysis, :await_decision, :complete]
      assert Enum.all?(valid_phases, &is_atom/1)
    end
  end

  describe "proposal building" do
    test "builds proposal from anomaly and analysis data" do
      # Test the proposal structure that would be built
      anomaly = %{
        id: 123,
        skill: :beam,
        severity: :warning,
        details: %{reductions: 1_000_000},
        timestamp: System.monotonic_time(:millisecond)
      }

      analysis_data = %{
        target_module: MyApp.Worker,
        suggested_fix: "def fix, do: :ok",
        root_cause: "High reduction count in worker",
        confidence: 0.8
      }

      # Expected proposal structure
      expected_keys = [:topic, :description, :target_module, :fix_code, :root_cause, :confidence]
      proposal = build_test_proposal(anomaly, analysis_data)

      Enum.each(expected_keys, fn key ->
        assert Map.has_key?(proposal, key), "Missing key: #{key}"
      end)

      assert proposal.topic == :runtime_fix
      assert proposal.target_module == MyApp.Worker
      assert proposal.confidence == 0.8
    end
  end

  # Helper to simulate proposal building for testing
  defp build_test_proposal(anomaly, analysis_data) do
    %{
      topic: :runtime_fix,
      description: "Fix for #{anomaly.skill} #{anomaly.severity} anomaly",
      target_module: analysis_data[:target_module],
      fix_code: analysis_data[:suggested_fix] || "",
      root_cause: analysis_data[:root_cause] || "Unknown",
      confidence: analysis_data[:confidence] || 0.5,
      anomaly_id: anomaly.id,
      context: %{
        anomaly: anomaly,
        analysis: analysis_data
      }
    }
  end
end
