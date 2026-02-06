defmodule Arbor.Gateway.Schemas.Memory do
  @moduledoc """
  Zoi schemas for memory API validation.

  Validates incoming request parameters for the Memory router endpoints.
  """

  @doc """
  Schema for POST /recall requests.

  Fields:
  - `agent_id` (required) - Agent identifier
  - `query` (required) - Search query string
  - `limit` - Maximum results, 1-100, default 10
  - `threshold` - Similarity threshold, 0.0-1.0, default 0.3
  - `type` - Memory type filter (fact, experience, skill, insight, relationship)
  """
  def recall_request do
    Zoi.map(
      %{
        "agent_id" => Zoi.string(),
        "query" => Zoi.string(),
        "limit" => Zoi.integer() |> Zoi.min(1) |> Zoi.max(100) |> Zoi.optional(),
        "threshold" => Zoi.number() |> Zoi.min(0.0) |> Zoi.max(1.0) |> Zoi.optional(),
        "type" =>
          Zoi.enum(["fact", "experience", "skill", "insight", "relationship"])
          |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Schema for POST /index requests.

  Fields:
  - `agent_id` (required) - Agent identifier
  - `content` (required) - Content to index
  - `metadata` - Optional metadata map with type/source
  """
  def index_request do
    Zoi.map(
      %{
        "agent_id" => Zoi.string(),
        "content" => Zoi.string(),
        "metadata" => Zoi.map() |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Schema for PUT /working/:agent_id requests.

  Fields:
  - `working_memory` (required) - Working memory state to save
  """
  def working_memory_request do
    Zoi.map(
      %{
        "working_memory" => Zoi.map()
      },
      coerce: true
    )
  end

  @doc """
  Schema for POST /summarize requests.

  Fields:
  - `agent_id` (required) - Agent identifier
  - `text` (required) - Text to summarize
  - `max_length` - Maximum summary length, 50-5000, default 500
  """
  def summarize_request do
    Zoi.map(
      %{
        "agent_id" => Zoi.string(),
        "text" => Zoi.string(),
        "max_length" => Zoi.integer() |> Zoi.min(50) |> Zoi.max(5000) |> Zoi.optional()
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
