defmodule Arbor.Dashboard.ConversationNavigationSecurityRegressionTest do
  use Arbor.Dashboard.ConnCase, async: false

  alias Arbor.Security.SessionToken

  @moduletag :fast
  @subject "human_navigation_test"
  @static_error "Conversation link is invalid. Open Home and select a conversation."

  test "legacy selected links preserve exactly the target in a temporary local redirect", %{
    conn: conn
  } do
    for target <- [
          "agent_selected",
          "agent_" <> String.duplicate("a", 32),
          "agent_" <> String.duplicate("b", 64)
        ] do
      response =
        get(
          conn,
          "/chat?agent_id=#{target}&session_token=private-navigation-sentinel&return_to=https%3A%2F%2Felsewhere.example"
        )

      assert redirected_to(response, 302) == "/conversation/#{target}"
      assert get_resp_header(response, "cache-control") == ["no-store"]
      refute response.resp_body =~ "private-navigation-sentinel"
      refute response.resp_body =~ "elsewhere.example"
    end
  end

  test "missing legacy target opens Home and never chooses a running agent", %{conn: conn} do
    for path <- [
          "/chat",
          "/chat?unrelated=agent_other",
          "/chat?session_token=private-navigation-sentinel"
        ] do
      response = get(conn, path)
      assert redirected_to(response, 302) == "/"
      refute response.resp_body =~ "private-navigation-sentinel"
    end
  end

  @tag :navigation_predecessor
  test "security regression: duplicate legacy targets are refused before a conversation can mount",
       %{conn: conn} do
    for query <- [
          "agent_id=agent_allowed&agent_id=agent_other",
          "agent_id=agent_allowed&agent_id=agent_allowed",
          "agent_id=agent_allowed&%61gent_id=agent_other"
        ] do
      response = get(conn, "/chat?" <> query)
      assert response(response, 400) == @static_error
      assert get_resp_header(response, "location") == []
      refute response.resp_body =~ "agent_allowed"
      refute response.resp_body =~ "agent_other"
      refute response.resp_body =~ "data-phx-session"
    end
  end

  test "security regression: malformed and structured legacy targets fail statically without fallback",
       %{conn: conn} do
    for query <- [
          "agent_id=",
          "agent_id",
          "agent_id=human_other",
          "agent_id=agent_a%2F..%2Fagent_other",
          "agent_id=agent_a%3Fagent_id%3Dagent_other",
          "agent_id=agent_a%0D%0A",
          "agent_id=agent_%E2%98%83",
          "agent_id[]=agent_allowed",
          "agent_id[other]=agent_other",
          "agent_id=agent_" <> String.duplicate("a", 251),
          "agent_id=agent_allowed&unrelated=" <> String.duplicate("a", 4096),
          "agent_id=agent_allowed&" <> Enum.map_join(1..64, "&", fn n -> "field#{n}=value" end)
        ] do
      response = get(conn, "/chat?" <> query)
      assert response(response, 400) == @static_error
      assert get_resp_header(response, "location") == []
      assert get_resp_header(response, "cache-control") == ["no-store"]
      refute response.resp_body =~ "agent_other"
      refute response.resp_body =~ "data-phx-session"
    end
  end

  test "decoded recognized key and target retain their exact destination", %{conn: conn} do
    response = get(conn, "/chat?%61gent_id=agent_%73elected")
    assert redirected_to(response, 302) == "/conversation/agent_selected"
  end

  test "bounded legacy links retain supported target and query limits", %{conn: conn} do
    target = "agent_" <> String.duplicate("a", 250)

    assert conn |> get("/chat?agent_id=" <> target) |> redirected_to(302) ==
             "/conversation/" <> target

    query = "agent_id=agent_selected&unrelated="
    query = query <> String.duplicate("a", 4096 - byte_size(query))

    assert conn |> get("/chat?" <> query) |> redirected_to(302) ==
             "/conversation/agent_selected"

    query = "agent_id=agent_selected&" <> Enum.map_join(1..63, "&", fn n -> "field#{n}=value" end)

    assert conn |> get("/chat?" <> query) |> redirected_to(302) ==
             "/conversation/agent_selected"
  end

  test "security regression: undecodable query input is refused before navigation", %{conn: conn} do
    for query <- ["agent_id=agent_a%", "agent_id=agent_a%GG"] do
      response = get(conn, "/chat?" <> query)
      assert response(response, 400) == @static_error
      assert get_resp_header(response, "location") == []
    end

    {400, headers, body} = assert_error_sent(400, fn -> get(conn, "/chat?agent_id=agent_%FF") end)
    refute List.keyfind(headers, "location", 0)
    refute body =~ "agent_%FF"
    refute body =~ "data-phx-session"
  end

  test "Agents navigation opens the exact canonical conversation target", %{conn: conn} do
    {:ok, view, _} = live(conn, "/agents")
    render_click(view, "chat-agent", %{"id" => "agent_selected"})
    assert_redirect(view, "/conversation/agent_selected")
  end

  @tag :navigation_predecessor
  test "security regression: Agents navigation refuses a selector containing an injected second target",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/agents")
    html = render_click(view, "chat-agent", %{"id" => "agent_allowed&agent_id=agent_other"})
    assert is_binary(html)
    assert html =~ "Conversation link is invalid."
    assert has_element?(view, "#agents-stream")
    refute html =~ "agent_other"
  end

  test "security regression: invalid Agents target shapes remain on the Agents page", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/agents")

    for params <- [
          %{},
          %{"id" => nil},
          %{"id" => ["agent_other"]},
          %{"id" => "human_other"},
          %{"id" => "agent_a/agent_other"}
        ] do
      html = render_click(view, "chat-agent", params)
      assert html =~ "Conversation link is invalid."
      assert has_element?(view, "#agents-stream")
    end
  end

  test "legacy and canonical links preserve the browser authentication gate", %{conn: conn} do
    configure_oidc!()

    for path <- ["/chat?agent_id=agent_selected", "/conversation/agent_selected", "/", "/console"] do
      response = get(conn, path)
      assert redirected_to(response, 302) == "/auth/login"
      assert get_session(response, "return_to") == path
      refute get_session(response, "agent_id")
    end
  end

  test "signed-in legacy redirect retains browser identity without forwarding credentials", %{
    conn: conn
  } do
    configure_oidc!()
    {:ok, token} = SessionToken.generate(@subject)

    response =
      conn
      |> init_test_session(%{"agent_id" => @subject, "session_token" => token})
      |> get("/chat?agent_id=agent_selected&session_token=private-query-sentinel")

    assert redirected_to(response, 302) == "/conversation/agent_selected"
    assert get_session(response, "agent_id") == @subject
    assert get_session(response, "session_token") == token
    refute response.resp_body =~ token
    refute response.resp_body =~ "private-query-sentinel"
  end

  defp configure_oidc! do
    settings = [
      {:arbor_security, :oidc,
       [providers: [%{issuer: "https://navigation.fixture", client_id: "dashboard"}]]},
      {:arbor_security, :session_token_secret, "isolated-navigation-session-secret"},
      {:arbor_security, :session_token_module, SessionToken},
      {:arbor_dashboard, :session_auth_api, Arbor.Security}
    ]

    for {app, key, value} <- settings do
      previous = Application.fetch_env(app, key)
      Application.put_env(app, key, value)

      on_exit(fn ->
        case previous do
          {:ok, old} -> Application.put_env(app, key, old)
          :error -> Application.delete_env(app, key)
        end
      end)
    end
  end
end
