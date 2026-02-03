defmodule Arbor.Dashboard.Endpoint do
  @moduledoc false

  use Arbor.Web.Endpoint, otp_app: :arbor_dashboard

  plug Arbor.Dashboard.Router
end
