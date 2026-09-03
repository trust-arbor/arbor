defmodule Arbor.Actions.Coding.DesignConformanceSeatTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.ReviewLedgerCore
  alias Arbor.Contracts.Consensus.CodeReviewRequest

  @moduletag :fast

  @promise "caller-only show/1 and dry-run output matches today's literals exactly"

  @diff """
  diff --git a/apps/arbor_security/test/arbor/security/capability_test.exs b/apps/arbor_security/test/arbor/security/capability_test.exs
  --- a/apps/arbor_security/test/arbor/security/capability_test.exs
  +++ b/apps/arbor_security/test/arbor/security/capability_test.exs
  @@ -10,8 +10,14 @@
  -    assert show(grant) == "grant:caller-only"
  -    assert dry_run(grant) == "dry-run:caller-only"
  +    assert show(grant) == %{
  +      principal: "caller",
  +      visibility: "grouped"
  +    }
  +    assert dry_run(grant) == %{
  +      principal: "caller",
  +      visibility: "grouped"
  +    }
  """

  test "recorded 2026-09-01 shape keeps shared prompt clean and blocks a violated promise" do
    {:ok, request} =
      CodeReviewRequest.new(%{
        diff: @diff,
        files: ["apps/arbor_security/test/arbor/security/capability_test.exs"],
        branch: "agent/grant-both-principals-v1",
        intent: "Grant both principals without rewriting goldens",
        approved_design: "Keep caller-only show/1 and dry-run output so it #{@promise}.",
        packet_constraints: [@promise],
        packet_success_criteria: ["focused tests pass"]
      })

    shared = CodeReviewRequest.prompt_text(request)
    conformance = CodeReviewRequest.prompt_conformance_text(request)

    refute shared =~ "Approved design:"
    refute shared =~ "Packet constraints:"
    assert String.starts_with?(conformance, shared)
    assert conformance =~ "Approved design:"
    assert conformance =~ @promise
    assert conformance =~ "Packet constraints:\nC1. #{@promise}"

    {:ok, ledger} = ReviewLedgerCore.new(%{})
    assert length(ledger["perspectives"]) == 11
    assert "design_conformance" in ledger["perspectives"]

    {:ok, completed} =
      ReviewLedgerCore.apply_cycle(ledger, 1, %{
        "design_conformance" =>
          report("reject",
            new_findings: [
              %{
                "severity" => "blocking",
                "title" => "Rewrote caller-only show/1 and dry-run goldens",
                "required_action" => @promise,
                "anchor" => %{
                  "path" => "apps/arbor_security/test/arbor/security/capability_test.exs",
                  "side" => "new",
                  "line" => 12
                }
              }
            ]
          )
      })

    finding = completed["findings"] |> Map.values() |> hd()
    assert finding["blocks_merge"] == true
    assert finding["required_action"] == @promise
    assert finding["owner"] == "design_conformance"

    decision = ReviewLedgerCore.decision(completed)
    assert decision["disposition"] == "rework"

    assert Enum.any?(decision["blocking_reasons"], fn reason ->
             reason["id"] == finding["id"]
           end)
  end

  test "missing design reports the sentinel and still blocks on a packet constraint" do
    {:ok, with_design} =
      CodeReviewRequest.new(%{
        diff: @diff,
        files: ["apps/arbor_security/test/arbor/security/capability_test.exs"],
        branch: "agent/grant-both-principals-v1",
        intent: "Grant both principals",
        approved_design: "Keep the goldens unchanged.",
        packet_constraints: [@promise]
      })

    {:ok, request} =
      CodeReviewRequest.new(%{
        diff: @diff,
        files: ["apps/arbor_security/test/arbor/security/capability_test.exs"],
        branch: "agent/grant-both-principals-v1",
        intent: "Grant both principals",
        packet_constraints: [@promise]
      })

    shared = CodeReviewRequest.prompt_text(request)
    assert shared == CodeReviewRequest.prompt_text(with_design)
    refute shared =~ "no approved design; constraints only"

    conformance = CodeReviewRequest.prompt_conformance_text(request)
    assert conformance =~ "Approved design:\nno approved design; constraints only"
    assert conformance =~ "C1. #{@promise}"

    {:ok, ledger} = ReviewLedgerCore.new(%{})

    {:ok, blocked} =
      ReviewLedgerCore.apply_cycle(ledger, 1, %{
        "design_conformance" =>
          report("reject",
            new_findings: [
              %{
                "severity" => "blocking",
                "title" => "Packet constraint C1 violated",
                "required_action" => "C1. #{@promise}",
                "anchor" => %{
                  "path" => "apps/arbor_security/test/arbor/security/capability_test.exs",
                  "side" => "new",
                  "line" => 12
                }
              }
            ]
          )
      })

    finding = blocked["findings"] |> Map.values() |> hd()
    assert finding["blocks_merge"] == true
    assert ReviewLedgerCore.decision(blocked)["disposition"] == "rework"

    {:ok, abstained} =
      ReviewLedgerCore.apply_cycle(ledger, 1, %{
        "design_conformance" => report("abstain")
      })

    abstain_decision = ReviewLedgerCore.decision(abstained)
    refute abstain_decision["disposition"] == "rework"
    assert abstain_decision["vote_counts"]["abstain"] == 11
  end

  test "sanitize admits eleven reviewer outcomes and wipes twelve" do
    eleven =
      Map.new(1..11, fn index ->
        {"reviewer-#{index}", %{"status" => "reported", "effective_vote" => "abstain"}}
      end)

    assert map_size(Arbor.Consensus.sanitize_reviewer_outcomes(eleven)) == 11

    assert Arbor.Consensus.sanitize_reviewer_outcomes(Map.put(eleven, "reviewer-12", %{})) ==
             %{}
  end

  test "not-checkable stays out of the ledger and one-owner silent scope is nonbinding" do
    {:ok, ledger} = ReviewLedgerCore.new(%{})

    {:ok, completed} =
      ReviewLedgerCore.apply_cycle(ledger, 1, %{
        "design_conformance" =>
          report("approve",
            new_findings: [
              %{
                "severity" => "major",
                "title" => "Silent scope beyond the approved design",
                "required_action" => "Remove the extra grouped-format helper",
                "anchor" => %{
                  "path" => "apps/arbor_security/test/arbor/security/capability_test.exs",
                  "side" => "new",
                  "line" => 20
                }
              }
            ]
          )
      })

    findings = Map.values(completed["findings"])
    refute Enum.any?(findings, fn finding -> finding["title"] =~ "not-checkable" end)
    refute Enum.any?(findings, & &1["blocks_merge"])
    assert ReviewLedgerCore.decision(completed)["disposition"] != "rework"
  end

  defp report(vote), do: report(vote, [])

  defp report(vote, opts) do
    options = Map.new(opts, fn {key, value} -> {Atom.to_string(key), value} end)
    Map.merge(%{"vote" => vote, "finding_updates" => [], "new_findings" => []}, options)
  end
end
