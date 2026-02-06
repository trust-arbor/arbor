defmodule Arbor.Gateway.Schemas.Bridge do
  @moduledoc """
  Zoi schemas for bridge API validation.

  Validates incoming request parameters for the Bridge router endpoints.
  """

  @doc """
  Schema for POST /authorize_tool requests.

  Fields:
  - `session_id` (required) - Claude Code session identifier
  - `tool_name` (required) - Name of the tool being authorized
  - `tool_input` - Tool input parameters map
  - `cwd` - Current working directory (validated separately with SafePath)
  """
  def authorize_tool_request do
    Zoi.map(
      %{
        "session_id" => Zoi.string() |> Zoi.min(1),
        "tool_name" => Zoi.string() |> Zoi.min(1),
        "tool_input" => Zoi.map() |> Zoi.optional(),
        "cwd" => Zoi.string() |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Parse and validate request params using the given schema.

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
