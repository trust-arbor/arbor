defmodule Arbor.Gateway.Bridge.Router do
  @moduledoc """
  HTTP router for Claude Code bridge requests.

  Handles authorization requests from Claude Code PreToolUse hooks.
  Mounted at `/api/bridge` by the main Gateway router.
  """

  use Plug.Router

  alias Arbor.Gateway.Bridge.ClaudeSession
  alias Arbor.Gateway.Schemas

  require Logger

  plug(:match)
  plug(:dispatch)

  # POST /api/bridge/authorize_tool - Authorize a tool call from Claude Code
  #
  # Request body: {session_id, tool_name, tool_use_id, tool_input, cwd}
  # Response: {decision: allow|deny|ask|passthrough, reason?, updated_input?, system_message?}
  post "/authorize_tool" do
    case Schemas.Bridge.validate(Schemas.Bridge.authorize_tool_request(), conn.body_params) do
      {:ok, validated} ->
        tool_input = validated["tool_input"] || %{}
        cwd = validated["cwd"] || "."

        result =
          authorize_tool_call(validated["session_id"], validated["tool_name"], tool_input, cwd)

        # Emit signal for observability
        emit_bridge_signal(validated["session_id"], validated["tool_name"], result)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(result))

      {:error, errors} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "invalid_params", details: errors}))
    end
  end

  match _ do
    send_resp(conn, 404, "Not found")
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
    decision = result[:decision]
    type = if decision == "allow", do: :allowed, else: :denied

    Arbor.Signals.emit(
      :tool_authorization,
      type,
      %{
        tool_name: tool_name,
        decision: decision,
        reason: result[:reason],
        agent_id: agent_id
      }
    )
  rescue
    _ -> :ok
  end
end
