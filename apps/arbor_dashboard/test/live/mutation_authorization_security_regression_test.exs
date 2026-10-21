defmodule Arbor.Dashboard.Live.MutationAuthorizationSecurityRegressionTest do
  use Arbor.Dashboard.ConnCase, async: false

  alias Arbor.Security.SessionToken

  @moduletag :fast
  @subject "human_mutation_viewer"

  defmodule AuthorizationStub do
    def authorize(actor, resource, action, opts) do
      send(
        Application.fetch_env!(:arbor_dashboard, :mutation_test_observer),
        {:mutation_authorization, actor, resource, action, opts}
      )

      case Application.fetch_env!(:arbor_dashboard, :mutation_test_result) do
        :raise -> raise "security unavailable"
        :exit -> exit(:security_unavailable)
        result -> result
      end
    end
  end

  setup_all do
    :ok = Arbor.Security.TestBootstrap.start!()
    :ok = Arbor.Memory.TestBootstrap.start!()
    :ok
  end

  setup do
    keys = [
      {:arbor_security, :oidc},
      {:arbor_security, :session_token_secret},
      {:arbor_security, :session_token_module},
      {:arbor_dashboard, :mutation_security_api},
      {:arbor_dashboard, :mutation_test_observer},
      {:arbor_dashboard, :mutation_test_result}
    ]

    previous = Map.new(keys, fn {app, key} -> {{app, key}, Application.fetch_env(app, key)} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {{app, key}, {:ok, value}} -> Application.put_env(app, key, value)
        {{app, key}, :error} -> Application.delete_env(app, key)
      end)
    end)

    Application.put_env(:arbor_security, :oidc,
      providers: [%{issuer: "https://login.example", client_id: "dashboard"}]
    )

    Application.put_env(
      :arbor_security,
      :session_token_secret,
      "isolated-mutation-session-secret"
    )

    Application.put_env(:arbor_security, :session_token_module, SessionToken)
    Application.put_env(:arbor_dashboard, :mutation_security_api, Arbor.Security)
    Application.put_env(:arbor_dashboard, :mutation_test_observer, self())

    {:ok, token} = SessionToken.generate(@subject)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Map.put(:host, "localhost")
      |> Plug.Test.init_test_session(%{
        "agent_id" => @subject,
        "session_token" => token,
        "local_dev_operator" => false
      })

    %{conn: conn, token: token}
  end

  for event <- ~w(accept-proposal reject-proposal defer-proposal) do
    test "security regression: OIDC viewer without write capability cannot #{event}", %{
      conn: conn
    } do
      target = unique("agent_memory_victim")

      {:ok, proposal} =
        Arbor.Memory.create_proposal(target, :goal, %{content: "Keep private goal"})

      {:ok, view, _} = live(conn, "/memory/#{target}")

      render_click(view, unquote(event), %{"id" => proposal.id})

      assert {:ok, %{status: :pending}} = Arbor.Memory.get_proposal(target, proposal.id)
      assert Arbor.Memory.get_active_goals(target) == []
    end
  end

  test "security regression: OIDC viewer without capability cannot create a channel", %{
    conn: conn
  } do
    name = unique("unauthorized_channel")
    {:ok, view, _} = live(conn, "/channels")
    render_click(view, "create-channel", %{"name" => name, "type" => "group"})
    assert channels_named(name) == []
  end

  test "security regression: missing principal or session proof cannot mutate proposals" do
    for identity <- [
          %{current_agent_id: nil, session_token: nil},
          %{current_agent_id: "human_dashboard", session_token: nil},
          %{current_agent_id: @subject, session_token: ""}
        ] do
      target = unique("agent_memory_victim")
      {:ok, proposal} = Arbor.Memory.create_proposal(target, :goal, %{content: "Keep goal"})

      socket =
        %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
        |> Phoenix.Component.assign(Map.merge(identity, %{agent_id: target, tab_data: %{}}))

      assert {:noreply, _} =
               Arbor.Dashboard.Live.MemoryLive.handle_event(
                 "reject-proposal",
                 %{"id" => proposal.id},
                 socket
               )

      assert {:ok, %{status: :pending}} = Arbor.Memory.get_proposal(target, proposal.id)
    end
  end

  test "security regression: only explicit authorization permits proposal mutation", %{conn: conn} do
    Application.put_env(:arbor_dashboard, :mutation_security_api, AuthorizationStub)

    for result <- [
          {:error, :unauthorized},
          {:ok, :pending_approval, "proposal_approval"},
          :authorized,
          :ok,
          nil,
          :raise,
          :exit
        ] do
      Application.put_env(:arbor_dashboard, :mutation_test_result, result)
      target = unique("agent_memory_victim")
      {:ok, proposal} = Arbor.Memory.create_proposal(target, :goal, %{content: "Keep goal"})
      {:ok, view, _} = live(conn, "/memory/#{target}")

      render_click(view, "reject-proposal", %{"id" => proposal.id})
      assert {:ok, %{status: :pending}} = Arbor.Memory.get_proposal(target, proposal.id)
      GenServer.stop(view.pid)
    end
  end

  test "a permitted decision binds the viewer, target and session while using the real proposal store",
       %{conn: conn, token: token} do
    Application.put_env(:arbor_dashboard, :mutation_security_api, AuthorizationStub)
    Application.put_env(:arbor_dashboard, :mutation_test_result, {:ok, :authorized})
    target = unique("agent_memory_victim")
    {:ok, proposal} = Arbor.Memory.create_proposal(target, :goal, %{content: "Reviewed goal"})
    {:ok, view, _} = live(conn, "/memory/#{target}")

    render_click(view, "reject-proposal", %{"id" => proposal.id, "agent_id" => @subject})

    assert_receive {:mutation_authorization, @subject, resource, :write, opts}
    assert resource == "arbor://memory/write/#{target}"
    assert opts == [session_token: token]
    assert {:ok, %{status: :rejected}} = Arbor.Memory.get_proposal(target, proposal.id)
  end

  test "a permitted channel creation records the authenticated owner", %{conn: conn, token: token} do
    Application.put_env(:arbor_dashboard, :mutation_security_api, AuthorizationStub)
    Application.put_env(:arbor_dashboard, :mutation_test_result, {:ok, :authorized})
    name = unique("authorized_channel")
    {:ok, view, _} = live(conn, "/channels")

    render_click(view, "create-channel", %{"name" => name, "type" => "group"})

    assert_receive {:mutation_authorization, @subject, "arbor://comms/channel/create", :create,
                    [session_token: ^token]}

    assert [%{owner_id: @subject}] = channels_named(name)
  end

  defp channels_named(name) do
    for {id, _pid} <- Arbor.Comms.list_channels(),
        {:ok, %{name: ^name} = channel} <- [Arbor.Comms.get_channel_info(id)],
        do: channel
  end

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"
end
