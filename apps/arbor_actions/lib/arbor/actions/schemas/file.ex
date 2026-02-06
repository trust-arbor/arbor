defmodule Arbor.Actions.Schemas.File do
  @moduledoc """
  Zoi schemas for file action parameter validation.

  These schemas provide runtime validation for action parameters when invoked
  via external APIs (HTTP, JSON). The schemas complement Jido's compile-time
  NimbleOptions validation with structured runtime validation.
  """

  @doc """
  Schema for Read action parameters.

  Fields:
  - `path` (required) - Path to the file to read
  - `encoding` - File encoding: utf8, latin1, or binary (default: utf8)
  """
  def read_params do
    Zoi.map(
      %{
        "path" => Zoi.string() |> Zoi.min(1),
        "encoding" => Zoi.enum(["utf8", "latin1", "binary"]) |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Schema for Write action parameters.

  Fields:
  - `path` (required) - Path to the file to write
  - `content` (required) - Content to write
  - `create_dirs` - Create parent directories if needed (default: false)
  - `mode` - Write mode: write or append (default: write)
  """
  def write_params do
    Zoi.map(
      %{
        "path" => Zoi.string() |> Zoi.min(1),
        "content" => Zoi.string(),
        "create_dirs" => Zoi.boolean() |> Zoi.optional(),
        "mode" => Zoi.enum(["write", "append"]) |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Schema for Edit action parameters.

  Fields:
  - `path` (required) - Path to the file to edit
  - `old_string` (required) - String to find and replace
  - `new_string` (required) - Replacement string
  - `replace_all` - Replace all occurrences (default: false)
  """
  def edit_params do
    Zoi.map(
      %{
        "path" => Zoi.string() |> Zoi.min(1),
        "old_string" => Zoi.string() |> Zoi.min(1),
        "new_string" => Zoi.string(),
        "replace_all" => Zoi.boolean() |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Schema for Search action parameters.

  Fields:
  - `pattern` (required) - Search pattern
  - `path` (required) - File or directory to search
  - `glob` - File filter pattern (e.g., "*.ex")
  - `max_results` - Maximum matches (1-1000, default: 50)
  - `context_lines` - Lines of context (0-20, default: 2)
  - `regex` - Treat pattern as regex (default: false)
  """
  def search_params do
    Zoi.map(
      %{
        "pattern" => Zoi.string() |> Zoi.min(1) |> Zoi.max(500),
        "path" => Zoi.string() |> Zoi.min(1),
        "glob" => Zoi.string() |> Zoi.optional(),
        "max_results" => Zoi.integer() |> Zoi.min(1) |> Zoi.max(1000) |> Zoi.optional(),
        "context_lines" => Zoi.integer() |> Zoi.min(0) |> Zoi.max(20) |> Zoi.optional(),
        "regex" => Zoi.boolean() |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Schema for Glob action parameters.

  Fields:
  - `pattern` (required) - Glob pattern (e.g., "**/*.ex")
  - `base_path` - Base directory for relative patterns
  - `match_dot` - Match hidden files (default: false)
  """
  def glob_params do
    Zoi.map(
      %{
        "pattern" => Zoi.string() |> Zoi.min(1),
        "base_path" => Zoi.string() |> Zoi.optional(),
        "match_dot" => Zoi.boolean() |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Parse and validate parameters against a schema.

  Returns `{:ok, validated_params}` or `{:error, error_details}`.
  """
  def validate(schema, params) do
    case Zoi.parse(schema, params) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, errors} ->
        {:error, format_errors(errors)}
    end
  end

  defp format_errors(errors) do
    Enum.map(errors, fn error ->
      %{
        field: Enum.join(error.path, "."),
        message: error.message
      }
    end)
  end
end
