defmodule Arbor.Web.Endpoint do
  @moduledoc """
  Macro for Phoenix endpoint boilerplate shared across Arbor dashboards.

  Configures LiveView socket, static file serving, session management,
  telemetry, and standard plugs.

  ## Usage

      defmodule MyApp.Endpoint do
        use Arbor.Web.Endpoint, otp_app: :my_app
      end

  ## Options

    * `:otp_app` - The OTP application name (required)
    * `:session_key` - Session cookie key (default: "_arbor_\#{otp_app}_key")
    * `:session_salt` - Session signing salt (default: "arbor_\#{otp_app}")
    * `:static_from` - Static file source (default: `{otp_app, "priv/static"}`)
    * `:static_only` - Allowed static file patterns (default: standard web assets)
  """

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    session_key = Keyword.get(opts, :session_key, "_arbor_#{otp_app}_key")
    session_salt = Keyword.get(opts, :session_salt, "arbor_#{otp_app}")

    static_from =
      Keyword.get_lazy(opts, :static_from, fn ->
        {otp_app, "priv/static"}
      end)

    static_only =
      Keyword.get(
        opts,
        :static_only,
        ~w(assets fonts images css js favicon.ico robots.txt arbor_web.css arbor_web.js)
      )

    quote do
      use Phoenix.Endpoint, otp_app: unquote(otp_app)

      # LiveView socket
      socket("/live", Phoenix.LiveView.Socket,
        websocket: [connect_info: [:peer_data, :x_headers]]
      )

      # Static files
      plug(Plug.Static,
        at: "/",
        from: unquote(static_from),
        gzip: false,
        only: unquote(static_only)
      )

      # Also serve arbor_web shared static assets
      plug(Plug.Static,
        at: "/assets",
        from: {:arbor_web, "priv/static"},
        gzip: false,
        only: ~w(arbor_web.css arbor_web.js)
      )

      # Code reloading in dev (use config check to avoid macro hygiene issues)
      if Application.compile_env(unquote(otp_app), __MODULE__)[:code_reloader] do
        plug(Phoenix.CodeReloader)
      end

      plug(Plug.RequestId)
      plug(Plug.Telemetry, event_prefix: [:arbor, :web, :endpoint])

      # Tidewave AI integration (dev only, before body parsing)
      if Code.ensure_loaded?(Tidewave) do
        plug(Tidewave)
      end

      plug(Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Jason
      )

      plug(Plug.MethodOverride)
      plug(Plug.Head)

      plug(Plug.Session,
        store: :cookie,
        key: unquote(session_key),
        signing_salt: unquote(session_salt)
      )
    end
  end
end
