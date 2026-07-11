defmodule Arbor.Eval.ReportTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Eval.Report

  @results [
    %{"id" => "pass", "expected" => "same", "actual" => "same", "passed" => true},
    %{"id" => "fail", "expected" => "expected", "actual" => "actual", "passed" => false}
  ]
  @metrics %{"accuracy" => 0.5}

  test "formats the established terminal report" do
    assert Report.format(@results, @metrics, "terminal") == """
           === Evaluation Report ===
           Samples: 2 | Passed: 1 | Failed: 1

           Metrics:
             accuracy: 0.5

           Top Failures:
             - fail: expected=expected actual=actual
           """

    assert Report.format(@results, @metrics, "unknown") ==
             Report.format(@results, @metrics, "terminal")
  end

  test "formats the established Markdown report" do
    assert Report.format(@results, @metrics, "markdown") == """
           # Evaluation Report

           **Samples:** 2 total, 1 passed, 1 failed

           ## Metrics

           | Metric | Value |
           |--------|-------|
           | accuracy | 0.5 |

           ## Top Failures

           - **fail**: expected=`expected` actual=`actual`
           """
  end

  test "formats JSON with the established payload shape" do
    report = Report.format(@results, @metrics, "json")

    assert Jason.decode!(report) == %{"results" => @results, "metrics" => @metrics}
    assert report == Jason.encode!(%{"results" => @results, "metrics" => @metrics}, pretty: true)
  end
end
