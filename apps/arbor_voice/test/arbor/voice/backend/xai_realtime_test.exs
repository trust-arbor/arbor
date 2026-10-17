defmodule Arbor.Voice.Backend.XaiRealtimeTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Arbor.Voice.Backend.XaiRealtime
  alias Arbor.Voice.Backend.XaiRealtime.Transport
  alias Arbor.Voice.Test.XaiRealtimeFakeTransport, as: FakeTransport

  @moduletag :fast

  defmodule TokenBearingTransport do
    @moduledoc false

    def connect(opts) do
      {:ok,
       %{
         token: Keyword.fetch!(opts, :token),
         mode: Keyword.get(opts, :mode, :ok),
         frames: []
       }}
    end

    def send_frame(%{mode: :send_error, token: token}, _frame),
      do: {:error, {:echoed_token, token}}

    def send_frame(state, _frame), do: {:ok, state}

    def send_frame(state, frame, _deadline), do: send_frame(state, frame)

    def recv_frame(%{mode: :recv_error, token: token}, _timeout),
      do: {:error, {:echoed_token, token}}

    def recv_frame(_state, _timeout), do: {:error, :timeout}

    def close(%{mode: :close_raise, token: token}), do: raise("close failed for #{token}")
    def close(%{mode: :close_error, token: token}), do: {:error, token}
    def close(%{mode: :close_throw, token: token}), do: throw(token)
    def close(%{mode: :close_exit, token: token}), do: exit(token)
    def close(_state), do: :ok
  end

  defp stub_resolver(:xai), do: {:ok, "stub-token"}
  defp allow_effect(_effect, _route), do: :allow

  defp record_event(key, event) do
    Process.put(key, Process.get(key, []) ++ [event])
    :ok
  end

  defp reset_events(key), do: Process.put(key, [])
  defp events(key), do: Process.get(key, [])

  defp authorizer_fault(:deny, secret), do: {:error, {:distinctive_denial, secret}}
  defp authorizer_fault(:malformed, secret), do: %{malformed: secret}
  defp authorizer_fault(:raise, secret), do: raise("authorizer raised #{secret}")
  defp authorizer_fault(:throw, secret), do: throw({:authorizer_threw, secret})
  defp authorizer_fault(:exit, secret), do: exit({:authorizer_exited, secret})

  # ── VOICE-8: tool-call mapping, send_tool_result sequencing, malformed args ──

  @tag spec: "VOICE-8"
  test "a function_call_arguments.done frame yields a :tool_call event" do
    frame = %{
      "type" => "response.function_call_arguments.done",
      "call_id" => "call_1",
      "name" => "delegate_to_agent",
      "arguments" => Jason.encode!(%{"provider" => "codex", "task" => "hi"})
    }

    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        transport_opts: [frames: [frame]],
        effect_authorizer: &allow_effect/2,
        oauth_resolver: &stub_resolver/1
      )

    assert {:ok, _session,
            {:tool_call, %{id: "call_1", name: "delegate_to_agent", arguments: args}}} =
             XaiRealtime.recv(session, 1_000)

    assert args == %{"provider" => "codex", "task" => "hi"}
  end

  @tag spec: "VOICE-8"
  test "send_tool_result/3 emits function_call_output, then request_response/1 emits response.create, in order" do
    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        transport_opts: [frames: []],
        effect_authorizer: &allow_effect/2,
        oauth_resolver: &stub_resolver/1
      )

    {:ok, session} = XaiRealtime.send_tool_result(session, "call_1", "ok output")
    {:ok, session} = XaiRealtime.request_response(session)

    assert session.transport_state.sent == [
             %{
               "type" => "conversation.item.create",
               "item" => %{
                 "type" => "function_call_output",
                 "call_id" => "call_1",
                 "output" => "ok output"
               }
             },
             %{"type" => "response.create"}
           ]
  end

  @tag spec: "VOICE-8"
  test "parallel tool outputs send only items; receives never send a continuation" do
    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        transport_opts: [
          frames: [
            tool_call_frame("call_a", "lookup"),
            tool_call_frame("call_b", "lookup"),
            %{"type" => "response.done"}
          ]
        ],
        effect_authorizer: &allow_effect/2,
        oauth_resolver: &stub_resolver/1
      )

    assert {:ok, session, {:tool_call, %{id: "call_a"}}} = XaiRealtime.recv(session, 1_000)
    assert {:ok, session, {:tool_call, %{id: "call_b"}}} = XaiRealtime.recv(session, 1_000)
    assert {:ok, session, {:turn_done, _}} = XaiRealtime.recv(session, 1_000)
    assert session.transport_state.sent == []

    {:ok, session} = XaiRealtime.send_tool_result(session, "call_a", "first")
    {:ok, session} = XaiRealtime.send_tool_result(session, "call_b", "second")

    assert session.transport_state.sent == [
             function_output_frame("call_a", "first"),
             function_output_frame("call_b", "second")
           ]

    {:ok, session} = XaiRealtime.request_response(session)

    assert session.transport_state.sent == [
             function_output_frame("call_a", "first"),
             function_output_frame("call_b", "second"),
             %{"type" => "response.create"}
           ]
  end

  @tag spec: "VOICE-8"
  test "tool output and continuation each send one frame behind their own effect check" do
    key = {__MODULE__, make_ref()}
    route = XaiRealtime.egress_route()

    authorizer = fn effect, received_route ->
      record_event(key, {:authorize, effect, received_route})
      :allow
    end

    on_send = fn frame -> record_event(key, {:send, frame["type"]}) end

    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        transport_opts: [on_send: on_send],
        effect_authorizer: authorizer,
        oauth_resolver: &stub_resolver/1
      )

    reset_events(key)
    {:ok, session} = XaiRealtime.send_tool_result(session, "call_early", "early")

    assert events(key) == [
             {:authorize, :tool_result_item, route},
             {:send, "conversation.item.create"}
           ]

    reset_events(key)
    {:ok, session} = XaiRealtime.request_response(session)

    assert events(key) == [
             {:authorize, :tool_result_response, route},
             {:send, "response.create"}
           ]

    refute inspect(session) =~ "call_early"
  end

  @tag spec: "VOICE-8"
  test "malformed tool arguments yield a structured error event, not a crash" do
    frame = %{
      "type" => "response.function_call_arguments.done",
      "call_id" => "call_2",
      "name" => "delegate_to_agent",
      "arguments" => "{not json"
    }

    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        transport_opts: [frames: [frame]],
        effect_authorizer: &allow_effect/2,
        oauth_resolver: &stub_resolver/1
      )

    assert {:ok, _session, {:error, {:bad_tool_args, "delegate_to_agent"}}} =
             XaiRealtime.recv(session, 1_000)
  end

  # ── VOICE-6: credential hygiene, OAuth failure, redacted connect failures ──

  @tag spec: "VOICE-6"
  test "the token never appears in inspect(session) nor in any sent frame, though it did reach the transport" do
    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        transport_opts: [frames: []],
        effect_authorizer: &allow_effect/2,
        oauth_resolver: fn :xai -> {:ok, "super-secret-token-xyz"} end
      )

    refute inspect(session) =~ "super-secret-token-xyz"
    assert session.transport_state.captured_token == "super-secret-token-xyz"

    {:ok, session} = XaiRealtime.send_text(session, "hello")

    refute Enum.any?(session.transport_state.sent, &(inspect(&1) =~ "super-secret-token-xyz"))
  end

  @tag spec: "VOICE-6"
  test "session inspection excludes an arbitrary transport state that retains the token" do
    {:ok, session} =
      XaiRealtime.open(
        transport: TokenBearingTransport,
        effect_authorizer: &allow_effect/2,
        oauth_resolver: fn :xai -> {:ok, "transport-retained-secret"} end
      )

    assert session.transport_state.token == "transport-retained-secret"
    refute inspect(session) =~ "transport-retained-secret"
    refute inspect(session) =~ "transport_state"
  end

  @tag :security_regression
  test "session inspection redacts a populated output accumulator" do
    secret_delta = "distinctive-populated-accumulator-secret"

    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        transport_opts: [
          frames: [%{"type" => "response.output_text.delta", "delta" => secret_delta}]
        ],
        effect_authorizer: &allow_effect/2,
        oauth_resolver: &stub_resolver/1
      )

    assert {:ok, session, {:output_text_delta, ^secret_delta}} = XaiRealtime.recv(session, 1_000)
    assert session.acc == secret_delta
    refute inspect(session) =~ secret_delta
    refute inspect(session) =~ "acc:"
  end

  @tag spec: "VOICE-6"
  test "post-connect transport failures cannot echo a retained token" do
    token = "post-connect-secret"

    for {mode, operation} <- [
          {:send_error, fn session -> XaiRealtime.send_text(session, "hello") end},
          {:recv_error, fn session -> XaiRealtime.recv(session, 1_000) end}
        ] do
      {:ok, session} =
        XaiRealtime.open(
          transport: TokenBearingTransport,
          transport_opts: [mode: mode],
          effect_authorizer: &allow_effect/2,
          oauth_resolver: fn :xai -> {:ok, token} end
        )

      result = operation.(session)
      assert result == {:error, :xai_transport_failed}
      refute inspect(result) =~ token
    end

    {:ok, session} =
      XaiRealtime.open(
        transport: TokenBearingTransport,
        transport_opts: [mode: :close_raise],
        effect_authorizer: &allow_effect/2,
        oauth_resolver: fn :xai -> {:ok, token} end
      )

    assert {:error, :xai_close_failed} = XaiRealtime.close(session)
  end

  test "security regression: provider close faults are bounded uncertainty, never success" do
    for mode <- [:close_error, :close_throw, :close_exit] do
      {:ok, session} =
        XaiRealtime.open(
          transport: TokenBearingTransport,
          transport_opts: [mode: mode],
          effect_authorizer: &allow_effect/2,
          oauth_resolver: &stub_resolver/1
        )

      assert {:error, :xai_close_failed} = XaiRealtime.close(session)
    end

    {:ok, session} =
      XaiRealtime.open(
        transport: TokenBearingTransport,
        effect_authorizer: &allow_effect/2,
        oauth_resolver: &stub_resolver/1
      )

    assert :ok = XaiRealtime.close(session)
  end

  test "security regression: Mint close faults cannot become a positive transport receipt" do
    assert {:error, :close_failed} = Transport.close(%{conn: :not_a_connection})
    # A Mint logical closed flag is not independent TLS close evidence.
    assert {:error, :close_failed} = Transport.close(%{conn: struct(Mint.HTTP1, state: :closed)})
  end

  @tag spec: "VOICE-6"
  test "open/1 with a failing OAuth resolver returns {:error, _} without raising" do
    assert {:error, :oauth_login_required} =
             XaiRealtime.open(
               transport: FakeTransport,
               transport_opts: [frames: []],
               effect_authorizer: &allow_effect/2,
               oauth_resolver: fn :xai -> {:error, :oauth_login_required} end
             )
  end

  @tag spec: "VOICE-6"
  test "open/1 redacts a connect error that echoes the token" do
    assert {:error, :xai_connect_failed, :cleanup_pending} =
             XaiRealtime.open(
               transport: FakeTransport,
               transport_opts: [connect_mode: {:error_echo, "super-secret-token-xyz"}],
               effect_authorizer: &allow_effect/2,
               oauth_resolver: fn :xai -> {:ok, "super-secret-token-xyz"} end
             )
  end

  @tag spec: "VOICE-6"
  test "open/1 redacts a connect that raises with the token embedded in the exception message" do
    assert {:error, :xai_connect_failed, :cleanup_pending} =
             XaiRealtime.open(
               transport: FakeTransport,
               transport_opts: [connect_mode: {:raise_echo, "super-secret-token-xyz"}],
               effect_authorizer: &allow_effect/2,
               oauth_resolver: fn :xai -> {:ok, "super-secret-token-xyz"} end
             )
  end

  # ── Source-owned route and bounded transport_opts channel ──

  @tag :security_regression
  @tag spec: "VOICE-17"
  test "security regression: open/1 rejects top-level and nested route overrides" do
    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        host: "top-level-attacker.example",
        port: 444,
        path: "/top-level-attacker",
        effect_authorizer: &allow_effect/2,
        transport_opts: [
          frames: [],
          token: "attacker-supplied",
          host: "evil.example",
          port: 1,
          path: "/evil"
        ],
        oauth_resolver: fn :xai -> {:ok, "real-token"} end
      )

    ts = session.transport_state
    assert ts.captured_token == "real-token"
    assert ts.captured_host == "api.x.ai"
    assert ts.captured_port == 443
    assert ts.captured_path == "/v1/realtime?model=grok-voice-latest"
  end

  @tag spec: "VOICE-17"
  test "egress_route/0 returns the exact canonical xAI descriptor" do
    assert XaiRealtime.egress_route() == %{
             destination: "api.x.ai",
             provider: "xai",
             runtime: "arbor",
             model: "grok-voice-latest"
           }
  end

  # ── P2 physical-effect authorization ──

  @tag spec: "VOICE-17"
  test "connect authorization precedes OAuth and transport with only effect and exact route" do
    key = {__MODULE__, make_ref()}

    authorizer = fn effect, route ->
      record_event(key, {:authorize, effect, route})
      :allow
    end

    resolver = fn :xai ->
      record_event(key, :oauth)
      {:ok, "ordered-connect-token"}
    end

    on_connect = fn -> record_event(key, :connect) end

    assert {:ok, _session} =
             XaiRealtime.open(
               transport: FakeTransport,
               transport_opts: [on_connect: on_connect],
               effect_authorizer: authorizer,
               oauth_resolver: resolver
             )

    assert events(key) == [
             {:authorize, :connect,
              %{
                destination: "api.x.ai",
                provider: "xai",
                runtime: "arbor",
                model: "grok-voice-latest"
              }},
             :oauth,
             :connect
           ]
  end

  @tag spec: "VOICE-17"
  test "every physical frame has a distinct exact check immediately before its send" do
    key = {__MODULE__, make_ref()}
    route = XaiRealtime.egress_route()

    authorizer = fn effect, received_route ->
      record_event(key, {:authorize, effect, received_route})
      :allow
    end

    on_send = fn frame -> record_event(key, {:send, frame["type"]}) end

    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        transport_opts: [on_send: on_send],
        effect_authorizer: authorizer,
        oauth_resolver: &stub_resolver/1
      )

    reset_events(key)
    {:ok, session} = XaiRealtime.configure(session, %{})

    assert events(key) == [
             {:authorize, :configure, route},
             {:send, "session.update"}
           ]

    reset_events(key)
    {:ok, session} = XaiRealtime.send_text(session, "distinctive text")

    assert events(key) == [
             {:authorize, :text_item, route},
             {:send, "conversation.item.create"},
             {:authorize, :text_response, route},
             {:send, "response.create"}
           ]

    reset_events(key)
    {:ok, session} = XaiRealtime.send_audio(session, <<1, 2>>)

    assert events(key) == [
             {:authorize, :audio_append, route},
             {:send, "input_audio_buffer.append"},
             {:authorize, :audio_commit, route},
             {:send, "input_audio_buffer.commit"},
             {:authorize, :audio_response, route},
             {:send, "response.create"}
           ]

    reset_events(key)

    {:ok, session} =
      XaiRealtime.send_tool_result(session, "distinctive-call-id", "distinctive output")

    {:ok, _session} = XaiRealtime.request_response(session)

    assert events(key) == [
             {:authorize, :tool_result_item, route},
             {:send, "conversation.item.create"},
             {:authorize, :tool_result_response, route},
             {:send, "response.create"}
           ]
  end

  @tag :security_regression
  @tag spec: "VOICE-17"
  test "security regression: missing or faulting connect authority performs no OAuth or connect" do
    secret = "distinctive-connect-authorizer-secret"

    for mode <- [:missing, :deny, :malformed, :raise, :throw, :exit] do
      key = {__MODULE__, mode, make_ref()}

      resolver = fn :xai ->
        record_event(key, :oauth)
        {:ok, "must-not-resolve"}
      end

      on_connect = fn -> record_event(key, :connect) end

      opts = [
        transport: FakeTransport,
        transport_opts: [on_connect: on_connect],
        oauth_resolver: resolver
      ]

      opts =
        if mode == :missing do
          opts
        else
          authorizer = fn effect, route ->
            record_event(key, {:authorize, effect, route})
            authorizer_fault(mode, secret)
          end

          Keyword.put(opts, :effect_authorizer, authorizer)
        end

      result = XaiRealtime.open(opts)

      assert result == {:error, :xai_effect_not_authorized}, "mode=#{mode}"
      refute :oauth in events(key), "mode=#{mode}"
      refute :connect in events(key), "mode=#{mode}"
      refute inspect(result) =~ secret
    end
  end

  @tag :security_regression
  @tag spec: "VOICE-17"
  test "security regression: denied or faulting frame authority performs zero sends" do
    secret = "distinctive-frame-authorizer-secret"

    for mode <- [:deny, :malformed, :raise, :throw, :exit] do
      key = {__MODULE__, mode, make_ref()}

      authorizer = fn
        :connect, route ->
          record_event(key, {:authorize, :connect, route})
          :allow

        :configure, route ->
          record_event(key, {:authorize, :configure, route})
          authorizer_fault(mode, secret)
      end

      on_send = fn frame -> record_event(key, {:send, frame["type"]}) end

      {:ok, session} =
        XaiRealtime.open(
          transport: FakeTransport,
          transport_opts: [on_send: on_send],
          effect_authorizer: authorizer,
          oauth_resolver: &stub_resolver/1
        )

      reset_events(key)
      result = XaiRealtime.configure(session, %{})

      assert result == {:error, :xai_effect_not_authorized}, "mode=#{mode}"
      assert events(key) == [{:authorize, :configure, XaiRealtime.egress_route()}]
      refute inspect(result) =~ secret
      assert :ok = XaiRealtime.close(session)
    end
  end

  @tag :security_regression
  @tag spec: "VOICE-17"
  test "security regression: second text-frame denial preserves the first physical effect" do
    key = {__MODULE__, make_ref()}
    route = XaiRealtime.egress_route()

    authorizer = fn
      effect, received_route when effect in [:connect, :text_item] ->
        record_event(key, {:authorize, effect, received_route})
        :allow

      :text_response, received_route ->
        record_event(key, {:authorize, :text_response, received_route})
        {:error, :denied}
    end

    on_send = fn frame -> record_event(key, {:send, frame["type"]}) end

    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        transport_opts: [on_send: on_send],
        effect_authorizer: authorizer,
        oauth_resolver: &stub_resolver/1
      )

    reset_events(key)

    assert {:error, :xai_effect_not_authorized, latest_session} =
             XaiRealtime.send_text(session, "partial")

    assert latest_session.diagnostic_last_effect == :text_item

    assert latest_session.transport_state.sent == [
             %{
               "type" => "conversation.item.create",
               "item" => %{
                 "type" => "message",
                 "role" => "user",
                 "content" => [%{"type" => "input_text", "text" => "partial"}]
               }
             }
           ]

    assert events(key) == [
             {:authorize, :text_item, route},
             {:send, "conversation.item.create"},
             {:authorize, :text_response, route}
           ]

    refute inspect(latest_session) =~ "partial"
    assert :ok = XaiRealtime.close(latest_session)
  end

  @tag :security_regression
  @tag spec: "VOICE-17"
  test "security regression: third audio-frame denial preserves both earlier physical effects" do
    key = {__MODULE__, make_ref()}
    route = XaiRealtime.egress_route()

    authorizer = fn
      effect, received_route
      when effect in [:connect, :configure, :audio_append, :audio_commit] ->
        record_event(key, {:authorize, effect, received_route})
        :allow

      :audio_response, received_route ->
        record_event(key, {:authorize, :audio_response, received_route})
        {:error, :denied}
    end

    on_send = fn frame -> record_event(key, {:send, frame["type"]}) end

    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        transport_opts: [on_send: on_send],
        effect_authorizer: authorizer,
        oauth_resolver: &stub_resolver/1
      )

    {:ok, session} = XaiRealtime.configure(session, %{})
    reset_events(key)

    assert {:error, :xai_effect_not_authorized, latest_session} =
             XaiRealtime.send_audio(session, <<1, 2>>)

    assert events(key) == [
             {:authorize, :audio_append, route},
             {:send, "input_audio_buffer.append"},
             {:authorize, :audio_commit, route},
             {:send, "input_audio_buffer.commit"},
             {:authorize, :audio_response, route}
           ]

    assert :ok = XaiRealtime.close(latest_session)
  end

  @tag spec: "VOICE-17"
  test "session inspection redacts the retained authorizer and its captured secret" do
    secret = "captured-effect-authorizer-secret"
    key = {__MODULE__, make_ref()}

    authorizer = fn _effect, _route ->
      Process.put(key, secret)
      :allow
    end

    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        effect_authorizer: authorizer,
        oauth_resolver: &stub_resolver/1
      )

    assert Process.get(key) == secret
    refute inspect(session) =~ secret
    refute inspect(session) =~ "effect_authorizer"
    refute inspect(session) =~ "transport_state"
  end

  @tag spec: "VOICE-17"
  test "recv and close do not invoke effect authorization" do
    key = {__MODULE__, make_ref()}

    authorizer = fn effect, route ->
      record_event(key, {:authorize, effect, route})
      :allow
    end

    frame = %{"type" => "response.output_text.delta", "delta" => "ready"}

    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        transport_opts: [frames: [frame]],
        effect_authorizer: authorizer,
        oauth_resolver: &stub_resolver/1
      )

    reset_events(key)

    assert {:ok, session, {:output_text_delta, "ready"}} =
             XaiRealtime.recv(session, 1_000)

    assert :ok = XaiRealtime.close(session)
    assert events(key) == []
  end

  # ── transport-level deadline arithmetic ──

  test "Transport.remaining_budget/2 never resets across repeated internal-skip checks" do
    key = {__MODULE__, make_ref()}
    Process.put(key, [0, 40, 90, 130])

    clock_fun = fn ->
      [head | tail] = Process.get(key)
      Process.put(key, tail)
      head
    end

    deadline = 100

    assert Transport.remaining_budget(deadline, clock_fun) == 100
    assert Transport.remaining_budget(deadline, clock_fun) == 60
    assert Transport.remaining_budget(deadline, clock_fun) == 10
    assert Transport.remaining_budget(deadline, clock_fun) == :timeout
  end

  test "Transport.remaining_budget/2 preserves an infinite timeout without consulting the clock" do
    assert Transport.remaining_budget(:infinity, fn -> flunk("clock must not be consulted") end) ==
             :infinity
  end

  test "Transport upgrade handling skips foreign mailbox messages and preserves partial state" do
    assert {:continue, :current_conn, 101, []} =
             Transport.upgrade_step(:unknown, :current_conn, :request_ref, 101, [])

    assert {:continue, :next_conn, 101, nil} =
             Transport.upgrade_step(
               {:ok, :next_conn, [{:status, :request_ref, 101}]},
               :current_conn,
               :request_ref,
               nil,
               nil
             )

    assert {:complete, :final_conn, 101, [{"upgrade", "websocket"}]} =
             Transport.upgrade_step(
               {:ok, :final_conn,
                [
                  {:headers, :request_ref, [{"upgrade", "websocket"}]},
                  {:done, :request_ref}
                ]},
               :next_conn,
               :request_ref,
               101,
               nil
             )
  end

  # ── recv/2 accumulator + backend-level deadline ──

  test "response.done resets accumulated text so a reused session starts each turn clean" do
    frames = [
      %{"type" => "response.output_text.delta", "delta" => "first turn "},
      %{"type" => "response.output_text.delta", "delta" => "text"},
      %{"type" => "response.done", "response" => %{"id" => "r1"}},
      %{"type" => "response.output_text.delta", "delta" => "second turn only"},
      %{"type" => "response.done", "response" => %{"id" => "r2"}}
    ]

    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        transport_opts: [frames: frames],
        effect_authorizer: &allow_effect/2,
        oauth_resolver: &stub_resolver/1
      )

    assert {:ok, session, {:output_text_delta, "first turn "}} = XaiRealtime.recv(session, 1_000)
    assert {:ok, session, {:output_text_delta, "text"}} = XaiRealtime.recv(session, 1_000)

    assert {:ok, session, {:turn_done, %{text: "first turn text"}}} =
             XaiRealtime.recv(session, 1_000)

    assert {:ok, session, {:output_text_delta, "second turn only"}} =
             XaiRealtime.recv(session, 1_000)

    assert {:ok, _session, {:turn_done, %{text: "second turn only"}}} =
             XaiRealtime.recv(session, 1_000)
  end

  test "recv/2 timeout budget is one absolute deadline across unknown-event recursion" do
    key = {__MODULE__, make_ref()}
    Process.put(key, 0)
    advance = fn -> Process.put(key, Process.get(key) + 40) end
    clock_fun = fn -> Process.get(key) end

    frames = [
      %{"type" => "input_audio_buffer.committed"},
      %{"type" => "response.created"},
      %{"type" => "unknown.three"}
    ]

    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        transport_opts: [frames: frames, on_recv: advance],
        effect_authorizer: &allow_effect/2,
        oauth_resolver: &stub_resolver/1,
        clock_fun: clock_fun
      )

    assert {:error, :timeout, latest} = XaiRealtime.recv(session, 100)
    assert latest.transport_state.frames == []
    assert latest.diagnostic_commit
    assert latest.diagnostic_response
    refute latest.diagnostic_transcript
  end

  test "recv/2 accepts :infinity consistently with the backend callback contract" do
    frame = %{"type" => "response.output_text.delta", "delta" => "ready"}

    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        transport_opts: [frames: [frame]],
        effect_authorizer: &allow_effect/2,
        oauth_resolver: &stub_resolver/1
      )

    assert {:ok, _session, {:output_text_delta, "ready"}} =
             XaiRealtime.recv(session, :infinity)
  end

  # ── event-mapping table ──

  test "maps each documented wire event type to its behaviour event, skipping unknown types" do
    frames = [
      %{"type" => "some.unknown.event"},
      %{
        "type" => "conversation.item.input_audio_transcription.completed",
        "transcript" => "hello there"
      },
      %{"type" => "response.output_audio_transcript.delta", "delta" => "Hi "},
      %{"type" => "response.output_text.delta", "delta" => "friend"},
      %{"type" => "response.output_audio.delta", "delta" => Base.encode64(<<1, 2>>)},
      %{"type" => "response.done", "response" => %{"id" => "r1"}},
      %{"type" => "error", "error" => %{"message" => "boom"}}
    ]

    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        transport_opts: [frames: frames],
        effect_authorizer: &allow_effect/2,
        oauth_resolver: &stub_resolver/1
      )

    {:ok, session} = XaiRealtime.configure(session, %{})
    assert {:ok, session, {:input_transcript, "hello there"}} = XaiRealtime.recv(session, 1_000)
    assert {:ok, session, {:output_text_delta, "Hi "}} = XaiRealtime.recv(session, 1_000)
    assert {:ok, session, {:output_text_delta, "friend"}} = XaiRealtime.recv(session, 1_000)
    assert {:ok, session, {:output_audio, <<1, 2>>}} = XaiRealtime.recv(session, 1_000)
    assert {:ok, session, {:turn_done, %{text: "Hi friend"}}} = XaiRealtime.recv(session, 1_000)
    assert {:ok, _session, {:error, %{"message" => "boom"}}} = XaiRealtime.recv(session, 1_000)
  end

  test "runtime provider error diagnostics preserve events and never log private fields" do
    secret = "private-provider-error-message-sentinel"

    cases = [
      {%{
         "code" => "rate_limit_exceeded",
         "param" => "session.audio.output.format.rate",
         "message" => secret
       }, :rate_limit_exceeded, :output_format_rate},
      {%{"code" => secret, "param" => secret, "message" => secret}, :unknown, :unknown},
      {secret, :unknown, :unknown}
    ]

    for {error, code, parameter} <- cases do
      {:ok, session} =
        XaiRealtime.open(
          transport: FakeTransport,
          transport_opts: [frames: [%{"type" => "error", "error" => error}]],
          effect_authorizer: &allow_effect/2,
          oauth_resolver: &stub_resolver/1
        )

      {:ok, session} = XaiRealtime.configure(session, %{})

      log =
        capture_log(fn ->
          assert {:ok, latest, {:error, ^error}} = XaiRealtime.recv(session, 1_000)
          assert :ok = XaiRealtime.close(latest)
        end)

      assert log =~ "stage=provider_runtime_error_code reason=#{code}"
      assert log =~ "stage=provider_runtime_error_parameter reason=#{parameter}"
      refute log =~ secret
      refute log =~ "stub-token"
    end
  end

  test "security regression: runtime error field shapes distinguish missing values without disclosure" do
    secret = "private-error-type-code-param-message-event-id-sentinel"

    cases = [
      {%{"type" => "error"}, :absent, :absent, :unknown, :unknown, :unknown},
      {%{"type" => "error", "error" => nil}, :null, :absent, :unknown, :unknown, :unknown},
      {%{"type" => "error", "error" => secret}, :non_map, :absent, :unknown, :unknown, :unknown},
      {%{"type" => "error", "error" => %{}}, :map, :absent, :unknown, :unknown, :unknown},
      {%{"type" => "error", "error" => %{"type" => nil, "code" => nil, "param" => nil}}, :map,
       :null, :unknown, :unknown, :unknown},
      {%{
         "type" => "error",
         "error" => %{"type" => "server_error", "param" => nil, "message" => secret}
       }, :map, %{type: :binary, code: :absent, parameter: :null}, :server_error, :unknown,
       :unknown},
      {%{"type" => "error", "error" => %{"type" => secret, "code" => secret, "param" => secret}},
       :map, :binary, :unknown, :unknown, :unknown},
      {%{
         "type" => "error",
         "error" => %{"type" => %{private: secret}, "code" => [secret], "param" => {secret}}
       }, :map, :nonbinary, :unknown, :unknown, :unknown},
      {%{
         "type" => "error",
         "error" => %{
           "type" => "server_error",
           "code" => "server_error",
           "param" => "session.audio.input",
           "message" => secret,
           "event_id" => secret
         }
       }, :map, :binary, :server_error, :server_error, :input_audio},
      {%{
         "type" => "error",
         "error" => %{
           "type" => "invalid_request_error",
           "code" => "rate_limit_exceeded",
           "param" => "session.audio.output"
         }
       }, :map, :binary, :invalid_request, :rate_limit_exceeded, :output_audio}
    ]

    for {frame, envelope, shape, type, code, parameter} <- cases do
      session = runtime_script([frame])
      error = frame["error"]

      log =
        capture_log(fn ->
          assert {:ok, latest, {:error, ^error}} = XaiRealtime.recv(session, 1_000)
          assert latest.transport_state.frames == []
          assert :ok = XaiRealtime.close(latest)
        end)

      assert log =~ "stage=provider_runtime_error_envelope reason=#{envelope}"

      for field <- [:type, :code, :parameter] do
        field_shape = if is_map(shape), do: Map.fetch!(shape, field), else: shape
        assert log =~ "stage=provider_runtime_error_#{field}_shape reason=#{field_shape}"
      end

      assert log =~ "stage=provider_runtime_error_type reason=#{type}"
      assert log =~ "stage=provider_runtime_error_code reason=#{code}"
      assert log =~ "stage=provider_runtime_error_parameter reason=#{parameter}"
      refute log =~ secret
      refute log =~ "stub-token"
    end
  end

  test "runtime rejection reports observed milestones and last successful effect without changing frames" do
    secret = "private-audio-transcript-tool-output-sentinel"
    error = %{"type" => "server_error", "message" => secret}
    error_frame = %{"type" => "error", "error" => error}
    commit = %{"type" => "input_audio_buffer.committed", "item_id" => secret}

    transcript = %{
      "type" => "conversation.item.input_audio_transcription.completed",
      "transcript" => secret
    }

    response = %{"type" => "response.created", "response" => %{"id" => secret}}

    for {frames, consume_transcript?, send_result?, commit_seen, transcript_seen, response_seen} <-
          [
            {[error_frame], false, false, :not_observed, :not_observed, :not_observed},
            {[commit, error_frame], false, false, :observed, :not_observed, :not_observed},
            {[commit, transcript, response, error_frame], true, true, :observed, :observed,
             :observed}
          ] do
      session = runtime_script(frames)
      assert {:ok, session} = XaiRealtime.send_audio(session, <<0, 0>>)
      [_, append, commit_frame, create] = session.transport_state.sent
      assert append == %{"type" => "input_audio_buffer.append", "audio" => "AAA="}
      assert commit_frame == %{"type" => "input_audio_buffer.commit"}
      assert create == %{"type" => "response.create"}

      session =
        if consume_transcript? do
          assert {:ok, latest, {:input_transcript, ^secret}} = XaiRealtime.recv(session, 1_000)
          latest
        else
          session
        end

      session =
        if send_result? do
          assert {:ok, latest} = XaiRealtime.send_tool_result(session, secret, secret)
          assert {:ok, latest} = XaiRealtime.request_response(latest)

          assert Enum.take(latest.transport_state.sent, -2) == [
                   %{
                     "type" => "conversation.item.create",
                     "item" => %{
                       "type" => "function_call_output",
                       "call_id" => secret,
                       "output" => secret
                     }
                   },
                   %{"type" => "response.create"}
                 ]

          latest
        else
          session
        end

      log =
        capture_log(fn ->
          assert {:ok, latest, {:error, ^error}} = XaiRealtime.recv(session, 1_000)
          # A new physical input starts new observations even on a reused backend.
          assert {:ok, reused} = XaiRealtime.send_audio(latest, <<0, 0>>)
          refute reused.diagnostic_commit
          refute reused.diagnostic_transcript
          refute reused.diagnostic_response
          assert :ok = XaiRealtime.close(reused)
        end)

      effect = if send_result?, do: :tool_result_response, else: :audio_response
      assert log =~ "stage=provider_runtime_last_effect reason=#{effect}"
      assert log =~ "stage=provider_runtime_commit_seen reason=#{commit_seen}"
      assert log =~ "stage=provider_runtime_transcript_seen reason=#{transcript_seen}"
      assert log =~ "stage=provider_runtime_response_seen reason=#{response_seen}"
      refute log =~ secret
      refute log =~ "stub-token"
    end
  end

  defp tool_call_frame(call_id, name) do
    %{
      "type" => "response.function_call_arguments.done",
      "call_id" => call_id,
      "name" => name,
      "arguments" => Jason.encode!(%{"task" => name})
    }
  end

  defp function_output_frame(call_id, output) do
    %{
      "type" => "conversation.item.create",
      "item" => %{
        "type" => "function_call_output",
        "call_id" => call_id,
        "output" => output
      }
    }
  end

  defp runtime_script(frames) do
    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        transport_opts: [frames: frames],
        effect_authorizer: &allow_effect/2,
        oauth_resolver: &stub_resolver/1
      )

    {:ok, session} = XaiRealtime.configure(session, %{})
    session
  end

  # ── close/1 ──

  test "close/1 is idempotent" do
    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        transport_opts: [frames: []],
        effect_authorizer: &allow_effect/2,
        oauth_resolver: &stub_resolver/1
      )

    assert :ok = XaiRealtime.close(session)
    assert :ok = XaiRealtime.close(session)
  end
end
