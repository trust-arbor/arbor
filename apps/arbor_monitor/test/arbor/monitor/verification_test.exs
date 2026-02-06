defmodule Arbor.Monitor.VerificationTest do
  use ExUnit.Case, async: false

  alias Arbor.Monitor.{Fingerprint, Verification}

  # Use short soak for testing
  @test_opts [
    soak_cycles: 3,
    check_interval_ms: 50
  ]

  setup do
    start_supervised!({Verification, @test_opts})
    Verification.clear_all()
    :ok
  end

  defp make_fingerprint(skill \\ :memory, metric \\ :total_bytes) do
    Fingerprint.new(skill, metric, :above)
  end

  defp make_anomaly(skill, metric) do
    %{
      skill: skill,
      severity: :warning,
      details: %{
        metric: metric,
        value: 1_000_000,
        ewma: 800_000
      }
    }
  end

  describe "start_verification/2" do
    test "starts verification for new fingerprint" do
      fp = make_fingerprint()

      assert {:ok, verification_id} = Verification.start_verification(fp, "prop_001")
      assert String.starts_with?(verification_id, "ver_")
    end

    test "returns error if already verifying same fingerprint" do
      fp = make_fingerprint()

      assert {:ok, _} = Verification.start_verification(fp, "prop_001")
      assert {:error, :already_verifying} = Verification.start_verification(fp, "prop_002")
    end

    test "allows verification of different fingerprints" do
      fp1 = make_fingerprint(:memory, :total_bytes)
      fp2 = make_fingerprint(:ets, :table_count)

      assert {:ok, _} = Verification.start_verification(fp1, "prop_001")
      assert {:ok, _} = Verification.start_verification(fp2, "prop_002")

      assert length(Verification.list_verifying()) == 2
    end
  end

  describe "get_verification/1" do
    test "returns nil for unknown fingerprint" do
      fp = make_fingerprint(:unknown, :metric)
      assert Verification.get_verification(fp) == nil
    end

    test "returns verification record" do
      fp = make_fingerprint()
      {:ok, _} = Verification.start_verification(fp, "prop_001")

      record = Verification.get_verification(fp)

      assert record.proposal_id == "prop_001"
      assert record.cycles_remaining == 3
      assert record.outcome == :verifying
    end
  end

  describe "list_verifying/0" do
    test "returns empty list when no verifications" do
      assert Verification.list_verifying() == []
    end

    test "returns only active verifications" do
      fp1 = make_fingerprint(:memory, :total_bytes)
      fp2 = make_fingerprint(:ets, :table_count)

      {:ok, _} = Verification.start_verification(fp1, "prop_001")
      {:ok, _} = Verification.start_verification(fp2, "prop_002")

      verifying = Verification.list_verifying()
      assert length(verifying) == 2
      assert Enum.all?(verifying, &(&1.outcome == :verifying))
    end
  end

  describe "tick/0" do
    test "decrements cycle countdown" do
      fp = make_fingerprint()
      {:ok, _} = Verification.start_verification(fp, "prop_001")

      assert Verification.get_verification(fp).cycles_remaining == 3

      Verification.tick()
      assert Verification.get_verification(fp).cycles_remaining == 2

      Verification.tick()
      assert Verification.get_verification(fp).cycles_remaining == 1
    end

    test "marks verified when countdown reaches zero" do
      fp = make_fingerprint()
      {:ok, _} = Verification.start_verification(fp, "prop_001")

      # Tick 3 times (soak_cycles = 3)
      Verification.tick()
      Verification.tick()
      verified = Verification.tick()

      assert length(verified) == 1
      assert hd(verified).status == :verified
      assert hd(verified).proposal_id == "prop_001"
      assert hd(verified).soak_cycles == 3
    end

    test "returns empty list when no verifications complete" do
      fp = make_fingerprint()
      {:ok, _} = Verification.start_verification(fp, "prop_001")

      verified = Verification.tick()
      assert verified == []
    end
  end

  describe "check_recurrences/1" do
    test "marks ineffective when fingerprint recurs" do
      fp = make_fingerprint(:memory, :total_bytes)
      {:ok, _} = Verification.start_verification(fp, "prop_001")

      # Simulate recurrence with matching anomaly
      anomaly = make_anomaly(:memory, :total_bytes)
      failures = Verification.check_recurrences([anomaly])

      assert length(failures) == 1
      assert hd(failures).status == :ineffective
      assert hd(failures).proposal_id == "prop_001"
    end

    test "does not affect verification with different fingerprint" do
      fp = make_fingerprint(:memory, :total_bytes)
      {:ok, _} = Verification.start_verification(fp, "prop_001")

      # Non-matching anomaly
      anomaly = make_anomaly(:ets, :table_count)
      failures = Verification.check_recurrences([anomaly])

      assert failures == []
      assert Verification.get_verification(fp).outcome == :verifying
    end

    test "handles empty anomaly list" do
      fp = make_fingerprint()
      {:ok, _} = Verification.start_verification(fp, "prop_001")

      failures = Verification.check_recurrences([])
      assert failures == []
    end

    test "handles anomalies with missing fields" do
      fp = make_fingerprint()
      {:ok, _} = Verification.start_verification(fp, "prop_001")

      # Invalid anomaly without details
      failures = Verification.check_recurrences([%{skill: :memory}])
      assert failures == []
    end
  end

  describe "cancel_verification/1" do
    test "removes verification record" do
      fp = make_fingerprint()
      {:ok, _} = Verification.start_verification(fp, "prop_001")

      assert Verification.get_verification(fp) != nil

      Verification.cancel_verification(fp)

      assert Verification.get_verification(fp) == nil
    end
  end

  describe "stats/0" do
    test "returns correct statistics" do
      fp1 = make_fingerprint(:memory, :total_bytes)
      fp2 = make_fingerprint(:ets, :table_count)
      fp3 = make_fingerprint(:beam, :process_count)

      {:ok, _} = Verification.start_verification(fp1, "prop_001")
      {:ok, _} = Verification.start_verification(fp2, "prop_002")
      {:ok, _} = Verification.start_verification(fp3, "prop_003")

      # First, mark one as ineffective (before ticking to completion)
      anomaly = make_anomaly(:ets, :table_count)
      Verification.check_recurrences([anomaly])

      # Now tick remaining to verified
      for _ <- 1..3, do: Verification.tick()

      stats = Verification.stats()

      assert stats.active == 0
      assert stats.verified == 2
      assert stats.ineffective == 1
      assert stats.total == 3
    end
  end

  describe "signal emission" do
    test "calls signal callback on verification success" do
      test_pid = self()

      callback = fn category, event, payload ->
        send(test_pid, {:signal, category, event, payload})
      end

      stop_supervised!(Verification)

      start_supervised!(
        {Verification,
         [
           soak_cycles: 2,
           signal_callback: callback
         ]}
      )

      fp = make_fingerprint()
      {:ok, _} = Verification.start_verification(fp, "prop_001")

      Verification.tick()
      refute_receive {:signal, _, _, _}, 10

      Verification.tick()
      assert_receive {:signal, :healing, :healing_verified, payload}, 100

      assert payload.proposal_id == "prop_001"
      assert payload.soak_cycles == 2
    end

    test "calls signal callback on ineffective fix" do
      test_pid = self()

      callback = fn category, event, payload ->
        send(test_pid, {:signal, category, event, payload})
      end

      stop_supervised!(Verification)

      start_supervised!(
        {Verification,
         [
           soak_cycles: 3,
           signal_callback: callback
         ]}
      )

      fp = make_fingerprint(:memory, :total_bytes)
      {:ok, _} = Verification.start_verification(fp, "prop_001")

      anomaly = make_anomaly(:memory, :total_bytes)
      Verification.check_recurrences([anomaly])

      assert_receive {:signal, :healing, :healing_ineffective, payload}, 100

      assert payload.proposal_id == "prop_001"
      assert payload.cycles_completed == 0
    end
  end

  describe "complete soak period flow" do
    test "full verification cycle without recurrence" do
      fp = make_fingerprint()

      {:ok, _} = Verification.start_verification(fp, "prop_001")
      assert Verification.get_verification(fp).outcome == :verifying

      # Simulate 3 polling cycles with no recurrence
      Verification.check_recurrences([])
      Verification.tick()
      assert Verification.get_verification(fp).cycles_remaining == 2

      Verification.check_recurrences([])
      Verification.tick()
      assert Verification.get_verification(fp).cycles_remaining == 1

      Verification.check_recurrences([])
      verified = Verification.tick()

      assert length(verified) == 1
      assert Verification.get_verification(fp).outcome == :verified
    end

    test "verification fails mid-cycle on recurrence" do
      fp = make_fingerprint(:memory, :total_bytes)

      {:ok, _} = Verification.start_verification(fp, "prop_001")

      # Pass first cycle
      Verification.check_recurrences([])
      Verification.tick()
      assert Verification.get_verification(fp).cycles_remaining == 2

      # Recurrence on second cycle
      anomaly = make_anomaly(:memory, :total_bytes)
      failures = Verification.check_recurrences([anomaly])

      assert length(failures) == 1
      assert Verification.get_verification(fp).outcome == :ineffective
    end
  end
end
