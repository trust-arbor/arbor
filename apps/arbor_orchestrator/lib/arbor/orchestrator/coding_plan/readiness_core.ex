defmodule Arbor.Orchestrator.CodingPlan.ReadinessCore do
  @moduledoc false

  alias Arbor.Contracts.Coding.{Diagnostic, ReadinessReport}

  @sha256_prefix "sha256:"

  @doc false
  def plan_digest(plan_map) when is_map(plan_map) do
    @sha256_prefix <> (plan_map |> canonical_json() |> Jason.encode!() |> sha256())
  end

  @doc false
  def report(plan_digest, observed_at, diagnostics, opts \\ []) do
    {:ok, report} =
      ReadinessReport.new(%{
        version: ReadinessReport.schema_version(),
        status: readiness_status(diagnostics),
        plan_digest: plan_digest,
        observed_at: observed_at,
        diagnostics: Enum.map(diagnostics, &Diagnostic.to_map/1),
        expires_at: Keyword.get(opts, :expires_at)
      })

    {:ok, ReadinessReport.to_map(report)}
  end

  @doc false
  def diagnostic(gate_id, phase, decision, code, observed_at, message, remediation) do
    {:ok, diagnostic} =
      Diagnostic.new(
        version: Diagnostic.schema_version(),
        gate_id: gate_id,
        phase: phase,
        decision: decision,
        code: code,
        observed_at: observed_at,
        message: message,
        remediation: remediation
      )

    diagnostic
  end

  @doc false
  def sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp readiness_status(diagnostics) do
    decisions = Enum.map(diagnostics, & &1.decision)

    cond do
      "blocked" in decisions -> "blocked"
      Enum.any?(decisions, &(&1 in ["degraded", "unavailable"])) -> "degraded"
      true -> "ready"
    end
  end

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, nested} -> {key, canonical_json(nested)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonical_json(value) when is_list(value), do: Enum.map(value, &canonical_json/1)
  defp canonical_json(value), do: value
end
