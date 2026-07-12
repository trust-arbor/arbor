defmodule Arbor.Commands.CodingBenchmark.LegacyAdapter do
  @moduledoc """
  Trusted production adapter for the legacy coding executor.

  The principal is read from `:arbor_commands, :coding_benchmark_principal_id`.
  Tests may replace the executor only through the trusted
  `:coding_benchmark_legacy_executor_module` Application setting.
  """

  alias Arbor.Agent.Orchestration.LegacyCodingTaskExecutor
  alias Arbor.Commands.CodingBenchmark.Adapter

  @doc "Run one closed benchmark request through the legacy executor."
  @spec run(map()) :: {:ok, map()} | {:error, term()} | {:error, term(), map()}
  def run(request) do
    Adapter.run(
      request,
      "legacy",
      LegacyCodingTaskExecutor,
      :coding_benchmark_legacy_executor_module
    )
  end
end
