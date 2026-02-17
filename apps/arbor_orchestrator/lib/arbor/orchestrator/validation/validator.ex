defmodule Arbor.Orchestrator.Validation.Validator do
  @moduledoc """
  Built-in validator/linter for Attractor graph rules.

  Uses modular `LintRule` behaviour modules for each validation check.
  Rules can be selectively included or excluded via `validate/2` opts.
  """

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Validation.Rules

  defmodule ValidationError do
    defexception [:diagnostics, message: "Pipeline validation failed"]
  end

  @default_rules [
    Rules.StartNode,
    Rules.TerminalNode,
    Rules.StartNoIncoming,
    Rules.ExitNoOutgoing,
    Rules.EdgeTargetExists,
    Rules.Reachability,
    Rules.ConditionSyntax,
    Rules.RetryTargetExists,
    Rules.GoalGateRetry,
    Rules.CodergenPrompt
  ]

  @doc """
  Validate a graph using all default rules.
  """
  @spec validate(Graph.t()) :: [Arbor.Orchestrator.Validation.Diagnostic.t()]
  def validate(%Graph{} = graph), do: validate(graph, [])

  @doc """
  Validate a graph with options.

  ## Options

    * `:rules` - override the default rule list with a custom list of rule modules
    * `:exclude` - list of rule name strings to skip (e.g., `["codergen_prompt"]`)
  """
  @spec validate(Graph.t(), keyword()) :: [Arbor.Orchestrator.Validation.Diagnostic.t()]
  def validate(%Graph{} = graph, opts) do
    rules = Keyword.get(opts, :rules, @default_rules)
    exclude = Keyword.get(opts, :exclude, []) |> MapSet.new()

    rules
    |> Enum.reject(fn rule -> MapSet.member?(exclude, rule.name()) end)
    |> Enum.flat_map(fn rule -> rule.validate(graph) end)
  end

  @spec validate_or_error(Graph.t()) ::
          :ok | {:error, [Arbor.Orchestrator.Validation.Diagnostic.t()]}
  def validate_or_error(%Graph{} = graph) do
    diagnostics = validate(graph)

    if Enum.any?(diagnostics, &(&1.severity == :error)) do
      {:error, diagnostics}
    else
      :ok
    end
  end

  @spec validate_or_raise(Graph.t()) :: :ok
  def validate_or_raise(%Graph{} = graph) do
    case validate_or_error(graph) do
      :ok ->
        :ok

      {:error, diagnostics} ->
        raise ValidationError, diagnostics: diagnostics
    end
  end
end
