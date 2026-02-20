defmodule Arbor.Orchestrator.Graph.Edge do
  @moduledoc false

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
          # Typed fields populated from attrs via from_attrs/3
          condition: String.t() | nil,
          label: String.t() | nil,
          weight: non_neg_integer() | nil,
          fidelity: String.t() | nil,
          thread_id: String.t() | nil,
          loop_restart: boolean(),
          # IR compilation fields (nil until Compiler.compile/1 enriches them)
          parsed_condition: parsed_condition() | nil,
          source_classification: data_class() | nil,
          target_classification: data_class() | nil
        }

  defstruct from: "",
            to: "",
            attrs: %{},
            condition: nil,
            label: nil,
            weight: nil,
            fidelity: nil,
            thread_id: nil,
            loop_restart: false,
            parsed_condition: nil,
            source_classification: nil,
            target_classification: nil

  @known_attrs ~w(condition label weight fidelity thread_id loop_restart)

  @doc "List of attribute keys that have typed struct fields."
  @spec known_attrs() :: [String.t()]
  def known_attrs, do: @known_attrs

  @doc "Populate typed fields from the attrs map."
  @spec from_attrs(String.t(), String.t(), map()) :: t()
  def from_attrs(from, to, attrs) when is_map(attrs) do
    %__MODULE__{
      from: from,
      to: to,
      attrs: attrs,
      condition: Map.get(attrs, "condition"),
      label: Map.get(attrs, "label"),
      weight: parse_weight(Map.get(attrs, "weight")),
      fidelity: Map.get(attrs, "fidelity"),
      thread_id: Map.get(attrs, "thread_id"),
      loop_restart: truthy?(Map.get(attrs, "loop_restart", false))
    }
  end

  @spec attr(t(), String.t() | atom(), term()) :: term()
  def attr(edge, key, default \\ nil)

  def attr(%__MODULE__{attrs: attrs}, key, default) when is_atom(key) do
    attr(%__MODULE__{attrs: attrs}, Atom.to_string(key), default)
  end

  def attr(%__MODULE__{attrs: attrs}, key, default) when is_binary(key) do
    Map.get(attrs, key, default)
  end

  @doc "Returns true if this edge is unconditional (always taken)."
  @spec unconditional?(t()) :: boolean()
  def unconditional?(%__MODULE__{parsed_condition: nil}), do: true
  def unconditional?(%__MODULE__{parsed_condition: {:always, true}}), do: true
  def unconditional?(_), do: false

  @doc "Returns true if this is a success-path edge."
  @spec success_path?(t()) :: boolean()
  def success_path?(%__MODULE__{parsed_condition: {:eq, "outcome", "success"}}), do: true
  def success_path?(%__MODULE__{parsed_condition: {:eq, "status", "success"}}), do: true
  def success_path?(_), do: false

  @doc "Returns true if this is a failure-path edge."
  @spec failure_path?(t()) :: boolean()
  def failure_path?(%__MODULE__{parsed_condition: {:eq, "outcome", "fail"}}), do: true
  def failure_path?(%__MODULE__{parsed_condition: {:eq, "status", "fail"}}), do: true
  def failure_path?(_), do: false

  @doc "Parse a condition string into a typed condition."
  @spec parse_condition(String.t() | nil) :: parsed_condition() | nil
  def parse_condition(nil), do: nil
  def parse_condition(""), do: nil

  def parse_condition(condition) when is_binary(condition) do
    condition = String.trim(condition)

    if String.contains?(condition, "&&") do
      clauses =
        condition
        |> String.split("&&")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&parse_single_clause/1)

      {:and, clauses}
    else
      parse_single_clause(condition)
    end
  end

  defp parse_single_clause(condition) do
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

  # -- Private helpers --

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  defp parse_weight(nil), do: nil

  defp parse_weight(val) when is_integer(val), do: val

  defp parse_weight(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_weight(_), do: nil
end
