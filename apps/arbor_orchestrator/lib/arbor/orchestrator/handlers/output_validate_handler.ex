defmodule Arbor.Orchestrator.Handlers.OutputValidateHandler do
  @moduledoc """
  Handler that validates LLM outputs against format, length, and pattern constraints
  before downstream nodes consume them.

  Node attributes:
    - `source_key` - context key to read the value from (default: "last_response")
    - `format` - expected format: "json", "elixir", "dot", "markdown", "text" (optional)
    - `max_length` - maximum character count (integer string, optional)
    - `min_length` - minimum character count (integer string, optional)
    - `must_contain` - comma-separated substrings that must appear (optional)
    - `must_not_contain` - comma-separated substrings that must NOT appear (optional)
    - `json_schema` - JSON string with "type" and "required" fields for basic validation (optional)
    - `pattern` - regex pattern that content must match (optional)
    - `action` - behavior on failure: "fail" (default), "warn", "truncate"
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  import Arbor.Orchestrator.Handlers.Helpers, only: [parse_csv: 1]

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  @impl true
  def execute(node, context, _graph, _opts) do
    source_key = Map.get(node.attrs, "source_key", "last_response")
    content = Context.get(context, source_key)

    unless content do
      raise "source key '#{source_key}' not found in context"
    end

    content_str = to_string(content)
    format = Map.get(node.attrs, "format")
    action = Map.get(node.attrs, "action", "fail")

    errors =
      []
      |> maybe_validate_format(content_str, format)
      |> maybe_validate_length(content_str, node.attrs)
      |> maybe_validate_patterns(content_str, node.attrs)
      |> maybe_validate_excluded(content_str, node.attrs)
      |> maybe_validate_json_schema(content_str, node.attrs)
      |> maybe_validate_regex(content_str, node.attrs)
      |> Enum.reverse()

    passed = errors == []

    base_updates = %{
      "validate.#{node.id}.passed" => passed,
      "validate.#{node.id}.errors" => errors,
      "validate.#{node.id}.format" => format || "none"
    }

    build_outcome(action, errors, passed, base_updates, content_str, source_key, node)
  rescue
    e ->
      %Outcome{
        status: :fail,
        failure_reason: "output.validate error: #{Exception.message(e)}"
      }
  end

  @impl true
  def idempotency, do: :read_only

  # --- Outcome builders ---

  defp build_outcome(_action, _errors, true = _passed, updates, _content, _source_key, _node) do
    %Outcome{
      status: :success,
      notes: "All validations passed",
      context_updates: updates
    }
  end

  defp build_outcome("warn", errors, _passed, updates, _content, _source_key, _node) do
    %Outcome{
      status: :success,
      notes: "Validation warnings: #{Enum.join(errors, "; ")}",
      context_updates: updates
    }
  end

  defp build_outcome("truncate", errors, _passed, updates, content, source_key, node) do
    case parse_integer(Map.get(node.attrs, "max_length")) do
      {:ok, max} when byte_size(content) > max ->
        truncated = String.slice(content, 0, max)

        %Outcome{
          status: :success,
          notes: "Content truncated from #{String.length(content)} to #{max} characters",
          context_updates: Map.merge(updates, %{source_key => truncated})
        }

      _ ->
        # No max_length or content not over limit — treat remaining errors as warnings
        %Outcome{
          status: :success,
          notes: "Validation warnings (truncate mode): #{Enum.join(errors, "; ")}",
          context_updates: updates
        }
    end
  end

  defp build_outcome(_fail, errors, _passed, updates, _content, _source_key, _node) do
    %Outcome{
      status: :fail,
      failure_reason: "Validation failed: #{Enum.join(errors, "; ")}",
      context_updates: updates
    }
  end

  # --- Conditional validators (only run when attr is present) ---

  defp maybe_validate_format(errors, _content, nil), do: errors

  defp maybe_validate_format(errors, content, format) do
    case validate_format(content, format) do
      :ok -> errors
      {:error, msg} -> [msg | errors]
    end
  end

  defp maybe_validate_length(errors, content, attrs) do
    min = parse_integer(Map.get(attrs, "min_length"))
    max = parse_integer(Map.get(attrs, "max_length"))

    case validate_length(content, min, max) do
      :ok -> errors
      {:error, msgs} -> Enum.reverse(msgs) ++ errors
    end
  end

  defp maybe_validate_patterns(errors, content, attrs) do
    case Map.get(attrs, "must_contain") do
      nil ->
        errors

      patterns_str ->
        case validate_patterns(content, parse_csv(patterns_str)) do
          :ok -> errors
          {:error, msgs} -> Enum.reverse(msgs) ++ errors
        end
    end
  end

  defp maybe_validate_excluded(errors, content, attrs) do
    case Map.get(attrs, "must_not_contain") do
      nil ->
        errors

      patterns_str ->
        case validate_excluded(content, parse_csv(patterns_str)) do
          :ok -> errors
          {:error, msgs} -> Enum.reverse(msgs) ++ errors
        end
    end
  end

  defp maybe_validate_json_schema(errors, content, attrs) do
    case Map.get(attrs, "json_schema") do
      nil ->
        errors

      schema_str ->
        case validate_json_schema(content, schema_str) do
          :ok -> errors
          {:error, msg} -> [msg | errors]
        end
    end
  end

  defp maybe_validate_regex(errors, content, attrs) do
    case Map.get(attrs, "pattern") do
      nil ->
        errors

      pattern ->
        case validate_regex(content, pattern) do
          :ok -> errors
          {:error, msg} -> [msg | errors]
        end
    end
  end

  # --- Core validators ---

  defp validate_format(content, "json") do
    case Jason.decode(content) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, "content is not valid JSON"}
    end
  end

  defp validate_format(content, "elixir") do
    case Code.string_to_quoted(content) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, "content is not valid Elixir"}
    end
  end

  defp validate_format(content, "dot") do
    if String.contains?(content, "digraph") do
      :ok
    else
      {:error, "content does not appear to be a DOT graph (missing 'digraph')"}
    end
  end

  defp validate_format(_content, "markdown"), do: :ok
  defp validate_format(_content, "text"), do: :ok

  defp validate_format(_content, unknown) do
    {:error, "unknown format '#{unknown}' (expected: json, elixir, dot, markdown, text)"}
  end

  defp validate_length(content, min, max) do
    len = String.length(content)

    errs =
      []
      |> then(fn acc ->
        case min do
          {:ok, min_val} when len < min_val ->
            ["content length #{len} is below minimum #{min_val}" | acc]

          _ ->
            acc
        end
      end)
      |> then(fn acc ->
        case max do
          {:ok, max_val} when len > max_val ->
            ["content length #{len} exceeds maximum #{max_val}" | acc]

          _ ->
            acc
        end
      end)

    case errs do
      [] -> :ok
      msgs -> {:error, msgs}
    end
  end

  defp validate_patterns(content, patterns) do
    missing =
      Enum.reject(patterns, fn pattern ->
        String.contains?(content, pattern)
      end)

    case missing do
      [] -> :ok
      _ -> {:error, Enum.map(missing, &"missing required content: '#{&1}'")}
    end
  end

  defp validate_excluded(content, patterns) do
    found =
      Enum.filter(patterns, fn pattern ->
        String.contains?(content, pattern)
      end)

    case found do
      [] -> :ok
      _ -> {:error, Enum.map(found, &"contains prohibited content: '#{&1}'")}
    end
  end

  defp validate_json_schema(content, schema_str) do
    with {:schema, {:ok, schema}} <- {:schema, Jason.decode(schema_str)},
         {:parse, {:ok, parsed}} <- {:parse, Jason.decode(content)} do
      errs = check_schema(parsed, schema)

      case errs do
        [] -> :ok
        _ -> {:error, "JSON schema validation failed: #{Enum.join(errs, "; ")}"}
      end
    else
      {:schema, {:error, _}} ->
        {:error, "invalid json_schema attribute (not valid JSON)"}

      {:parse, {:error, _}} ->
        {:error, "content is not valid JSON (cannot validate against schema)"}
    end
  end

  defp check_schema(parsed, schema) do
    type_errors = check_type(parsed, Map.get(schema, "type"))
    required_errors = check_required(parsed, Map.get(schema, "required"))
    type_errors ++ required_errors
  end

  defp check_type(_parsed, nil), do: []
  defp check_type(parsed, "object") when is_map(parsed), do: []
  defp check_type(parsed, "array") when is_list(parsed), do: []
  defp check_type(parsed, "string") when is_binary(parsed), do: []
  defp check_type(parsed, "number") when is_number(parsed), do: []
  defp check_type(parsed, "boolean") when is_boolean(parsed), do: []

  defp check_type(_parsed, expected) do
    ["expected type '#{expected}'"]
  end

  defp check_required(_parsed, nil), do: []
  defp check_required(_parsed, required) when not is_list(required), do: []

  defp check_required(parsed, required) when is_map(parsed) do
    Enum.flat_map(required, fn field ->
      if Map.has_key?(parsed, field) do
        []
      else
        ["missing required field '#{field}'"]
      end
    end)
  end

  defp check_required(_parsed, _required), do: ["cannot check required fields on non-object"]

  defp validate_regex(content, pattern_str) do
    # Validates output against user-defined regex from pipeline node attrs
    # credo:disable-for-next-line Credo.Check.Security.UnsafeRegexCompile
    case Regex.compile(pattern_str) do
      {:ok, regex} ->
        if Regex.match?(regex, content) do
          :ok
        else
          {:error, "content does not match pattern '#{pattern_str}'"}
        end

      {:error, {reason, _}} ->
        {:error, "invalid regex pattern '#{pattern_str}': #{reason}"}
    end
  end

  # --- Utilities ---

  defp parse_integer(nil), do: :none

  defp parse_integer(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> {:ok, int}
      :error -> :none
    end
  end

  defp parse_integer(val) when is_integer(val), do: {:ok, val}
  defp parse_integer(_), do: :none
end
