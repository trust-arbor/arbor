defmodule Arbor.Commands.CodingBenchmark.LegacyAdapter do
  @moduledoc """
  Trusted production adapter for the legacy coding executor.

  The principal is read from `:arbor_commands, :coding_benchmark_principal_id`.
  Tests may replace the executor only through the trusted
  `:coding_benchmark_legacy_executor_module` Application setting.
  Workspace roots and the execution timeout use the required trusted benchmark
  runtime configuration documented by `Arbor.Commands.CodingBenchmark.run/2`.
  """

  alias Arbor.Agent
  alias Arbor.Commands.CodingBenchmark.Adapter

  @doc "Run one closed benchmark request through the legacy executor."
  @spec run(map()) :: {:ok, map()} | {:error, term()} | {:error, term(), map()}
  def run(request) do
    Adapter.run(
      request,
      "legacy",
      &Agent.run_legacy_coding_task/3,
      :coding_benchmark_legacy_executor_module
    )
  end

  @doc "Report or invoke the configured legacy executor's explicit cancellation support."
  @spec cancel(map()) :: :ok | {:ok, term()} | {:error, term()}
  def cancel(request) do
    Adapter.cancel(
      request,
      "legacy",
      &Agent.run_legacy_coding_task/3,
      :coding_benchmark_legacy_executor_module,
      :unsupported
    )
  end
end
