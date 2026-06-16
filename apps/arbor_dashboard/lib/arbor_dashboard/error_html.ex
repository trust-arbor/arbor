defmodule Arbor.Dashboard.ErrorHTML do
  @moduledoc """
  Minimal HTML error view for the dashboard endpoint.

  Phoenix's `render_errors` config points its endpoint at an error view to
  render when a request raises (404, 500, etc.). Without one, the render-errors
  path itself crashes with `no "500" html template defined`, which *masks* the
  original exception. This module provides the standard Phoenix 1.8 minimal
  form: render the HTTP status message for the requested template
  (`"404.html"` -> "Not Found", `"500.html"` -> "Internal Server Error").
  """

  use Phoenix.Component

  # Renders "404.html" => "Not Found", "500.html" => "Internal Server Error", etc.
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
