defmodule Arbor.Dashboard.ConversationNavigationTest do
  use Arbor.Dashboard.ConnCase, async: false

  @moduletag :fast

  test "all conversation entry routes share compact Home and Console navigation", %{conn: conn} do
    for path <- [
          "/",
          "/home",
          "/c/eng_11111111111111111111111111111111",
          "/conversation/agent_navigation"
        ] do
      html = conn |> get(path) |> html_response(200) |> Floki.parse_document!()
      links = Floki.find(html, ".aw-header > .aw-nav .aw-nav-link")

      assert Enum.map(links, &Floki.attribute(&1, "href")) == [["/"], ["/console"]]

      assert Enum.map(links, &(Floki.text(&1) |> String.replace(~r/\s+/, " ") |> String.trim())) ==
               [
                 "🏠 Home",
                 "⬢ Console"
               ]

      assert Floki.find(html, ".aw-header > .aw-nav .aw-nav-active") |> Floki.attribute("href") ==
               ["/"]

      refute Floki.text(html) =~ "Open existing chat"
    end
  end

  test "Console keeps the existing operator destinations reachable", %{conn: conn} do
    html = conn |> get("/console") |> html_response(200) |> Floki.parse_document!()
    links = Floki.find(html, ".aw-header > .aw-nav .aw-nav-link")

    assert Enum.map(links, &Floki.attribute(&1, "href")) == [
             ["/"],
             ["/console"],
             ["/signals"],
             ["/eval"],
             ["/consensus"],
             ["/events"],
             ["/agents"],
             ["/monitor"],
             ["/roadmap"],
             ["/channels"],
             ["/memory"],
             ["/telemetry"],
             ["/settings"]
           ]

    assert Floki.find(html, ".aw-header > .aw-nav .aw-nav-active") |> Floki.attribute("href") == [
             "/console"
           ]
  end
end
