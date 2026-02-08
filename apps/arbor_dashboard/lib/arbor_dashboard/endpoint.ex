defmodule Arbor.Dashboard.Endpoint do
  @moduledoc false

  use Arbor.Web.Endpoint, otp_app: :arbor_dashboard

  # H5: HTTP Basic Auth for dashboard access
  plug Arbor.Dashboard.Auth

  plug Arbor.Dashboard.Router
end
