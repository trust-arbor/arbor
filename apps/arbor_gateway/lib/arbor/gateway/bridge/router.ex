defmodule Arbor.Gateway.Bridge.Router do
  @moduledoc """
  HTTP router for Claude Code bridge requests.

  Handles authorization requests from Claude Code PreToolUse hooks.
  Mounted at `/api/bridge` by the main Gateway router.
  """

  use Plug.Router

  alias Arbor.Gateway.Bridge.ClaudeSession

  require Logger

  plug(:match)
  plug(:dispatch)

  # POST /api/bridge/authorize_tool - Authorize a tool call from Claude Code
  #
  # Request body: {session_id, tool_name, tool_use_id, tool_input, cwd}
  # Response: {decision: allow|deny|ask|passthrough, reason?, updated_input?, system_message?}
  post "/authorize_tool" do
    with {:ok, session_id} <- get_required(conn.body_params, "session_id"),
         {:ok, tool_name} <- get_required(conn.body_params, "tool_name") do
      tool_input = Map.get(conn.body_params, "tool_input", %{})
      cwd = Map.get(conn.body_params, "cwd", ".")
      result = authorize_tool_call(session_id, tool_name, tool_input, cwd)

      # Emit signal for observability
      emit_bridge_signal(session_id, tool_name, result)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(result))
    else
      {:error, missing_field} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Missing required field: #{missing_field}"}))
    end
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  # Private helpers

  defp get_required(params, field) do
    case Map.get(params, field) do
      nil -> {:error, field}
      value -> {:ok, value}
    end
  end

  defp authorize_tool_call(session_id, tool_name, tool_input, cwd) do
    case ClaudeSession.authorize_tool(session_id, tool_name, tool_input, cwd) do
      {:ok, :authorized} ->
        Logger.debug("Bridge authorized", tool: tool_name, session: session_id)
        %{decision: "allow"}

      {:error, :unauthorized, reason} ->
        Logger.info("Bridge denied tool",
          tool: tool_name,
          session: session_id,
          reason: reason
        )

        %{decision: "deny", reason: reason}
    end
  rescue
    e ->
      Logger.error("Bridge authorization error, failing closed to deny",
        tool: tool_name,
        session: session_id,
        error: Exception.message(e)
      )

      %{decision: "deny", reason: "authorization error: #{Exception.message(e)}"}
  catch
    :exit, reason ->
      Logger.error("Bridge authorization process unavailable, failing closed to deny",
        tool: tool_name,
        session: session_id,
        error: inspect(reason)
      )

      %{decision: "deny", reason: "authorization unavailable"}
  end

  defp emit_bridge_signal(session_id, tool_name, result) do
    agent_id = ClaudeSession.to_agent_id(session_id)

    Arbor.Signals.emit(
      :tool_authorization,
      %{
        tool_name: tool_name,
        decision: result[:decision],
        reason: result[:reason]
      },
      agent_id: agent_id
    )
  rescue
    _ -> :ok
  end
end
