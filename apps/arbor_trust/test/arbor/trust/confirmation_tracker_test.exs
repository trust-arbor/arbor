defmodule Arbor.Trust.ConfirmationTrackerTest do
  use ExUnit.Case, async: false

  alias Arbor.Trust.ConfirmationTracker

  @moduletag :fast

  setup do
    start_supervised!(ConfirmationTracker)
    agent_id = "agent_tracker_test_#{System.unique_integer([:positive])}"
    {:ok, agent_id: agent_id}
  end

  # ===========================================================================
  # Basic confirmation tracking
  # ===========================================================================

  describe "record_approval/2" do
    test "increments approval count and streak", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      assert :ok = ConfirmationTracker.record_approval(agent_id, uri)

      status = ConfirmationTracker.status(agent_id, :codebase_write)
      assert status.approvals == 1
      assert status.streak == 1
      assert status.rejections == 0
    end

    test "increments streak on consecutive approvals", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)

      status = ConfirmationTracker.status(agent_id, :codebase_write)
      assert status.approvals == 3
      assert status.streak == 3
    end

    test "returns :ok for unknown URIs (no bundle)", %{agent_id: agent_id} do
      assert :ok = ConfirmationTracker.record_approval(agent_id, "arbor://unknown/thing")
    end

    test "sets last_confirmation timestamp", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"
      ConfirmationTracker.record_approval(agent_id, uri)

      status = ConfirmationTracker.status(agent_id, :codebase_write)
      assert %DateTime{} = status.last_confirmation
    end
  end

  describe "record_rejection/2" do
    test "resets streak to 0", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      assert :ok = ConfirmationTracker.record_rejection(agent_id, uri)

      status = ConfirmationTracker.status(agent_id, :codebase_write)
      assert status.approvals == 2
      assert status.rejections == 1
      assert status.streak == 0
    end

    test "returns :ok for unknown URIs", %{agent_id: agent_id} do
      assert :ok = ConfirmationTracker.record_rejection(agent_id, "arbor://unknown/thing")
    end
  end

  # ===========================================================================
  # Graduation logic
  # ===========================================================================

  describe "graduation" do
    test "graduates after reaching threshold (codebase_write: 3)", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      assert :ok = ConfirmationTracker.record_approval(agent_id, uri)
      assert :ok = ConfirmationTracker.record_approval(agent_id, uri)
      # Third approval should trigger graduation
      assert {:graduated, :codebase_write} = ConfirmationTracker.record_approval(agent_id, uri)

      assert ConfirmationTracker.graduated?(agent_id, uri)
    end

    test "returns :ok (not :graduated) on subsequent approvals after graduation", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      {:graduated, _} = ConfirmationTracker.record_approval(agent_id, uri)

      # Already graduated — returns :ok
      assert :ok = ConfirmationTracker.record_approval(agent_id, uri)
    end

    test "not graduated before reaching threshold", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)

      refute ConfirmationTracker.graduated?(agent_id, uri)
    end

    test "rejection resets graduation progress", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_rejection(agent_id, uri)

      # Streak reset — need 3 more approvals
      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)

      refute ConfirmationTracker.graduated?(agent_id, uri)
    end

    test "rejection reverts existing graduation", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      # Graduate first
      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      assert ConfirmationTracker.graduated?(agent_id, uri)

      # Rejection reverts graduation
      ConfirmationTracker.record_rejection(agent_id, uri)
      refute ConfirmationTracker.graduated?(agent_id, uri)
    end

    test "graduated_at timestamp is set on graduation", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)

      status = ConfirmationTracker.status(agent_id, :codebase_write)
      assert %DateTime{} = status.graduated_at
    end
  end

  # ===========================================================================
  # Security invariants
  # ===========================================================================

  describe "security invariants" do
    test "shell NEVER graduates regardless of approvals", %{agent_id: agent_id} do
      uri = "arbor://shell/exec/ls"

      for _ <- 1..20 do
        ConfirmationTracker.record_approval(agent_id, uri)
      end

      refute ConfirmationTracker.graduated?(agent_id, uri)
      assert ConfirmationTracker.threshold_for(:shell) == :never
    end

    test "governance NEVER graduates regardless of approvals", %{agent_id: agent_id} do
      uri = "arbor://governance/change/self/policy"

      for _ <- 1..20 do
        ConfirmationTracker.record_approval(agent_id, uri)
      end

      refute ConfirmationTracker.graduated?(agent_id, uri)
      assert ConfirmationTracker.threshold_for(:governance) == :never
    end
  end

  # ===========================================================================
  # Lock/unlock
  # ===========================================================================

  describe "lock_gated/2 and unlock_gated/2" do
    test "locked bundles cannot graduate", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      ConfirmationTracker.lock_gated(agent_id, :codebase_write)

      # Even after reaching threshold, should not graduate
      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)

      refute ConfirmationTracker.graduated?(agent_id, uri)
      assert ConfirmationTracker.status(agent_id, :codebase_write).locked
    end

    test "unlocking allows graduation again", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      ConfirmationTracker.lock_gated(agent_id, :codebase_write)
      ConfirmationTracker.unlock_gated(agent_id, :codebase_write)

      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)

      assert ConfirmationTracker.graduated?(agent_id, uri)
    end

    test "locking reverts existing graduation", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      # Graduate first
      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      assert ConfirmationTracker.graduated?(agent_id, uri)

      # Lock reverts graduation
      ConfirmationTracker.lock_gated(agent_id, :codebase_write)
      refute ConfirmationTracker.graduated?(agent_id, uri)
    end
  end

  # ===========================================================================
  # Revert and reset
  # ===========================================================================

  describe "revert_to_gated/2" do
    test "reverts graduated capability back to gated", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      # Graduate
      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      assert ConfirmationTracker.graduated?(agent_id, uri)

      # Revert
      ConfirmationTracker.revert_to_gated(agent_id, :codebase_write)
      refute ConfirmationTracker.graduated?(agent_id, uri)

      # Streak also reset
      status = ConfirmationTracker.status(agent_id, :codebase_write)
      assert status.streak == 0
    end
  end

  describe "reset/1" do
    test "clears all confirmation history for an agent", %{agent_id: agent_id} do
      write_uri = "arbor://code/write/#{agent_id}/impl/file.ex"
      network_uri = "arbor://network/request/https://example.com"

      # Build history in multiple bundles
      ConfirmationTracker.record_approval(agent_id, write_uri)
      ConfirmationTracker.record_approval(agent_id, write_uri)
      ConfirmationTracker.record_approval(agent_id, network_uri)

      # Reset everything
      ConfirmationTracker.reset(agent_id)

      assert ConfirmationTracker.status(agent_id, :codebase_write) == new_entry()
      assert ConfirmationTracker.status(agent_id, :network) == new_entry()
    end

    test "does not affect other agents", %{agent_id: agent_id} do
      other_id = "other_agent_#{System.unique_integer([:positive])}"
      uri = "arbor://code/write/self/impl/file.ex"

      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(other_id, uri)

      ConfirmationTracker.reset(agent_id)

      assert ConfirmationTracker.status(agent_id, :codebase_write).approvals == 0
      assert ConfirmationTracker.status(other_id, :codebase_write).approvals == 1
    end
  end

  # ===========================================================================
  # Thresholds
  # ===========================================================================

  describe "threshold_for/1" do
    test "returns default thresholds" do
      assert ConfirmationTracker.threshold_for(:codebase_read) == 0
      assert ConfirmationTracker.threshold_for(:codebase_write) == 3
      assert ConfirmationTracker.threshold_for(:shell) == :never
      assert ConfirmationTracker.threshold_for(:network) == 5
      assert ConfirmationTracker.threshold_for(:ai_generate) == 3
      assert ConfirmationTracker.threshold_for(:system_config) == 10
      assert ConfirmationTracker.threshold_for(:governance) == :never
    end

    test "returns default (5) for unknown bundles" do
      assert ConfirmationTracker.threshold_for(:unknown_bundle) == 5
    end
  end

  # ===========================================================================
  # graduated?/2 edge cases
  # ===========================================================================

  describe "graduated?/2 edge cases" do
    test "returns false for unknown agent", %{agent_id: _agent_id} do
      refute ConfirmationTracker.graduated?("unknown_agent", "arbor://code/write/self/file.ex")
    end

    test "returns false for unknown URI" do
      refute ConfirmationTracker.graduated?("any_agent", "arbor://unknown/path")
    end

    test "returns false when tracker not running" do
      # Stop the tracker
      stop_supervised!(ConfirmationTracker)

      # Should return false (not crash)
      refute ConfirmationTracker.graduated?("any_agent", "arbor://code/write/self/file.ex")
    end
  end

  # ===========================================================================
  # Different bundles have different thresholds
  # ===========================================================================

  describe "per-bundle graduation thresholds" do
    test "network requires 5 approvals", %{agent_id: agent_id} do
      uri = "arbor://network/request/https://example.com"

      for _ <- 1..4 do
        assert :ok = ConfirmationTracker.record_approval(agent_id, uri)
      end
      refute ConfirmationTracker.graduated?(agent_id, uri)

      assert {:graduated, :network} = ConfirmationTracker.record_approval(agent_id, uri)
      assert ConfirmationTracker.graduated?(agent_id, uri)
    end

    test "system_config requires 10 approvals", %{agent_id: agent_id} do
      uri = "arbor://config/write/self/setting"

      for _ <- 1..9 do
        assert :ok = ConfirmationTracker.record_approval(agent_id, uri)
      end
      refute ConfirmationTracker.graduated?(agent_id, uri)

      assert {:graduated, :system_config} = ConfirmationTracker.record_approval(agent_id, uri)
      assert ConfirmationTracker.graduated?(agent_id, uri)
    end

    test "codebase_read has threshold 0 (always graduated)", %{agent_id: agent_id} do
      # codebase_read is already :auto in the matrix, so graduation
      # isn't typically checked. But the threshold is 0, meaning
      # any single approval would graduate it.
      assert ConfirmationTracker.threshold_for(:codebase_read) == 0
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp new_entry do
    %{
      approvals: 0,
      rejections: 0,
      streak: 0,
      graduated: false,
      locked: false,
      last_confirmation: nil,
      graduated_at: nil
    }
  end
end
