defmodule Arbor.Actions.Schemas.Shell do
  @moduledoc """
  Zoi schemas for shell action parameter validation.

  These schemas provide runtime validation for action parameters when invoked
  via external APIs (HTTP, JSON).
  """

  @doc """
  Schema for Execute action parameters.

  Fields:
  - `command` (required) - Shell command to execute
  - `timeout` - Timeout in ms (1000-300000, default: 30000)
  - `cwd` - Working directory
  - `env` - Environment variables map
  - `sandbox` - Sandbox mode: none, basic, strict (default: basic)
  """
  def execute_params do
    Zoi.map(
      %{
        "command" => Zoi.string() |> Zoi.min(1),
        "timeout" => Zoi.integer() |> Zoi.min(1_000) |> Zoi.max(300_000) |> Zoi.optional(),
        "cwd" => Zoi.string() |> Zoi.optional(),
        "env" => Zoi.map(Zoi.string(), Zoi.string()) |> Zoi.optional(),
        "sandbox" => Zoi.enum(["none", "basic", "strict"]) |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Schema for ExecuteScript action parameters.

  Fields:
  - `script` (required) - Script content to execute
  - `shell` - Shell interpreter (default: "/bin/bash")
  - `timeout` - Timeout in ms (1000-300000, default: 60000)
  - `cwd` - Working directory
  - `env` - Environment variables map
  - `sandbox` - Sandbox mode: none, basic, strict (default: basic)
  """
  def execute_script_params do
    Zoi.map(
      %{
        "script" => Zoi.string() |> Zoi.min(1),
        "shell" => Zoi.string() |> Zoi.optional(),
        "timeout" => Zoi.integer() |> Zoi.min(1_000) |> Zoi.max(300_000) |> Zoi.optional(),
        "cwd" => Zoi.string() |> Zoi.optional(),
        "env" => Zoi.map(Zoi.string(), Zoi.string()) |> Zoi.optional(),
        "sandbox" => Zoi.enum(["none", "basic", "strict"]) |> Zoi.optional()
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
