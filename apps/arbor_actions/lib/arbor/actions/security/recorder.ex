defmodule Arbor.Actions.Security.Recorder do
  @moduledoc """
  Shared recording for Security Sentinel findings — used by both the per-file
  `StaticScan` and the cross-file `WholeTreeScan`.

  Routes each finding through the status-aware `FindingStore` and emits a
  `security.sentinel_finding` signal only for genuinely NEW or REGRESSED
  findings (suppressed/refreshed ones stay quiet), then builds a uniform
  summary including the outcome breakdown.
  """

  alias Arbor.Actions.Security.FindingStore
  alias Arbor.Contracts.Security.Finding

  @type summary :: %{
          total: non_neg_integer(),
          by_category: %{optional(atom()) => non_neg_integer()},
          by_severity: %{optional(atom()) => non_neg_integer()},
          by_outcome: %{optional(atom()) => non_neg_integer()},
          recorded_to: String.t() | nil
        }

  @doc "Records one finding (FindingStore + signal). Returns the store outcome."
  @spec record(Finding.t(), String.t()) :: FindingStore.record_outcome()
  def record(%Finding{} = finding, dir) do
    outcome = FindingStore.record(finding, dir)

    case outcome do
      {:recorded, f} -> emit_signal(f, Path.join(dir, f.id <> ".md"))
      {:reopened, f} -> emit_signal(f, Path.join(dir, f.id <> ".md"))
      _suppressed_or_updated -> :ok
    end

    outcome
  end

  @doc """
  Records all findings (when `record?`) and returns `{outcomes, summary}`.
  """
  @spec record_all([Finding.t()], boolean(), String.t()) ::
          {[FindingStore.record_outcome()], summary()}
  def record_all(findings, record?, dir) do
    outcomes = if record?, do: Enum.map(findings, &record(&1, dir)), else: []
    {outcomes, summarize(findings, outcomes, record?, dir)}
  end

  @doc "Builds a uniform summary from findings + their record outcomes."
  @spec summarize([Finding.t()], [tuple()], boolean(), String.t()) :: summary()
  def summarize(findings, outcomes, record?, dir) do
    %{
      total: length(findings),
      by_category: count_by(findings, & &1.category),
      by_severity: count_by(findings, &(&1.severity[:level] || :unknown)),
      by_outcome: count_by(outcomes, &elem(&1, 0)),
      recorded_to: if(record?, do: dir)
    }
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp emit_signal(finding, path) do
    if Code.ensure_loaded?(Arbor.Signals) and function_exported?(Arbor.Signals, :emit, 4) do
      apply(Arbor.Signals, :emit, [
        :security,
        :sentinel_finding,
        %{
          id: finding.id,
          category: finding.category,
          severity: finding.severity[:level],
          file: finding.location[:file],
          line: finding.location[:line],
          path: path
        },
        []
      ])
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp count_by(items, fun) do
    items |> Enum.group_by(fun) |> Map.new(fn {k, v} -> {k, length(v)} end)
  end
end
