defmodule Arbor.Dashboard.Endpoint do
  @moduledoc false

  use Arbor.Web.Endpoint, otp_app: :arbor_dashboard

  # HTTP Basic Auth when DASHBOARD_USER/DASHBOARD_PASS are configured; a
  # no-op otherwise. This plug existed but was never mounted, so the
  # documented credentials gated nothing (2026-10-11 cross-library review
  # F-012). It runs before OIDC so a LAN-exposed dev dashboard can at least
  # be password-protected without an identity provider.
  plug Arbor.Dashboard.Auth

  # OIDC auth — redirects to provider or passes through in dev
  plug Arbor.Dashboard.OidcAuth

  plug Arbor.Dashboard.Router
end
