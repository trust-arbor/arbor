defmodule Arbor.Dashboard.Test.LegacyChatRouter do
  @moduledoc false
  use Arbor.Web.Router

  # Retained legacy behavior is exercised through an explicitly test-only
  # route. Production /chat is a redirect and never mounts ChatLive.
  scope "/", Arbor.Dashboard.Live do
    arbor_browser_pipeline()

    live_session :legacy_chat_test,
      layout: {Arbor.Web.Layouts, :app},
      session: {Arbor.Dashboard.Router, :live_session_data, []},
      on_mount: Arbor.Dashboard.Nav do
      live "/chat", ChatLive
    end
  end

  forward "/", Arbor.Dashboard.Router
end

defmodule Arbor.Dashboard.Test.LegacyChatEndpoint do
  @moduledoc false
  use Arbor.Web.Endpoint, otp_app: :arbor_dashboard

  plug Arbor.Dashboard.OidcAuth
  plug Arbor.Dashboard.Test.LegacyChatRouter
end

defmodule Arbor.Dashboard.Test.LegacyChatFixture do
  @moduledoc false

  def start! do
    endpoint = Arbor.Dashboard.Test.LegacyChatEndpoint
    previous = Application.fetch_env(:arbor_dashboard, endpoint)

    config =
      :arbor_dashboard
      |> Application.fetch_env!(Arbor.Dashboard.Endpoint)
      |> Keyword.put(:server, false)

    Application.put_env(:arbor_dashboard, endpoint, config)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_dashboard, endpoint, value)
        :error -> Application.delete_env(:arbor_dashboard, endpoint)
      end
    end)

    ExUnit.Callbacks.start_supervised!(endpoint)
    :ok
  end
end
