defmodule Arbor.Contracts.Coding.VerificationReportTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.VerificationReport

  @moduletag :fast

  test "constructs a canonical verification report from keyword input" do
    assert VerificationReport.schema_version() == 1
    assert VerificationReport.statuses() == ~w(passed failed blocked)

    attrs = [
      version: 1,
      status: :passed,
      profile: "contract_change",
      candidate_ref: "commit:abc123",
      observed_at: "2026-07-22T12:00:00Z",
      diagnostics: [valid_diagnostic()],
      evidence_ref: "refs/arbor/evidence/verification.json"
    ]

    assert {:ok, report} = VerificationReport.new(attrs)
    assert report.status == "passed"
    assert report.diagnostics == [valid_diagnostic()]

    assert VerificationReport.to_map(report)["evidence_ref"] ==
             "refs/arbor/evidence/verification.json"

    assert {:ok, _json} = report |> VerificationReport.to_map() |> Jason.encode()
  end

  test "rejects missing, invalid, non-JSON, duplicate, and oversized values" do
    attrs = valid_attrs()

    for field <- [:version, :status, :profile, :candidate_ref, :observed_at, :diagnostics] do
      refute VerificationReport.valid?(Map.delete(attrs, field)),
             "expected #{field} to be required"
    end

    for {field, value} <- [
          {:version, 2},
          {:status, "ready"},
          {:profile, " "},
          {:candidate_ref, self()},
          {:observed_at, DateTime.utc_now()},
          {:diagnostics, [%{not: "a diagnostic"}]},
          {:evidence_ref, String.duplicate("x", 513)}
        ] do
      refute VerificationReport.valid?(Map.put(attrs, field, value)), "expected #{field} to fail"
    end

    assert {:error, {:duplicate_field, "profile"}} =
             VerificationReport.new([{:profile, "one"}, {"profile", "two"} | valid_keyword()])

    assert {:error, {:unknown_field, "authority"}} =
             VerificationReport.new(Map.put(attrs, :authority, "forbidden"))

    assert {:ok, report} = VerificationReport.new(attrs)

    assert {:error, {:invalid_verification_report, :struct_not_allowed}} =
             VerificationReport.new(report)

    refute VerificationReport.valid?(
             Map.put(attrs, :diagnostics, List.duplicate(valid_diagnostic(), 257))
           )
  end

  defp valid_attrs do
    %{
      version: 1,
      status: "failed",
      profile: "default",
      candidate_ref: "commit:abc123",
      observed_at: "2026-07-22T12:00:00Z",
      diagnostics: [valid_diagnostic()]
    }
  end

  defp valid_keyword do
    [
      version: 1,
      status: :passed,
      candidate_ref: "commit:abc123",
      observed_at: "2026-07-22T12:00:00Z",
      diagnostics: []
    ]
  end

  defp valid_diagnostic do
    %{
      "version" => 1,
      "gate_id" => "gate",
      "phase" => "validation",
      "decision" => "passed",
      "code" => "ok",
      "observed_at" => "2026-07-22T12:00:00Z"
    }
  end
end
