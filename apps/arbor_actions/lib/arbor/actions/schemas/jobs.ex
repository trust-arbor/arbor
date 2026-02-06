defmodule Arbor.Actions.Schemas.Jobs do
  @moduledoc """
  Zoi schemas for jobs action parameter validation.

  These schemas provide runtime validation for action parameters when invoked
  via external APIs (HTTP, JSON).
  """

  @valid_priorities ~w(low normal high critical)
  @valid_statuses ~w(all created active completed failed cancelled)

  @doc """
  Schema for CreateJob action parameters.

  Fields:
  - `title` (required) - Job title
  - `description` - Detailed description
  - `priority` - Priority level: low, normal, high, critical (default: normal)
  - `tags` - List of categorization tags
  """
  def create_params do
    Zoi.map(
      %{
        "title" => Zoi.string() |> Zoi.min(1),
        "description" => Zoi.string() |> Zoi.optional(),
        "priority" => Zoi.enum(@valid_priorities) |> Zoi.optional(),
        "tags" => Zoi.list(Zoi.string()) |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Schema for ListJobs action parameters.

  Fields:
  - `status` - Filter by status: all, created, active, completed, failed, cancelled
  - `tag` - Filter by tag
  - `limit` - Maximum results (1-100, default: 20)
  """
  def list_params do
    Zoi.map(
      %{
        "status" => Zoi.enum(@valid_statuses) |> Zoi.optional(),
        "tag" => Zoi.string() |> Zoi.optional(),
        "limit" => Zoi.integer() |> Zoi.min(1) |> Zoi.max(100) |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Schema for GetJob action parameters.

  Fields:
  - `job_id` (required) - Job ID to retrieve
  - `include_history` - Include event history (default: false)
  """
  def get_params do
    Zoi.map(
      %{
        "job_id" => Zoi.string() |> Zoi.min(1),
        "include_history" => Zoi.boolean() |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Schema for UpdateJob action parameters.

  Fields:
  - `job_id` (required) - Job ID to update
  - `status` - New status: active, completed, failed, cancelled
  - `notes` - Progress note to append
  """
  def update_params do
    Zoi.map(
      %{
        "job_id" => Zoi.string() |> Zoi.min(1),
        "status" => Zoi.enum(["active", "completed", "failed", "cancelled"]) |> Zoi.optional(),
        "notes" => Zoi.string() |> Zoi.optional()
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
