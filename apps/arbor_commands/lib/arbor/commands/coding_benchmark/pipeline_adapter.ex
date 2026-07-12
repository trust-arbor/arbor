defmodule Arbor.Commands.CodingBenchmark.PipelineAdapter do
  @moduledoc """
  Trusted production adapter for the packaged coding pipeline executor.

  The principal is read from `:arbor_commands, :coding_benchmark_principal_id`.
  Tests may replace the executor only through the trusted
  `:coding_benchmark_pipeline_executor_module` Application setting.
  Workspace roots and the execution timeout use the required trusted benchmark
  runtime configuration documented by `Arbor.Commands.CodingBenchmark.run/2`.
  """

  alias Arbor.Commands.CodingBenchmark.Adapter
  alias Arbor.Orchestrator.CodingTaskExecutor

  @doc "Run one closed benchmark request through the pipeline executor."
  @spec run(map()) :: {:ok, map()} | {:error, term()} | {:error, term(), map()}
  def run(request) do
    Adapter.run(
      request,
      "pipeline",
      CodingTaskExecutor,
      :coding_benchmark_pipeline_executor_module
    )
  end
end
