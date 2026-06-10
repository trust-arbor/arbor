defmodule Arbor.Persistence.VerdictLogTest do
  @moduledoc """
  Tests the pure `VerdictLog.project/2` — the shared Verdict→eval-tables
  projection used by judge, security verify-finding, and council. The write
  path (`record/2`) degrades silently without a running Repo, so the projection
  is tested directly.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Judge.Verdict
  alias Arbor.Persistence.VerdictLog

  defp verdict(attrs \\ %{}) do
    {:ok, v} =
      Verdict.new(
        Map.merge(
          %{
            overall_score: 0.8,
            recommendation: :keep,
            mode: :verification,
            dimension_scores: %{confidence: 0.9},
            weaknesses: ["one concern"],
            meta: %{source: "test", decision: :confirmed, refuted: 1, dissent: ["nope"]}
          },
          attrs
        )
      )

    v
  end

  describe "project/2" do
    test "builds linked run + result records with sensible defaults" do
      {run, result} = VerdictLog.project(verdict(), domain: "security_verify")

      assert run.domain == "security_verify"
      assert run.dataset == "security_verify"
      assert run.graders == ["security_verify"]
      assert run.sample_count == 1
      assert run.status == "completed"
      assert run.metadata["mode"] == "verification"

      # result links to the run and carries the verdict projection
      assert result.run_id == run.id
      assert result.passed == true
      assert result.scores["overall"] == 0.8
      assert result.scores["confidence"] == 0.9
      assert result.metadata["recommendation"] == "keep"
      assert result.metadata["weaknesses"] == ["one concern"]
    end

    test "passed reflects recommendation (reject → false)" do
      {_run, result} = VerdictLog.project(verdict(%{recommendation: :reject}), domain: "x")
      assert result.passed == false
    end

    test "actual is JSON-encodable and preserves meta (atom values stringified)" do
      {_run, result} = VerdictLog.project(verdict(), domain: "security_verify")

      assert {:ok, decoded} = Jason.decode(result.actual)
      assert decoded["recommendation"] == "keep"
      # meta atoms (decision: :confirmed) survive as strings
      assert decoded["meta"]["decision"] == "confirmed"
      assert decoded["meta"]["dissent"] == ["nope"]
    end

    test "domain-specific edges flow through (sample_id, input, source, metadata merge)" do
      {run, result} =
        VerdictLog.project(verdict(),
          domain: "council_decision",
          source: "council",
          sample_id: "prop_abc",
          input: "Proposal prop_abc",
          result_metadata: %{"proposal_id" => "prop_abc"}
        )

      assert run.metadata["source"] == "council"
      assert result.sample_id == "prop_abc"
      assert result.input == "Proposal prop_abc"
      assert result.metadata["proposal_id"] == "prop_abc"
      # generic metadata still present alongside the merged edge
      assert result.metadata["source"] == "council"
      assert result.metadata["recommendation"] == "keep"
    end

    test "requires :domain" do
      assert_raise KeyError, fn -> VerdictLog.project(verdict(), []) end
    end
  end

  describe "record/2 degradation" do
    test "never raises; returns :ok or {:ok, run_id} regardless of Repo state" do
      result = VerdictLog.record(verdict(), domain: "security_verify")
      assert result == :ok or match?({:ok, _}, result)
    end
  end
end
