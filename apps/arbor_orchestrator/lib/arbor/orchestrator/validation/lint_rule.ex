defmodule Arbor.Orchestrator.Validation.LintRule do
  @moduledoc """
  Behaviour for modular graph validation rules.

  Each rule implements `name/0` (a unique string identifier) and
  `validate/1` (which returns a list of diagnostics for a given graph).
  """

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Validation.Diagnostic

  @callback name() :: String.t()
  @callback validate(Graph.t()) :: [Diagnostic.t()]
end
