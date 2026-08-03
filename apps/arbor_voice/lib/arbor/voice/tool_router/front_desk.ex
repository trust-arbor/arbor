defmodule Arbor.Voice.ToolRouter.FrontDesk do
  @moduledoc """
  Production static front-desk catalog (VP-05B / VP-05C).

  Exactly two tools: `consult_agent` and `dispatch_coding_task`. Schemas are
  source-owned; model/speech cannot add, rename, or mutate tools or fields.
  Both routes go through a Session-built authority that calls public facades —
  never raw credentials or Persistence/Comms from this module.
  """

  @behaviour Arbor.Voice.ToolRouter

  @max_message_bytes 8192
  @max_task_intent_bytes 2048
  @max_task_id_bytes 256
  @task_id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @control_chars ~r/[\x00-\x1F\x7F]/

  @consult_description "Consult the user's Arbor agent with one message and return the grounded reply."
  @message_description "The message to send to the user's Arbor agent."
  @dispatch_description "Dispatch one bounded coding change as a managed Arbor task and return the task id."
  @task_description "Bounded coding intent for one reviewable change."

  @doc "Static production catalog: consult_agent and dispatch_coding_task."
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
      },
      %{
        "type" => "function",
        "name" => "dispatch_coding_task",
        "description" => @dispatch_description,
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "task" => %{
              "type" => "string",
              "description" => @task_description,
              "minLength" => 1,
              "maxLength" => @max_task_intent_bytes
            }
          },
          "required" => ["task"],
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

  def invoke(%{name: "dispatch_coding_task"} = context, authority) do
    case Map.fetch(context, :arguments) do
      {:ok, args} when is_map(args) ->
        with {:ok, task_intent} <- admit_task_arg(args),
             {:ok, dispatch} <- fetch_dispatch(authority) do
          case dispatch.(task_intent) do
            {:ok, task_id} when is_binary(task_id) ->
              if valid_task_id?(task_id) do
                {:ok, %{"task_id" => task_id, "status" => "dispatched"}}
              else
                {:error, :tool_error}
              end

            {:error, _} ->
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

  defp admit_task_arg(%{"task" => task} = args) when map_size(args) == 1 do
    cond do
      not is_binary(task) ->
        {:error, :invalid_arguments}

      byte_size(task) > @max_task_intent_bytes ->
        {:error, :invalid_arguments}

      not String.valid?(task) ->
        {:error, :invalid_arguments}

      String.trim(task) == "" ->
        {:error, :invalid_arguments}

      String.match?(task, @control_chars) ->
        {:error, :invalid_arguments}

      true ->
        {:ok, task}
    end
  end

  defp admit_task_arg(_), do: {:error, :invalid_arguments}

  defp fetch_consult(%{consult_agent: fun}) when is_function(fun, 1), do: {:ok, fun}
  defp fetch_consult(_), do: {:error, :tool_error}

  defp fetch_dispatch(%{dispatch_coding_task: fun}) when is_function(fun, 1), do: {:ok, fun}
  defp fetch_dispatch(_), do: {:error, :tool_error}

  defp valid_reply?(reply) when is_binary(reply) do
    String.valid?(reply) and String.trim(reply) != ""
  end

  defp valid_reply?(_), do: false

  defp valid_task_id?(task_id)
       when is_binary(task_id) and byte_size(task_id) > 0 and
              byte_size(task_id) <= @max_task_id_bytes do
    String.valid?(task_id) and Regex.match?(@task_id_pattern, task_id)
  end

  defp valid_task_id?(_), do: false
end
