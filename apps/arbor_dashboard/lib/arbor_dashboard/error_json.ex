defmodule Arbor.Dashboard.ErrorJSON do
  @moduledoc """
  Minimal JSON error view for the dashboard endpoint.

  Companion to `Arbor.Dashboard.ErrorHTML` for requests that accept JSON.
  Renders `%{errors: %{detail: "Not Found"}}` etc. so the render-errors path
  never crashes and mask the original exception.
  """

  # Renders "404.json" => %{errors: %{detail: "Not Found"}}, etc.
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
