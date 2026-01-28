defmodule Arbor.Web.Layouts do
  @moduledoc """
  Parametric layout components for Arbor dashboards.

  These layouts accept assigns for customization (app_name, nav_items, etc.)
  so each consuming app can brand its dashboard while sharing the same structure.
  """

  use Phoenix.Component

  import Arbor.Web.Components
  import Plug.CSRFProtection, only: [get_csrf_token: 0]

  embed_templates("layouts/*")
end
