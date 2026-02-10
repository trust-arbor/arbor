defmodule Arbor.Orchestrator.Validation.Diagnostic do
  @moduledoc false

  @type severity :: :error | :warning | :info

  @type t :: %__MODULE__{
          rule: String.t(),
          severity: severity(),
          message: String.t(),
          node_id: String.t() | nil,
          edge: {String.t(), String.t()} | nil,
          fix: String.t() | nil
        }

  defstruct [:rule, :severity, :message, :node_id, :edge, :fix]

  @spec error(String.t(), String.t(), keyword()) :: t()
  def error(rule, message, opts \\ []) do
    %__MODULE__{
      rule: rule,
      severity: :error,
      message: message,
      node_id: Keyword.get(opts, :node_id),
      edge: Keyword.get(opts, :edge),
      fix: Keyword.get(opts, :fix)
    }
  end

  @spec warning(String.t(), String.t(), keyword()) :: t()
  def warning(rule, message, opts \\ []) do
    %__MODULE__{
      rule: rule,
      severity: :warning,
      message: message,
      node_id: Keyword.get(opts, :node_id),
      edge: Keyword.get(opts, :edge),
      fix: Keyword.get(opts, :fix)
    }
  end
end
