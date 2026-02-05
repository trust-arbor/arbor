defmodule Arbor.Dashboard.Router do
  @moduledoc false

  use Arbor.Web.Router

  scope "/", Arbor.Dashboard.Live do
    arbor_browser_pipeline()

    live_session :dashboard,
      layout: {Arbor.Web.Layouts, :app},
      on_mount: Arbor.Dashboard.Nav do
      live "/", LandingLive
      live "/signals", SignalsLive
      live "/eval", EvalLive
      live "/consensus", ConsensusLive
      live "/activity", ActivityLive
    end
  end
end
