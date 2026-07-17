defmodule Arbor.Actions.Coding.SubmitReviewReportTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions
  alias Arbor.Actions.Coding.SubmitReviewReport

  @moduletag :fast

  describe "discovery and canonical URI" do
    test "registered under coding with exact review/submit URI" do
      assert SubmitReviewReport in Actions.list_actions().coding
      assert {:ok, SubmitReviewReport} = Actions.name_to_module("coding_submit_review_report")

      assert Actions.canonical_uri_for(SubmitReviewReport, %{}) ==
               "arbor://action/coding/review/submit"

      assert SubmitReviewReport.name() == "coding_submit_review_report"
      assert SubmitReviewReport.effect_class() == :read
    end
  end

  describe "run/2 schema-bounded result" do
    test "returns canonical JSON-clean three-field report" do
      params = %{
        "vote" => "approve",
        "finding_updates" => [],
        "new_findings" => [
          %{
            "title" => "Nil guard missing",
            "required_action" => "Add a nil check",
            "severity" => "major",
            "anchor" => %{"path" => "lib/a.ex", "side" => "new", "line" => 12},
            "evidence" => "line 12 pattern matches without nil"
          }
        ]
      }

      assert {:ok, report} = SubmitReviewReport.run(params, %{})
      assert Map.keys(report) |> Enum.sort() == ["finding_updates", "new_findings", "vote"]
      assert report["vote"] == "approve"
      assert report["finding_updates"] == []
      assert [finding] = report["new_findings"]
      assert finding["title"] == "Nil guard missing"
      assert finding["severity"] == "major"
      assert finding["anchor"] == %{"path" => "lib/a.ex", "side" => "new", "line" => 12}
      assert finding["evidence"] == "line 12 pattern matches without nil"
      assert Jason.encode!(report)
    end

    test "accepts atom-keyed params from schema atomization" do
      assert {:ok, report} =
               SubmitReviewReport.run(
                 %{
                   vote: "abstain",
                   finding_updates: [],
                   new_findings: []
                 },
                 %{}
               )

      assert report == %{
               "vote" => "abstain",
               "finding_updates" => [],
               "new_findings" => []
             }
    end

    test "rejects invalid vote and over-budget findings" do
      assert {:error, :invalid_vote} =
               SubmitReviewReport.run(%{"vote" => "maybe", "finding_updates" => []}, %{})

      too_many =
        for i <- 1..9 do
          %{
            "title" => "Finding #{i}",
            "required_action" => "Fix #{i}",
            "severity" => "nit",
            "anchor" => %{"path" => "lib/a.ex", "side" => "new", "line" => i}
          }
        end

      assert {:error, :too_many_findings} =
               SubmitReviewReport.run(
                 %{"vote" => "reject", "new_findings" => too_many},
                 %{}
               )
    end

    test "fail-closed: unknown keys and malformed optional values are rejected" do
      assert {:error, :invalid_report_field} =
               SubmitReviewReport.run(
                 %{"vote" => "approve", "extra" => "nope"},
                 %{}
               )

      assert {:error, :invalid_finding_update} =
               SubmitReviewReport.run(
                 %{
                   "vote" => "approve",
                   "finding_updates" => [
                     %{"id" => "f1", "state" => "fixed", "unknown" => true}
                   ]
                 },
                 %{}
               )

      assert {:error, :invalid_report_field} =
               SubmitReviewReport.run(
                 %{
                   "vote" => "approve",
                   "finding_updates" => [
                     %{"id" => "f1", "state" => "fixed", "evidence" => 123}
                   ]
                 },
                 %{}
               )

      assert {:error, :invalid_report_field} =
               SubmitReviewReport.run(
                 %{
                   "vote" => "reject",
                   "new_findings" => [
                     %{
                       "title" => "x",
                       "required_action" => "y",
                       "severity" => "major",
                       "anchor" => %{"path" => "lib/a.ex", "side" => "new", "line" => 1},
                       "state" => "open"
                     }
                   ]
                 },
                 %{}
               )
    end

    test "fail-closed: runtime validation enforces byte bounds and valid UTF-8" do
      assert {:error, :invalid_report_field} =
               SubmitReviewReport.run(
                 %{
                   "vote" => "reject",
                   "new_findings" => [
                     %{
                       "title" => String.duplicate("x", 513),
                       "required_action" => "fix it",
                       "severity" => "major",
                       "anchor" => %{"path" => "lib/a.ex", "side" => "new", "line" => 1}
                     }
                   ]
                 },
                 %{}
               )

      assert {:error, :invalid_report_field} =
               SubmitReviewReport.run(
                 %{
                   "vote" => "reject",
                   "new_findings" => [
                     %{
                       "title" => "invalid path",
                       "required_action" => "fix it",
                       "severity" => "major",
                       "anchor" => %{
                         "path" => String.duplicate("x", 1_025),
                         "side" => "new",
                         "line" => 1
                       }
                     }
                   ]
                 },
                 %{}
               )

      assert {:error, :invalid_report_field} =
               SubmitReviewReport.run(
                 %{
                   "vote" => "approve",
                   "finding_updates" => [
                     %{"id" => "f1", "state" => "fixed", "evidence" => <<255>>}
                   ]
                 },
                 %{}
               )
    end

    test "fail-closed: atom and string aliases cannot duplicate one logical key" do
      assert {:error, :invalid_report_field} =
               SubmitReviewReport.run(
                 %{"vote" => "approve", vote: "reject"},
                 %{}
               )

      assert {:error, :invalid_new_finding} =
               SubmitReviewReport.run(
                 %{
                   "vote" => "reject",
                   "new_findings" => [
                     %{
                       "title" => "duplicate",
                       :title => "shadowed",
                       "required_action" => "fix it",
                       "severity" => "major",
                       "anchor" => %{"path" => "lib/a.ex", "side" => "new", "line" => 1}
                     }
                   ]
                 },
                 %{}
               )
    end
  end

  describe "tool schema" do
    test "to_tool exposes closed report parameters" do
      tool = SubmitReviewReport.to_tool()
      assert tool.name == "coding_submit_review_report"
      schema = tool.parameters_schema
      assert is_map(schema)
      # Root should not accept unknown report fields.
      assert Map.get(schema, :additionalProperties) == false or
               Map.get(schema, "additionalProperties") == false
    end
  end
end
