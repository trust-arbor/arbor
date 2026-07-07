defmodule Arbor.Trust.ConfirmationTrackerTest do
  use ExUnit.Case, async: false

  alias Arbor.Trust.ConfirmationTracker

  @moduletag :fast

  setup do
    previous_thresholds = Application.get_env(:arbor_trust, :graduation_thresholds)
    Application.delete_env(:arbor_trust, :graduation_thresholds)

    start_supervised!(ConfirmationTracker)
    agent_id = "agent_tracker_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if is_nil(previous_thresholds) do
        Application.delete_env(:arbor_trust, :graduation_thresholds)
      else
        Application.put_env(:arbor_trust, :graduation_thresholds, previous_thresholds)
      end
    end)

    {:ok, agent_id: agent_id}
  end

  # ===========================================================================
  # Basic confirmation tracking
  # ===========================================================================

  describe "record_approval/2" do
    test "increments approval count and streak", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      assert :ok = ConfirmationTracker.record_approval(agent_id, uri)

      status = ConfirmationTracker.status(agent_id, "arbor://code/write")
      assert status.approvals == 1
      assert status.streak == 1
      assert status.rejections == 0
    end

    test "increments streak on consecutive approvals", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)

      status = ConfirmationTracker.status(agent_id, "arbor://code/write")
      assert status.approvals == 3
      assert status.streak == 3
    end

    test "returns :ok for unknown URIs (no matching prefix)", %{agent_id: agent_id} do
      assert :ok = ConfirmationTracker.record_approval(agent_id, "arbor://unknown/thing")
    end

    test "sets last_confirmation timestamp", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"
      ConfirmationTracker.record_approval(agent_id, uri)

      status = ConfirmationTracker.status(agent_id, "arbor://code/write")
      assert %DateTime{} = status.last_confirmation
    end
  end

  describe "record_rejection/2" do
    test "resets streak to 0", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      assert :ok = ConfirmationTracker.record_rejection(agent_id, uri)

      status = ConfirmationTracker.status(agent_id, "arbor://code/write")
      assert status.approvals == 2
      assert status.rejections == 1
      assert status.streak == 0
    end

    test "returns :ok for unknown URIs", %{agent_id: agent_id} do
      assert :ok = ConfirmationTracker.record_rejection(agent_id, "arbor://unknown/thing")
    end
  end

  # ===========================================================================
  # Graduation logic (now suggestion-based)
  # ===========================================================================

  describe "graduation" do
    test "suggests graduation after reaching threshold (code/write: 3)", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      assert :ok = ConfirmationTracker.record_approval(agent_id, uri)
      assert :ok = ConfirmationTracker.record_approval(agent_id, uri)
      # Third approval triggers graduation suggestion
      assert {:graduation_suggested, "arbor://code/write"} =
               ConfirmationTracker.record_approval(agent_id, uri)

      assert ConfirmationTracker.graduated?(agent_id, uri)
    end

    test "returns :ok (not suggestion) on subsequent approvals after graduation", %{
      agent_id: agent_id
    } do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      {:graduation_suggested, _} = ConfirmationTracker.record_approval(agent_id, uri)

      # Already graduated — returns :ok
      assert :ok = ConfirmationTracker.record_approval(agent_id, uri)
    end

    test "not graduated before reaching threshold", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)

      refute ConfirmationTracker.graduated?(agent_id, uri)
    end

    @tag spec: "TRUST-7"
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

    @tag spec: "TRUST-7"
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

      status = ConfirmationTracker.status(agent_id, "arbor://code/write")
      assert %DateTime{} = status.graduated_at
    end
  end

  # ===========================================================================
  # Security invariants
  # ===========================================================================

  describe "security invariants" do
    @tag spec: "TRUST-8"
    test "shell NEVER graduates regardless of approvals", %{agent_id: agent_id} do
      uri = "arbor://shell/exec/ls"

      for _ <- 1..20 do
        ConfirmationTracker.record_approval(agent_id, uri)
      end

      refute ConfirmationTracker.graduated?(agent_id, uri)
      assert ConfirmationTracker.threshold_for("arbor://shell") == :never
    end

    @tag spec: "TRUST-8"
    test "governance NEVER graduates regardless of approvals", %{agent_id: agent_id} do
      uri = "arbor://governance/change/self/policy"

      for _ <- 1..20 do
        ConfirmationTracker.record_approval(agent_id, uri)
      end

      refute ConfirmationTracker.graduated?(agent_id, uri)
      assert ConfirmationTracker.threshold_for("arbor://governance") == :never
    end
  end

  # ===========================================================================
  # Lock/unlock (now URI-prefix based)
  # ===========================================================================

  describe "lock_gated/2 and unlock_gated/2" do
    test "locked prefixes cannot graduate", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      ConfirmationTracker.lock_gated(agent_id, "arbor://code/write")

      # Even after reaching threshold, should not graduate
      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)

      refute ConfirmationTracker.graduated?(agent_id, uri)
      assert ConfirmationTracker.status(agent_id, "arbor://code/write").locked
    end

    test "unlocking allows graduation again", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      ConfirmationTracker.lock_gated(agent_id, "arbor://code/write")
      ConfirmationTracker.unlock_gated(agent_id, "arbor://code/write")

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
      ConfirmationTracker.lock_gated(agent_id, "arbor://code/write")
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
      ConfirmationTracker.revert_to_gated(agent_id, "arbor://code/write")
      refute ConfirmationTracker.graduated?(agent_id, uri)

      # Streak also reset
      status = ConfirmationTracker.status(agent_id, "arbor://code/write")
      assert status.streak == 0
    end
  end

  describe "reset/1" do
    @tag spec: "TRUST-9"
    test "clears all confirmation history for an agent", %{agent_id: agent_id} do
      write_uri = "arbor://code/write/#{agent_id}/impl/file.ex"
      github_uri = "arbor://action/github/pr/#{agent_id}"

      # Build history in multiple prefixes
      ConfirmationTracker.record_approval(agent_id, write_uri)
      ConfirmationTracker.record_approval(agent_id, write_uri)
      ConfirmationTracker.record_approval(agent_id, github_uri)

      # Reset everything
      ConfirmationTracker.reset(agent_id)

      assert ConfirmationTracker.status(agent_id, "arbor://code/write") == new_entry()
      assert ConfirmationTracker.status(agent_id, "arbor://action/github/pr") == new_entry()
    end

    @tag spec: "TRUST-9"
    test "does not affect other agents", %{agent_id: agent_id} do
      other_id = "other_agent_#{System.unique_integer([:positive])}"
      uri = "arbor://code/write/self/impl/file.ex"

      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(other_id, uri)

      ConfirmationTracker.reset(agent_id)

      assert ConfirmationTracker.status(agent_id, "arbor://code/write").approvals == 0
      assert ConfirmationTracker.status(other_id, "arbor://code/write").approvals == 1
    end
  end

  # ===========================================================================
  # Thresholds (now URI-prefix based)
  # ===========================================================================

  describe "threshold_for/1" do
    test "returns profile-derived thresholds for high-risk URI prefixes" do
      assert ConfirmationTracker.threshold_for("arbor://code/write") == 3
      assert ConfirmationTracker.threshold_for("arbor://fs/write") == 3
      assert ConfirmationTracker.threshold_for("arbor://code/compile") == 5
      assert ConfirmationTracker.threshold_for("arbor://action/github/pr") == 5
      assert ConfirmationTracker.threshold_for("arbor://shell") == :never
      assert ConfirmationTracker.threshold_for("arbor://code/hot_load") == :never
      assert ConfirmationTracker.threshold_for("arbor://governance") == :never
    end

    test "returns default (5) for unknown prefixes" do
      assert ConfirmationTracker.threshold_for("arbor://unknown") == 5
    end

    test "resolves sub-prefixes to parent threshold" do
      # arbor://shell/exec inherits arbor://shell threshold
      assert ConfirmationTracker.threshold_for("arbor://shell/exec") == :never
      # arbor://code/write/foo inherits arbor://code/write threshold
      assert ConfirmationTracker.threshold_for("arbor://code/write/foo") == 3
    end

    test "configuration can override or add threshold prefixes" do
      Application.put_env(:arbor_trust, :graduation_thresholds, %{
        "arbor://code/write" => 4,
        "arbor://config" => 10
      })

      assert ConfirmationTracker.threshold_for("arbor://code/write/foo") == 4
      assert ConfirmationTracker.threshold_for("arbor://config/write/self/setting") == 10
    end
  end

  # ===========================================================================
  # resolve_tracking_prefix/1
  # ===========================================================================

  describe "resolve_tracking_prefix/1" do
    test "resolves full URI to tracking prefix" do
      assert ConfirmationTracker.resolve_tracking_prefix("arbor://code/write/agent/file.ex") ==
               "arbor://code/write"

      assert ConfirmationTracker.resolve_tracking_prefix("arbor://shell/exec/ls") ==
               "arbor://shell"

      assert ConfirmationTracker.resolve_tracking_prefix("arbor://action/github/pr/repo") ==
               "arbor://action/github/pr"
    end

    test "returns nil for unknown URIs" do
      assert ConfirmationTracker.resolve_tracking_prefix("arbor://unknown/path") == nil
    end

    test "does not match sibling URI text" do
      assert ConfirmationTracker.resolve_tracking_prefix("arbor://shellfish/exec") == nil
    end

    test "picks longest matching prefix" do
      assert ConfirmationTracker.resolve_tracking_prefix("arbor://code/write/file.ex") ==
               "arbor://code/write"

      assert ConfirmationTracker.resolve_tracking_prefix("arbor://action/github/pr/repo") ==
               "arbor://action/github/pr"
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
  # Different prefixes have different thresholds
  # ===========================================================================

  describe "per-prefix graduation thresholds" do
    test "network-egress action profiles require 5 approvals", %{agent_id: agent_id} do
      uri = "arbor://action/github/pr/#{agent_id}"

      for _ <- 1..4 do
        assert :ok = ConfirmationTracker.record_approval(agent_id, uri)
      end

      refute ConfirmationTracker.graduated?(agent_id, uri)

      assert {:graduation_suggested, "arbor://action/github/pr"} =
               ConfirmationTracker.record_approval(agent_id, uri)

      assert ConfirmationTracker.graduated?(agent_id, uri)
    end

    test "configured non-profiled prefix can require 10 approvals", %{agent_id: agent_id} do
      Application.put_env(:arbor_trust, :graduation_thresholds, %{"arbor://config" => 10})

      uri = "arbor://config/write/self/setting"

      for _ <- 1..9 do
        assert :ok = ConfirmationTracker.record_approval(agent_id, uri)
      end

      refute ConfirmationTracker.graduated?(agent_id, uri)

      assert {:graduation_suggested, "arbor://config"} =
               ConfirmationTracker.record_approval(agent_id, uri)

      assert ConfirmationTracker.graduated?(agent_id, uri)
    end

    test "critical profiles never graduate", %{agent_id: agent_id} do
      uri = "arbor://code/hot_load/module"

      for _ <- 1..20 do
        ConfirmationTracker.record_approval(agent_id, uri)
      end

      refute ConfirmationTracker.graduated?(agent_id, uri)
      assert ConfirmationTracker.threshold_for("arbor://code/hot_load") == :never
    end
  end

  # ===========================================================================
  # Graduation suggestion signal
  # ===========================================================================

  describe "graduation_suggested signal" do
    test "emits graduation_suggested on first graduation", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      # Record enough to graduate
      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      result = ConfirmationTracker.record_approval(agent_id, uri)

      assert {:graduation_suggested, "arbor://code/write"} = result
    end

    test "does not emit again after already graduated", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      {:graduation_suggested, _} = ConfirmationTracker.record_approval(agent_id, uri)

      # Subsequent approvals don't re-suggest
      assert :ok = ConfirmationTracker.record_approval(agent_id, uri)
      assert :ok = ConfirmationTracker.record_approval(agent_id, uri)
    end

    test "re-suggests after rejection and re-graduation", %{agent_id: agent_id} do
      uri = "arbor://code/write/#{agent_id}/impl/file.ex"

      # Graduate
      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)
      {:graduation_suggested, _} = ConfirmationTracker.record_approval(agent_id, uri)

      # Reject (reverts graduation)
      ConfirmationTracker.record_rejection(agent_id, uri)

      # Re-graduate — should suggest again
      ConfirmationTracker.record_approval(agent_id, uri)
      ConfirmationTracker.record_approval(agent_id, uri)

      assert {:graduation_suggested, "arbor://code/write"} =
               ConfirmationTracker.record_approval(agent_id, uri)
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
