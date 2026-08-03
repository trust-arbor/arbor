defmodule Arbor.Voice.ToolRouter.FrontDesk do
  @moduledoc """
  Production static front-desk catalog (VP-05B / VOICE-9).

  Exactly one tool: `consult_agent`. Schema is source-owned; model/speech
  cannot add, rename, or mutate tools or fields. Consultation goes through a
  Session-built authority that calls the public Agent facade — never raw
  credentials or Persistence/Comms from this module.
  """

  @behaviour Arbor.Voice.ToolRouter

  @max_message_bytes 8192

  @consult_description "Consult the user's Arbor agent with one message and return the grounded reply."
  @message_description "The message to send to the user's Arbor agent."

  @doc "Static production catalog: exactly one consult_agent function declaration."
  @spec catalog() :: [map()]
  def catalog do
    [
      %{
        "type" => "function",
        "name" => "consult_agent",
        "description" => @consult_description,
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "message" => %{
              "type" => "string",
              "description" => @message_description,
              "minLength" => 1,
              "maxLength" => @max_message_bytes
            }
          },
          "required" => ["message"],
          "additionalProperties" => false
        }
      }
    ]
  end

  @impl true
  def tools, do: catalog()

  @impl true
  def invoke(%{name: "consult_agent"} = context, authority) do
    # Correct name with missing/malformed arguments is invalid_arguments, not
    # unknown_tool. Wrong names fall through below.
    case Map.fetch(context, :arguments) do
      {:ok, args} when is_map(args) ->
        with {:ok, message} <- admit_message(args),
             {:ok, consult} <- fetch_consult(authority) do
          case consult.(message) do
            {:ok, reply} when is_binary(reply) ->
              if valid_reply?(reply) do
                {:ok, %{"reply" => reply}}
              else
                {:error, :tool_error}
              end

            {:error, _} ->
              # Collapse Agent vocabulary; never leak reason atoms as content.
              {:error, :tool_error}

            _other ->
              {:error, :tool_error}
          end
        end

      _missing_or_non_map ->
        {:error, :invalid_arguments}
    end
  end

  def invoke(%{name: _other}, _authority), do: {:error, :unknown_tool}
  def invoke(_context, _authority), do: {:error, :unknown_tool}

  defp admit_message(%{"message" => message} = args) when map_size(args) == 1 do
    cond do
      not is_binary(message) ->
        {:error, :invalid_arguments}

      byte_size(message) > @max_message_bytes ->
        {:error, :invalid_arguments}

      not String.valid?(message) ->
        {:error, :invalid_arguments}

      String.trim(message) == "" ->
        {:error, :invalid_arguments}

      true ->
        {:ok, message}
    end
  end

  defp admit_message(_), do: {:error, :invalid_arguments}

  defp fetch_consult(%{consult_agent: fun}) when is_function(fun, 1), do: {:ok, fun}
  defp fetch_consult(_), do: {:error, :tool_error}

  defp valid_reply?(reply) when is_binary(reply) do
    String.valid?(reply) and String.trim(reply) != ""
  end

  defp valid_reply?(_), do: false
end
