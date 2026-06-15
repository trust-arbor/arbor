defmodule Arbor.Orchestrator.Validation.Rules.LlmSimulate do
  @moduledoc """
  Run-blocking enforcement of the require-explicit-`simulate=` gate.

  `IR.Compiler` already attaches an `:error` schema-error to any LLM-routed node
  (a `type="llm"` node, a `compute` node with `purpose="llm"`/default, or a
  bare-prompt `codergen` node) that omits `simulate=`. But the structural
  `Validation.Validator` — what `Arbor.Orchestrator.run/2` and the `Engine` gate on
  via `validate_or_error/1` — does NOT read IR schema-errors, so without this rule a
  bare LLM node would only fail at RUNTIME (mid-execution, after earlier nodes'
  side effects had already landed).

  This rule promotes that existing IR schema-error into a structural `:error`
  diagnostic, so the graph is rejected BEFORE any node executes (atomic fail-fast,
  no partial side effects). It reuses `IR.Compiler`'s exact node classification
  (reading `node.schema_errors`) rather than re-deriving "is this an LLM node?",
  so the two layers can't drift. The run path always hands `validate_or_error/1` a
  compiled graph (`Arbor.Orchestrator.ensure_graph/2` always compiles), so the
  schema-errors are populated; an uncompiled graph simply yields no diagnostics
  here and falls back to the runtime fail-loud.
  """
  @behaviour Arbor.Orchestrator.Validation.LintRule

  alias Arbor.Orchestrator.Validation.Diagnostic

  @impl true
  def name, do: "llm_simulate"

  @impl true
  def validate(graph) do
    graph.nodes
    |> Map.values()
    |> Enum.flat_map(fn node ->
      node.schema_errors
      |> Enum.filter(&simulate_error?/1)
      |> Enum.map(fn {_severity, message} ->
        Diagnostic.error("llm_simulate", "#{node.id}: #{message}", node_id: node.id)
      end)
    end)
  end

  # Match the IR.Compiler simulate gate's error (see validate_simulate_explicit/2).
  defp simulate_error?({:error, message}) when is_binary(message),
    do: String.contains?(message, "explicit simulate=")

  defp simulate_error?(_), do: false
end
