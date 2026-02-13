defmodule Arbor.Orchestrator.IR.HandlerSchema do
  @moduledoc """
  Declares the typed schema for each handler type.

  Each schema defines:
  - Required and optional attributes with their expected types
  - Capabilities the handler requires at runtime
  - Default data classification for outputs
  - Input/output port declarations for data flow analysis
  """

  @type attr_type :: :string | :integer | :float | :boolean | :number | :any
  @type data_class :: :public | :internal | :sensitive | :secret

  @type data_port :: %{
          key: String.t(),
          type: attr_type(),
          classification: data_class()
        }

  @type t :: %__MODULE__{
          handler_type: String.t(),
          required_attrs: [String.t()],
          optional_attrs: [String.t()],
          attr_types: %{String.t() => attr_type()},
          capabilities: [String.t()],
          default_classification: data_class(),
          inputs: [data_port()],
          outputs: [data_port()]
        }

  defstruct handler_type: "",
            required_attrs: [],
            optional_attrs: [],
            attr_types: %{},
            capabilities: [],
            default_classification: :public,
            inputs: [],
            outputs: []

  @doc "Returns the schema for a handler type, or a permissive default for unknown types."
  @spec for_type(String.t()) :: t()
  def for_type(handler_type) do
    Map.get(schemas(), handler_type, default_schema(handler_type))
  end

  @doc "Returns all known handler type names."
  @spec known_types() :: [String.t()]
  def known_types, do: Map.keys(schemas())

  @doc "Returns all schemas."
  @spec all() :: %{String.t() => t()}
  def all, do: schemas()

  defp schemas do
    %{
      "start" => schema("start", [], [], %{}, [], :public, [], [port("context", :any, :public)]),
      "exit" =>
        schema(
          "exit",
          [],
          ["goal_gate", "retry_target", "fallback_retry_target"],
          %{
            "goal_gate" => :boolean,
            "retry_target" => :string,
            "fallback_retry_target" => :string
          },
          [],
          :public,
          [port("context", :any, :public)],
          []
        ),
      "conditional" =>
        schema(
          "conditional",
          [],
          ["condition_key"],
          %{"condition_key" => :string},
          [],
          :public,
          [port("outcome", :any, :public)],
          [port("branch", :string, :public)]
        ),
      "tool" =>
        schema(
          "tool",
          ["tool_command"],
          ["max_retries", "retry_target", "fallback_retry_target"],
          %{
            "tool_command" => :string,
            "max_retries" => :integer,
            "retry_target" => :string,
            "fallback_retry_target" => :string
          },
          ["shell_exec"],
          :internal,
          [port("context", :any, :public)],
          [port("tool.output", :string, :internal)]
        ),
      "wait.human" =>
        schema(
          "wait.human",
          [],
          ["prompt", "question"],
          %{"prompt" => :string, "question" => :string},
          ["human_interaction"],
          :internal,
          [port("context", :any, :public)],
          [port("human.answer", :string, :internal)]
        ),
      "parallel" =>
        schema(
          "parallel",
          [],
          ["fail_fast"],
          %{"fail_fast" => :boolean},
          [],
          :public,
          [port("context", :any, :public)],
          [port("parallel.results", :any, :public)]
        ),
      "parallel.fan_in" =>
        schema(
          "parallel.fan_in",
          [],
          ["merge_strategy"],
          %{"merge_strategy" => :string},
          [],
          :public,
          [port("parallel.results", :any, :public)],
          [port("context", :any, :public)]
        ),
      "stack.manager_loop" =>
        schema(
          "stack.manager_loop",
          [],
          ["max_iterations"],
          %{"max_iterations" => :integer},
          [],
          :public,
          [port("context", :any, :public)],
          [port("context", :any, :public)]
        ),
      "codergen" =>
        schema(
          "codergen",
          ["prompt"],
          [
            "llm_model",
            "llm_provider",
            "reasoning_effort",
            "simulate",
            "score",
            "system_prompt",
            "temperature"
          ],
          %{
            "prompt" => :string,
            "llm_model" => :string,
            "llm_provider" => :string,
            "reasoning_effort" => :string,
            "simulate" => :string,
            "score" => :number,
            "system_prompt" => :string,
            "temperature" => :float
          },
          ["llm_query"],
          :internal,
          [port("context", :any, :public)],
          [port("last_response", :string, :internal)]
        ),
      "file.write" =>
        schema(
          "file.write",
          ["content_key", "output"],
          ["format", "append"],
          %{
            "content_key" => :string,
            "output" => :string,
            "format" => :string,
            "append" => :boolean
          },
          ["file_write"],
          :internal,
          [port("content_key", :string, :internal)],
          [port("file.written", :string, :internal)]
        ),
      "output.validate" =>
        schema(
          "output.validate",
          [],
          [
            "source_key",
            "format",
            "max_length",
            "min_length",
            "must_contain",
            "must_not_contain",
            "json_schema",
            "pattern",
            "action"
          ],
          %{
            "source_key" => :string,
            "format" => :string,
            "max_length" => :integer,
            "min_length" => :integer,
            "must_contain" => :string,
            "must_not_contain" => :string,
            "json_schema" => :string,
            "pattern" => :string,
            "action" => :string
          },
          [],
          :public,
          [port("source_key", :string, :public)],
          [
            port("validate.passed", :boolean, :public),
            port("validate.errors", :any, :public),
            port("validate.format", :string, :public)
          ]
        ),
      "pipeline.validate" =>
        schema(
          "pipeline.validate",
          [],
          ["source_key", "file"],
          %{"source_key" => :string, "file" => :string},
          [],
          :public,
          [port("context", :any, :public)],
          [port("pipeline.valid", :boolean, :public)]
        ),
      "pipeline.run" =>
        schema(
          "pipeline.run",
          [],
          ["source_key", "file", "workdir"],
          %{"source_key" => :string, "file" => :string, "workdir" => :string},
          [],
          :public,
          [port("context", :any, :public)],
          [port("pipeline.child_status", :string, :public)]
        ),
      "eval.dataset" =>
        schema(
          "eval.dataset",
          ["dataset"],
          ["limit", "shuffle", "seed"],
          %{
            "dataset" => :string,
            "limit" => :integer,
            "shuffle" => :boolean,
            "seed" => :integer
          },
          ["file_read"],
          :internal,
          [],
          [port("eval.dataset", :any, :internal)]
        ),
      "eval.run" =>
        schema(
          "eval.run",
          ["graders"],
          ["subject", "subject_module", "subject_function"],
          %{
            "graders" => :string,
            "subject" => :string,
            "subject_module" => :string,
            "subject_function" => :string
          },
          [],
          :internal,
          [port("eval.dataset", :any, :internal)],
          [port("eval.results", :any, :internal)]
        ),
      "eval.aggregate" =>
        schema(
          "eval.aggregate",
          [],
          ["source", "metrics", "threshold"],
          %{
            "source" => :string,
            "metrics" => :string,
            "threshold" => :float
          },
          [],
          :public,
          [port("eval.results", :any, :internal)],
          [port("eval.metrics", :any, :public)]
        ),
      "eval.report" =>
        schema(
          "eval.report",
          [],
          ["format", "output", "source", "metrics_source"],
          %{
            "format" => :string,
            "output" => :string,
            "source" => :string,
            "metrics_source" => :string
          },
          [],
          :public,
          [port("eval.results", :any, :internal), port("eval.metrics", :any, :public)],
          [port("eval.report", :string, :public)]
        )
    }
  end

  defp schema(type, required, optional, types, caps, classification, inputs, outputs) do
    %__MODULE__{
      handler_type: type,
      required_attrs: required,
      optional_attrs: optional,
      attr_types: types,
      capabilities: caps,
      default_classification: classification,
      inputs: inputs,
      outputs: outputs
    }
  end

  defp port(key, type, classification) do
    %{key: key, type: type, classification: classification}
  end

  @doc "Validates a node's attrs against its handler schema. Returns list of {severity, message} tuples."
  @spec validate_attrs(String.t(), map()) :: [{:error | :warning, String.t()}]
  def validate_attrs(handler_type, attrs) do
    schema = for_type(handler_type)

    missing_errors =
      schema.required_attrs
      |> Enum.filter(fn key ->
        value = Map.get(attrs, key)
        value in [nil, ""]
      end)
      |> Enum.map(fn key ->
        {:error, "#{handler_type} node requires attribute '#{key}'"}
      end)

    type_errors =
      attrs
      |> Enum.flat_map(fn {key, value} ->
        case Map.get(schema.attr_types, key) do
          nil -> []
          expected_type -> check_type(key, value, expected_type)
        end
      end)

    missing_errors ++ type_errors
  end

  defp check_type(_key, nil, _expected), do: []
  defp check_type(_key, _value, :any), do: []

  defp check_type(key, value, :string) when not is_binary(value),
    do: [{:warning, "Attribute '#{key}' expected string, got #{inspect(value)}"}]

  defp check_type(key, value, :integer) when not is_integer(value),
    do: [{:warning, "Attribute '#{key}' expected integer, got #{inspect(value)}"}]

  defp check_type(key, value, :float) when not is_float(value) and not is_integer(value),
    do: [{:warning, "Attribute '#{key}' expected float, got #{inspect(value)}"}]

  defp check_type(key, value, :number)
       when not is_number(value),
       do: [{:warning, "Attribute '#{key}' expected number, got #{inspect(value)}"}]

  defp check_type(key, value, :boolean) when value not in [true, false, "true", "false"],
    do: [{:warning, "Attribute '#{key}' expected boolean, got #{inspect(value)}"}]

  defp check_type(_key, _value, _type), do: []

  defp default_schema(handler_type) do
    %__MODULE__{
      handler_type: handler_type,
      required_attrs: [],
      optional_attrs: [],
      attr_types: %{},
      capabilities: [],
      default_classification: :public,
      inputs: [%{key: "context", type: :any, classification: :public}],
      outputs: [%{key: "context", type: :any, classification: :public}]
    }
  end
end
