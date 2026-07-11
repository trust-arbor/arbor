defmodule Arbor.Orchestrator.Eval.Metrics do
  @moduledoc """
  Compatibility wrapper for `Arbor.Eval.Metrics`.
  """

  @doc "Computes a named metric over a list of result maps."
  @spec compute(String.t(), [map()], keyword()) :: float()
  defdelegate compute(name, results, opts), to: Arbor.Eval.Metrics

  @doc "Returns all known metric names."
  @spec known_metrics() :: [String.t()]
  defdelegate known_metrics(), to: Arbor.Eval.Metrics
end
