defmodule Arbor.Dashboard.Nav do
  @moduledoc false
  @doc """
  LiveView on_mount hook that sets shared navigation assigns.

  Assigns `app_name`, `nav_items`, and `node_info` so the
  `Arbor.Web.Layouts` app template renders the header and nav bar.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Arbor.Dashboard.Live.{EvalLive, LandingLive, SignalsLive}

  @nav_entries [
    %{href: "/", label: "Home", icon: "\u{1F3E0}", view: LandingLive},
    %{href: "/signals", label: "Signals", icon: "\u{1F4E1}", view: SignalsLive},
    %{href: "/eval", label: "Eval", icon: "\u{1F4CA}", view: EvalLive}
  ]

  def on_mount(:default, _params, _session, socket) do
    current_view = socket.view

    nav_items =
      Enum.map(@nav_entries, fn entry ->
        Map.put(entry, :active, entry.view == current_view)
      end)

    socket =
      socket
      |> assign(:app_name, "Arbor Dashboard")
      |> assign(:nav_items, nav_items)
      |> assign(:node_info, node() |> to_string())

    {:cont, socket}
  end
end
