defmodule Arbor.Gateway.Signals.Router do
  @moduledoc """
  HTTP router for signal ingestion from external sources.

  Receives signals from Claude Code hooks and other external emitters,
  validates them, and emits them onto the Arbor signal bus.

  Mounted at `/api/signals` by the main Gateway router.

  ## Endpoints

  - `POST /:source/:type` — Emit a signal from an external source

  ## Supported Sources

  - `claude` — Claude Code session hooks (session lifecycle, tool usage, etc.)
  """

  use Plug.Router

  require Logger

  plug(:match)
  plug(:dispatch)

  alias Arbor.Common.SafeAtom

  # Allowed signal types per source — prevents atom exhaustion from untrusted input
  @allowed_claude_types ~w(
    session_start session_end subagent_stop notification
    tool_used idle permission_request pre_compact
    pre_tool_use user_prompt
  )a

  # POST /api/signals/:source/:type — Ingest a signal from an external source
  #
  # Request body: JSON payload (varies by type)
  # Response: 202 Accepted
  post "/:source/:type" do
    with {:ok, validated_source} <- validate_source(source),
         {:ok, validated_type} <- validate_type(validated_source, type) do
      payload = conn.body_params || %{}

      emit_signal(validated_source, validated_type, payload)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(202, Jason.encode!(%{status: "accepted"}))
    else
      {:error, reason} ->
        Logger.debug("Signal rejected: #{reason}", source: source, type: type)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{status: "rejected", reason: reason}))
    end
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  # Private helpers

  defp validate_source("claude"), do: {:ok, :claude}
  defp validate_source(source), do: {:error, "unknown source: #{source}"}

  defp validate_type(:claude, type) do
    case SafeAtom.to_allowed(type, @allowed_claude_types) do
      {:ok, atom} -> {:ok, atom}
      {:error, _} -> {:error, "unknown type: #{type}"}
    end
  end

  defp validate_type(_source, type), do: {:error, "unknown type: #{type}"}

  defp emit_signal(source, type, payload) do
    Arbor.Signals.emit(source, type, payload)
  rescue
    e ->
      Logger.warning("Failed to emit signal: #{Exception.message(e)}",
        source: source,
        type: type
      )
  end
end
