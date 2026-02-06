defmodule Arbor.Actions.Schemas.Historian do
  @moduledoc """
  Zoi schemas for historian action parameter validation.

  These schemas provide runtime validation for action parameters when invoked
  via external APIs (HTTP, JSON).
  """

  @doc """
  Schema for QueryEvents action parameters.

  Fields:
  - `stream` - Stream ID to query
  - `category` - Event category filter
  - `type` - Event type filter
  - `source` - Event source filter
  - `from` - Start time (ISO8601)
  - `to` - End time (ISO8601)
  - `limit` - Maximum events (1-1000, default: 100)
  """
  def query_events_params do
    Zoi.map(
      %{
        "stream" => Zoi.string() |> Zoi.optional(),
        "category" => Zoi.string() |> Zoi.optional(),
        "type" => Zoi.string() |> Zoi.optional(),
        "source" => Zoi.string() |> Zoi.optional(),
        "from" => iso8601_datetime(),
        "to" => iso8601_datetime(),
        "limit" => Zoi.integer() |> Zoi.min(1) |> Zoi.max(1000) |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Schema for CausalityTree action parameters.

  Fields:
  - `event_id` (required) - Event ID to trace from
  - `max_depth` - Maximum chain depth (1-100, default: 10)
  """
  def causality_tree_params do
    Zoi.map(
      %{
        "event_id" => Zoi.string() |> Zoi.min(1),
        "max_depth" => Zoi.integer() |> Zoi.min(1) |> Zoi.max(100) |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Schema for ReconstructState action parameters.

  Fields:
  - `stream` (required) - Stream to reconstruct
  - `as_of` (required) - Timestamp to reconstruct to (ISO8601)
  - `include_events` - Include events in response (default: false)
  """
  def reconstruct_state_params do
    Zoi.map(
      %{
        "stream" => Zoi.string() |> Zoi.min(1),
        "as_of" => iso8601_datetime() |> required(),
        "include_events" => Zoi.boolean() |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Schema for TaintTrace action parameters.

  Fields:
  - `query_type` (required) - Query type: trace_backward, trace_forward, events, summary
  - `signal_id` - Signal ID for trace queries
  - `agent_id` - Agent ID for summary/filtering
  - `taint_level` - Filter by taint level
  - `event_type` - Filter by event type
  - `limit` - Maximum results (1-1000, default: 100)
  """
  def taint_trace_params do
    Zoi.map(
      %{
        "query_type" =>
          Zoi.enum(["trace_backward", "trace_forward", "events", "summary"]),
        "signal_id" => Zoi.string() |> Zoi.optional(),
        "agent_id" => Zoi.string() |> Zoi.optional(),
        "taint_level" =>
          Zoi.enum(["trusted", "derived", "untrusted", "hostile"]) |> Zoi.optional(),
        "event_type" => Zoi.string() |> Zoi.optional(),
        "limit" => Zoi.integer() |> Zoi.min(1) |> Zoi.max(1000) |> Zoi.optional()
      },
      coerce: true
    )
  end

  # Helper for ISO8601 datetime strings with optional validation
  defp iso8601_datetime do
    Zoi.string()
    |> Zoi.refine(fn value ->
      case DateTime.from_iso8601(value) do
        {:ok, _, _} -> :ok
        _ -> {:error, "must be valid ISO8601 datetime"}
      end
    end)
    |> Zoi.optional()
  end

  # Helper to mark a field as required after optional modifiers
  defp required(schema) do
    # Remove optional flag by creating a new schema that requires the value
    Zoi.refine(schema, fn
      nil -> {:error, "is required"}
      _ -> :ok
    end)
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
