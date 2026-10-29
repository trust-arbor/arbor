defmodule Arbor.Contracts.Coding.ReadinessReportTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.Diagnostic
  alias Arbor.Contracts.Coding.ReadinessReport

  @moduletag :fast

  test "constructs and canonicalizes nested diagnostics" do
    assert ReadinessReport.schema_version() == 1
    assert ReadinessReport.statuses() == ~w(ready degraded blocked)

    attrs = %{
      version: 1,
      status: :degraded,
      plan_digest: "sha256:plan-123",
      observed_at: "2026-07-22T12:00:00-05:00",
      diagnostics: [
        [
          version: 1,
          gate_id: "provider",
          phase: :worker_start,
          decision: :unavailable,
          code: "provider_health_unknown",
          observed_at: "2026-07-22T12:00:00Z"
        ]
      ],
      expires_at: "2026-07-22T18:00:00-05:00"
    }

    assert {:ok, report} = ReadinessReport.new(attrs)
    assert report.observed_at == "2026-07-22T17:00:00Z"
    assert report.expires_at == "2026-07-22T23:00:00Z"
    assert [%{"version" => 1, "phase" => "worker_start"}] = report.diagnostics
    refute Enum.any?(report.diagnostics, &is_struct(&1))

    assert ReadinessReport.to_map(report) == %{
             "version" => 1,
             "status" => "degraded",
             "plan_digest" => "sha256:plan-123",
             "observed_at" => "2026-07-22T17:00:00Z",
             "diagnostics" => report.diagnostics,
             "expires_at" => "2026-07-22T23:00:00Z"
           }
  end

  test "rejects invalid ordering, nested structs, aliases, unknown keys, and oversized data" do
    attrs = valid_attrs()

    assert {:error, {:invalid_field, "expires_at"}} =
             ReadinessReport.new(Map.put(attrs, :expires_at, "2026-07-22T11:59:59Z"))

    assert {:error, {:invalid_field, "diagnostics"}} =
             ReadinessReport.new(Map.put(attrs, :diagnostics, [diagnostic_struct()]))

    assert {:error, {:duplicate_field, "status"}} =
             ReadinessReport.new([{:status, :ready}, {"status", "blocked"} | valid_keyword()])

    assert {:error, {:unknown_field, "authority"}} =
             ReadinessReport.new(Map.put(attrs, :authority, "forbidden"))

    assert {:ok, report} = ReadinessReport.new(attrs)

    assert {:error, {:invalid_readiness_report, :struct_not_allowed}} =
             ReadinessReport.new(report)

    refute ReadinessReport.valid?(Map.put(attrs, :plan_digest, %{not: :json}))
    refute ReadinessReport.valid?(Map.put(attrs, :diagnostics, :not_a_list))

    oversized = Map.put(attrs, :diagnostics, List.duplicate(valid_diagnostic(), 257))
    refute ReadinessReport.valid?(oversized)
  end

  defp valid_attrs do
    %{
      version: 1,
      status: "ready",
      plan_digest: "sha256:plan-123",
      observed_at: "2026-07-22T12:00:00Z",
      diagnostics: [valid_diagnostic()]
    }
  end

  defp valid_keyword do
    [
      version: 1,
      plan_digest: "sha256:plan-123",
      observed_at: "2026-07-22T12:00:00Z",
      diagnostics: []
    ]
  end

  defp valid_diagnostic do
    %{
      "version" => 1,
      "gate_id" => "gate",
      "phase" => "preflight",
      "decision" => "passed",
      "code" => "ok",
      "observed_at" => "2026-07-22T12:00:00Z"
    }
  end

  defp diagnostic_struct do
    {:ok, diagnostic} = Diagnostic.new(valid_diagnostic())
    diagnostic
  end
end
