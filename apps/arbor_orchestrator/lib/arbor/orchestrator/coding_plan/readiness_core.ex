defmodule Arbor.Orchestrator.CodingPlan.ReadinessCore do
  @moduledoc false

  alias Arbor.Contracts.Coding.{Diagnostic, ReadinessReport}

  @sha256_prefix "sha256:"

  @doc false
  def plan_digest(plan_map) when is_map(plan_map) do
    @sha256_prefix <> (plan_map |> canonical_json() |> Jason.encode!() |> sha256())
  end

  @doc false
  def report(plan_digest, observed_at, status, diagnostics) do
    {:ok, report} =
      ReadinessReport.new(%{
        version: ReadinessReport.schema_version(),
        status: status,
        plan_digest: plan_digest,
        observed_at: observed_at,
        diagnostics: Enum.map(diagnostics, &Diagnostic.to_map/1)
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

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, nested} -> {key, canonical_json(nested)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonical_json(value) when is_list(value), do: Enum.map(value, &canonical_json/1)
  defp canonical_json(value), do: value
end
