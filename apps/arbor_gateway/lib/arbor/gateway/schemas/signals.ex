defmodule Arbor.Gateway.Schemas.Signals do
  @moduledoc """
  Zoi schemas for signals API validation.

  Validates incoming signal payloads for the Signals router endpoints.
  """

  @allowed_claude_types ~w(
    session_start session_end subagent_stop notification
    tool_used idle permission_request pre_compact
    pre_tool_use user_prompt
  )

  @allowed_sdlc_types ~w(session_started session_complete)

  @doc """
  Schema for POST /:source/:type signal requests.

  Validates the source and type path parameters are known values.
  """
  def signal_params do
    Zoi.map(
      %{
        "source" => Zoi.enum(["claude", "sdlc"]),
        "type" => Zoi.string() |> Zoi.min(1)
      },
      coerce: true
    )
  end

  @doc """
  Validate signal type is allowed for the given source.
  """
  def validate_signal_type("claude", type) when is_binary(type) do
    if type in @allowed_claude_types do
      {:ok, String.to_existing_atom(type)}
    else
      {:error, "unknown type: #{type}"}
    end
  rescue
    ArgumentError -> {:error, "unknown type: #{type}"}
  end

  def validate_signal_type("sdlc", type) when is_binary(type) do
    if type in @allowed_sdlc_types do
      {:ok, String.to_existing_atom(type)}
    else
      {:error, "unknown type: #{type}"}
    end
  rescue
    ArgumentError -> {:error, "unknown type: #{type}"}
  end

  def validate_signal_type(source, _type), do: {:error, "unknown source: #{source}"}

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
