defmodule Arbor.Dashboard.SessionAuthSecurityRegressionTest do
  use Arbor.Dashboard.ConnCase, async: false

  alias Arbor.Dashboard.{Nav, OidcAuth, SessionAuth}
  alias Arbor.Security
  alias Arbor.Security.SessionToken

  @moduletag :fast
  @subject "human_dashboard_session_subject"

  defmodule HookView do
    use Phoenix.LiveView
    on_mount({Arbor.Dashboard.Nav, :default})

    def mount(_params, session, socket) do
      {:ok, assign(socket, observer: session["observer"])}
    end

    def render(assigns) do
      ~H"""
      <button phx-click="effect">Effect</button>
      """
    end

    def handle_event("effect", _params, socket) do
      send(socket.assigns.observer, :private_event_callback)
      {:noreply, socket}
    end

    def handle_info(:effect, socket) do
      send(socket.assigns.observer, :private_info_callback)
      {:noreply, socket}
    end
  end

  setup do
    keys = [
      {:arbor_security, :oidc},
      {:arbor_security, :session_token_secret},
      {:arbor_security, :session_token_module},
      {:arbor_dashboard, :session_auth_api}
    ]

    previous = Map.new(keys, fn {app, key} -> {{app, key}, Application.fetch_env(app, key)} end)

    Application.put_env(:arbor_security, :oidc,
      providers: [%{issuer: "https://login.example", client_id: "dashboard"}]
    )

    Application.put_env(
      :arbor_security,
      :session_token_secret,
      "isolated-dashboard-session-secret"
    )

    Application.put_env(:arbor_security, :session_token_module, SessionToken)
    Application.put_env(:arbor_dashboard, :session_auth_api, Arbor.Security)

    on_exit(fn ->
      Enum.each(previous, fn
        {{app, key}, {:ok, value}} -> Application.put_env(app, key, value)
        {{app, key}, :error} -> Application.delete_env(app, key)
      end)
    end)

    :ok
  end

  test "valid exact-subject OIDC proof preserves HTTP and LiveView identity" do
    session = session(:valid)
    conn = request(session)
    refute conn.halted
    assert conn.assigns.current_agent_id == @subject
    assert {:cont, socket} = Nav.on_mount(:default, %{}, session, socket())
    assert socket.assigns.current_agent_id == @subject
    assert socket.assigns.authenticated?
  end

  for kind <- [:expired, :wrong_subject, :malformed, :scoped] do
    test "security regression: HTTP rejects #{kind} proof instead of trusting cookie presence" do
      conn = request(session(unquote(kind)))
      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/auth/login"]
      assert get_session(conn, "return_to") == "/chat?agent_id=agent_target"

      for key <- ["agent_id", "user_display_name", "session_token", "local_dev_operator"],
          do: refute(get_session(conn, key))

      refute conn.assigns[:current_agent_id]
      refute conn.assigns[:current_user_display_name]
    end

    test "security regression: LiveView reconnect rejects #{kind} proof before identity assignment" do
      assert {:halt, socket} = Nav.on_mount(:default, %{}, session(unquote(kind)), socket())
      assert socket.redirected == {:redirect, %{status: 302, to: "/auth/login"}}
      refute socket.assigns[:current_agent_id]
      refute socket.assigns[:current_user_display_name]
      refute socket.assigns[:session_token]
      refute socket.assigns[:tenant_context]
      refute socket.assigns[:authenticated?]
    end
  end

  test "security regression: expired proof cannot mount a connected LiveView", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/login"}}} =
             live_isolated(conn, HookView, session: session(:expired))
  end

  test "security regression: session denial queues exact-subject private storage clearing before redirect" do
    assert {:cont, authorized} = Nav.on_mount(:default, %{}, session(:valid), socket())
    Application.put_env(:arbor_security, :session_token_secret, "rotated-test-secret")
    assert {:halt, denied} = SessionAuth.guard_socket(authorized)

    assert Phoenix.LiveView.Utils.get_push_events(denied) == [
             ["conversation-access-denied", %{}],
             ["conversation-home-clear", %{subject: @subject}]
           ]

    assert denied.redirected == {:redirect, %{status: 302, to: "/auth/login"}}

    for key <- [:current_agent_id, :current_user_display_name, :session_token, :tenant_context],
        do: assert(is_nil(denied.assigns[key]))

    refute denied.assigns.local_dev_operator?
    refute denied.assigns.authenticated?
    refute inspect(Phoenix.LiveView.Utils.get_push_events(denied)) =~ "rotated-test-secret"
  end

  test "security regression: event hook redirects invalidated proof before private callback", %{
    conn: conn
  } do
    {:ok, view, _html} =
      live_isolated(conn, HookView, session: Map.put(session(:valid), "observer", self()))

    Application.put_env(:arbor_security, :session_token_secret, "rotated-test-secret")
    render_click(view, "effect")
    assert_push_event(view, "conversation-access-denied", %{})
    assert_push_event(view, "conversation-home-clear", %{subject: @subject})
    assert_redirect(view, "/auth/login")
    refute_received :private_event_callback
  end

  test "security regression: info hook redirects invalidated proof before private callback", %{
    conn: conn
  } do
    {:ok, view, _html} =
      live_isolated(conn, HookView, session: Map.put(session(:valid), "observer", self()))

    Application.put_env(:arbor_security, :session_token_secret, "rotated-test-secret")
    send(view.pid, :effect)
    assert_push_event(view, "conversation-access-denied", %{})
    assert_push_event(view, "conversation-home-clear", %{subject: @subject})
    assert_redirect(view, "/auth/login")
    refute_received :private_info_callback
  end

  test "no-OIDC local mode remains available without creating a session proof" do
    Application.put_env(:arbor_security, :oidc, [])
    conn = request(%{})
    refute conn.halted
    refute get_session(conn, "session_token")
    assert {:cont, socket} = Nav.on_mount(:default, %{}, get_session(conn), socket())
    assert socket.assigns.local_dev_operator?
    refute socket.assigns.session_token
  end

  defp request(session) do
    Plug.Test.conn(:get, "http://localhost/chat?agent_id=agent_target")
    |> Plug.Test.init_test_session(session)
    |> OidcAuth.call([])
  end

  defp socket do
    %Phoenix.LiveView.Socket{
      view: HookView,
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{push_events: nil}}
    }
  end

  defp session(kind) do
    token =
      case kind do
        :valid ->
          signed(@subject)

        :expired ->
          {:ok, expired} = SessionToken.generate_expired_fixture(@subject)
          expired

        :wrong_subject ->
          signed("human_other_subject")

        :malformed ->
          "not-a-session-proof"

        :scoped ->
          elem(Security.issue_conversation_session_fixture(@subject, "agent_target"), 1)
      end

    %{
      "agent_id" => @subject,
      "user_display_name" => "Private name",
      "session_token" => token,
      "local_dev_operator" => false
    }
  end

  defp signed(subject, opts \\ []) do
    {:ok, token} = SessionToken.generate(subject, opts)
    token
  end
end
