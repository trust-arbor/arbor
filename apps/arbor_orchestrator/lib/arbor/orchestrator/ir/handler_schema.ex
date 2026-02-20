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
          outputs: [data_port()],
          # Taint profile fields (Phase 2)
          required_sanitizations: non_neg_integer(),
          output_sanitizations: non_neg_integer(),
          wipes_sanitizations: boolean(),
          min_confidence: atom(),
          sensitivity: atom(),
          provider_constraint: atom() | nil,
          refinements: %{{String.t(), String.t()} => map()}
        }

  defstruct handler_type: "",
            required_attrs: [],
            optional_attrs: [],
            attr_types: %{},
            capabilities: [],
            default_classification: :public,
            inputs: [],
            outputs: [],
            required_sanitizations: 0,
            output_sanitizations: 0,
            wipes_sanitizations: false,
            min_confidence: :unverified,
            sensitivity: :public,
            provider_constraint: nil,
            refinements: %{}

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

  # command_injection | path_traversal bitmask
  @cmd_inj_path_trav Bitwise.bor(0b00000100, 0b00001000)
  # path_traversal bitmask
  @path_trav 0b00001000

  defp schemas do
    %{
      # ── 15 Canonical Types ──────────────────────────────────────────────
      "start" =>
        schema("start", [], [], %{}, [], :public, [], [port("context", :any, :public)],
          sensitivity: :public
        ),
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
          [],
          sensitivity: :public
        ),
      "branch" =>
        schema(
          "branch",
          [],
          ["condition_key"],
          %{"condition_key" => :string},
          [],
          :public,
          [port("outcome", :any, :public)],
          [port("branch", :string, :public)],
          sensitivity: :public
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
          [port("parallel.results", :any, :public)],
          sensitivity: :public
        ),
      "fan_in" =>
        schema(
          "fan_in",
          [],
          ["merge_strategy"],
          %{"merge_strategy" => :string},
          [],
          :public,
          [port("parallel.results", :any, :public)],
          [port("context", :any, :public)],
          sensitivity: :public
        ),
      "compute" =>
        schema(
          "compute",
          [],
          [
            "prompt",
            "purpose",
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
            "purpose" => :string,
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
          [port("last_response", :string, :internal)],
          sensitivity: :internal,
          refinements: %{
            {"purpose", "llm"} => %{wipes_sanitizations: true}
          }
        ),
      "transform" =>
        schema(
          "transform",
          [],
          ["transform_fn", "source_key", "target_key"],
          %{
            "transform_fn" => :string,
            "source_key" => :string,
            "target_key" => :string
          },
          [],
          :public,
          [port("context", :any, :public)],
          [port("context", :any, :public)],
          sensitivity: :public
        ),
      "exec" =>
        schema(
          "exec",
          [],
          ["tool_command", "target", "max_retries", "retry_target", "fallback_retry_target"],
          %{
            "tool_command" => :string,
            "target" => :string,
            "max_retries" => :integer,
            "retry_target" => :string,
            "fallback_retry_target" => :string
          },
          ["shell_exec"],
          :internal,
          [port("context", :any, :public)],
          [port("tool.output", :string, :internal)],
          sensitivity: :internal,
          refinements: %{
            {"target", "shell"} => %{required_sanitizations: @cmd_inj_path_trav}
          }
        ),
      "read" =>
        schema(
          "read",
          [],
          ["source", "op", "dataset", "limit", "shuffle", "seed"],
          %{
            "source" => :string,
            "op" => :string,
            "dataset" => :string,
            "limit" => :integer,
            "shuffle" => :boolean,
            "seed" => :integer
          },
          [],
          :internal,
          [],
          [port("read.output", :any, :internal)],
          sensitivity: :internal,
          refinements: %{
            {"source", "file"} => %{required_sanitizations: @path_trav}
          }
        ),
      "write" =>
        schema(
          "write",
          [],
          [
            "target",
            "op",
            "content_key",
            "output",
            "format",
            "append",
            "source",
            "metrics",
            "threshold",
            "metrics_source"
          ],
          %{
            "target" => :string,
            "op" => :string,
            "content_key" => :string,
            "output" => :string,
            "format" => :string,
            "append" => :boolean,
            "source" => :string,
            "metrics" => :string,
            "threshold" => :float,
            "metrics_source" => :string
          },
          ["file_write"],
          :internal,
          [port("content_key", :string, :internal)],
          [port("write.output", :string, :internal)],
          sensitivity: :internal,
          refinements: %{
            {"target", "file"} => %{required_sanitizations: @path_trav}
          }
        ),
      "compose" =>
        schema(
          "compose",
          [],
          ["mode", "source_key", "file", "workdir", "max_iterations"],
          %{
            "mode" => :string,
            "source_key" => :string,
            "file" => :string,
            "workdir" => :string,
            "max_iterations" => :integer
          },
          [],
          :public,
          [port("context", :any, :public)],
          [port("context", :any, :public)],
          sensitivity: :public
        ),
      "map" =>
        schema(
          "map",
          [],
          ["source_key", "item_handler"],
          %{"source_key" => :string, "item_handler" => :string},
          [],
          :public,
          [port("context", :any, :public)],
          [port("map.results", :any, :public)],
          sensitivity: :public
        ),
      "adapt" =>
        schema(
          "adapt",
          [],
          ["mutation", "conditions", "trust_tier"],
          %{"mutation" => :string, "conditions" => :string, "trust_tier" => :string},
          ["graph_mutation"],
          :secret,
          [port("context", :any, :public)],
          [port("context", :any, :secret)],
          sensitivity: :restricted,
          wipes_sanitizations: true,
          provider_constraint: :can_see_restricted
        ),
      "wait" =>
        schema(
          "wait",
          [],
          ["prompt", "question", "source"],
          %{"prompt" => :string, "question" => :string, "source" => :string},
          ["human_interaction"],
          :internal,
          [port("context", :any, :public)],
          [port("wait.answer", :string, :internal)],
          sensitivity: :internal
        ),
      "gate" =>
        schema(
          "gate",
          [],
          [
            "predicate",
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
            "predicate" => :string,
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
          [port("gate.passed", :boolean, :public)],
          sensitivity: :public
        ),
      # ── Legacy aliases (backward compatibility) ─────────────────────────
      "conditional" =>
        schema(
          "conditional",
          [],
          ["condition_key"],
          %{"condition_key" => :string},
          [],
          :public,
          [port("outcome", :any, :public)],
          [port("branch", :string, :public)],
          sensitivity: :public
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
          [port("context", :any, :public)],
          sensitivity: :public
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
          [port("context", :any, :public)],
          sensitivity: :public
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
          [port("last_response", :string, :internal)],
          sensitivity: :internal,
          wipes_sanitizations: true
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
          [port("tool.output", :string, :internal)],
          sensitivity: :internal,
          required_sanitizations: @cmd_inj_path_trav
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
          [port("human.answer", :string, :internal)],
          sensitivity: :internal
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
          [port("file.written", :string, :internal)],
          sensitivity: :internal,
          required_sanitizations: @path_trav
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
          ],
          sensitivity: :public
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
          [port("pipeline.valid", :boolean, :public)],
          sensitivity: :public
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
          [port("pipeline.child_status", :string, :public)],
          sensitivity: :public
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
          [port("eval.dataset", :any, :internal)],
          sensitivity: :internal
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
          [port("eval.results", :any, :internal)],
          sensitivity: :internal
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
          [port("eval.metrics", :any, :public)],
          sensitivity: :public
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
          [port("eval.report", :string, :public)],
          sensitivity: :public
        )
    }
  end

  defp schema(type, required, optional, types, caps, classification, inputs, outputs, taint_opts) do
    %__MODULE__{
      handler_type: type,
      required_attrs: required,
      optional_attrs: optional,
      attr_types: types,
      capabilities: caps,
      default_classification: classification,
      inputs: inputs,
      outputs: outputs,
      required_sanitizations: Keyword.get(taint_opts, :required_sanitizations, 0),
      output_sanitizations: Keyword.get(taint_opts, :output_sanitizations, 0),
      wipes_sanitizations: Keyword.get(taint_opts, :wipes_sanitizations, false),
      min_confidence: Keyword.get(taint_opts, :min_confidence, :unverified),
      sensitivity: Keyword.get(taint_opts, :sensitivity, :public),
      provider_constraint: Keyword.get(taint_opts, :provider_constraint),
      refinements: Keyword.get(taint_opts, :refinements, %{})
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
