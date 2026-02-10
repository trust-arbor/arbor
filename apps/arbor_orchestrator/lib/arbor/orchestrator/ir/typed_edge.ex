defmodule Arbor.Orchestrator.IR.TypedEdge do
  @moduledoc """
  A typed intermediate representation of a pipeline edge.

  Contains parsed condition expressions and data flow declarations
  for taint analysis.
  """

  @type parsed_condition ::
          {:eq, String.t(), String.t()}
          | {:neq, String.t(), String.t()}
          | {:gt, String.t(), String.t()}
          | {:lt, String.t(), String.t()}
          | {:gte, String.t(), String.t()}
          | {:lte, String.t(), String.t()}
          | {:contains, String.t(), String.t()}
          | {:always, true}
          | {:parse_error, String.t()}

  @type data_class :: :public | :internal | :sensitive | :secret

  @type t :: %__MODULE__{
          from: String.t(),
          to: String.t(),
          attrs: map(),
          condition: parsed_condition() | nil,
          source_classification: data_class(),
          target_classification: data_class()
        }

  defstruct from: "",
            to: "",
            attrs: %{},
            condition: nil,
            source_classification: :public,
            target_classification: :public

  @doc "Returns true if this edge is unconditional (always taken)."
  @spec unconditional?(t()) :: boolean()
  def unconditional?(%__MODULE__{condition: nil}), do: true
  def unconditional?(%__MODULE__{condition: {:always, true}}), do: true
  def unconditional?(_), do: false

  @doc "Returns true if this is a success-path edge."
  @spec success_path?(t()) :: boolean()
  def success_path?(%__MODULE__{condition: {:eq, "outcome", "success"}}), do: true
  def success_path?(%__MODULE__{condition: {:eq, "status", "success"}}), do: true
  def success_path?(_), do: false

  @doc "Returns true if this is a failure-path edge."
  @spec failure_path?(t()) :: boolean()
  def failure_path?(%__MODULE__{condition: {:eq, "outcome", "fail"}}), do: true
  def failure_path?(%__MODULE__{condition: {:eq, "status", "fail"}}), do: true
  def failure_path?(_), do: false

  @doc "Parse a condition string into a typed condition."
  @spec parse_condition(String.t() | nil) :: parsed_condition() | nil
  def parse_condition(nil), do: nil
  def parse_condition(""), do: nil

  def parse_condition(condition) when is_binary(condition) do
    condition = String.trim(condition)

    cond do
      String.contains?(condition, "!=") ->
        [field, value] = String.split(condition, "!=", parts: 2)
        {:neq, String.trim(field), String.trim(value)}

      String.contains?(condition, ">=") ->
        [field, value] = String.split(condition, ">=", parts: 2)
        {:gte, String.trim(field), String.trim(value)}

      String.contains?(condition, "<=") ->
        [field, value] = String.split(condition, "<=", parts: 2)
        {:lte, String.trim(field), String.trim(value)}

      String.contains?(condition, ">") ->
        [field, value] = String.split(condition, ">", parts: 2)
        {:gt, String.trim(field), String.trim(value)}

      String.contains?(condition, "<") ->
        [field, value] = String.split(condition, "<", parts: 2)
        {:lt, String.trim(field), String.trim(value)}

      String.contains?(condition, "=") ->
        [field, value] = String.split(condition, "=", parts: 2)
        {:eq, String.trim(field), String.trim(value)}

      String.contains?(condition, "~") ->
        [field, value] = String.split(condition, "~", parts: 2)
        {:contains, String.trim(field), String.trim(value)}

      true ->
        {:parse_error, condition}
    end
  end
end
