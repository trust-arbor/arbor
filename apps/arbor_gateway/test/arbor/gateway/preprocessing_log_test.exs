defmodule Arbor.Gateway.PreprocessingLogTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Gateway.PreprocessingLog

  setup do
    if Process.whereis(PreprocessingLog) do
      GenServer.stop(PreprocessingLog)
      Process.sleep(10)
    end

    if :ets.whereis(:arbor_preprocessing_log) != :undefined do
      :ets.delete(:arbor_preprocessing_log)
    end

    {:ok, pid} = PreprocessingLog.start_link()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    :ok
  end

  describe "record/1" do
    test "records an entry and returns id" do
      assert {:ok, id} =
               PreprocessingLog.record(%{
                 prompt_hash: "abc123",
                 classification: %{overall_sensitivity: :public},
                 outcome: :pending
               })

      assert is_binary(id)
      assert String.starts_with?(id, "preproc_")
    end

    test "recorded entry can be retrieved" do
      {:ok, id} =
        PreprocessingLog.record(%{
          prompt_hash: "abc123",
          classification: %{overall_sensitivity: :confidential},
          intent: %{goal: "deploy"},
          outcome: :pending
        })

      assert {:ok, entry} = PreprocessingLog.get(id)
      assert entry.prompt_hash == "abc123"
      assert entry.intent.goal == "deploy"
      assert entry.outcome == :pending
      assert %DateTime{} = entry.timestamp
    end
  end

  describe "update/2" do
    test "updates an existing entry" do
      {:ok, id} = PreprocessingLog.record(%{outcome: :pending})

      assert :ok =
               PreprocessingLog.update(id, %{
                 outcome: :success,
                 duration_ms: 1500,
                 verification_results: [%{passed: true}]
               })

      {:ok, entry} = PreprocessingLog.get(id)
      assert entry.outcome == :success
      assert entry.duration_ms == 1500
      assert length(entry.verification_results) == 1
    end

    test "returns error for missing entry" do
      assert {:error, :not_found} = PreprocessingLog.update("nonexistent", %{outcome: :success})
    end
  end

  describe "get/1" do
    test "returns error for missing entry" do
      assert {:error, :not_found} = PreprocessingLog.get("nonexistent")
    end
  end

  describe "recent/1" do
    test "returns entries newest first" do
      {:ok, _} =
        PreprocessingLog.record(%{prompt_hash: "first", timestamp: ~U[2026-01-01 00:00:00Z]})

      {:ok, _} =
        PreprocessingLog.record(%{prompt_hash: "second", timestamp: ~U[2026-01-02 00:00:00Z]})

      {:ok, _} =
        PreprocessingLog.record(%{prompt_hash: "third", timestamp: ~U[2026-01-03 00:00:00Z]})

      entries = PreprocessingLog.recent(limit: 3)
      hashes = Enum.map(entries, & &1.prompt_hash)

      assert hashes == ["third", "second", "first"]
    end

    test "respects limit" do
      for i <- 1..5 do
        PreprocessingLog.record(%{prompt_hash: "hash_#{i}"})
      end

      assert length(PreprocessingLog.recent(limit: 2)) == 2
    end

    test "returns empty list when no entries" do
      assert PreprocessingLog.recent() == []
    end
  end

  describe "stats/0" do
    test "returns zeroed stats when empty" do
      stats = PreprocessingLog.stats()
      assert stats.total == 0
      assert stats.success_rate == 0.0
    end

    test "computes stats from entries" do
      PreprocessingLog.record(%{
        classification: %{overall_sensitivity: :public},
        outcome: :success,
        duration_ms: 100
      })

      PreprocessingLog.record(%{
        classification: %{overall_sensitivity: :confidential},
        outcome: :failure,
        duration_ms: 200
      })

      PreprocessingLog.record(%{
        classification: %{overall_sensitivity: :public},
        outcome: :success,
        duration_ms: 150
      })

      stats = PreprocessingLog.stats()
      assert stats.total == 3
      assert stats.success_rate == 2 / 3
      assert stats.avg_duration_ms == 150
      assert stats.by_outcome[:success] == 2
      assert stats.by_outcome[:failure] == 1
      assert stats.by_sensitivity[:public] == 2
      assert stats.by_sensitivity[:confidential] == 1
    end
  end

  describe "similar/1" do
    test "finds entries with matching prompt hash" do
      PreprocessingLog.record(%{prompt_hash: "deploy_abc", outcome: :success})
      PreprocessingLog.record(%{prompt_hash: "deploy_abc", outcome: :failure})
      PreprocessingLog.record(%{prompt_hash: "other_xyz", outcome: :success})

      similar = PreprocessingLog.similar("deploy_abc")
      assert length(similar) == 2
      assert Enum.all?(similar, &(&1.prompt_hash == "deploy_abc"))
    end

    test "returns empty for no matches" do
      assert PreprocessingLog.similar("nonexistent") == []
    end
  end

  describe "full pipeline integration" do
    test "classify → extract → verify → log" do
      alias Arbor.Gateway.{PromptClassifier, VerificationPlan}

      prompt = "check that mix.exs exists"
      prompt_hash = :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)

      # Phase 1: Classify
      classification = PromptClassifier.classify(prompt)

      # Phase 2: Intent (mock since no LLM)
      intent = %{
        goal: "Verify mix.exs exists",
        success_criteria: ["mix.exs exists"],
        constraints: [],
        resources: ["mix.exs"],
        risk_level: :low
      }

      # Phase 3: Verification plan
      plan = VerificationPlan.from_intent(intent)
      results = VerificationPlan.execute(plan)

      # Phase 4: Log
      start_time = System.monotonic_time(:millisecond)
      Process.sleep(1)
      duration = System.monotonic_time(:millisecond) - start_time

      outcome = if VerificationPlan.all_passed?(results), do: :success, else: :failure

      {:ok, id} =
        PreprocessingLog.record(%{
          prompt_hash: prompt_hash,
          classification: classification,
          intent: intent,
          verification_results: results,
          duration_ms: duration,
          outcome: outcome
        })

      {:ok, entry} = PreprocessingLog.get(id)
      assert entry.outcome == :success
      assert entry.classification.overall_sensitivity == :public
      assert entry.intent.goal =~ "mix.exs"
    end
  end
end
