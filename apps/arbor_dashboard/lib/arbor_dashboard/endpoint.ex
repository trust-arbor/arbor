defmodule Arbor.Dashboard.Endpoint do
  @moduledoc false

  use Arbor.Web.Endpoint, otp_app: :arbor_dashboard

  # OIDC auth (replaces HTTP Basic Auth) — redirects to provider or passes through in dev
  plug Arbor.Dashboard.OidcAuth

  plug Arbor.Dashboard.Router
end
