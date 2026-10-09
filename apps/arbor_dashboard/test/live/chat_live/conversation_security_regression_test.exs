defmodule Arbor.Dashboard.Live.ChatLive.ConversationSecurityRegressionTest do
  use Arbor.Dashboard.ConnCase, async: false

  # Retained ChatLive behavior uses a test-only endpoint; production /chat redirects.
  @endpoint Arbor.Dashboard.Test.LegacyChatEndpoint
  setup do
    Arbor.Dashboard.Test.LegacyChatFixture.start!()
  end

  alias Arbor.Dashboard.Components.VoiceDeskComponent
  alias Arbor.Dashboard.Live.ChatLive
  alias Arbor.Dashboard.Live.ChatLive.Conversation
  import Phoenix.Component, only: [assign: 2]

  @moduletag :fast

  defmodule ConversationAPI do
    def conversation_history(caller, target, opts) do
      invoke(:history, caller, target, opts, fn state ->
        after_cursor = Keyword.fetch!(opts, :after)
        entries = if after_cursor == 0, do: [state.entry], else: []

        {:ok,
         %{
           entries: entries,
           cursor: 61,
           head: 61,
           has_more: false,
           engagement_id: state.engagement_id
         }}
      end)
    end

    def conversation_events(caller, target, cursor, opts) do
      invoke(:events, caller, target, {cursor, opts}, fn state ->
        {:ok,
         %{
           events: state.events,
           cursor: 9,
           head: 9,
           has_more: false,
           engagement_id: state.journal_engagement_id || state.engagement_id
         }}
      end)
    end

    def submit_conversation_command(caller, target, command, opts) do
      invoke(:submit, caller, target, {command, opts}, fn state ->
        case state.submit_result do
          :admitted ->
            {:ok,
             Map.merge(command, %{
               status: :admitted,
               updated_cursor: 10,
               engagement_id: state.engagement_id
             })}

          result ->
            result
        end
      end)
    end

    def conversation_command(caller, target, id, opts) do
      invoke(:command, caller, target, {id, opts}, fn state -> state.lookup end)
    end

    defp invoke(operation, caller, target, opts, callback) do
      {pid, owner} = Application.fetch_env!(:arbor_dashboard, :conversation_test)
      send(owner, {:conversation_api, operation, caller, target, opts})
      state = Agent.get(pid, & &1)
      options = if is_tuple(opts), do: elem(opts, 1), else: opts
      expected = Keyword.get(options, :expected_engagement_id)

      cond do
        not state.allowed -> {:error, :unauthorized}
        expected && expected != state.engagement_id -> {:error, :conversation_scope_changed}
        true -> callback.(state)
      end
    end
  end

  defmodule VoiceAPI do
    def desk_recording_options do
      {state, _owner} = Application.fetch_env!(:arbor_dashboard, :conversation_test)

      Agent.get(
        state,
        &Map.get(
          &1,
          :voice_recording_options,
          {:ok, %{default_ms: 10_000, min_ms: 100, max_ms: 30_000}}
        )
      )
    end

    def start_desk_turn(user, agent, opts) do
      {_state, owner} = Application.fetch_env!(:arbor_dashboard, :conversation_test)
      send(owner, {:voice_start, user, agent, opts})
      {:ok, String.duplicate("v", 43)}
    end

    def desk_turn_status(_id) do
      {state, _owner} = Application.fetch_env!(:arbor_dashboard, :conversation_test)
      Agent.get(state, &Map.get(&1, :voice_status, {:ok, %{terminal: false, state: :capture}}))
    end

    def finish_desk_turn(id) do
      {state, owner} = Application.fetch_env!(:arbor_dashboard, :conversation_test)
      send(owner, {:voice_finish, id})

      Agent.update(
        state,
        &Map.put(
          &1,
          :voice_status,
          {:ok, %{terminal: false, state: :finishing, can_finish: false}}
        )
      )

      :ok
    end

    def cancel_desk_turn(id) do
      {_state, owner} = Application.fetch_env!(:arbor_dashboard, :conversation_test)
      send(owner, {:voice_cancel, id})
      {:error, :cleanup_pending}
    end
  end

  defmodule MultimediaAPI do
    def request_microphone_permission do
      {_state, owner} = Application.fetch_env!(:arbor_dashboard, :conversation_test)
      send(owner, :microphone_permission_requested)
      :authorized
    end
  end

  setup do
    keys = [:conversation_api, :conversation_test]
    previous = Map.new(keys, &{&1, Application.fetch_env(:arbor_dashboard, &1)})
    secret = Application.fetch_env(:arbor_security, :session_token_secret)

    Application.put_env(
      :arbor_security,
      :session_token_secret,
      "isolated-dashboard-proof-secret-32"
    )

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             allowed: true,
             engagement_id: "eng_11111111111111111111111111111111",
             journal_engagement_id: nil,
             entry: %{
               id: "owned-history",
               role: "user",
               content: "owned private text",
               timestamp: ~U[2026-09-27 12:00:00Z],
               entry_ordinal: 61
             },
             events: [],
             submit_result: :admitted,
             lookup: {:error, :not_found}
           }
         end}
      )

    Application.put_env(:arbor_dashboard, :conversation_api, ConversationAPI)
    Application.put_env(:arbor_dashboard, :conversation_test, {state, self()})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore_env(:arbor_dashboard, key, value) end)
      restore_env(:arbor_security, :session_token_secret, secret)
    end)

    %{state: state}
  end

  test "security regression: real LiveView uses scoped history and durable admission with socket proof",
       %{conn: conn} do
    conn =
      Plug.Test.init_test_session(conn, %{"agent_id" => "human_ui", "session_token" => "proof"})

    {:ok, view, html} = live(conn, "/chat?agent_id=agent_ui")
    assert html =~ "owned private text"
    refute html =~ ~s(value="proof")

    assert_received {:conversation_api, :history, "human_ui", "agent_ui", opts}
    assert opts[:session_token] == "proof"

    render_submit(view, "send-message", %{
      "message" => "durable draft",
      "command_id" => "ui-request-1"
    })

    assert_received {:conversation_api, :submit, "human_ui", "agent_ui", {command, opts}}
    assert command == %{id: "ui-request-1", text: "durable draft"}
    assert opts[:session_token] == "proof"
    assert opts[:expected_engagement_id] == "eng_11111111111111111111111111111111"
    assert render(view) =~ "Message admitted"
  end

  test "security regression: local voice control uses socket proof and exact existing conversation",
       %{conn: conn} do
    enable_voice()
    conn = voice_connection(conn)

    conn =
      Plug.Test.init_test_session(conn, %{"agent_id" => "human_ui", "session_token" => "proof"})

    {:ok, view, html} = live(conn, "/chat?agent_id=agent_ui")
    assert html =~ "Local voice check"
    refute_received {:voice_start, _, _, _}
    refute_received :microphone_permission_requested

    render_click(view, "voice:loopback", %{
      "user" => "human_attacker",
      "session_token" => "forged",
      "duration_ms" => "30000"
    })

    assert_received {:voice_start, "human_ui", "agent_ui", opts}
    assert opts[:session_token] == "proof"
    assert opts[:mode] == :loopback
    assert opts[:duration_ms] == 10_000
    assert opts[:expected_engagement_id] == "eng_11111111111111111111111111111111"
    refute render(view) =~ ~s(value="proof")
    assert has_element?(view, "#voice-desk button[phx-click='voice:talk'][disabled]")
  end

  test "voice cue waits for sample delivery before telling the user to speak", %{
    conn: conn,
    state: state
  } do
    enable_voice()

    Agent.update(
      state,
      &Map.put(
        &1,
        :voice_status,
        {:ok, %{terminal: false, state: :preparing_capture, can_finish: true}}
      )
    )

    conn =
      conn
      |> voice_connection()
      |> Plug.Test.init_test_session(%{"agent_id" => "human_ui", "session_token" => "proof"})

    {:ok, view, _} = live(conn, "/chat?agent_id=agent_ui")
    render_click(view, "voice:talk", %{})
    id = String.duplicate("v", 43)
    send(view.pid, {:voice_desk_poll, id})
    assert render(view) =~ "Starting microphone—wait to speak."
    refute render(view) =~ "speak now"
    assert has_element?(view, "#voice-desk button[phx-click='voice:finish']")

    Agent.update(
      state,
      &Map.put(&1, :voice_status, {:ok, %{terminal: false, state: :capture, can_finish: true}})
    )

    send(view.pid, {:voice_desk_poll, id})
    assert render(view) =~ "speak now"
  end

  test "voice duration uses operator settings, preserves exact milliseconds, and persists across turns",
       %{conn: conn, state: state} do
    enable_voice()

    Agent.update(
      state,
      &Map.put(
        &1,
        :voice_recording_options,
        {:ok, %{default_ms: 4_500, min_ms: 1_001, max_ms: 12_999}}
      )
    )

    conn =
      conn
      |> voice_connection()
      |> Plug.Test.init_test_session(%{"agent_id" => "human_ui", "session_token" => "proof"})

    {:ok, view, _} = live(conn, "/chat?agent_id=agent_ui")
    assert has_element?(view, "#voice-duration[value='4.5'][min='1.001'][max='12.999']")

    view |> form("#voice-duration-form", %{"seconds" => "7.501"}) |> render_change()
    render_click(view, "voice:talk", %{})
    assert_received {:voice_start, "human_ui", "agent_ui", first}
    assert first[:duration_ms] == 7_501

    # A forged change while capture owns the device cannot change this turn or
    # the user's saved choice. The status names the actual admitted duration.
    render_change(view, "voice:duration", %{"seconds" => "2"})
    send(view.pid, {:voice_desk_poll, String.duplicate("v", 43)})
    assert render(view) =~ "Recording for 7.501 seconds"
    assert has_element?(view, "#voice-duration[value='7.501'][disabled]")

    Agent.update(
      state,
      &Map.put(
        &1,
        :voice_status,
        {:ok, %{terminal: true, state: :complete, mode: :conversation, error: nil, result: %{}}}
      )
    )

    send(view.pid, {:voice_desk_poll, String.duplicate("v", 43)})
    assert render(view) =~ "Voice turn complete"
    assert has_element?(view, "#voice-duration[value='7.501']:not([disabled])")
    render_click(view, "voice:loopback", %{})
    assert_received {:voice_start, "human_ui", "agent_ui", second}
    assert second[:duration_ms] == 7_501
    assert second[:mode] == :loopback
  end

  test "voice duration rejects malformed and out-of-range input before recording", %{conn: conn} do
    enable_voice()

    conn =
      conn
      |> voice_connection()
      |> Plug.Test.init_test_session(%{"agent_id" => "human_ui", "session_token" => "proof"})

    {:ok, view, _} = live(conn, "/chat?agent_id=agent_ui")

    for value <- [
          "",
          "0.099",
          "30.001",
          "-1",
          "1e1",
          "1.0001",
          "NaN",
          %{},
          String.duplicate("1", 100)
        ] do
      render_change(view, "voice:duration", %{"seconds" => value})
      assert has_element?(view, "#voice-duration[aria-invalid='true']")
      assert has_element?(view, "#voice-desk button[phx-click='voice:talk'][disabled]")
      render_click(view, "voice:talk", %{})
      refute_received {:voice_start, _, _, _}
    end

    render_change(view, "voice:duration", %{"seconds" => "0.1"})
    render_click(view, "voice:loopback", %{})
    assert_received {:voice_start, "human_ui", "agent_ui", opts}
    assert opts[:duration_ms] == 100
  end

  test "voice duration rechecks operator limits immediately before starting", %{
    conn: conn,
    state: state
  } do
    enable_voice()

    conn =
      conn
      |> voice_connection()
      |> Plug.Test.init_test_session(%{"agent_id" => "human_ui", "session_token" => "proof"})

    {:ok, view, _} = live(conn, "/chat?agent_id=agent_ui")
    assert has_element?(view, "#voice-duration[value='10']")

    Agent.update(
      state,
      &Map.put(
        &1,
        :voice_recording_options,
        {:ok, %{default_ms: 3_000, min_ms: 100, max_ms: 5_000}}
      )
    )

    render_click(view, "voice:talk", %{})
    refute_received {:voice_start, _, _, _}
    assert has_element?(view, "#voice-duration[value='10'][max='5'][aria-invalid='true']")
    assert render(view) =~ "Choose a recording length from 0.1 to 5 seconds."

    render_change(view, "voice:duration", %{"seconds" => "5"})
    render_click(view, "voice:talk", %{})
    assert_received {:voice_start, "human_ui", "agent_ui", opts}
    assert opts[:duration_ms] == 5_000
  end

  test "unavailable voice duration policy disables recording without requesting devices",
       %{conn: conn, state: state} do
    enable_voice()
    Agent.update(state, &Map.put(&1, :voice_recording_options, {:error, :invalid_config}))

    conn =
      conn
      |> voice_connection()
      |> Plug.Test.init_test_session(%{"agent_id" => "human_ui", "session_token" => "proof"})

    {:ok, view, _} = live(conn, "/chat?agent_id=agent_ui")
    assert render(view) =~ "Recording settings are unavailable"
    assert has_element?(view, "#voice-desk button[phx-click='voice:talk'][disabled]")
    render_click(view, "voice:talk", %{})
    refute_received {:voice_start, _, _, _}
    refute_received :microphone_permission_requested
  end

  test "security regression: remote browser cannot request host microphone or start capture", %{
    conn: conn
  } do
    enable_voice()
    conn = voice_connection(conn, {203, 0, 113, 8})

    conn =
      Plug.Test.init_test_session(conn, %{"agent_id" => "human_ui", "session_token" => "proof"})

    {:ok, view, html} = live(conn, "/chat?agent_id=agent_ui")
    refute html =~ "Local voice check"
    render_click(view, "voice:talk", %{})
    render_click(view, "voice:request-permission", %{})
    refute_received {:voice_start, _, _, _}
    refute_received :microphone_permission_requested
  end

  test "security regression: revoked chat authority blocks even explicit permission and recording",
       %{conn: conn, state: state} do
    enable_voice()
    conn = voice_connection(conn)

    conn =
      Plug.Test.init_test_session(conn, %{"agent_id" => "human_ui", "session_token" => "proof"})

    {:ok, view, _} = live(conn, "/chat?agent_id=agent_ui")
    Agent.update(state, &%{&1 | allowed: false})
    render_click(view, "voice:talk", %{})
    render_click(view, "voice:request-permission", %{})
    refute_received {:voice_start, _, _, _}
    refute_received :microphone_permission_requested
  end

  test "voice finish is advertised only by active status and invokes the public control", %{
    conn: conn,
    state: state
  } do
    enable_voice()

    conn =
      conn
      |> voice_connection()
      |> Plug.Test.init_test_session(%{"agent_id" => "human_ui", "session_token" => "proof"})

    {:ok, view, _} = live(conn, "/chat?agent_id=agent_ui")
    render_click(view, "voice:talk", %{})
    id = String.duplicate("v", 43)
    refute has_element?(view, "#voice-desk button[phx-click='voice:finish']")

    Agent.update(
      state,
      &Map.put(&1, :voice_status, {:ok, %{terminal: false, state: :capture, can_finish: true}})
    )

    send(view.pid, {:voice_desk_poll, id})
    assert render(view) =~ "Finish and send"
    render_click(view, "voice:finish", %{})
    assert_received {:voice_finish, ^id}
    refute has_element?(view, "#voice-desk button[phx-click='voice:finish']")
    assert render(view) =~ "Finishing recording and closing the microphone"
    assert has_element?(view, "#voice-desk button[phx-click='voice:cancel']")
  end

  test "security regression: finishing voice rechecks current conversation authority", %{
    conn: conn,
    state: state
  } do
    enable_voice()

    conn =
      conn
      |> voice_connection()
      |> Plug.Test.init_test_session(%{"agent_id" => "human_ui", "session_token" => "proof"})

    {:ok, view, _} = live(conn, "/chat?agent_id=agent_ui")
    render_click(view, "voice:talk", %{})
    id = String.duplicate("v", 43)

    Agent.update(
      state,
      &Map.put(&1, :voice_status, {:ok, %{terminal: false, state: :capture, can_finish: true}})
    )

    send(view.pid, {:voice_desk_poll, id})
    assert render(view) =~ "Finish and send"
    Agent.update(state, &%{&1 | allowed: false})
    render_click(view, "voice:finish", %{})
    refute_received {:voice_finish, _}
    assert_received {:voice_cancel, ^id}
  end

  test "voice completion reloads canonical history without rendering status reply payload", %{
    conn: conn,
    state: state
  } do
    enable_voice()
    conn = voice_connection(conn)

    conn =
      Plug.Test.init_test_session(conn, %{"agent_id" => "human_ui", "session_token" => "proof"})

    {:ok, view, _} = live(conn, "/chat?agent_id=agent_ui")
    render_click(view, "voice:talk", %{})

    Agent.update(
      state,
      &Map.put(
        &1,
        :voice_status,
        {:ok,
         %{
           terminal: true,
           state: :complete,
           mode: :conversation,
           error: nil,
           result: %{reply: "unscoped-status-reply"}
         }}
      )
    )

    send(view.pid, {:voice_desk_poll, String.duplicate("v", 43)})
    html = render(view)
    assert html =~ "Voice turn complete"
    refute html =~ "unscoped-status-reply"
    refute has_element?(view, "#voice-desk button[phx-click='voice:talk'][disabled]")
  end

  test "security regression: revoked terminal result cannot be presented as successful completion",
       %{conn: conn, state: state} do
    enable_voice()

    conn =
      conn
      |> voice_connection()
      |> Plug.Test.init_test_session(%{"agent_id" => "human_ui", "session_token" => "proof"})

    {:ok, view, _} = live(conn, "/chat?agent_id=agent_ui")
    render_click(view, "voice:talk", %{})

    Agent.update(
      state,
      &Map.put(
        &1,
        :voice_status,
        {:ok,
         %{
           terminal: true,
           state: :complete,
           mode: :conversation,
           result: nil,
           error: :conversation_unauthorized
         }}
      )
    )

    send(view.pid, {:voice_desk_poll, String.duplicate("v", 43)})
    html = render(view)
    assert html =~ "Conversation access changed"
    refute html =~ "Voice turn complete"
    refute has_element?(view, "#voice-desk button[phx-click='voice:talk'][disabled]")
  end

  test "security regression: lost scope retains disabled controls until positive desk termination",
       %{state: state} do
    enable_voice()
    id = String.duplicate("v", 43)

    socket =
      socket()
      |> VoiceDeskComponent.mount(%{address: {127, 0, 0, 1}}, %URI{host: "localhost"}, [])
      |> Conversation.refresh()
      |> assign(
        voice_operation: %{id: id, user: "human_old", agent: "agent_ui", engagement: "old"}
      )

    pending = VoiceDeskComponent.poll(socket, id)
    assert pending.assigns.voice_operation.retiring
    assert_received {:voice_cancel, ^id}
    still_pending = VoiceDeskComponent.poll(pending, id)
    assert still_pending.assigns.voice_operation != nil

    Agent.update(
      state,
      &Map.put(&1, :voice_status, {:ok, %{terminal: true, state: :cancelled, error: :cancelled}})
    )

    closed = VoiceDeskComponent.poll(still_pending, id)
    assert closed.assigns.voice_operation == nil
  end

  test "security regression: a loopback proxy forwarding remote traffic cannot expose host audio",
       %{conn: conn} do
    enable_voice()
    conn = voice_connection(conn, {127, 0, 0, 1}, [{"x-forwarded-for", "203.0.113.8"}])

    conn =
      Plug.Test.init_test_session(conn, %{"agent_id" => "human_ui", "session_token" => "proof"})

    {:ok, view, html} = live(conn, "/chat?agent_id=agent_ui")
    refute html =~ "Local voice check"
    render_click(view, "voice:talk", %{})
    refute_received {:voice_start, _, _, _}
  end

  test "security regression: missing or negative transport evidence denies voice but preserves chat",
       %{conn: conn} do
    enable_voice()

    for headers <- [[], [{"x-arbor-voice-direct", "false"}]] do
      connection =
        conn
        |> Plug.Conn.put_private(:live_view_connect_info, %{
          peer_data: %{address: {127, 0, 0, 1}},
          uri: %URI{host: "localhost"},
          x_headers: headers
        })
        |> Plug.Test.init_test_session(%{"agent_id" => "human_ui", "session_token" => "proof"})

      {:ok, view, html} = live(connection, "/chat?agent_id=agent_ui")
      assert html =~ "owned private text"
      refute html =~ "Local voice check"
      render_click(view, "voice:talk", %{})
      render_click(view, "voice:request-permission", %{})
      refute_received {:voice_start, _, _, _}
      refute_received :microphone_permission_requested
    end
  end

  defp voice_connection(conn, address \\ {127, 0, 0, 1}, headers \\ []) do
    Plug.Conn.put_private(conn, :live_view_connect_info, %{
      peer_data: %{address: address},
      uri: %URI{host: "localhost"},
      x_headers: [{"x-arbor-voice-direct", "true"} | headers]
    })
  end

  defp enable_voice do
    for {key, value} <- [
          voice_api: VoiceAPI,
          multimedia_api: MultimediaAPI,
          local_voice_controls: true
        ] do
      previous = Application.fetch_env(:arbor_dashboard, key)
      on_exit(fn -> restore_env(:arbor_dashboard, key, previous) end)
      Application.put_env(:arbor_dashboard, key, value)
    end
  end

  test "security regression: missing forged expired and foreign proof cannot use direct query fallback" do
    Application.put_env(:arbor_dashboard, :conversation_api, Arbor.Agent)
    {:ok, expired} = Arbor.Security.SessionToken.generate_expired_fixture("human_ui")
    {:ok, foreign} = Arbor.Security.SessionToken.generate("human_someone_else")

    for proof <- [nil, "forged", expired, foreign] do
      socket = socket(proof)

      socket =
        Phoenix.LiveView.stream_insert(socket, :messages, %{
          id: "old",
          role: :user,
          content: "cached private"
        })

      {:noreply, result} =
        ChatLive.handle_event(
          "send-message",
          %{
            "message" => "must not dispatch",
            "command_id" => "proof-regression"
          },
          socket
        )

      refute result.assigns.conversation_authorized
      assert result.assigns.error =~ "Sign in"
      assert result.assigns.streams.messages.reset?
      assert result.assigns.streams.messages.inserts == []
      assert result.assigns.input == ""
      refute_receive {:"$gen_call", _, {:query, _, _}}, 10
    end
  end

  test "security regression: revoked access clears cached transcript and all private panels", %{
    state: state
  } do
    socket = Conversation.refresh(socket())
    assert socket.assigns.conversation_authorized

    socket =
      assign(socket, streaming_text: "foreign stream", last_llm_thinking: "private thought")

    Agent.update(state, &%{&1 | allowed: false})
    {:noreply, result} = ChatLive.handle_info(:refresh_conversation, socket)

    refute result.assigns.conversation_authorized
    assert result.assigns.streaming_text == ""
    assert result.assigns.last_llm_thinking == nil

    for name <- [:messages, :thinking, :memories, :actions, :approvals] do
      assert result.assigns.streams[name].reset?
      assert result.assigns.streams[name].inserts == []
    end

    assert result.assigns.error =~ "Sign in"
  end

  test "security regression: agent-wide and stale query payloads cannot populate private chat" do
    socket = socket()

    for type <- [:stream_delta, :chat_message, :notification, :recalled] do
      signal = %{
        category: :agent,
        type: type,
        data: %{
          agent_id: "agent_ui",
          text: "foreign secret",
          content: "foreign secret",
          source: :turn
        }
      }

      assert {:noreply, ^socket} = ChatLive.handle_info({:signal_received, signal}, socket)
    end

    assert {:noreply, ^socket} =
             ChatLive.handle_info({:query_result, :arbor, {:ok, %{text: "stale secret"}}}, socket)
  end

  test "history and journal cursors stay independent and transcript does not settle delivery", %{
    state: state
  } do
    socket = socket() |> Conversation.submit("draft", "original-id") |> Conversation.refresh()
    assert socket.assigns.conversation_history_cursor == 61
    assert socket.assigns.conversation_journal_cursor == 9
    assert socket.assigns.conversation_pending == %{id: "original-id", text: "draft"}

    drain_api_messages()
    {:noreply, next} = ChatLive.handle_info(:refresh_conversation, socket)
    assert_received {:conversation_api, :history, _, _, history_opts}
    assert history_opts[:session_token] == "proof"
    assert history_opts[:after] == 61
    assert history_opts[:expected_engagement_id] == "eng_11111111111111111111111111111111"
    assert_received {:conversation_api, :events, _, _, {9, event_opts}}
    assert event_opts[:expected_engagement_id] == "eng_11111111111111111111111111111111"
    assert next.assigns.conversation_status == :admitted

    Agent.update(
      state,
      &%{
        &1
        | events: [
            %{
              command: %{
                id: "original-id",
                text: "draft",
                status: :completed,
                updated_cursor: 12,
                engagement_id: "eng_11111111111111111111111111111111"
              }
            }
          ]
      }
    )

    next = next |> assign(input: "a newer draft") |> Conversation.refresh()
    assert next.assigns.conversation_pending == nil
    assert next.assigns.input == "a newer draft"
  end

  test "uncertain submission keeps exact ID and text; reconnect only reads receipt", %{
    state: state
  } do
    Agent.update(state, &%{&1 | submit_result: {:error, :conversation_unavailable}})
    socket = socket() |> assign(input: "draft") |> Conversation.submit("draft", "stable-id")
    assert socket.assigns.input == "draft"
    assert socket.assigns.conversation_pending == %{id: "stable-id", text: "draft"}

    assert_received {:conversation_api, :submit, _, _, {%{id: "stable-id", text: "draft"}, _}}
    restored = Conversation.restore(socket(), %{"id" => "stable-id", "text" => "draft"})
    assert restored.assigns.conversation_pending.id == "stable-id"
    assert_received {:conversation_api, :command, _, _, {"stable-id", _}}
    refute_received {:conversation_api, :submit, _, _, _}

    Conversation.retry(restored)
    assert_received {:conversation_api, :submit, _, _, {%{id: "stable-id", text: "draft"}, _}}
    rejected = Conversation.submit(restored, "different draft", "different-id")
    assert rejected.assigns.error =~ "previous delivery"
    refute_received {:conversation_api, :submit, _, _, _}
  end

  test "security regression: ownership change detaches cached transcript and outbox until explicit reconnect",
       %{state: state} do
    socket =
      socket()
      |> assign(input: "old private draft")
      |> Conversation.submit("old private draft", "old-scope-id")

    assert_received {:conversation_api, :submit, _, _, _}

    Agent.update(state, fn current ->
      %{
        current
        | engagement_id: "eng_22222222222222222222222222222222",
          entry: %{current.entry | id: "new-history", content: "new owner history"}
      }
    end)

    {:noreply, changed} = ChatLive.handle_event("conversation:retry", %{}, socket)
    assert changed.assigns.conversation_rebind_required
    assert changed.assigns.conversation_pending == nil
    assert changed.assigns.input == ""
    assert changed.assigns.streams.messages.inserts == []
    assert changed.assigns.streams.messages.reset?
    refute_received {:conversation_api, :submit, _, _, _}

    assert {:noreply, ^changed} = ChatLive.handle_info(:refresh_conversation, changed)
    {:noreply, rebound} = ChatLive.handle_event("conversation:reconnect", %{}, changed)
    assert rebound.assigns.conversation_authorized
    assert rebound.assigns.conversation_engagement_id == "eng_22222222222222222222222222222222"
    refute rebound.assigns.conversation_rebind_required
    refute_received {:conversation_api, :submit, _, _, _}
  end

  test "security regression: revoked conversation cannot repopulate approvals from raw interaction or security signal",
       %{state: state} do
    socket = Conversation.refresh(socket())
    assert socket.assigns.conversation_authorized
    Agent.update(state, &%{&1 | allowed: false})
    {:noreply, denied} = ChatLive.handle_info(:refresh_conversation, socket)

    {:ok, interaction} =
      Arbor.Contracts.Comms.Interaction.new(%{
        request_id: "irq_revoked",
        kind: :approval,
        agent_id: "agent_ui",
        user_id: "human_ui",
        description: "private approval after revocation"
      })

    assert {:noreply, ^denied} =
             ChatLive.handle_info({:dashboard_interaction, interaction}, denied)

    assert {:noreply, ^denied} =
             ChatLive.handle_info(
               {:signal_received,
                %{
                  category: :security,
                  type: :authorization_pending,
                  data: %{principal_id: "agent_ui"}
                }},
               denied
             )

    assert {:noreply, ^denied} = ChatLive.handle_info(:refresh_approvals, denied)
    assert denied.assigns.streams.approvals.inserts == []
  end

  test "security regression: mismatched history and journal scopes are never published together",
       %{state: state} do
    Agent.update(state, &%{&1 | journal_engagement_id: "eng_22222222222222222222222222222222"})
    {:noreply, result} = ChatLive.handle_info(:refresh_conversation, socket())
    assert result.assigns.conversation_rebind_required
    refute result.assigns.conversation_authorized
    assert result.assigns.streams.messages.inserts == []
    assert result.assigns.conversation_history_cursor == 0
    assert result.assigns.conversation_journal_cursor == 0
  end

  defp drain_api_messages do
    receive do
      {:conversation_api, _, _, _, _} -> drain_api_messages()
    after
      0 -> :ok
    end
  end

  defp socket(proof \\ "proof") do
    socket = %Phoenix.LiveView.Socket{
      endpoint: Arbor.Dashboard.Endpoint,
      view: ChatLive,
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}},
      assigns: %{__changed__: %{}, current_agent_id: "human_ui", session_token: proof}
    }

    {:ok, socket} = ChatLive.mount(%{}, %{}, socket)
    assign(socket, agent_id: "agent_ui", agent_host_pid: self())
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)

  test "voice completion distinguishes played audio from screen-only presentation", %{
    conn: conn,
    state: state
  } do
    enable_voice()

    conn =
      conn
      |> voice_connection()
      |> Plug.Test.init_test_session(%{"agent_id" => "human_ui", "session_token" => "proof"})

    {:ok, view, _} = live(conn, "/chat?agent_id=agent_ui")

    for {disposition, expected} <- [
          {:played, "The response finished playing through the host speaker."},
          {:screen_only, "The response is on screen; no audio was played."}
        ] do
      render_click(view, "voice:talk", %{})

      Agent.update(
        state,
        &Map.put(
          &1,
          :voice_status,
          {:ok,
           %{
             terminal: true,
             state: :complete,
             mode: :conversation,
             error: nil,
             result: %{disposition: disposition, reply: "private-status-payload"}
           }}
        )
      )

      send(view.pid, {:voice_desk_poll, String.duplicate("v", 43)})
      html = render(view)
      assert html =~ expected
      refute html =~ "private-status-payload"
      refute has_element?(view, "#voice-desk button[phx-click='voice:talk'][disabled]")
    end
  end
end
