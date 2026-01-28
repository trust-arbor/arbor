defmodule Arbor.Web.Router do
  @moduledoc """
  Macro for Phoenix router boilerplate shared across Arbor dashboards.

  Provides a standard browser pipeline and layout configuration.

  ## Usage

      defmodule MyApp.Router do
        use Arbor.Web.Router

        scope "/", MyApp.Live do
          arbor_browser_pipeline()
          live "/", DashboardLive
        end
      end

  ## Provided Macros

    * `arbor_browser_pipeline/0` - Standard browser pipeline with session,
      flash, layout, CSRF, and security headers.
    * `arbor_browser_pipeline/1` - Same but accepts options:
      - `:layout` - Custom root layout `{module, :template}` (default: Arbor.Web.Layouts)
  """

  defmacro __using__(_opts) do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
      import Arbor.Web.Router, only: [arbor_browser_pipeline: 0, arbor_browser_pipeline: 1]
    end
  end

  @doc """
  Injects the standard Arbor browser pipeline into the current scope.

  This sets up: accepts HTML, fetch_session, fetch_live_flash,
  put_root_layout (Arbor.Web.Layouts), protect_from_forgery, put_secure_browser_headers.
  """
  defmacro arbor_browser_pipeline(opts \\ []) do
    layout_mod = Keyword.get(opts, :layout, Arbor.Web.Layouts)

    quote do
      pipe_through(:browser)

      pipeline :browser do
        plug(:accepts, ["html"])
        plug(:fetch_session)
        plug(:fetch_live_flash)
        plug(:put_root_layout, html: {unquote(layout_mod), :root})
        plug(:protect_from_forgery)
        plug(:put_secure_browser_headers)
      end
    end
  end
end
