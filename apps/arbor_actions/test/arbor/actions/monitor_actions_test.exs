defmodule Arbor.Actions.MonitorActionsTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Monitor.{
    ClaimAnomaly,
    CompleteAnomaly,
    ReadDiagnostics,
    ResetBaseline,
    SuppressFingerprint
  }

  describe "ClaimAnomaly" do
    @tag :fast
    test "returns unavailable when queue not running" do
      assert {:error, :anomaly_queue_unavailable} =
               ClaimAnomaly.run(%{agent_id: "test-agent"}, %{})
    end

    @tag :fast
    test "has correct action metadata" do
      assert ClaimAnomaly.__action_metadata__().name == "monitor_claim_anomaly"
    end

    @tag :fast
    test "defines taint roles" do
      roles = ClaimAnomaly.taint_roles()
      assert roles.agent_id == :control
    end
  end

  describe "CompleteAnomaly" do
    @tag :fast
    test "returns unavailable when queue not running" do
      assert {:error, :anomaly_queue_unavailable} =
               CompleteAnomaly.run(
                 %{lease_token: "test-lease", outcome: "fixed"},
                 %{}
               )
    end

    @tag :fast
    test "has correct action metadata" do
      assert CompleteAnomaly.__action_metadata__().name == "monitor_complete_anomaly"
    end

    @tag :fast
    test "defines taint roles" do
      roles = CompleteAnomaly.taint_roles()
      assert roles.lease_token == :control
      assert roles.outcome == :control
    end
  end

  describe "SuppressFingerprint" do
    @tag :fast
    test "returns unavailable when queue not running" do
      assert {:error, :anomaly_queue_unavailable} =
               SuppressFingerprint.run(
                 %{skill: "beam", metric: "reductions", reason: "test"},
                 %{}
               )
    end

    @tag :fast
    test "has correct action metadata" do
      assert SuppressFingerprint.__action_metadata__().name == "monitor_suppress_fingerprint"
    end
  end

  describe "ResetBaseline" do
    @tag :fast
    test "returns unavailable when detector not loaded" do
      # AnomalyDetector might or might not be loaded in test env
      result = ResetBaseline.run(%{skill: "beam", metric: "reductions"}, %{})

      case result do
        {:error, :anomaly_detector_unavailable} -> :ok
        {:ok, %{reset: true}} -> :ok
        {:error, {:unknown_metric, _}} -> :ok
      end
    end

    @tag :fast
    test "has correct action metadata" do
      assert ResetBaseline.__action_metadata__().name == "monitor_reset_baseline"
    end

    @tag :fast
    test "rejects unknown skill names" do
      # If detector is available, it should reject unknown skills
      case ResetBaseline.run(%{skill: "nonexistent_skill", metric: "foo"}, %{}) do
        {:error, {:unknown_skill, "nonexistent_skill"}} -> :ok
        {:error, :anomaly_detector_unavailable} -> :ok
      end
    end
  end

  describe "ReadDiagnostics" do
    @tag :fast
    test "system_info works without pid" do
      result = ReadDiagnostics.run(%{query: "system_info"}, %{})

      case result do
        {:ok, %{query: "system_info", data: data}} ->
          assert is_integer(data.process_count)
          assert is_integer(data.process_limit)
          assert is_map(data.memory)
          assert is_integer(data.schedulers)

        {:error, :diagnostics_unavailable} ->
          :ok
      end
    end

    @tag :fast
    test "process query requires pid" do
      result = ReadDiagnostics.run(%{query: "process"}, %{})

      case result do
        {:error, :pid_required} -> :ok
        {:error, :diagnostics_unavailable} -> :ok
      end
    end

    @tag :fast
    test "supervisor query requires pid" do
      result = ReadDiagnostics.run(%{query: "supervisor"}, %{})

      case result do
        {:error, :pid_required} -> :ok
        {:error, :diagnostics_unavailable} -> :ok
      end
    end

    @tag :fast
    test "top_processes returns list" do
      result = ReadDiagnostics.run(%{query: "top_processes", sort_by: "memory", limit: 5}, %{})

      case result do
        {:ok, %{query: "top_processes", data: data}} ->
          assert is_list(data)

        {:error, :diagnostics_unavailable} ->
          :ok
      end
    end

    @tag :fast
    test "has correct action metadata" do
      assert ReadDiagnostics.__action_metadata__().name == "monitor_read_diagnostics"
    end

    @tag :fast
    test "defines taint roles" do
      roles = ReadDiagnostics.taint_roles()
      assert roles.query == :control
      assert roles.pid == :data
    end
  end
end
