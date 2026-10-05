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

  @doc false
  def client_asset_paths do
    %{
      phoenix: client_asset_path(:phoenix, "/assets/phoenix/phoenix.mjs"),
      phoenix_live_view:
        client_asset_path(
          :phoenix_live_view,
          "/assets/phoenix_live_view/phoenix_live_view.esm.js"
        )
    }
  end

  defp client_asset_path(application, path) do
    version = application |> Application.spec(:vsn) |> to_string()
    path <> "?v=" <> URI.encode_www_form(version)
  end
end
