defmodule Arbor.Commands.CodingBenchmark.LegacyAdapter do
  @moduledoc """
  Archived compatibility adapter for the historical `legacy` benchmark axis.

  The retired legacy coding executor is no longer present in production. The
  default callback returns `:legacy_executor_removed`, while trusted tests may
  still inject an executor through `:coding_benchmark_legacy_executor_module` to
  exercise the frozen parity reports and generic adapter lifecycle machinery.

  The principal, workspace, and execution-timeout checks remain in the shared
  adapter so historical report compatibility does not weaken benchmark bounds.
  """

  alias Arbor.Commands.CodingBenchmark.Adapter

  @doc "Run one archived legacy-axis request without reviving the retired executor."
  @spec run(map()) :: {:ok, map()} | {:error, term()} | {:error, term(), map()}
  def run(request) do
    Adapter.run(
      request,
      "legacy",
      &legacy_executor_removed/3,
      :coding_benchmark_legacy_executor_module
    )
  end

  @doc "Report cancellation support for the archived legacy-axis adapter."
  @spec cancel(map()) :: :ok | {:ok, term()} | {:error, term()}
  def cancel(request) do
    Adapter.cancel(
      request,
      "legacy",
      &legacy_executor_removed/3,
      :coding_benchmark_legacy_executor_module,
      :unsupported
    )
  end

  defp legacy_executor_removed(_agent_id, _task, _context),
    do: {:error, :legacy_executor_removed}
end
