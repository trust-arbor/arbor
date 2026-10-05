defmodule Arbor.Dashboard.SessionAuth do
  @moduledoc false

  alias Arbor.Dashboard.Config

  def verify(principal, token) do
    case Config.session_auth_api().verify_human_session(principal, token) do
      :ok -> :ok
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  # These hooks are installed only on mounts requiring OIDC authentication.
  # Keep checking their original proof even if configuration changes later.
  def guard_socket(socket) do
    case verify(socket.assigns[:current_agent_id], socket.assigns[:session_token]) do
      :ok -> {:cont, socket}
      _ -> reject_socket(socket)
    end
  end

  def reject_socket(socket) do
    # Preserve the exact authenticated subject before clearing identity. The
    # pinned LiveView channel flushes pending events before its redirect; Home
    # keeps a receiver mounted even when a target-switch composer is absent.
    socket =
      if is_binary(socket.assigns[:current_agent_id]) do
        socket
        |> Phoenix.LiveView.push_event("conversation-access-denied", %{})
        |> Phoenix.LiveView.push_event("conversation-home-clear", %{
          subject: socket.assigns.current_agent_id
        })
      else
        socket
      end

    socket =
      socket
      |> Phoenix.Component.assign(
        current_agent_id: nil,
        current_user_display_name: nil,
        session_token: nil,
        local_dev_operator?: false,
        tenant_context: nil,
        authenticated?: false
      )
      |> Phoenix.LiveView.redirect(to: "/auth/login")

    {:halt, socket}
  end
end
