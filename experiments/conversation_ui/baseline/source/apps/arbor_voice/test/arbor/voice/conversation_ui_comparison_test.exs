defmodule ConversationComparison.RealGatewayTest do
  use Arbor.Voice.ConversationCrossSurfaceFixture
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Arbor.Client.Login
  alias Arbor.Security
  alias Arbor.Security.OIDCTestHelper

  @endpoint ConversationDemo.Endpoint
  @moduletag :ui_comparison_real_gateway

  # The real DeviceFlow performs HTTP to this deterministic provider. JWT
  # verification uses the real verifier and a test-owned cached public JWKS.
  # No terminal key file, signature proxy, live provider, or native audio is used.
  defmodule Provider do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, opts) do
      state = Agent.get(Keyword.fetch!(opts, :state), & &1)
      {:ok, body, conn} = read_body(conn, length: 8_192)
      params = URI.decode_query(body)

      reply =
        cond do
          params["client_id"] != state.client_id or
              params["client_secret"] != state.secret ->
            {400, %{error: "invalid_client"}}

          conn.method == "POST" and conn.request_path == "/device" ->
            send(state.observer, :provider_device_started)

            {200,
             %{
               device_code: state.device_code,
               user_code: "ABCD-EFGH",
               # Public browser instructions exercise the local provider shape;
               # device/token HTTP stays on the test-owned literal-loopback port.
               verification_uri: "http://localhost:8080/activate",
               expires_in: 30,
               interval: 1
             }}

          conn.method == "POST" and conn.request_path == "/token" and
            params["device_code"] == state.device_code and
              params["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code" ->
            send(state.observer, :provider_token_polled)
            {200, %{id_token: state.id_token}}

          true ->
            {400, %{error: "invalid_request"}}
        end

      {status, body} = reply
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
    end
  end

  setup c do
    assert Application.get_env(:arbor_gateway, :terminal_login_security, Arbor.Security) ==
             Arbor.Security

    assert Application.get_env(:arbor_gateway, :chat_agent_facade, Arbor.Agent) == Arbor.Agent

    assert Keyword.get(
             Application.get_env(:arbor_security, :terminal_login, []),
             :device_flow_module,
             Arbor.Security.OIDC.DeviceFlow
           ) == Arbor.Security.OIDC.DeviceFlow

    oidc =
      OIDCTestHelper.issue_identity(
        issuer: c.secondary.metadata["oidc_issuer"],
        subject: c.secondary.metadata["oidc_sub"],
        client_id: "terminal-device-client",
        expires_in: if(c[:connection_lifetime], do: 10, else: 3_600)
      )

    assert oidc.identity.agent_id == c.secondary.agent_id
    secret = "fixture-confidential-client-#{System.unique_integer([:positive])}"
    observer = self()

    provider_state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             observer: observer,
             client_id: oidc.provider.client_id,
             secret: secret,
             id_token: oidc.id_token,
             device_code: "fixture-device-code"
           }
         end}
      )

    provider_ref = {__MODULE__, :provider, make_ref()}
    gateway_ref = {__MODULE__, :gateway, make_ref()}

    {:ok, _} =
      Plug.Cowboy.http(Provider, [state: provider_state],
        ref: provider_ref,
        ip: {127, 0, 0, 1},
        port: 0
      )

    {:ok, _} =
      Plug.Cowboy.http(Arbor.Gateway.Router, [],
        ref: gateway_ref,
        ip: {127, 0, 0, 1},
        port: 0
      )

    on_exit(fn ->
      :ok = Plug.Cowboy.shutdown(gateway_ref)
      :ok = Plug.Cowboy.shutdown(provider_ref)
      oidc.cleanup.()
    end)

    provider_url = "http://127.0.0.1:#{:ranch.get_port(provider_ref)}"

    device_config =
      Map.merge(oidc.provider, %{
        client_secret: secret,
        allow_http: true,
        # Pinning skips discovery fetching; cross-origin endpoints still require
        # explicit trust. Authorize only this test-owned provider listener.
        trusted_origins: [provider_url],
        endpoints: %{
          device_authorization_endpoint: provider_url <> "/device",
          token_endpoint: provider_url <> "/token"
        }
      })

    save_env(:arbor_security, :oidc,
      # Device client differs from browser client. The host must select its
      # configured device policy, never JwtAuth's browser audience by accident.
      providers: [Map.put(oidc.provider, :client_id, "browser-client")],
      device_flow: device_config
    )

    if c[:connection_lifetime] do
      previous = Application.fetch_env(:arbor_security, :terminal_login)

      Application.put_env(:arbor_security, :terminal_login,
        # Retain the old option as a regression trigger for the original host.
        # The connection-lifetime host no longer gives it session-age meaning.
        session_seconds: 1,
        attach_seconds: 1,
        reconnect_seconds: 2
      )

      restart_terminal_login!()

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:arbor_security, :terminal_login, value)
          :error -> Application.delete_env(:arbor_security, :terminal_login)
        end

        restart_terminal_login!()
      end)

      save_env(:arbor_gateway, :terminal_session_keepalive,
        interval_ms: 100,
        timeout_ms: 500,
        idle_timeout_ms: 1_000
      )
    end

    unless Process.whereis(Arbor.Security.TerminalLogin),
      do: start_supervised!({Arbor.Security.TerminalLogin, []})

    %{url: "ws://127.0.0.1:#{:ranch.get_port(gateway_ref)}", oidc_expires_at: oidc.claims["exp"]}
  end

  defmodule ComparisonProvider do
    def provider, do: "lm_studio"
    def runtime_contract, do: %Arbor.Contracts.AI.RuntimeContract{}

    def complete(request, opts) do
      {:ok, response} = Fixture.CaptureProvider.complete(request, opts)
      metrics = Application.fetch_env!(:arbor_voice, :cross_surface_metrics)
      first? = Agent.get(metrics, &(length(&1.requests) == 1))

      text =
        if first? do
          ConversationDemo.Question.encode_question(%{
            "id" => "destination",
            "revision" => 1,
            "prompt" => "Which route should we inspect?",
            "options" => [
              %{"id" => "web", "label" => "Web"},
              %{"id" => "terminal", "label" => "Terminal"},
              %{"id" => "voice", "label" => "Voice"}
            ]
          })
        else
          "Conversation received."
        end

      {:ok, %{response | text: text, content_parts: [Arbor.LLM.ContentPart.text(text)]}}
    end

    def complete_single_attempt(request, opts), do: complete(request, opts)
  end

  @tag timeout: 60_000
  test "JavaScript store joins authenticated Gateway and baseline renderers without exporting a key",
       c do
    before = Arbor.LLM.Client.default_client()

    client =
      Arbor.LLM.Client.new(default_provider: "lm_studio")
      |> Arbor.LLM.Client.register_adapter(ComparisonProvider)

    Arbor.LLM.Client.set_default_client(client)
    on_exit(fn -> Arbor.LLM.Client.set_default_client(before) end)
    {:ok, web, _} = live(build_conn(), "/arbor")
    web |> form("#composer", text: "Show the route question") |> render_submit()
    Fixture.completed!(c, Fixture.latest_command(c).id)
    web |> element("#refresh") |> render_click()
    assert has_element?(web, "#structured-question")

    terminal =
      Breeze.Test.start!(ConversationDemo.ArborBreezeView,
        size: {110, 55},
        start_opts: [
          client_options: Fixture.client_options(c.secondary.agent_id, c.target, c.voice_token)
        ]
      )

    on_exit(fn -> Breeze.Test.stop(terminal) end)
    assert Breeze.Test.render_text!(terminal) =~ "Which route should we inspect?"
    session = login!(c)

    directory =
      Path.join(
        System.tmp_dir!(),
        "conversation-comparison-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    path = Path.join(directory, "node-session.json")

    config = %{
      gatewayUrl: String.replace_prefix(c.url, "ws://", "http://"),
      caller: session.principal,
      target: c.target,
      credential: session.credential
    }

    File.write!(path, Jason.encode!(config), [:exclusive])
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm_rf!(directory) end)
    javascript = System.fetch_env!("CONVERSATION_COMPARISON_NODE_SCRIPT")
    expected = Path.expand("../../../../../../../typescript/tests/real_gateway.mjs", __DIR__)

    unless Path.expand(javascript) == expected and File.regular?(expected),
      do: raise("closed comparison Node entrypoint required")

    node = System.find_executable("node") || raise("Node is unavailable")

    {output, status} =
      try do
        System.cmd(node, ["--import", "tsx", expected, path],
          cd: Path.dirname(Path.dirname(expected)),
          stderr_to_stdout: true
        )
      after
        File.rm!(path)
      end

    assert status == 0,
           "Node comparison failed; sanitized output hash #{Base.encode16(:crypto.hash(:sha256, output))}"

    assert {:ok, result} = Jason.decode(output)
    assert result["status"] == "passed"

    assert Enum.sort(Map.keys(result)) == [
             "claims",
             "journalCursor",
             "status",
             "transcriptCount",
             "transcriptIdHash"
           ]

    web |> element("#refresh") |> render_click()
    Breeze.Test.event(terminal, "chat:refresh", %{})
    assert has_element?(web, "#question-status", "completed")
    assert Breeze.Test.render_text!(terminal) =~ "[completed]"
    assert length(Fixture.history(c).entries) == result["transcriptCount"]
    assert Fixture.metrics(c).captures == []
    assert Fixture.metrics(c).playbacks == []
    IO.puts("UI_COMPARISON_REAL_GATEWAY=" <> Jason.encode!(result))
  end

  defp login!(c) do
    assert {:ok, pending} = Login.start(c.url, c.target)
    assert pending.user_code == "ABCD-EFGH"
    assert pending.verification_uri == "http://localhost:8080/activate"
    assert_receive :provider_device_started, 5_000
    on_exit(fn -> Login.cancel(c.url, pending.handle) end)
    session = poll!(c.url, pending.handle, System.monotonic_time(:millisecond) + 10_000)
    assert_receive :provider_token_polled, 5_000
    assert {:error, _} = Login.poll(c.url, pending.handle)
    on_exit(fn -> Security.revoke_terminal_session(session.credential) end)
    session
  end

  defp poll!(url, handle, deadline) do
    assert System.monotonic_time(:millisecond) < deadline

    case Login.poll(url, handle) do
      {:ok, :pending} ->
        Process.sleep(100)
        poll!(url, handle, deadline)

      {:ok, session} when is_map(session) ->
        session

      _ ->
        flunk("terminal login did not complete")
    end
  end

  defp save_env(app, key, value) do
    before = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case before do
        {:ok, original} -> Application.put_env(app, key, original)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp restart_terminal_login! do
    assert :ok =
             Supervisor.terminate_child(Arbor.Security.Supervisor, Arbor.Security.TerminalLogin)

    assert {:ok, _} =
             Supervisor.restart_child(Arbor.Security.Supervisor, Arbor.Security.TerminalLogin)
  end
end
